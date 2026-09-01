package main

import (
	"context"
	"fmt"
	"os"
	"path"
	"strings"

	"github.com/makeafide/timeshift/src-go/internal/engines"
	tsengine "github.com/makeafide/timeshift/src-go/internal/engines/timeshift"
	"github.com/makeafide/timeshift/src-go/internal/ipc"
	"github.com/makeafide/timeshift/src-go/internal/jobs"
)

/* The btrfs restore path.
 *
 * Separate from the rsync one rather than a branch inside it, because the two
 * share almost nothing. There is no transfer, no exclude list, no target to
 * mount, no fstab to rewrite -- the restored subvolume brings its own -- and,
 * most importantly, no bootloader or initramfs step: swapping "@" does not
 * change the running system, so update-grub now would describe the system being
 * replaced. The snapshot becomes the system at the next boot.
 *
 * Forcing this through restore.Executor would mean making every one of those
 * steps conditional on a mode, which is exactly the shape the engine layer
 * exists to avoid, and would put the rsync restore -- the one that is verified
 * in a VM -- at risk for the sake of code it does not share.
 */

// btrfsRestorePlan describes a subvolume restore before anything is done.
type btrfsRestorePlan struct {
	SnapshotName string
	SnapshotDir  string
	MountPath    string
	Subvolumes   []string
	Blockers     []string
}

func (p *btrfsRestorePlan) result() ipc.RestorePlanResult {
	out := ipc.RestorePlanResult{
		Snapshot: p.SnapshotName,
		Target:   "the running system",
		Blocked:  len(p.Blockers) > 0,
		Blockers: p.Blockers,
		Phases: []string{
			"Preparing",
			"Keeping the current subvolumes",
			"Restoring subvolumes",
			"Running post-restore scripts",
		},
		Notes: []string{
			"BTRFS mode: subvolumes are replaced, not copied. Nothing is transferred.",
			"The restored snapshot becomes the running system after a reboot.",
			"The current subvolumes are kept as a pre-restore snapshot, so this can be undone.",
		},
	}
	for _, s := range p.Subvolumes {
		out.Rows = append(out.Rows, ipc.RestorePlanRow{
			MountPoint: s,
			Device:     path.Join(p.SnapshotDir, s),
			Status:     "will replace the live " + s,
		})
	}

	var b strings.Builder
	fmt.Fprintf(&b, "Snapshot:  %s\n", p.SnapshotName)
	fmt.Fprintf(&b, "Target:    the running system (BTRFS)\n")
	b.WriteString("Subvolumes:\n")
	for _, s := range p.Subvolumes {
		fmt.Fprintf(&b, "   %-8s will be replaced by the snapshot's copy\n", s)
	}
	b.WriteString("Afterwards:\n")
	for _, ph := range out.Phases {
		fmt.Fprintf(&b, "  %s\n", ph)
	}
	b.WriteString("\nThe snapshot becomes active after a reboot.\n")
	out.Summary = b.String()
	return out
}

// buildBtrfsRestorePlan resolves the request against the repository.
func (d *daemon) buildBtrfsRestorePlan(ctx context.Context, in ipc.RestoreParams) (
	*btrfsRestorePlan, restoreDeps, error) {

	var deps restoreDeps

	if in.Snapshot == "" {
		return nil, deps, ipc.Errf(ipc.CodeBadRequest, "no snapshot named")
	}

	repo, _, _, err := d.openRepo(ctx)
	if err != nil {
		return nil, deps, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	deps.repo = repo

	ts, ok := repo.(*tsengine.Repo)
	if !ok {
		return nil, deps, ipc.Errf(ipc.CodeInternal, "btrfs mode needs the timeshift engine")
	}

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

	cfg := d.config()
	plan := &btrfsRestorePlan{
		SnapshotName: snap.Name,
		SnapshotDir:  snap.Path,
		MountPath:    ts.MountPath,
		Subvolumes:   []string{tsengine.SubvolRoot},
	}
	if cfg.IncludeBtrfsHomeForRestore {
		plan.Subvolumes = append(plan.Subvolumes, tsengine.SubvolHome)
	}

	/* Refuse a restore onto anything but this machine.
	 *
	 * A subvolume swap only makes sense on the filesystem the snapshot came
	 * from -- there is nowhere else its extents exist. --target is an rsync
	 * concept and cannot be honoured here, so it is rejected rather than
	 * quietly ignored. */
	if len(in.Mounts) > 0 && !in.CurrentSystem {
		plan.Blockers = append(plan.Blockers,
			"btrfs mode can only restore onto the filesystem the snapshot lives on; --target is not supported")
	}

	for _, s := range plan.Subvolumes {
		if !tsengine.IsSubvolume(ctx, d.runner, path.Join(snap.Path, s)) {
			plan.Blockers = append(plan.Blockers,
				fmt.Sprintf("%s: the snapshot has no %s subvolume", snap.Name, s))
		}
	}

	return plan, deps, nil
}

// runBtrfsRestore carries out a subvolume restore.
func (d *daemon) runBtrfsRestore(ctx context.Context, r jobs.Reporter,
	plan *btrfsRestorePlan, deps restoreDeps) (jobs.Outcome, error) {

	if deps.repo != nil {
		defer deps.repo.Close()
	}

	ts, _ := deps.repo.(*tsengine.Repo)
	if ts == nil {
		return jobs.OutcomeFailed, fmt.Errorf("btrfs mode needs the timeshift engine")
	}

	r.SetPhases([]jobs.Phase{
		{Key: "prepare", Title: "Preparing"},
		{Key: "keep", Title: "Keeping the current subvolumes"},
		{Key: "restore", Title: "Restoring subvolumes"},
		{Key: "hooks", Title: "Running post-restore scripts"},
	})
	r.Phase("prepare")

	cfg := d.config()
	r.Phase("keep")

	res, err := tsengine.BtrfsRestore(ctx, d.runner, tsengine.BtrfsRestoreOptions{
		MountPath:     plan.MountPath,
		SnapshotDir:   plan.SnapshotDir,
		IncludeHome:   cfg.IncludeBtrfsHomeForRestore,
		SnapshotsPath: ts.SnapshotsPath(),
		SysUUID:       d.systemUUID(ctx),
		AppVersion:    version,
	}, reporterAdapter{r})
	if err != nil {
		return jobs.OutcomeFailed, err
	}

	r.Phase("restore")
	r.Note("Restored: " + strings.Join(res.Restored, ", "))
	if res.PreRestoreName != "" {
		r.Note("The previous system is kept as snapshot " + res.PreRestoreName)
	}

	r.Phase("hooks")
	d.runRestoreHooks(ctx, r, plan.SnapshotDir)

	r.Note("The restored snapshot becomes the running system after a reboot.")
	return jobs.OutcomeOK, nil
}

/* runRestoreHooks runs /etc/timeshift/restore-hooks.d, as the rsync finish
 * script does. Failures are reported and do not fail the restore: the
 * subvolumes are already in place, and a hook is somebody's own script. */
func (d *daemon) runRestoreHooks(ctx context.Context, r jobs.Reporter, snapshotPath string) {
	const dir = "/etc/timeshift/restore-hooks.d"
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return
	}
	code, out, errOut, err := d.runner.RunEnv(ctx,
		[]string{"run-parts", "--verbose", dir}, "",
		append(os.Environ(), "TS_SNAPSHOT_PATH="+snapshotPath))
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line != "" {
			r.Log(line)
		}
	}
	if err != nil || code != 0 {
		r.Warn("Post-restore scripts reported a problem: " + strings.TrimSpace(errOut))
	}
}

// queueBtrfsRestore is snapshot.restore for a btrfs repository.
func (d *daemon) queueBtrfsRestore(ctx context.Context, in ipc.RestoreParams) (any, error) {

	plan, deps, err := d.buildBtrfsRestorePlan(ctx, in)
	if err != nil {
		deps.Close()
		return nil, err
	}
	if len(plan.Blockers) > 0 {
		deps.Close()
		return nil, ipc.Errf(ipc.CodeBadRequest,
			"the restore cannot proceed:\n%s", strings.Join(plan.Blockers, "\n"))
	}

	/* A dry run changes nothing, and for a subvolume swap there is nothing to
	 * rehearse -- no transfer to measure and no file list to compare. Saying so
	 * is better than reporting success for work that did not happen. */
	if in.DryRun {
		deps.Close()
		return nil, ipc.Errf(ipc.CodeBadRequest,
			"btrfs mode has no dry run: a subvolume swap copies nothing, so there is nothing to compare")
	}

	queued := false
	defer func() {
		if !queued {
			deps.Close()
		}
	}()

	job, err := d.queue.Submit(jobs.KindRestore, func(ctx context.Context, r jobs.Reporter) (jobs.Outcome, error) {
		return d.runBtrfsRestore(ctx, r, plan, deps)
	})
	if err != nil {
		return nil, ipc.Errf(ipc.CodeBusy, "%v", err)
	}
	queued = true

	d.log.Info("btrfs restore queued", "job", job.ID, "snapshot", in.Snapshot,
		"subvolumes", strings.Join(plan.Subvolumes, ","))
	return ipc.JobRef{Job: job.ID}, nil
}
