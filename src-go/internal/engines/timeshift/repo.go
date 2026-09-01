package timeshift

import (
	"context"
	"fmt"
	"path"
	"sort"
	"strings"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/engines"
	"github.com/makeafide/timeshift/src-go/internal/fsutil"
)

// MinFreeSpace is the floor a repository that already holds snapshots must keep
// available.
//
// Main.MIN_FREE_SPACE is `1 * GB` where TeeJee's GB is 1000*1000*1000 -- a
// DECIMAL gigabyte, not 2^30. The difference shows up in the message the CLI
// prints, because 1e9 is not greater than unit_g and so renders as "1,000 MB".
const MinFreeSpace = 1000 * 1000 * 1000

// SyncDirName is the in-progress transfer directory, which is not a snapshot
// and must never be listed as one.
const SyncDirName = ".sync"

// Control files read for every snapshot in one batch.
var controlFileNames = []string{
	"info.json",
	"exclude.list",
	"delete",
}

// Repo is one open timeshift-engine repository.
type Repo struct {
	Backend Backend
	Deps    engines.Deps

	// MountPath is where the repository lives: a local mount point, or the
	// remote path.
	MountPath string

	// BtrfsMode selects the timeshift-btrfs directory layout.
	BtrfsMode bool

	// FirstSnapshotSize is the estimated size of a first snapshot, used to
	// judge free space when the repository holds none yet.
	FirstSnapshotSize uint64

	// Runner is used for mount management; nil for a remote repository.
	Runner Runner

	// ownedMount is a mount point this Repo created and must release. Empty
	// when the device was already mounted, so Close never unmounts something
	// another client set up.
	ownedMount string

	cachedFree    uint64
	cachedFreeSet bool
}

// TimeshiftPath is the repository root inside the mount point. btrfs snapshots
// live in a separate tree so both modes can coexist on one filesystem.
func (r *Repo) TimeshiftPath() string {
	if r.BtrfsMode {
		return path.Join(r.MountPath, "timeshift-btrfs")
	}
	return path.Join(r.MountPath, "timeshift")
}

// SnapshotsPath is where snapshot directories live.
func (r *Repo) SnapshotsPath() string { return path.Join(r.TimeshiftPath(), "snapshots") }

// Close releases the backend and any mount this Repo made.
func (r *Repo) Close() error {
	err := r.Backend.Close()
	if r.ownedMount != "" && r.Runner != nil {
		if uerr := UnmountRepoDevice(context.Background(), r.Runner, r.ownedMount); uerr != nil && err == nil {
			err = uerr
		}
		r.ownedMount = ""
	}
	return err
}

// List returns every snapshot, oldest first.
//
// A transport failure is an error and never an empty list. That distinction is
// the difference between "this repository has no snapshots" and "I could not
// reach it", and conflating them is how auto_remove() once deleted an entire
// remote repository after a dropped link.
func (r *Repo) List(ctx context.Context) ([]engines.Snapshot, error) {
	root := r.SnapshotsPath()

	if !r.Backend.DirExists(ctx, root) {
		// Not an error: a configured location that has never been used yet.
		return nil, nil
	}

	names, err := r.Backend.ListSubdirs(ctx, root)
	if err != nil {
		return nil, err
	}

	dirs := make([]string, 0, len(names))
	keep := make([]string, 0, len(names))
	for _, name := range names {
		if name == SyncDirName {
			continue
		}
		keep = append(keep, name)
		dirs = append(dirs, path.Join(root, name))
	}
	if len(dirs) == 0 {
		return nil, nil
	}

	files, err := r.Backend.ReadControlFiles(ctx, dirs, controlFileNames)
	if err != nil {
		return nil, fmt.Errorf("timeshift: read control files: %w", err)
	}

	out := make([]engines.Snapshot, 0, len(dirs))
	for i, dir := range dirs {
		out = append(out, r.buildSnapshot(keep[i], dir, files))
	}

	// Oldest first. A snapshot whose control file would not parse has a zero
	// time and sorts to the front, where it is visible rather than buried.
	sort.SliceStable(out, func(i, j int) bool {
		return out[i].Created.Before(out[j].Created)
	})
	return out, nil
}

// buildSnapshot turns one directory's control files into a Snapshot.
func (r *Repo) buildSnapshot(name, dir string, files map[string]string) engines.Snapshot {
	s := engines.Snapshot{
		Name:          name,
		Path:          dir,
		Valid:         true,
		SizeBytes:     -1,
		UnsharedBytes: -1,
		EngineData:    map[string]any{},
	}

	raw, ok := files[dir+"\x00info.json"]
	if !ok {
		// No control file at all: listed, but marked invalid. Hiding it would
		// make the repository look emptier than it is, and what is not seen
		// gets pruned.
		s.Valid = false
		return s
	}

	c, err := ParseControlFile([]byte(raw))
	if err != nil {
		s.Valid = false
		return s
	}

	s.Created = c.Created

	/* A snapshot with no usable date must never be dated to the epoch.
	 *
	 * Retention compares dates against windows, so a zero time reads as "older
	 * than everything" and the snapshot is untagged and then deleted -- because
	 * one field of its control file would not parse.
	 *
	 * The directory name IS the timestamp, so there is a second source for it.
	 * If that fails too the snapshot is marked invalid, which is the safe end
	 * state: pruning an invalid snapshot needs positive evidence that it is
	 * incomplete, and a snapshot holding a control file never provides it.
	 */
	if s.Created.IsZero() {
		if t, err := time.ParseInLocation(NameLayout, name, time.Local); err == nil {
			s.Created = t
		} else {
			s.Valid = false
		}
	}

	s.Tags = c.Tags
	s.Description = c.Description
	s.SysUUID = c.SysUUID
	s.SysDistro = c.SysDistro
	s.AppVersion = c.AppVersion
	s.FileCount = c.FileCount
	s.Live = c.Live
	s.SizeBytes = c.TotalSize()
	s.UnsharedBytes = c.UnsharedSize()

	_, s.MarkedForDeletion = files[dir+"\x00delete"]

	/* An rsync snapshot with no exclude.list is invalid. The file records what
	 * was left out when the snapshot was taken, and without it a restore cannot
	 * know what it is allowed to delete on the target. */
	if !c.IsBtrfs() {
		if _, ok := files[dir+"\x00exclude.list"]; !ok {
			s.Valid = false
		}
	}

	s.EngineData["type"] = c.Type
	if len(c.Subvolumes) > 0 {
		s.EngineData["subvolumes"] = c.Subvolumes
	}

	return s
}

// FreeBytes reports the space available for new snapshots.
func (r *Repo) FreeBytes(ctx context.Context) (uint64, error) {
	if r.cachedFreeSet {
		return r.cachedFree, nil
	}
	_, _, avail, err := r.Backend.QuerySpace(ctx, r.MountPath)
	if err != nil {
		return 0, err
	}
	r.cachedFree, r.cachedFreeSet = avail, true
	return avail, nil
}

// Status reports whether the repository is usable, and renders the message and
// detail line the CLI and the GUI status card show.
//
// The strings are reproduced from SnapshotRepo.has_space() because they are
// what `timeshift --list` prints today.
func (r *Repo) Status(ctx context.Context) (engines.Status, error) {
	st := engines.Status{Code: engines.StatusNotAvailable}

	/* Strings from SnapshotRepo.available() and has_space(). They are what
	 * `timeshift --list` prints today, so they are output, not prose. */
	if msg, err := r.Backend.TestConnection(ctx); err != nil {
		if r.Backend.IsRemote() {
			st.Message = "Remote location not available"
		} else {
			st.Message = "Snapshot device not available"
		}
		st.Details = msg
		return st, nil
	}

	snapshots, listErr := r.List(ctx)
	if listErr != nil {
		if r.Backend.IsRemote() {
			st.Message = "Remote location not available"
		} else {
			st.Message = "Snapshot device not available"
		}
		st.Details = listErr.Error()
		return st, nil
	}
	st.Available = true
	st.HasSnapshots = len(snapshots) > 0

	free, err := r.FreeBytes(ctx)
	if err != nil {
		st.Available = false
		st.Message = "Failed to query disk space on remote location"
		st.Details = err.Error()
		return st, nil
	}

	if st.HasSnapshots {
		if free < MinFreeSpace {
			st.Code = engines.StatusHasSnapshotsNoSpace
			/* Decimals 0 and grouping, matching the format_file_size() call in
			 * has_space(). MinFreeSpace is 1e9, which is not GREATER than
			 * unit_g, so this renders as "1,000 MB" rather than "1 GB". */
			st.Message = "Not enough disk space (< " +
				fsutil.FormatSize(MinFreeSpace,
					fsutil.SizeOpts{ShowUnits: true, Group: true}) + ")"
			st.Details = "Select another device or free up some space"
			st.Available = false
			return st, nil
		}
		st.Code = engines.StatusHasSnapshotsHasSpace
		st.Message = "OK"
		st.Details = fmt.Sprintf("%d snapshots, %s free",
			len(snapshots), fsutil.FormatSize(free, fsutil.DefaultSizeOpts()))
		return st, nil
	}

	required := r.FirstSnapshotSize
	if free < required {
		st.Code = engines.StatusNoSnapshotsNoSpace
		st.Message = "Not enough disk space (< " +
			fsutil.FormatSize(required, fsutil.DefaultSizeOpts()) + ")"
		st.Details = "Select another device or free up some space"
		st.Available = false
		return st, nil
	}
	st.Code = engines.StatusNoSnapshotsHasSpace
	st.Message = "No snapshots on this device"
	st.Details = "First snapshot requires: " +
		fsutil.FormatSize(required, fsutil.DefaultSizeOpts())
	return st, nil
}

// PrintStatus renders the header block `timeshift --list` prints above the
// table, reproducing SnapshotRepo.print_status() including its "%-6s : %s"
// column and the blank line that follows.
// StatusView is everything the console header shows about a location.
//
// It exists so that the two ways of producing that header -- opening the
// repository in-process, and asking the daemon over the socket -- cannot drift.
// `timeshift --list` is byte-for-byte identical to the Vala binary's output and
// is verified by diffing the two, so a second renderer would be a second thing
// to keep identical, and the one that got missed would fail silently.
type StatusView struct {
	Remote     bool   `json:"remote"`
	Display    string `json:"display"`
	Path       string `json:"path"`
	TypeID     string `json:"type_id"`
	BtrfsMode  bool   `json:"btrfs_mode"`
	DeviceName string `json:"device_name"`
	DeviceUUID string `json:"device_uuid"`
	Message    string `json:"message"`
	Details    string `json:"details"`
}

// StatusView gathers the header fields for this repository.
func (r *Repo) StatusView(ctx context.Context, deviceName, deviceUUID string) (StatusView, error) {
	st, err := r.Status(ctx)
	if err != nil {
		return StatusView{}, err
	}
	return StatusView{
		Remote:     r.Backend.IsRemote(),
		Display:    r.Backend.DisplayName(),
		Path:       r.MountPath,
		TypeID:     r.Backend.TypeID(),
		BtrfsMode:  r.BtrfsMode,
		DeviceName: deviceName,
		DeviceUUID: deviceUUID,
		Message:    st.Message,
		Details:    st.Details,
	}, nil
}

// RenderStatus writes the console header. The ONLY place that layout exists.
func RenderStatus(w *strings.Builder, v StatusView) {
	line := func(label, value string) {
		fmt.Fprintf(w, "%-6s : %s\n", label, value)
	}

	if v.Remote {
		line("Remote", v.Display)
		line("Path", v.Path)
		line("Type", v.TypeID)
		line("Status", v.Message)
	} else if v.DeviceName == "" {
		line("Device", "Not Selected")
		w.WriteString("\n")
		return
	} else {
		line("Device", v.DeviceName)
		line("UUID", v.DeviceUUID)
		line("Path", v.Path)
		mode := "RSYNC"
		if v.BtrfsMode {
			mode = "BTRFS"
		}
		line("Mode", mode)
		line("Status", v.Message)
	}
	w.WriteString(v.Details + "\n")
	w.WriteString("\n")
}

func (r *Repo) PrintStatus(ctx context.Context, w *strings.Builder, deviceName, deviceUUID string) error {
	v, err := r.StatusView(ctx, deviceName, deviceUUID)
	if err != nil {
		return err
	}
	RenderStatus(w, v)
	return nil
}

// mkdirp creates a directory in the repository.
func (r *Repo) mkdirp(ctx context.Context, p string) error {
	return r.Backend.MakeDir(ctx, p)
}

// writeFile writes a file into the repository.
func (r *Repo) writeFile(ctx context.Context, p string, data []byte) error {
	return r.Backend.WriteFile(ctx, p, data)
}

// removeCommand is the argv that deletes a tree with one line of output per
// path removed.
func (r *Repo) removeCommand(p string) []string { return r.Backend.RemoveCommand(p) }

// streamCommand runs a command, handing every line of its output to onLine.
func (r *Repo) streamCommand(ctx context.Context, argv []string, onLine func(string)) (int, error) {
	if r.Deps.Runner == nil {
		return -1, fmt.Errorf("timeshift: no command runner")
	}
	return r.Deps.Runner.Stream(ctx, argv, func(_ string, line string) { onLine(line) })
}
