package timeshift

import (
	"context"
	"fmt"
	"os"
	"path"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/engines"
)

/* Restoring a btrfs snapshot.
 *
 * This is not the rsync restore with a different transfer. It is a different
 * operation, and the difference that matters is WHEN it takes effect: swapping
 * "@" does nothing to the running system, because the kernel still has the old
 * subvolume mounted at /. The restored one becomes the system at the next boot.
 *
 * That is why there is no bootloader step and no initramfs rebuild here, where
 * the rsync path has both. Running update-grub now would describe the system
 * that is running, not the one being restored, and rebuilding an initramfs
 * would write it into the subvolume being replaced. The Vala core reaches the
 * same conclusion (restore_execute_btrfs at Main.vala:4512): swap, run the
 * restore hooks, say that a reboot is needed.
 *
 * The live subvolumes are not deleted. They are moved aside into a snapshot
 * marked live=true -- a "pre-restore" backup -- so a restore that turns out to
 * be the wrong choice can itself be undone. Deleting them would make the
 * operation irreversible, which for something that replaces an entire system is
 * not a reasonable default.
 */

// BtrfsRestoreOptions describes a subvolume restore.
type BtrfsRestoreOptions struct {
	// MountPath is the btrfs filesystem's TOP LEVEL, where "@" lives.
	MountPath string

	// SnapshotDir is the stored snapshot's directory, holding "@" and
	// optionally "@home".
	SnapshotDir string

	// IncludeHome restores "@home" as well as "@".
	IncludeHome bool

	// SnapshotsPath is where the pre-restore backup is created.
	SnapshotsPath string

	// SysUUID and AppVersion go into the pre-restore snapshot's control file.
	SysUUID    string
	AppVersion string
}

// BtrfsRestoreResult reports what a restore did.
type BtrfsRestoreResult struct {
	// PreRestoreName is the snapshot the live subvolumes were moved into,
	// empty if there was nothing live to preserve.
	PreRestoreName string

	// Restored lists the subvolumes put back.
	Restored []string
}

// BtrfsRestore replaces the live subvolumes with a snapshot's.
func BtrfsRestore(ctx context.Context, runner Runner, o BtrfsRestoreOptions,
	rep engines.Reporter) (BtrfsRestoreResult, error) {

	var res BtrfsRestoreResult

	if runner == nil {
		return res, fmt.Errorf("timeshift: btrfs restore needs a local command runner")
	}

	wanted := []string{SubvolRoot}
	if o.IncludeHome {
		wanted = append(wanted, SubvolHome)
	}

	/* Everything is checked before anything is moved.
	 *
	 * Half a restore is the outcome to avoid: "@" replaced and "@home" not
	 * leaves a system whose root and home disagree about what version they
	 * are, and no single step to undo. */
	present := make([]string, 0, len(wanted))
	for _, name := range wanted {
		src := path.Join(o.SnapshotDir, name)
		if !IsSubvolume(ctx, runner, src) {
			return res, fmt.Errorf(
				"timeshift: %s is not a subvolume in this snapshot; it cannot be restored", name)
		}
		present = append(present, name)
	}

	/* A name that is not already taken.
	 *
	 * The timestamp has one-second resolution, and restoring a snapshot in the
	 * same second it was created -- which a test does, and a script could --
	 * would otherwise aim the pre-restore backup at the snapshot directory
	 * being restored FROM, and the rename would land the live "@" on top of
	 * the one about to be read. */
	preName := uniqueSnapshotName(o.SnapshotsPath, time.Now())
	preDir := path.Join(o.SnapshotsPath, preName)
	madePre := false

	for _, name := range present {
		live := path.Join(o.MountPath, name)

		if IsSubvolume(ctx, runner, live) {
			if !madePre {
				if err := os.MkdirAll(preDir, 0755); err != nil {
					return res, fmt.Errorf("timeshift: could not create %s: %w", preDir, err)
				}
				madePre = true
			}
			rep.Note("Keeping the current " + name + " as " + preName)
			/* A rename, not a copy. Both paths are on one filesystem by
			 * construction, and renaming a subvolume is what frees the name
			 * without destroying what it held. */
			if err := os.Rename(live, path.Join(preDir, name)); err != nil {
				return res, fmt.Errorf(
					"timeshift: could not move the live %s aside: %w", name, err)
			}
		} else if _, err := os.Stat(live); err == nil {
			return res, fmt.Errorf(
				"timeshift: %s exists but is not a subvolume; refusing to replace it", live)
		}

		rep.Note("Restoring " + name)
		if err := RestoreSubvolume(ctx, runner, path.Join(o.SnapshotDir, name), live); err != nil {
			return res, fmt.Errorf("timeshift: could not restore %s: %w", name, err)
		}
		res.Restored = append(res.Restored, name)
	}

	if madePre {
		res.PreRestoreName = preName
		control := &ControlFile{
			Created:     time.Now(),
			SysUUID:     o.SysUUID,
			AppVersion:  o.AppVersion,
			FileCount:   -1,
			Tags:        nil,
			Description: "Before restoring " + path.Base(o.SnapshotDir),
			Type:        "btrfs",
			// Live marks this as the pre-restore backup, which is what lets a
			// later restore recognise and replace it rather than stacking up
			// one of these per attempt.
			Live:          true,
			SizeBytes:     -1,
			UnsharedBytes: -1,
		}
		if err := os.WriteFile(path.Join(preDir, "info.json"), control.Marshal(), 0644); err != nil {
			// The subvolumes are safe; only their label is missing. Worth a
			// warning, not worth failing a completed restore over.
			rep.Warn("Could not write metadata for the pre-restore snapshot: " + err.Error())
		}
	}

	return res, nil
}

/* uniqueSnapshotName returns a snapshot name not already present.
 *
 * Suffixes rather than waiting for the clock: a caller that has already moved
 * a subvolume cannot afford to sleep, and the name only has to be unique, not
 * beautiful.
 */
func uniqueSnapshotName(snapshotsPath string, now time.Time) string {
	base := now.Format(NameLayout)
	name := base
	for i := 1; ; i++ {
		if _, err := os.Stat(path.Join(snapshotsPath, name)); os.IsNotExist(err) {
			return name
		}
		name = fmt.Sprintf("%s_%d", base, i)
	}
}
