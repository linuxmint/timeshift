package timeshift

import (
	"context"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/engines"
	"github.com/makeafide/timeshift/src-go/internal/fsutil"
	"github.com/makeafide/timeshift/src-go/internal/rsyncx"
)

// NameLayout is the snapshot directory name, which is also its identity
// everywhere including over IPC.
const NameLayout = "2006-01-02_15-04-05"

// PayloadDir is where an rsync snapshot's files live inside its directory.
// btrfs snapshots use "@" and "@home" instead.
const PayloadDir = "localhost"

// CreateRequest describes a snapshot to take.
type CreateRequest struct {
	// Tags are the retention levels this snapshot belongs to.
	Tags []string

	// Comments is the description. apt-snapshot-guard puts the apt command
	// line here.
	Comments string

	// Source is the tree to copy, "/" in every real use.
	Source string

	// Excludes are the filter rules, already ordered by BuildBackupExcludes.
	Excludes []string

	// SysUUID and SysDistro identify the system being snapshotted. A snapshot
	// whose SysUUID differs from the running system's was taken elsewhere and
	// is not a link-dest candidate.
	SysUUID   string
	SysDistro string

	// AppVersion is recorded in the control file.
	AppVersion string

	// DryRun changes nothing on disk. Everything else is identical, which is
	// what makes it a truthful rehearsal.
	DryRun bool

	// EstimatedLines is the progress denominator, from a previous dry run.
	// Zero means the client should show an indeterminate bar.
	EstimatedLines int64
}

// createPhases is the checklist a client draws for a snapshot.
var createPhases = []jobsPhase{
	{Key: "prepare", Title: "Preparing"},
	{Key: "sync_files", Title: "Copying files"},
	{Key: "finalise", Title: "Writing snapshot metadata"},
}

// jobsPhase mirrors jobs.Phase without importing it, so the engine layer does
// not depend on the daemon's job package.
type jobsPhase struct {
	Key   string
	Title string
}

// Phases returns the checklist for a create, in order.
func CreatePhases() []engines.Phase {
	out := make([]engines.Phase, 0, len(createPhases))
	for _, p := range createPhases {
		out = append(out, engines.Phase{Key: p.Key, Title: p.Title})
	}
	return out
}

// Create takes a snapshot.
func (r *Repo) Create(ctx context.Context, req CreateRequest, rep engines.Reporter) (engines.Snapshot, error) {
	rep.SetPhases(CreatePhases())
	rep.Phase("prepare")

	if req.Source == "" {
		req.Source = "/"
	}

	name := time.Now().Format(NameLayout)
	snapDir := path.Join(r.SnapshotsPath(), name)
	payload := path.Join(snapDir, PayloadDir)

	/* The link-dest source: the newest snapshot taken from THIS system. One
	 * from another machine would share almost nothing, and rsync would copy
	 * everything while reporting a successful incremental. */
	linkFrom, err := r.linkDestFor(ctx, req.SysUUID)
	if err != nil {
		return engines.Snapshot{}, err
	}
	if linkFrom != "" {
		rep.Note("Hard-linking unchanged files from " + path.Base(path.Dir(linkFrom)))
	}

	/* rsync opens --exclude-from and --log-file on the CLIENT side. For a
	 * remote repository they must be local files: pointing either inside a
	 * remote snapshot makes rsync warn, ignore it, and still exit 0 -- so the
	 * exclusions would silently not apply. */
	tmp := r.Deps.TempDir
	if tmp == "" {
		tmp = os.TempDir()
	}
	work, err := os.MkdirTemp(tmp, "ts-create-")
	if err != nil {
		return engines.Snapshot{}, fmt.Errorf("timeshift: work dir: %w", err)
	}
	defer os.RemoveAll(work)

	excludeFile := filepath.Join(work, "exclude.list")
	if err := os.WriteFile(excludeFile, []byte(ExcludeFileContents(req.Excludes)), 0644); err != nil {
		return engines.Snapshot{}, fmt.Errorf("timeshift: write exclude list: %w", err)
	}
	logFile := filepath.Join(work, "rsync-log")

	if !req.DryRun {
		if !r.Backend.DirExists(ctx, payload) {
			if err := r.mkdirp(ctx, payload); err != nil {
				return engines.Snapshot{}, err
			}
		}
	}

	rep.Phase("sync_files")

	opts := rsyncx.Options{
		Source:      req.Source,
		Dest:        r.rsyncDest(payload),
		DeleteExtra: true,
		Verbose:     true,
		DryRun:      req.DryRun,
		LinkFrom:    linkFrom,
		LogFile:     logFile,
		ExcludeFrom: excludeFile,
		Remote:      r.Backend.IsRemote(),
	}
	if ssh, ok := r.Backend.(*SSHBackend); ok {
		opts.RSH = strings.Join(append([]string{"ssh"}, ssh.SSHOptions(false, false)...), " ")
		if ssh.FakeSuper {
			opts.RsyncPath = "rsync --fake-super"
		}
	}

	parser := &rsyncx.Parser{Total: req.EstimatedLines, KeepChanges: true}
	code, err := r.runRsync(ctx, opts, parser, rep)
	if err != nil {
		return engines.Snapshot{}, err
	}

	switch {
	case rsyncx.Succeeded(code):
	case rsyncx.Warned(code):
		rep.Warn("Some files could not be transferred: " + rsyncx.ExitMeaning(code))
	default:
		/* A failed transfer leaves a partial snapshot directory. Removing it is
		 * not tidiness: a half-copied tree that looks like a snapshot is the
		 * worst possible thing to restore from. */
		if !req.DryRun {
			r.Backend.Remove(ctx, snapDir)
		}
		return engines.Snapshot{}, fmt.Errorf("timeshift: rsync failed (%d): %s",
			code, rsyncx.ExitMeaning(code))
	}

	if req.DryRun {
		rep.Note(fmt.Sprintf("Dry run: %d entries, %s",
			parser.LineCount, fsutil.FormatSize(uint64(max64(parser.TotalSize, 0)), fsutil.DefaultSizeOpts())))
		return engines.Snapshot{Name: name, Path: snapDir, Created: time.Now()}, nil
	}

	rep.Phase("finalise")

	fileCount, _ := fsutil.LineCount(logFile)

	control := &ControlFile{
		Created:       time.Now(),
		SysUUID:       req.SysUUID,
		SysDistro:     req.SysDistro,
		AppVersion:    req.AppVersion,
		FileCount:     fileCount,
		Tags:          req.Tags,
		Description:   req.Comments,
		Type:          "rsync",
		SizeBytes:     -1, // measured later by a du walk, not guessed here
		UnsharedBytes: -1,
	}
	if err := r.writeFile(ctx, path.Join(snapDir, "info.json"), control.Marshal()); err != nil {
		return engines.Snapshot{}, err
	}

	/* The exclude list travels WITH the snapshot. A restore needs to know what
	 * was left out when it was taken, or --delete would remove those paths from
	 * the target. A snapshot without it is treated as invalid. */
	if err := r.writeFile(ctx, path.Join(snapDir, "exclude.list"),
		[]byte(ExcludeFileContents(req.Excludes))); err != nil {
		return engines.Snapshot{}, err
	}

	if data, err := os.ReadFile(logFile); err == nil {
		r.writeFile(ctx, path.Join(snapDir, "rsync-log"), data)
	}

	return engines.Snapshot{
		Name:          name,
		Path:          snapDir,
		Created:       control.Created,
		Tags:          req.Tags,
		Description:   req.Comments,
		SysUUID:       req.SysUUID,
		SysDistro:     req.SysDistro,
		FileCount:     fileCount,
		SizeBytes:     -1,
		UnsharedBytes: -1,
		Valid:         true,
	}, nil
}

// EstimateRequest describes a dry run used to size the next snapshot.
type EstimateRequest struct {
	Source   string
	Excludes []string
}

// Estimate measures how much a snapshot would transfer, and how many lines it
// would emit -- which is the progress denominator for the real run.
//
// The destination is an empty directory, so every file counts as new: that is
// the point. It measures the whole system, not the delta.
func (r *Repo) Estimate(ctx context.Context, req EstimateRequest, rep engines.Reporter) (int64, int64, error) {
	rep.SetPhases([]engines.Phase{{Key: "estimate", Title: "Estimating system size"}})
	rep.Phase("estimate")

	if req.Source == "" {
		req.Source = "/"
	}

	tmp := r.Deps.TempDir
	if tmp == "" {
		tmp = os.TempDir()
	}
	work, err := os.MkdirTemp(tmp, "ts-estimate-")
	if err != nil {
		return 0, 0, fmt.Errorf("timeshift: work dir: %w", err)
	}
	defer os.RemoveAll(work)

	empty := filepath.Join(work, "empty")
	if err := os.MkdirAll(empty, 0755); err != nil {
		return 0, 0, err
	}
	excludeFile := filepath.Join(work, "exclude.list")
	if err := os.WriteFile(excludeFile, []byte(ExcludeFileContents(req.Excludes)), 0644); err != nil {
		return 0, 0, err
	}

	opts := rsyncx.Options{
		Source:      req.Source,
		Dest:        empty,
		DryRun:      true,
		Verbose:     true,
		ExcludeFrom: excludeFile,
	}

	parser := &rsyncx.Parser{}
	code, err := r.runRsync(ctx, opts, parser, rep)
	if err != nil {
		return 0, 0, err
	}
	if !rsyncx.Succeeded(code) && !rsyncx.Warned(code) {
		return 0, 0, fmt.Errorf("timeshift: estimate failed (%d): %s", code, rsyncx.ExitMeaning(code))
	}

	return max64(parser.TotalSize, 0), parser.LineCount, nil
}

// Delete removes snapshots.
//
// Progress is per line of `rm -rfv` output, which is one line per removed path
// -- the same line-counting contract as a transfer.
func (r *Repo) Delete(ctx context.Context, names []string, rep engines.Reporter) error {
	phases := make([]engines.Phase, 0, len(names))
	for _, n := range names {
		phases = append(phases, engines.Phase{Key: n, Title: "Deleting " + n})
	}
	rep.SetPhases(phases)

	for i, name := range names {
		if rep.Cancelled() {
			return context.Canceled
		}
		rep.Phase(name)

		dir := path.Join(r.SnapshotsPath(), name)
		if !r.Backend.DirExists(ctx, dir) {
			rep.Warn("No such snapshot: " + name)
			continue
		}

		/* Neighbouring snapshots share hard links with this one, so their
		 * recorded sizes stop being true the moment it goes. Clearing the cache
		 * is cheaper and more honest than recomputing here. */
		if err := r.invalidateNeighbourSizes(ctx, name); err != nil {
			rep.Warn("Could not refresh neighbouring snapshot sizes: " + err.Error())
		}

		count := int64(0)
		code, err := r.streamCommand(ctx, r.removeCommand(dir), func(line string) {
			count++
			rep.Log(line)
			rep.Progress(engines.Progress{
				Count:      int64(i),
				Total:      int64(len(names)),
				StatusLine: line,
			})
		})
		if err != nil {
			return err
		}
		if code != 0 {
			return fmt.Errorf("timeshift: could not delete %s (exit %d)", name, code)
		}

		/* The verdict is whether the directory is gone, not the exit code.
		 * `rm -rfv` reports success for paths it never touched, and a delete
		 * that silently left the snapshot in place would be reported as done. */
		if r.Backend.DirExists(ctx, dir) {
			return fmt.Errorf("timeshift: %s still exists after deletion", name)
		}
		rep.Note("Deleted " + name)
	}
	return nil
}

// linkDestFor picks the newest snapshot taken from the same system.
func (r *Repo) linkDestFor(ctx context.Context, sysUUID string) (string, error) {
	list, err := r.List(ctx)
	if err != nil {
		// Not fatal: a repository we cannot list yet simply has no link source.
		return "", nil
	}
	var best engines.Snapshot
	for _, s := range list {
		if !s.Valid || s.Created.IsZero() {
			continue
		}
		if sysUUID != "" && s.SysUUID != "" && s.SysUUID != sysUUID {
			continue
		}
		if best.Name == "" || s.Created.After(best.Created) {
			best = s
		}
	}
	if best.Name == "" {
		return "", nil
	}
	return path.Join(best.Path, PayloadDir), nil
}

// invalidateNeighbourSizes clears the cached sizes of the snapshots either side
// of one about to be deleted.
func (r *Repo) invalidateNeighbourSizes(ctx context.Context, name string) error {
	list, err := r.List(ctx)
	if err != nil {
		return err
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })

	for i, s := range list {
		if s.Name != name {
			continue
		}
		for _, n := range neighbours(list, i) {
			raw, err := r.Backend.ReadFile(ctx, path.Join(n.Path, "info.json"))
			if err != nil {
				continue
			}
			c, err := ParseControlFile(raw)
			if err != nil {
				continue
			}
			c.SizeBytes, c.UnsharedBytes = -1, -1
			r.writeFile(ctx, path.Join(n.Path, "info.json"), c.Marshal())
		}
		break
	}
	return nil
}

func neighbours(list []engines.Snapshot, i int) []engines.Snapshot {
	var out []engines.Snapshot
	if i > 0 {
		out = append(out, list[i-1])
	}
	if i+1 < len(list) {
		out = append(out, list[i+1])
	}
	return out
}

// rsyncDest prefixes the path with the host for a remote repository.
func (r *Repo) rsyncDest(p string) string {
	if ssh, ok := r.Backend.(*SSHBackend); ok {
		return ssh.HostSpec() + ":" + p
	}
	return p
}

// runRsync streams rsync's output through the parser and into the reporter.
func (r *Repo) runRsync(ctx context.Context, opts rsyncx.Options, parser *rsyncx.Parser, rep engines.Reporter) (int, error) {
	start := time.Now()
	last := time.Now()

	return r.streamCommand(ctx, opts.Command(), func(line string) {
		parser.Line(line)
		rep.Log(line)

		/* Throttled: rsync emits thousands of lines a second on a fast local
		 * transfer, and one event per line would swamp every subscriber for no
		 * gain -- nobody can read a progress bar updating that fast. */
		if time.Since(last) < 100*time.Millisecond {
			return
		}
		last = time.Now()

		rep.Progress(engines.Progress{
			Percent:    parser.Progress(),
			Count:      parser.LineCount,
			Total:      parser.Total,
			ETASeconds: eta(start, parser.Progress()),
			StatusLine: parser.StatusLine,
			Counters: map[string]int64{
				"created":     parser.Counters.Created,
				"deleted":     parser.Counters.Deleted,
				"modified":    parser.Counters.Modified,
				"unchanged":   parser.Counters.Unchanged,
				"checksum":    parser.Counters.Checksum,
				"size":        parser.Counters.Size,
				"timestamp":   parser.Counters.Timestamp,
				"permissions": parser.Counters.Permissions,
				"owner":       parser.Counters.Owner,
				"group":       parser.Counters.Group,
			},
		})
	})
}

// eta extrapolates linearly from elapsed time, or -1 when there is nothing to
// extrapolate from.
func eta(start time.Time, progress float64) int64 {
	if progress <= 0.01 {
		return -1
	}
	elapsed := time.Since(start).Seconds()
	return int64(elapsed/progress - elapsed)
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

/* RsyncSource, RsyncRSH and RsyncPath expose what a caller outside this package
 * needs to build its own rsync command against this repository.
 *
 * The restore path needs them: it copies FROM a snapshot rather than to one, so
 * it builds its own transfer, but the host prefix and the ssh options have to
 * be exactly the ones this repository uses. Reconstructing them from the config
 * would be a second implementation of the connection, and the first bug would
 * be a restore that silently used a different port or key from the backup.
 */

// RsyncSource prefixes a repository path with the host for a remote repository.
//
// Note that only a rsync SOURCE or DESTINATION takes the prefix. --link-dest is
// resolved on the receiving side and must stay a bare path.
func (r *Repo) RsyncSource(p string) string { return r.rsyncDest(p) }

// RsyncRSH is the -e command for this repository, empty when it is local.
func (r *Repo) RsyncRSH() string {
	ssh, ok := r.Backend.(*SSHBackend)
	if !ok {
		return ""
	}
	return strings.Join(append([]string{"ssh"}, ssh.SSHOptions(false, false)...), " ")
}

// RsyncPath is the --rsync-path for this repository, empty when there is none.
//
// --fake-super has to be repeated on the source side of a restore so that
// ownership stored in extended attributes is expanded again; without it every
// restored file comes back owned by the account that made the backup.
func (r *Repo) RsyncPath() string {
	if ssh, ok := r.Backend.(*SSHBackend); ok && ssh.FakeSuper {
		return "rsync --fake-super"
	}
	return ""
}
