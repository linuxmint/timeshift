package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"sync"

	"github.com/makeafide/timeshift/src-go/internal/block"
	"github.com/makeafide/timeshift/src-go/internal/config"
	"github.com/makeafide/timeshift/src-go/internal/distro"
	"github.com/makeafide/timeshift/src-go/internal/engines"
	tsengine "github.com/makeafide/timeshift/src-go/internal/engines/timeshift"
	"github.com/makeafide/timeshift/src-go/internal/ipc"
	"github.com/makeafide/timeshift/src-go/internal/jobs"
	"github.com/makeafide/timeshift/src-go/internal/schedule"
	"github.com/makeafide/timeshift/src-go/internal/sysexec"
)

// daemon holds everything the methods need.
type daemon struct {
	log        *slog.Logger
	configPath string
	runner     *pausableRunner
	queue      *jobs.Queue
	mountRoot  string

	// Parsed rsync logs, kept for paging. See logparse.go.
	logCache *logCache
	tempDir  string

	// ticker owns the schedule. Nil when the daemon runs with scheduling
	// switched off from the command line.
	ticker *schedule.Ticker

	mu  sync.RWMutex
	cfg config.Config
}

func newDaemon(log *slog.Logger, configPath string, cfg config.Config) *daemon {
	return &daemon{
		log:        log,
		configPath: configPath,
		cfg:        cfg,
		runner:     newPausableRunner(sysexec.NewSimple(sysexec.New(log))),
		// Depth 1 beyond the running job. apt-snapshot-guard blocks dpkg while
		// it waits, so a queue that refuses is better than one that grows.
		queue:     jobs.NewQueue(2),
		mountRoot: fmt.Sprintf("/run/timeshift/%d", os.Getpid()),
		logCache:  newLogCache(),
		tempDir:   os.TempDir(),
	}
}

func (d *daemon) config() config.Config {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.cfg
}

// openRepo resolves the configured location and opens it.
//
// Every method that touches the repository opens its own handle and closes it,
// rather than the daemon holding one open. A repository on a removable disk or
// at the end of an SSH link is not a resource worth keeping warm across hours
// of idleness, and a stale handle is worse than a new one.
func (d *daemon) openRepo(ctx context.Context) (engines.Repository, string, string, error) {
	return d.openRepoWith(ctx, d.config())
}

/* openRepoWith opens a repository described by an arbitrary config.
 *
 * The split exists for the CLI's per-run location flags -- --snapshot-device,
 * --snapshot-url, --btrfs, --rsync -- which Vala applies to one invocation
 * without persisting them. Expressing an override as a modified config rather
 * than as a second code path means there is one definition of how a location is
 * resolved, and the override cannot drift from the saved case.
 */
func (d *daemon) openRepoWith(ctx context.Context, cfg config.Config) (engines.Repository, string, string, error) {
	var devices []*block.Device
	if !cfg.Remote() {
		var err error
		if devices, err = (&block.Scanner{Runner: d.runner}).Scan(ctx); err != nil {
			return nil, "", "", err
		}
	}

	loc, deviceName, deviceUUID, err := tsengine.LocationFromConfig(cfg, devices)
	if err != nil {
		return nil, "", "", err
	}

	engine, err := engines.Lookup(cfg.Engine)
	if err != nil {
		return nil, "", "", err
	}

	repository, err := engine.Open(ctx, loc, engines.Deps{
		Runner:    d.runner,
		Log:       d.log,
		TempDir:   d.tempDir,
		MountRoot: d.mountRoot,
	})
	if err != nil {
		return nil, "", "", err
	}

	repository.SetFirstSnapshotSize(cfg.SnapshotSize)
	return repository, deviceName, deviceUUID, nil
}

// reporterAdapter presents the daemon's job Reporter as the engine's.
//
// The two interfaces are identical in shape and deliberately not the same type:
// an engine must not depend on the daemon's job package, or it could reach for
// job state instead of reporting through the one channel it is given.
type reporterAdapter struct{ r jobs.Reporter }

func (a reporterAdapter) SetPhases(phases []engines.Phase) {
	out := make([]jobs.Phase, 0, len(phases))
	for _, p := range phases {
		out = append(out, jobs.Phase{Key: p.Key, Title: p.Title})
	}
	a.r.SetPhases(out)
}

func (a reporterAdapter) Phase(key string) { a.r.Phase(key) }

func (a reporterAdapter) Progress(p engines.Progress) {
	a.r.Progress(jobs.Progress{
		Percent:    p.Percent,
		Count:      p.Count,
		Total:      p.Total,
		ETASeconds: p.ETASeconds,
		StatusLine: p.StatusLine,
		Counters:   p.Counters,
	})
}

func (a reporterAdapter) Log(line string) { a.r.Log(line) }
func (a reporterAdapter) Note(msg string) { a.r.Note(msg) }
func (a reporterAdapter) Warn(msg string) { a.r.Warn(msg) }
func (a reporterAdapter) Cancelled() bool { return a.r.Cancelled() }

// methods builds the dispatch table.
//
// ReadOnly marks what a member of the timeshift group may call. The rule is
// simple: anything that reads is read-only, anything that changes state or the
// repository is root. Watching a backup is reading.
func (d *daemon) methods() map[string]ipc.Method {
	return map[string]ipc.Method{
		ipc.MethodSystemInfo:     {ReadOnly: true, Fn: d.systemInfo},
		ipc.MethodEnginesList:    {ReadOnly: true, Fn: d.enginesList},
		ipc.MethodConfigGet:      {ReadOnly: true, Fn: d.configGet},
		ipc.MethodDevicesList:    {ReadOnly: true, Fn: d.devicesList},
		ipc.MethodRepoStatus:     {ReadOnly: true, Fn: d.repoStatus},
		ipc.MethodSnapshotsList:  {ReadOnly: true, Fn: d.snapshotsList},
		ipc.MethodJobsList:       {ReadOnly: true, Fn: d.jobsList},
		ipc.MethodJobsGet:        {ReadOnly: true, Fn: d.jobsGet},
		ipc.MethodJobsSubscribe:  {ReadOnly: true, Fn: d.jobsSubscribe},
		ipc.MethodScheduleStatus: {ReadOnly: true, Fn: d.scheduleStatus},

		ipc.MethodJobsCancel:      {Fn: d.jobsCancel},
		ipc.MethodJobsPause:       {Fn: d.jobsPause},
		ipc.MethodJobsResume:      {Fn: d.jobsResume},
		ipc.MethodSnapshotCreate:  {Fn: d.snapshotCreate},
		ipc.MethodSnapshotDelete:  {Fn: d.snapshotDelete},
		ipc.MethodEstimateRun:     {Fn: d.estimateRun},
		ipc.MethodConfigSet:       {Fn: d.configSet},
		ipc.MethodSnapshotsUpdate: {Fn: d.snapshotsUpdate},

		/* Browsing is root-only, not part of the group's read-only subset. It
		 * mounts a filesystem and exposes a snapshot's entire contents --
		 * every file on the system as it was -- to a uid the caller names. */
		ipc.MethodSnapshotsBrowse:        {Fn: d.snapshotsBrowse},
		ipc.MethodSnapshotsBrowseRelease: {Fn: d.snapshotsBrowseRelease},

		/* Parsing a log reads a file as root. Root-only, even though the
		 * result is only a list of paths: those paths are every file on the
		 * system, which is more than the group's read-only grant covers. */
		ipc.MethodLogParse:   {Fn: d.logParse},
		ipc.MethodLogEntries: {Fn: d.logEntries},

		/* Unlocking is root-only. It takes a passphrase and produces a device
		 * holding somebody's whole filesystem; a read-only grant does not
		 * stretch to that. */
		ipc.MethodDevicesUnlock: {Fn: d.devicesUnlock},
		ipc.MethodDevicesLock:   {Fn: d.devicesLock},

		/* Provisioning access to a remote repository. Root-only: it writes
		 * /etc/timeshift/ssh, and setup_key carries an account password. */
		ipc.MethodRepoSelect:      {Fn: d.repoSelect},
		ipc.MethodRepoDropMaster:  {Fn: d.repoDropMaster},
		ipc.MethodRepoSSHScanHost: {Fn: d.repoSSHScanHost},
		ipc.MethodRepoSSHSetupKey: {Fn: d.repoSSHSetupKey},
		ipc.MethodRepoSSHTest:     {Fn: d.repoSSHTest},

		/* The recovery environment. status is read-only in spirit but runs a
		 * setuid-adjacent provisioner and reports disk layout, so it stays
		 * root-only with the rest. */
		ipc.MethodRecoveryStatus:  {Fn: d.recoveryStatus},
		ipc.MethodRecoveryEnable:  {Fn: d.recoveryEnable},
		ipc.MethodRecoveryDisable: {Fn: d.recoveryDisable},
		ipc.MethodRecoveryInstall: {Fn: d.recoveryInstall},
		ipc.MethodRepoReload:      {Fn: d.repoReload},

		/* Planning a restore changes nothing, but it is not read-only in the
		 * sense the group grant means: it enumerates every device on the
		 * machine and would let a group member rehearse overwriting the disk.
		 * Root, like the restore it describes. */
		ipc.MethodRestorePlan:     {Fn: d.restorePlan},
		ipc.MethodSnapshotRestore: {Fn: d.snapshotRestore},
		ipc.MethodScheduleCheck:   {Fn: d.scheduleCheck},
	}
}

func (d *daemon) systemInfo(ctx context.Context, c *ipc.Conn, _ json.RawMessage) (any, error) {
	info := ipc.SystemInfo{
		Version:         version,
		ProtocolVersion: ipc.ProtocolVersion,
		Engine:          d.config().Engine,
		ReadOnly:        c.Peer.ReadOnly,
	}
	for _, e := range engines.List() {
		caps := e.Caps()
		info.Engines = append(info.Engines, ipc.EngineInfo{
			ID:          e.ID(),
			DisplayName: e.DisplayName(),
			Caps: ipc.Caps{
				Incremental:  caps.Incremental,
				Remote:       caps.Remote,
				Browse:       caps.Browse,
				UnsharedSize: caps.UnsharedSize,
			},
		})
	}
	if active := d.queue.Active(); active != nil {
		info.ActiveJob = active.ID
	}
	return info, nil
}

func (d *daemon) enginesList(ctx context.Context, c *ipc.Conn, _ json.RawMessage) (any, error) {
	info, err := d.systemInfo(ctx, c, nil)
	if err != nil {
		return nil, err
	}
	return info.(ipc.SystemInfo).Engines, nil
}

func (d *daemon) configGet(context.Context, *ipc.Conn, json.RawMessage) (any, error) {
	return d.config(), nil
}

func (d *daemon) devicesList(ctx context.Context, _ *ipc.Conn, _ json.RawMessage) (any, error) {
	devices, err := (&block.Scanner{Runner: d.runner}).Scan(ctx)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	type wire struct {
		Path      string `json:"path"`
		Name      string `json:"name"`
		UUID      string `json:"uuid"`
		Label     string `json:"label"`
		Type      string `json:"type"`
		FSType    string `json:"fstype"`
		SizeBytes int64  `json:"size_bytes"`
		FreeBytes int64  `json:"free_bytes"`
		Mounted   bool   `json:"mounted"`
	}
	var out []wire
	for _, dev := range devices {
		if !dev.HasLinuxFilesystem() {
			continue
		}
		out = append(out, wire{
			Path: dev.NameWithParent(), Name: dev.Name, UUID: dev.UUID,
			Label: dev.Label, Type: dev.Type, FSType: dev.FSType,
			SizeBytes: dev.SizeBytes, FreeBytes: dev.FreeBytes(),
			Mounted: dev.IsMounted(),
		})
	}
	return out, nil
}

/* repo.status carries the engine's health AND the fields a console header
 * needs to describe the location.
 *
 * Both travel together because `timeshift --list` renders them as one block,
 * and its output is byte-for-byte identical to the Vala binary's. Splitting
 * them across two calls would mean the header could be drawn from two
 * repository states observed a moment apart. */
func (d *daemon) repoStatus(ctx context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {
	var in ipc.RepoStatusParams
	json.Unmarshal(params, &in)

	repo, deviceName, deviceUUID, err := d.openRepoOverridden(ctx, in.Location)
	if err != nil {
		return nil, err
	}
	defer repo.Close()

	st, err := repo.Status(ctx)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	rawView, err := repo.ConsoleStatus(ctx, deviceName, deviceUUID)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}

	return ipc.RepoStatus{
		Code:         int(st.Code),
		Message:      st.Message,
		Details:      st.Details,
		Available:    st.Available,
		HasSnapshots: st.HasSnapshots,
		View:         rawView,
	}, nil
}

func (d *daemon) snapshotsList(ctx context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {
	var in ipc.SnapshotsListParams
	json.Unmarshal(params, &in)

	repo, _, _, err := d.openRepoOverridden(ctx, in.Location)
	if err != nil {
		return nil, err
	}
	defer repo.Close()

	list, err := repo.List(ctx)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	return list, nil
}

func (d *daemon) jobsList(context.Context, *ipc.Conn, json.RawMessage) (any, error) {
	return d.queue.List(), nil
}

func (d *daemon) jobsGet(_ context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {
	var in ipc.JobRefParams
	json.Unmarshal(params, &in)
	job, err := d.queue.Get(in.Job)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeNotFound, "%v", err)
	}
	return job.Snapshot(true), nil
}

// jobsSubscribe is the method the whole daemon exists for.
//
// It returns the job's current state -- phases, counters, log tail -- and then
// streams everything that happens next on the same connection. The subscription
// is registered before the snapshot is taken, so there is no gap between the
// two and a client joining halfway sees exactly what it would have seen from
// the start.
func (d *daemon) jobsSubscribe(_ context.Context, c *ipc.Conn, params json.RawMessage) (any, error) {
	var in ipc.SubscribeParams
	json.Unmarshal(params, &in)

	if in.Job == "" {
		// Follow everything. Used by a status display that wants to notice work
		// starting without knowing its id in advance.
		sub := d.queue.Hub().Subscribe(jobs.SubscribeOptions{WithLog: in.WithLog})
		c.Subscribe(sub)
		return jobs.Snapshot{}, nil
	}

	snap, sub, err := d.queue.Attach(in.Job, in.WithLog)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeNotFound, "%v", err)
	}
	c.Subscribe(sub)
	return snap, nil
}

func (d *daemon) jobsCancel(_ context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {
	var in ipc.JobRefParams
	json.Unmarshal(params, &in)
	job, err := d.queue.Get(in.Job)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeNotFound, "%v", err)
	}
	job.Cancel()
	return job.Snapshot(false), nil
}

/* jobs.pause and jobs.resume suspend the RUNNING job.
 *
 * Only the running one, and that is not a limitation to work around: the queue
 * runs a single mutating job at a time, so a queued job has nothing to suspend,
 * and pausing it would mean "do not start", which is a different thing that
 * nobody has asked for. Refusing is clearer than inventing it.
 *
 * The job keeps the repository write lock while paused. It is mid-write, so
 * that is the only correct answer -- but it does mean a job left paused blocks
 * every other write, which is worth a client saying out loud.
 */
func (d *daemon) jobsPause(_ context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {
	job, err := d.runningJob(params)
	if err != nil {
		return nil, err
	}
	if err := d.runner.Pause(); err != nil {
		return nil, ipc.Errf(ipc.CodeInternal, "could not suspend the job: %v", err)
	}
	job.Pause()
	d.log.Info("job paused", "job", job.ID, "kind", job.Kind)
	return job.Snapshot(false), nil
}

func (d *daemon) jobsResume(_ context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {
	job, err := d.runningJob(params)
	if err != nil {
		return nil, err
	}
	if err := d.runner.Resume(); err != nil {
		return nil, ipc.Errf(ipc.CodeInternal, "could not resume the job: %v", err)
	}
	job.Resume()
	d.log.Info("job resumed", "job", job.ID, "kind", job.Kind)
	return job.Snapshot(false), nil
}

// runningJob resolves the job a pause or resume names, and insists it is the
// one actually running.
func (d *daemon) runningJob(params json.RawMessage) (*jobs.Job, error) {
	var in ipc.JobRefParams
	json.Unmarshal(params, &in)

	job, err := d.queue.Get(in.Job)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeNotFound, "%v", err)
	}
	active := d.queue.Active()
	if active == nil || active.ID != job.ID {
		return nil, ipc.Errf(ipc.CodeBadRequest,
			"job %s is not the running job; only the running job can be paused", job.ID)
	}
	return job, nil
}

func (d *daemon) snapshotCreate(ctx context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {
	var in ipc.CreateParams
	json.Unmarshal(params, &in)

	/* Two apt frontends racing to snapshot should end up watching one job, not
	 * taking two snapshots of the same moment. AppLock could only refuse the
	 * second outright. */
	if in.AttachExisting {
		if active := d.queue.Active(); active != nil && active.Kind == jobs.KindCreate {
			return ipc.JobRef{Job: active.ID, Existing: true}, nil
		}
	}

	tags := in.Tags
	if len(tags) == 0 {
		tags = []string{"ondemand"}
	}

	job, err := d.queue.Submit(jobs.KindCreate, func(ctx context.Context, r jobs.Reporter) (jobs.Outcome, error) {
		return d.runCreate(ctx, r, tags, in.Comments, false)
	})
	if err != nil {
		return nil, ipc.Errf(ipc.CodeBusy, "%v", err)
	}
	return ipc.JobRef{Job: job.ID}, nil
}

func (d *daemon) estimateRun(ctx context.Context, _ *ipc.Conn, _ json.RawMessage) (any, error) {
	job, err := d.queue.Submit(jobs.KindEstimate, func(ctx context.Context, r jobs.Reporter) (jobs.Outcome, error) {
		repo, _, _, err := d.openRepo(ctx)
		if err != nil {
			return jobs.OutcomeFailed, err
		}
		defer repo.Close()

		size, lines, err := repo.Estimate(ctx, engines.EstimateRequest{
			Excludes: d.buildExcludes(),
		}, reporterAdapter{r})
		if err != nil {
			return jobs.OutcomeFailed, err
		}

		r.Note(fmt.Sprintf("Estimated size %d bytes over %d entries", size, lines))

		/* Persist the estimate: it is the progress denominator for the first
		 * real backup, and recomputing it costs a full filesystem walk. */
		d.mu.Lock()
		d.cfg.SnapshotSize = uint64(size)
		d.cfg.SnapshotCount = lines
		cfg := d.cfg
		d.mu.Unlock()
		if err := config.Save(d.configPath, cfg); err != nil {
			r.Warn("Could not save the estimate: " + err.Error())
		}
		return jobs.OutcomeOK, nil
	})
	if err != nil {
		return nil, ipc.Errf(ipc.CodeBusy, "%v", err)
	}
	return ipc.JobRef{Job: job.ID}, nil
}

func (d *daemon) snapshotDelete(ctx context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {
	var in ipc.DeleteParams
	if err := json.Unmarshal(params, &in); err != nil || len(in.Names) == 0 {
		return nil, ipc.Errf(ipc.CodeBadRequest, "no snapshots named")
	}

	job, err := d.queue.Submit(jobs.KindDelete, func(ctx context.Context, r jobs.Reporter) (jobs.Outcome, error) {
		return d.runDelete(ctx, r, in.Names, true)
	})
	if err != nil {
		return nil, ipc.Errf(ipc.CodeBusy, "%v", err)
	}
	return ipc.JobRef{Job: job.ID}, nil
}

// runCreate is the body of a create job.
func (d *daemon) runCreate(ctx context.Context, r jobs.Reporter, tags []string, comments string, dryRun bool) (jobs.Outcome, error) {
	repo, _, _, err := d.openRepo(ctx)
	if err != nil {
		return jobs.OutcomeFailed, err
	}
	defer repo.Close()

	cfg := d.config()

	devices, err := (&block.Scanner{Runner: d.runner}).Scan(ctx)
	if err != nil {
		return jobs.OutcomeFailed, err
	}
	sysRoot := block.MountedAt(devices, "/")
	sysUUID := ""
	if sysRoot != nil {
		sysUUID = sysRoot.UUID
	}

	_, err = repo.Create(ctx, engines.CreateRequest{
		Tags:     tags,
		Comments: comments,
		Excludes: d.buildExcludes(),
		SysUUID:  sysUUID,
		// Recorded so the listing can say which system each snapshot came
		// from, and so a cross-distribution restore knows what it is restoring.
		SysDistro:      distro.Detect("/").FullName(),
		AppVersion:     version,
		DryRun:         dryRun,
		EstimatedLines: cfg.SnapshotCount,
	}, reporterAdapter{r})
	if err != nil {
		return jobs.OutcomeFailed, err
	}
	return jobs.OutcomeOK, nil
}

// buildExcludes assembles the filter list from the configuration and the
// system.
func (d *daemon) buildExcludes() []string {
	cfg := d.config()
	return tsengine.BuildBackupExcludes(tsengine.ExcludeInput{
		UserPatterns: cfg.Exclude,
	})
}

/* runDelete is the body of a delete job, shared by the IPC method and by
 * retention -- which is why it has to be told which it is.
 *
 * explicit means a person named these snapshots. Retention did not, and an
 * automatic deletion may not remove a snapshot that merely reads as invalid:
 * a dropped link makes every remote snapshot read that way. */
func (d *daemon) runDelete(ctx context.Context, r jobs.Reporter, names []string, explicit bool) (jobs.Outcome, error) {
	repo, _, _, err := d.openRepo(ctx)
	if err != nil {
		return jobs.OutcomeFailed, err
	}
	defer repo.Close()

	opts := engines.DeleteOptions{Explicit: explicit}
	if err := repo.Delete(ctx, names, opts, reporterAdapter{r}); err != nil {
		return jobs.OutcomeFailed, err
	}
	return jobs.OutcomeOK, nil
}
