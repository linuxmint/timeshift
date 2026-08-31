package restore

import (
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
	"syscall"
)

/* Where a restore is allowed to write.
 *
 * This is the most safety-critical code in the tree. A restore runs rsync with
 * --delete against a mount point, so a mount point that is not what it appears
 * to be does not produce a wrong restore -- it deletes a filesystem.
 *
 * There are three layers, deliberately independent:
 *
 *   1. fold_aliased_mount_entries collapses entries that would mount the same
 *      device twice at nested points.
 *   2. Validate reports what the user is about to do and refuses the two
 *      arrangements that cannot work.
 *   3. VerifyNoAliasedMounts stats the mounted result and refuses if any nested
 *      mount point IS the target root. It compares (st_dev, st_ino) rather than
 *      the mount list, so it catches an alias arriving by ANY route -- a stale
 *      mount, a bind, a device that resolved to the same thing under two names.
 *
 * The third exists because the first two reason about intent and the third
 * about reality. It runs after mounting and before anything is deleted.
 */

// MountEntry is one line of the restore plan: where a directory of the restored
// system will live.
type MountEntry struct {
	MountPoint string

	// DeviceUUID identifies the device to mount. Empty means "keep on the root
	// device" -- the entry stays visible in the UI but nothing is mounted.
	DeviceUUID string

	// DevicePath is for display and for messages.
	DevicePath string

	// Options are the mount options, which matter to folding: two entries only
	// alias each other if they would mount the same device the same way.
	Options string

	// IsESP marks an EFI System Partition.
	IsESP bool

	// DiskPath is the whole disk this device belongs to, used to check the ESP
	// is on the same disk as the root.
	DiskPath string
}

// Assigned reports whether a device was chosen for this mount point.
func (m MountEntry) Assigned() bool { return m.DeviceUUID != "" }

// Severity grades a finding.
type Severity string

const (
	SeverityOK      Severity = "ok"
	SeverityNote    Severity = "note"
	SeverityWarning Severity = "warning"
	SeverityError   Severity = "error"
)

// LayoutRow is one line of the layout report a client shows before restoring.
type LayoutRow struct {
	MountPoint string
	Original   string
	Assigned   string
	Status     string
	Severity   Severity

	// Blocking marks a row that must be fixed before the restore may start.
	Blocking bool
}

// LayoutReport is the whole review.
type LayoutReport struct {
	Rows []LayoutRow

	// Notes explains anything folded away, so a device that silently stopped
	// being mounted is visible rather than mysterious.
	Notes []string
}

// Blocked reports whether anything must be fixed first.
func (r LayoutReport) Blocked() bool {
	for _, row := range r.Rows {
		if row.Blocking {
			return true
		}
	}
	return false
}

// MountPointIsUnder reports whether child is at or below parent.
//
// Not a prefix test: a plain HasPrefix would make /boot-backup a child of
// /boot, and folding those together would unmount a filesystem nobody asked
// about.
func MountPointIsUnder(child, parent string) bool {
	if parent == "/" {
		return child != "/"
	}
	if child == parent {
		return true
	}
	return strings.HasPrefix(child, parent+"/")
}

// FoldAliasedMountEntries collapses entries that would mount one device twice
// at nested points, and explains each fold.
//
// The device is set to empty rather than the entry being removed: empty is
// exactly what the device dropdown's "Keep on Root Device" stores, so the row
// stays in the UI and simply stops being mounted a second time. Removing it
// would make the dropdown vanish if the user stepped back to change it.
func FoldAliasedMountEntries(entries []MountEntry) ([]MountEntry, []string) {
	out := make([]MountEntry, len(entries))
	copy(out, entries)

	// Parents before children, so an ancestor is always seen first.
	sort.SliceStable(out, func(i, j int) bool { return out[i].MountPoint < out[j].MountPoint })

	var notes []string
	seen := map[string]bool{}

	for i := range out {
		mnt := &out[i]
		if !mnt.Assigned() || mnt.MountPoint == "/" {
			continue
		}

		/* Never the ESP. Folding /boot/efi onto the root device is not a
		 * shorthand for anything: it means no EFI System Partition is mounted,
		 * the snapshot's ESP payload lands as ordinary files on ext4, and
		 * grub-install then fails with "cannot find EFI directory". Validate
		 * reports it as an error instead. */
		if mnt.MountPoint == "/boot/efi" {
			continue
		}

		for j := 0; j < i; j++ {
			parent := out[j]
			if !parent.Assigned() {
				continue
			}
			// An ancestor, not merely a name prefix.
			if !MountPointIsUnder(mnt.MountPoint, parent.MountPoint) {
				continue
			}
			if parent.DeviceUUID != mnt.DeviceUUID {
				continue
			}
			// Only an alias if they would be mounted the same way.
			if parent.Options != mnt.Options {
				continue
			}

			note := fmt.Sprintf("%s and %s were both set to %s. %s will stay on %s.",
				parent.MountPoint, mnt.MountPoint, mnt.DevicePath,
				mnt.MountPoint, parent.MountPoint)
			if !seen[note] {
				seen[note] = true
				notes = append(notes, note)
			}
			mnt.DeviceUUID = ""
			break
		}
	}

	return out, notes
}

// ValidateOptions describe the restore being reviewed.
type ValidateOptions struct {
	Entries []MountEntry

	// SnapshotNeedsESP means the snapshot's fstab has a /boot/efi entry, so the
	// restored system expects to boot via UEFI.
	SnapshotNeedsESP bool

	// CurrentSystem means restoring in place, where nothing is being mounted
	// and the layout is whatever the running system already has.
	CurrentSystem bool
}

// Validate reviews the restore plan.
//
// Only two rows can block: the root, and the ESP when the snapshot needs one.
// Everything else is reported and allowed. That split is deliberate -- a
// missing /home device produces a system that boots with an empty home, which
// is recoverable; a missing root or a missing ESP produces a system that does
// not boot at all.
func Validate(o ValidateOptions) LayoutReport {
	var report LayoutReport

	if o.CurrentSystem {
		report.Rows = append(report.Rows, LayoutRow{
			MountPoint: "/",
			Assigned:   "the running system",
			Status:     "Files will be restored in place",
			Severity:   SeverityWarning,
		})
		return report
	}

	entries, notes := FoldAliasedMountEntries(o.Entries)
	report.Notes = notes

	var root, esp *MountEntry
	for i := range entries {
		switch entries[i].MountPoint {
		case "/":
			root = &entries[i]
		case "/boot/efi":
			esp = &entries[i]
		}
	}

	if root == nil || !root.Assigned() {
		report.Rows = append(report.Rows, LayoutRow{
			MountPoint: "/",
			Status:     "No device selected for the root filesystem",
			Severity:   SeverityError,
			Blocking:   true,
		})
	} else {
		report.Rows = append(report.Rows, LayoutRow{
			MountPoint: "/",
			Assigned:   root.DevicePath,
			Status:     "Will be restored",
			Severity:   SeverityOK,
		})
	}

	if o.SnapshotNeedsESP {
		switch {
		case esp == nil || !esp.Assigned():
			report.Rows = append(report.Rows, LayoutRow{
				MountPoint: "/boot/efi",
				Status:     "The snapshot expects an EFI System Partition, but none is selected",
				Severity:   SeverityError,
				Blocking:   true,
			})
		case !esp.IsESP:
			report.Rows = append(report.Rows, LayoutRow{
				MountPoint: "/boot/efi",
				Assigned:   esp.DevicePath,
				Status:     "Not an EFI System Partition",
				Severity:   SeverityError,
				Blocking:   true,
			})
		case root != nil && root.DiskPath != "" && esp.DiskPath != "" && esp.DiskPath != root.DiskPath:
			/* An ESP on a different disk than the root produces a system whose
			 * firmware entry points at one disk and whose root lives on
			 * another: it boots only while both are attached, which is not what
			 * anyone restoring a backup intends. */
			report.Rows = append(report.Rows, LayoutRow{
				MountPoint: "/boot/efi",
				Assigned:   esp.DevicePath,
				Status:     "On a different disk than the root filesystem",
				Severity:   SeverityError,
				Blocking:   true,
			})
		default:
			report.Rows = append(report.Rows, LayoutRow{
				MountPoint: "/boot/efi",
				Assigned:   esp.DevicePath,
				Status:     "Will be mounted",
				Severity:   SeverityOK,
			})
		}
	}

	for _, e := range entries {
		if e.MountPoint == "/" || e.MountPoint == "/boot/efi" {
			continue
		}
		row := LayoutRow{MountPoint: e.MountPoint, Assigned: e.DevicePath}
		if e.Assigned() {
			row.Status = "Will be mounted"
			row.Severity = SeverityOK
		} else {
			row.Assigned = "keep on root device"
			row.Status = "Will be restored onto the root filesystem"
			row.Severity = SeverityNote
		}
		report.Rows = append(report.Rows, row)
	}

	return report
}

// NormalizeESPSelection picks a sensible ESP when one is needed.
//
// Rejects a selection that is not an ESP, or is on a different disk than the
// root, and then auto-picks the ESP on the root's own disk if there is one.
// Returns the possibly-corrected entries and a note when something changed.
func NormalizeESPSelection(entries []MountEntry, candidates []MountEntry) ([]MountEntry, string) {
	out := make([]MountEntry, len(entries))
	copy(out, entries)

	var root, esp *MountEntry
	for i := range out {
		switch out[i].MountPoint {
		case "/":
			root = &out[i]
		case "/boot/efi":
			esp = &out[i]
		}
	}
	if esp == nil || root == nil || !root.Assigned() {
		return out, ""
	}

	wrong := esp.Assigned() && (!esp.IsESP || (esp.DiskPath != "" && root.DiskPath != "" && esp.DiskPath != root.DiskPath))
	if esp.Assigned() && !wrong {
		return out, ""
	}

	// Auto-pick the ESP on the root's own disk.
	for _, c := range candidates {
		if c.IsESP && c.DiskPath != "" && c.DiskPath == root.DiskPath {
			previous := esp.DevicePath
			esp.DeviceUUID = c.DeviceUUID
			esp.DevicePath = c.DevicePath
			esp.IsESP = true
			esp.DiskPath = c.DiskPath
			if previous == "" {
				return out, fmt.Sprintf("Selected %s as the EFI System Partition.", c.DevicePath)
			}
			return out, fmt.Sprintf("%s is not a usable EFI System Partition for this restore; selected %s instead.",
				previous, c.DevicePath)
		}
	}

	if wrong {
		// Clear it rather than leaving an unusable choice in place; Validate
		// then blocks with a message that says what to do.
		esp.DeviceUUID = ""
		esp.IsESP = false
		return out, "The selected EFI System Partition cannot be used for this restore."
	}
	return out, ""
}

// ErrAliasedMount reports a nested mount point that IS the restore target.
var ErrAliasedMount = errors.New("restore: aliased mount")

// AliasError names the offending mount point and explains the remedy.
type AliasError struct {
	MountPoint string
	Path       string
}

func (e AliasError) Error() string {
	return fmt.Sprintf(
		"%s is the same directory as the root of the restore target.\n"+
			"Restoring would delete the target's contents through it. Nothing was changed.\n"+
			"Select 'Keep on Root Device' for %s, or choose a different device.",
		e.MountPoint, e.MountPoint)
}

func (e AliasError) Unwrap() error { return ErrAliasedMount }

// VerifyNoAliasedMounts is the backstop, run after mounting and before anything
// is deleted.
//
// It compares (st_dev, st_ino) rather than consulting the mount list, so it
// catches an alias that arrived by any route at all. A genuine subdirectory of
// the target shares st_dev with it but never st_ino, so an ordinary layout
// passes.
//
// Restoring the current system needs no check: nothing was mounted by us and /
// is the target by definition.
func VerifyNoAliasedMounts(targetPath string, entries []MountEntry, currentSystem bool) error {
	if currentSystem {
		return nil
	}

	root := strings.TrimSuffix(targetPath, "/")
	if root == "" {
		root = "/"
	}

	rootInfo, err := os.Stat(root)
	if err != nil {
		return fmt.Errorf("restore: the restore target could not be read: %s: %w", root, err)
	}
	rootStat, ok := rootInfo.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("restore: could not stat the restore target: %s", root)
	}

	for _, e := range entries {
		if e.MountPoint == "/" {
			continue
		}
		path := root + e.MountPoint

		info, err := os.Stat(path)
		if err != nil {
			// Absent is fine: it will be created by the transfer.
			continue
		}
		st, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			continue
		}
		if st.Dev == rootStat.Dev && st.Ino == rootStat.Ino {
			return AliasError{MountPoint: e.MountPoint, Path: path}
		}
	}
	return nil
}
