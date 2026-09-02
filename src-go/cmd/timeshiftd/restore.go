package main

import (
	"context"
	"encoding/json"
	"fmt"
	"path"
	"strings"

	"github.com/makeafide/timeshift/src-go/internal/block"
	"github.com/makeafide/timeshift/src-go/internal/engines"
	tsengine "github.com/makeafide/timeshift/src-go/internal/engines/timeshift"
	"github.com/makeafide/timeshift/src-go/internal/ipc"
	"github.com/makeafide/timeshift/src-go/internal/jobs"
	"github.com/makeafide/timeshift/src-go/internal/restore"
)

/* Restore over the socket.
 *
 * Two methods, and the split is the point. restore.plan decides everything and
 * changes nothing, so a client -- or a person reading a terminal -- can see
 * exactly which device is about to be overwritten before agreeing to it.
 * snapshot.restore then carries out that same decision.
 *
 * A restore is the one operation here where a mistake destroys data rather than
 * producing a wrong answer, and "which disk did it say again?" is the mistake
 * that matters. Planning separately is what makes it answerable.
 */

// restorePlan builds the plan and returns it without touching anything.
func (d *daemon) restorePlan(ctx context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {

	var in ipc.RestoreParams
	if err := json.Unmarshal(params, &in); err != nil {
		return nil, ipc.Errf(ipc.CodeBadRequest, "%v", err)
	}

	/* btrfs mode is a subvolume swap, not a file transfer, and its plan says
	 * different things. See cmd/timeshiftd/btrfs_restore.go. */
	if d.config().BtrfsMode {
		plan, deps, err := d.buildBtrfsRestorePlan(ctx, in)
		defer deps.Close()
		if err != nil {
			return nil, err
		}
		return plan.result(), nil
	}

	/* restore.plan queues nothing, so the handle it opens is ours to close.
	 * The CLI calls plan then restore for every --restore, so leaking here
	 * leaked one repository mount per restore. */
	plan, deps, err := d.buildRestorePlan(ctx, in)
	defer deps.Close()
	if err != nil {
		return nil, err
	}
	return renderPlan(plan), nil
}

// snapshotRestore queues the restore as a job, so it can be watched like any
// other work -- including from a second client, and including after the client
// that started it has gone.
func (d *daemon) snapshotRestore(ctx context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {

	var in ipc.RestoreParams
	if err := json.Unmarshal(params, &in); err != nil {
		return nil, ipc.Errf(ipc.CodeBadRequest, "%v", err)
	}

	if d.config().BtrfsMode {
		return d.queueBtrfsRestore(ctx, in)
	}

	// Built here, before the job is queued, so an impossible restore is
	// refused synchronously with a reason rather than becoming a failed job.
	/* Ownership passes to the job, and only once it has actually been queued.
	 * Every path that returns before that has to close the handle itself.
	 *
	 * Registered BEFORE the error check, not after: buildRestorePlan hands
	 * back a usable deps on its error paths too, and deferring only after a
	 * successful build leaks the repository -- and its mount -- on every
	 * refused restore. Close is safe on a zero value, so covering the error
	 * path costs nothing.
	 */
	plan, deps, err := d.buildRestorePlan(ctx, in)
	queued := false
	defer func() {
		if !queued {
			deps.Close()
		}
	}()
	if err != nil {
		return nil, err
	}

	if plan.Report.Blocked() {
		return nil, ipc.Errf(ipc.CodeBadRequest,
			"the restore cannot proceed:\n%s", strings.Join(blockers(plan), "\n"))
	}

	job, err := d.queue.Submit(jobs.KindRestore, func(ctx context.Context, r jobs.Reporter) (jobs.Outcome, error) {
		return d.runRestore(ctx, r, plan, deps, in.EstimatedLines)
	})
	if err != nil {
		return nil, ipc.Errf(ipc.CodeBusy, "%v", err)
	}
	queued = true

	d.log.Info("restore queued",
		"job", job.ID, "snapshot", in.Snapshot,
		"current_system", in.CurrentSystem, "dry_run", in.DryRun)

	return ipc.JobRef{Job: job.ID}, nil
}

// restoreDeps are the pieces the job needs that the plan does not carry.
type restoreDeps struct {
	repo engines.Repository
}

/* Close releases the repository handle.
 *
 * It matters because Repo.Close() UNMOUNTS: a local repository opened by uuid
 * is mounted under /run/timeshift/<pid>/ on the way in, and dropping the
 * handle without closing leaves that mount behind for the reaper to find after
 * the process dies. A remote one leaves an sshfs mount and its ControlMaster.
 *
 * Only the job takes ownership of the handle -- everything that builds a plan
 * and does not queue one has to close it here. Safe on a zero value, so a
 * caller can defer it before the handle exists.
 */
func (d restoreDeps) Close() {
	if d.repo != nil {
		d.repo.Close()
	}
}

// buildRestorePlan resolves the request against the repository and the system.
func (d *daemon) buildRestorePlan(ctx context.Context, in ipc.RestoreParams) (*restore.Plan, restoreDeps, error) {

	var deps restoreDeps

	if in.Snapshot == "" {
		return nil, deps, ipc.Errf(ipc.CodeBadRequest, "no snapshot named")
	}

	repo, _, _, err := d.openRepoFor(ctx, nil)
	if err != nil {
		return nil, deps, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	deps.repo = repo

	/* Ownership passes to the CALLER, on every path including the error ones.
	 *
	 * This used to close the repository on each error return while still
	 * handing back a non-nil deps, so restorePlan -- which defers deps.Close()
	 * before checking the error -- closed it a second time. Harmless only
	 * because both backends' Close is a no-op and Repo.Close clears ownedMount
	 * after the first unmount; a backend that ever holds a real resource would
	 * make it a double release.
	 *
	 * buildBtrfsRestorePlan, its twin, already behaved this way. Now they
	 * agree.
	 */

	list, err := repo.List(ctx)
	if err != nil {
		return nil, deps, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}

	var snap *engines.Snapshot
	for i := range list {
		if list[i].Name == in.Snapshot {
			snap = &list[i]
			break
		}
	}
	if snap == nil {
		return nil, deps, ipc.Errf(ipc.CodeNotFound, "no snapshot named %q", in.Snapshot)
	}
	if !snap.Valid {
		return nil, deps, ipc.Errf(ipc.CodeBadRequest,
			"snapshot %q is incomplete and cannot be restored", in.Snapshot)
	}
	if snap.MarkedForDeletion {
		return nil, deps, ipc.Errf(ipc.CodeBadRequest,
			"snapshot %q is marked for deletion", in.Snapshot)
	}

	/* The snapshot's own fstab is the statement of what the restored system
	 * expects. Reading it through the backend matters: a local file read finds
	 * nothing for a remote repository, and the restore would then be planned
	 * with no mount points at all. */
	payload := path.Join(snap.Path, "localhost")
	fstabText := d.readSnapshotFile(ctx, repo, payload, "etc/fstab")
	crypttabText := d.readSnapshotFile(ctx, repo, payload, "etc/crypttab")

	devices, err := (&block.Scanner{Runner: d.runner}).Scan(ctx)
	if err != nil {
		return nil, deps, ipc.Errf(ipc.CodeInternal, "%v", err)
	}

	mounts := restore.BuildMountList(fstabText, crypttabText, devices, d.buildExcludes())
	if len(in.Mounts) > 0 {
		mounts, err = applyMountOverrides(mounts, in.Mounts, devices)
		if err != nil {
			return nil, deps, ipc.Errf(ipc.CodeBadRequest, "%v", err)
		}
	}

	cfg := d.config()

	/* One call, three values. They are only correct together: a remote source
	 * needs its host prefix AND its transport AND, when the far side cannot
	 * preserve ownership as itself, its --rsync-path. */
	src := repo.TransferSource(payload)

	req := restore.Request{
		SnapshotName:     snap.Name,
		SnapshotPath:     src.Path,
		SnapshotDir:      snap.Path,
		Mounts:           mounts,
		CurrentSystem:    in.CurrentSystem,
		ESPCandidates:    espCandidates(devices),
		SnapshotNeedsESP: restore.SnapshotNeedsESP(fstabText),
		ReinstallGrub:    !in.SkipGrub,
		GrubDevice:       in.GrubDevice,
		/* Default true when the caller said nothing: both steps are needed
		 * for a restored system to boot, and an older client that cannot
		 * express them must not silently get a system with a stale initramfs
		 * naming devices that no longer exist. */
		UpdateInitramfs:  boolOr(in.UpdateInitramfs, true),
		UpdateGrubMenu:   boolOr(in.UpdateGrubMenu, true),
		DryRun:           in.DryRun,
		Excludes:         tsengine.BuildRestoreExcludes(cfg.Exclude, snapshotExcludes(ctx, repo, snap)),
		Remote:           cfg.Remote(),
		RSH:              src.RSH,
		RsyncPath:        src.RemoteShellPath,
		MountRoot:        path.Join(d.mountRoot, "restore"),
		TempDir:          d.tempDir,
		FSTypeByUUID:     restore.FSTypes(mounts, devices),
		EncryptedDevices: restore.EncryptedDevicesFor(mounts, devices),
	}

	/* The bootloader goes on the disk holding the root filesystem unless the
	 * caller said otherwise. Guessing wrong here installs GRUB on the wrong
	 * disk, which is why it is derived from the selection rather than from
	 * whatever the running system happens to boot from. */
	if req.GrubDevice == "" {
		req.GrubDevice = rootDisk(mounts)
	}
	if req.GrubDevice == "" {
		req.ReinstallGrub = false
	}

	plan, err := restore.BuildPlan(req)
	if err != nil {
		return nil, deps, ipc.Errf(ipc.CodeBadRequest, "%v", err)
	}
	return plan, deps, nil
}

// boolOr reads an optional wire flag: nil means the caller said nothing.
func boolOr(v *bool, def bool) bool {
	if v == nil {
		return def
	}
	return *v
}

// runRestore is the body of a restore job.
func (d *daemon) runRestore(ctx context.Context, r jobs.Reporter, plan *restore.Plan,
	deps restoreDeps, estimated int64) (jobs.Outcome, error) {

	if deps.repo != nil {
		defer deps.repo.Close()
	}

	ex := &restore.Executor{
		Commands:       d.runner,
		Scripts:        &restore.ShellRunner{Runner: d.runner, Dir: d.mountRoot, Keep: true},
		Reporter:       restoreReporter{r},
		EstimatedLines: estimated,
	}

	result, err := ex.Run(ctx, plan)

	for _, m := range result.Messages {
		r.Note(m)
	}

	if err != nil {
		return jobs.OutcomeFailed, err
	}

	switch result.Outcome {
	case restore.OutcomeFailed:
		return jobs.OutcomeFailed, fmt.Errorf("the restore did not complete")
	case restore.OutcomeWarnings:
		return jobs.OutcomeWarnings, nil
	default:
		return jobs.OutcomeOK, nil
	}
}

// restoreReporter adapts a job reporter to the restore package's.
type restoreReporter struct{ r jobs.Reporter }

func (a restoreReporter) SetPhases(phases []restore.Phase) {
	out := make([]jobs.Phase, 0, len(phases))
	for _, p := range phases {
		out = append(out, jobs.Phase{Key: p.Key, Title: p.Title})
	}
	a.r.SetPhases(out)
}

func (a restoreReporter) Phase(key string) { a.r.Phase(key) }

func (a restoreReporter) Progress(count, total int64, line string) {
	var percent float64
	if total > 0 {
		percent = float64(count) / float64(total) * 100
		if percent > 100 {
			percent = 100
		}
	}
	a.r.Progress(jobs.Progress{
		Percent: percent, Count: count, Total: total, StatusLine: line,
	})
}

func (a restoreReporter) Log(line string) { a.r.Log(line) }
func (a restoreReporter) Note(msg string) { a.r.Note(msg) }

/* Warn must reach Warn, not Note.
 *
 * jobs.reporter.Warn is what moves a job to OutcomeWarnings; Note only appends
 * a message. Routing Warn to Note here meant every warning the restore
 * executor raises was invisible in the outcome -- including "Skipping the file
 * system check: the target is still mounted", which is the one a person most
 * needs to see, because the restore finished but the check that would have
 * caught a damaged filesystem did not run. The CLI prints "completed with
 * warnings" only on OutcomeWarnings, so those restores reported plain success.
 *
 * The sibling adapter for create and delete (reporterAdapter, daemon.go) had
 * always done this correctly; only this one was wrong. */
func (a restoreReporter) Warn(msg string) { a.r.Warn(msg) }

// readSnapshotFile reads one file out of a snapshot, through the backend so it
// works for a remote repository too.
func (d *daemon) readSnapshotFile(ctx context.Context, repo engines.Repository, payload, name string) string {
	raw, err := repo.ReadSnapshotFile(ctx, payload, name)
	if err != nil {
		d.log.Debug("snapshot file not readable", "file", name, "err", err)
		return ""
	}
	return string(raw)
}

// snapshotExcludes reads the exclude list recorded when the snapshot was taken.
func snapshotExcludes(ctx context.Context, repo engines.Repository, snap *engines.Snapshot) []string {
	raw, err := repo.ReadSnapshotFile(ctx, snap.Path, "exclude.list")
	if err != nil {
		return nil
	}
	var out []string
	for _, line := range strings.Split(string(raw), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			out = append(out, line)
		}
	}
	return out
}

/* applyMountOverrides replaces the default selection with the caller's.
 *
 * An unknown mount point is an error rather than an addition: a typo would
 * otherwise create a mount point the snapshot knows nothing about, and the
 * restore would mount a disk somewhere nothing is ever written.
 */
func applyMountOverrides(defaults []restore.MountEntry, overrides map[string]string,
	devices []*block.Device) ([]restore.MountEntry, error) {

	out := append([]restore.MountEntry(nil), defaults...)

	for mountPoint, ref := range overrides {
		idx := -1
		for i := range out {
			if out[i].MountPoint == mountPoint {
				idx = i
				break
			}
		}
		if idx < 0 {
			return nil, fmt.Errorf(
				"the snapshot has no mount point %q; it expects %s",
				mountPoint, strings.Join(mountPointNames(out), ", "))
		}

		if strings.TrimSpace(ref) == "" {
			// Deliberately left on the root filesystem.
			out[idx].DeviceUUID = ""
			out[idx].DevicePath = ""
			continue
		}

		dev := resolveDevice(ref, devices)
		if dev == nil {
			return nil, fmt.Errorf("no such device: %s", ref)
		}
		if dev.FSType == "" {
			return nil, fmt.Errorf("%s has no filesystem; format it before restoring to it", dev.Path)
		}

		out[idx].DeviceUUID = dev.UUID
		out[idx].DevicePath = dev.Path
		out[idx].DiskPath = dev.DiskPath()
	}

	return out, nil
}

// resolveDevice accepts a path or "UUID=x".
func resolveDevice(ref string, devices []*block.Device) *block.Device {
	if uuid, ok := strings.CutPrefix(ref, "UUID="); ok {
		for _, d := range devices {
			if d.UUID == uuid {
				return d
			}
		}
		return nil
	}
	for _, d := range devices {
		if d.Path == ref || d.Name == ref {
			return d
		}
	}
	return nil
}

func mountPointNames(entries []restore.MountEntry) []string {
	var out []string
	for _, e := range entries {
		out = append(out, e.MountPoint)
	}
	return out
}

// espCandidates lists partitions that could serve as /boot/efi.
func espCandidates(devices []*block.Device) []restore.MountEntry {
	var out []restore.MountEntry
	for _, d := range devices {
		if d.Type != "part" || d.FSType != "vfat" {
			continue
		}
		entry := restore.MountEntry{
			MountPoint: "/boot/efi",
			DeviceUUID: d.UUID,
			DevicePath: d.Path,
			IsESP:      true,
		}
		entry.DiskPath = d.DiskPath()
		out = append(out, entry)
	}
	return out
}

// rootDisk is the whole disk holding the selected root filesystem.
func rootDisk(entries []restore.MountEntry) string {
	for _, e := range entries {
		if e.MountPoint == "/" {
			return e.DiskPath
		}
	}
	return ""
}

func blockers(plan *restore.Plan) []string {
	var out []string
	for _, row := range plan.Report.Rows {
		if row.Blocking {
			out = append(out, fmt.Sprintf("  %s: %s", row.MountPoint, row.Status))
		}
	}
	return out
}

// renderPlan turns a plan into the wire shape.
func renderPlan(plan *restore.Plan) ipc.RestorePlanResult {

	out := ipc.RestorePlanResult{
		Snapshot: plan.SnapshotName,
		Target:   plan.TargetPath,
		Blocked:  plan.Report.Blocked(),
		Summary:  plan.Describe(),
		Notes:    append(append([]string(nil), plan.Report.Notes...), plan.Folded...),
	}
	if plan.CurrentSystem {
		out.Target = "the running system"
	}

	for _, row := range plan.Report.Rows {
		out.Rows = append(out.Rows, ipc.RestorePlanRow{
			MountPoint: row.MountPoint,
			Device:     row.Assigned,
			Status:     row.Status,
			Blocking:   row.Blocking,
		})
		if row.Blocking {
			out.Blockers = append(out.Blockers, row.MountPoint+": "+row.Status)
		}
	}
	for _, p := range plan.Phases {
		out.Phases = append(out.Phases, p.Title)
	}
	return out
}
