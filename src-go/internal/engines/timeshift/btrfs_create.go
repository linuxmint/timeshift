package timeshift

import (
	"context"
	"fmt"
	"os"
	"path"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/engines"
)

/* Creating a btrfs snapshot.
 *
 * Nothing is copied. `btrfs subvolume snapshot` makes a new subvolume sharing
 * every extent with the original, so the operation is instant and costs no
 * space until one side is written to. That is the whole reason btrfs mode
 * exists, and it is why there is no progress to report, no exclude list, and no
 * link-dest: a subvolume snapshot takes the whole subvolume or nothing.
 *
 * The constraint that shapes everything here is that source and destination
 * must be on the SAME filesystem. The repository is therefore not a separate
 * disk, as it is in rsync mode -- it is a directory on the very filesystem
 * being snapshotted, reached by mounting that filesystem's top level. See
 * BtrfsTopLevelOpts.
 */

// BtrfsCreatePhases are the steps a btrfs create reports.
//
// Deliberately not the rsync set: there is no "copying files" step to report,
// and showing one would be a progress bar for work that is not happening.
func BtrfsCreatePhases() []engines.Phase {
	return []engines.Phase{
		{Key: "prepare", Title: "Preparing"},
		{Key: "snapshot", Title: "Creating subvolume snapshots"},
		{Key: "finalise", Title: "Writing snapshot metadata"},
	}
}

// createBtrfs takes a snapshot by snapshotting subvolumes.
func (r *Repo) createBtrfs(ctx context.Context, req engines.CreateRequest, rep engines.Reporter) (engines.Snapshot, error) {
	rep.SetPhases(BtrfsCreatePhases())
	rep.Phase("prepare")

	if r.Runner == nil {
		return engines.Snapshot{}, fmt.Errorf("timeshift: btrfs mode needs a local command runner")
	}

	/* The layout is checked before anything is created.
	 *
	 * Only "@" plus optionally "@home" is handled, and a filesystem with other
	 * names is refused rather than half-handled -- a snapshot of the wrong
	 * subvolumes is worse than no snapshot, because it looks like a backup.
	 */
	includeHome := req.IncludeBtrfsHome
	if err := ValidateLayout(ctx, r.Runner, r.MountPath, includeHome); err != nil {
		return engines.Snapshot{}, err
	}

	name := time.Now().Format(NameLayout)
	snapDir := path.Join(r.SnapshotsPath(), name)

	plan := PlanBtrfsSnapshot(r.SnapshotsPath(), name, includeHome)

	if err := os.MkdirAll(snapDir, 0755); err != nil {
		return engines.Snapshot{}, fmt.Errorf("timeshift: could not create %s: %w", snapDir, err)
	}

	rep.Phase("snapshot")

	/* Undo what we made if a later subvolume fails.
	 *
	 * A half-made snapshot is the dangerous outcome: it carries no info.json,
	 * so it reads as invalid, and an invalid snapshot is never pruned without
	 * positive evidence that it is incomplete. Leaving one behind means a
	 * directory nothing will ever clean up, holding extents that cannot be
	 * freed.
	 */
	made := make([]string, 0, len(plan.Subvolumes))
	fail := func(err error) (engines.Snapshot, error) {
		for i := len(made) - 1; i >= 0; i-- {
			DeleteSubvolume(ctx, r.Runner, Subvolume{Name: path.Base(made[i]), Path: made[i]},
				DeleteOptions{})
		}
		os.Remove(snapDir)
		return engines.Snapshot{}, err
	}

	for _, subvol := range SupportedSubvolumes {
		dst, wanted := plan.Subvolumes[subvol]
		if !wanted {
			continue
		}
		src := path.Join(r.MountPath, subvol)
		rep.Note("Snapshotting " + subvol)
		if err := SnapshotSubvolume(ctx, r.Runner, src, dst); err != nil {
			return fail(fmt.Errorf("timeshift: could not snapshot %s: %w", subvol, err))
		}
		made = append(made, dst)
	}

	rep.Phase("finalise")

	control := &ControlFile{
		Created:    time.Now(),
		SysUUID:    req.SysUUID,
		SysDistro:  req.SysDistro,
		AppVersion: req.AppVersion,
		// No file count: nothing was enumerated, and a zero here would be read
		// as an empty snapshot rather than as "not applicable".
		FileCount:   -1,
		Tags:        req.Tags,
		Description: req.Comments,
		Type:        "btrfs",
		// Sizes are meaningless for a fresh subvolume snapshot: it shares every
		// extent with the original, so it occupies nothing of its own yet.
		SizeBytes:     -1,
		UnsharedBytes: -1,
	}
	if err := r.writeFile(ctx, path.Join(snapDir, "info.json"), control.Marshal()); err != nil {
		return fail(err)
	}

	subvols := make([]string, 0, len(plan.Subvolumes))
	for _, s := range SupportedSubvolumes {
		if _, ok := plan.Subvolumes[s]; ok {
			subvols = append(subvols, s)
		}
	}

	return engines.Snapshot{
		Name:        name,
		Path:        snapDir,
		Created:     control.Created,
		Tags:        req.Tags,
		Description: req.Comments,
		SysUUID:     req.SysUUID,
		SysDistro:   req.SysDistro,
		AppVersion:  req.AppVersion,
		Valid:       true,
		SizeBytes:   -1,
		EngineData:  map[string]any{"subvolumes": subvols},
	}, nil
}

/* deleteBtrfsSnapshot removes the subvolumes a btrfs snapshot is made of, and
 * then the directory that held them.
 *
 * Order matters and is not interchangeable with the rsync path's `rm -rf`: the
 * kernel refuses to unlink a subvolume as though it were a directory, so a
 * plain recursive remove fails partway through and leaves the snapshot half
 * deleted -- with its info.json gone, which makes it read as invalid, which is
 * the state nothing will ever clean up on its own.
 *
 * A qgroup is left behind by some btrfs-progs versions and cleaned up after.
 * That is best effort: quotas are usually off, and a stale qgroup wastes a
 * little metadata rather than breaking anything.
 */
func (r *Repo) deleteBtrfsSnapshot(ctx context.Context, name, dir string, rep engines.Reporter) error {
	if r.Runner == nil {
		return fmt.Errorf("timeshift: btrfs mode needs a local command runner")
	}

	for _, subvol := range SupportedSubvolumes {
		p := path.Join(dir, subvol)
		if !IsSubvolume(ctx, r.Runner, p) {
			continue
		}
		rep.Note("Deleting subvolume " + name + "/" + subvol)
		sv := Subvolume{Name: subvol, Path: p}
		if err := DeleteSubvolume(ctx, r.Runner, sv, DeleteOptions{}); err != nil {
			return fmt.Errorf("timeshift: could not delete %s: %w", p, err)
		}
		if err := CleanupQGroup(ctx, r.Runner, sv, r.MountPath, QGroupCleanupOptions{}); err != nil {
			rep.Warn("Could not clean up the qgroup for " + subvol + ": " + err.Error())
		}
	}

	/* Whatever is left is ordinary files -- info.json and any stray control
	 * files -- so a plain remove finishes the job.
	 *
	 * os.RemoveAll rather than the backend's remove command, because btrfs mode
	 * is local by construction: btrfs and a remote repository are mutually
	 * exclusive (ValidateLocation says so, and Open forces it off), so there is
	 * no remote case to serve here. */
	if err := os.RemoveAll(dir); err != nil {
		return fmt.Errorf("timeshift: could not remove %s: %w", dir, err)
	}
	return nil
}
