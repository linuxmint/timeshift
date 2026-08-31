// Package engines defines the seam between "what Timeshift decides" and "how a
// snapshot is actually stored".
//
// The Vala core has no such seam. The backup mode is the boolean
// App.btrfs_mode and every mode-sensitive operation is an `if (btrfs_mode)`
// branch, repeated some forty times across the core and the GUI; local versus
// remote is a second, unrelated axis handled by RepoBackend. Adding a third way
// to store a snapshot would mean a third axis of branching through the same
// forty sites.
//
// Here there is one named Engine per storage strategy. The rsync/btrfs/SSH
// behaviour every existing installation is using becomes the "timeshift"
// engine; anything new is a sibling, not another branch.
//
// Four boundaries make that hold up:
//
//   - Reporter is the ONLY way an engine talks to the outside world. It never
//     learns whether a GUI is attached, which is what retires the
//     `Gtk.Window? parent_window` parameter threaded through restore_snapshot(),
//     mount_target_devices() and all five SnapshotRepo constructors purely to
//     raise a password prompt.
//
//   - The engine restores the payload; the host restores the system. That line
//     already exists in the Vala code as the sh_sync / sh_finish split in
//     create_restore_scripts(): sh_sync is the file transfer, sh_finish is
//     chroot + GRUB + initramfs + hooks. GRUB does not care which engine
//     produced the files.
//
//   - Caps drives the UI, never `if engine == "timeshift"`. A client hides the
//     Browse button because Caps.Browse is false, not because it recognised a
//     name.
//
//   - Engine-specific metadata rides in Snapshot.EngineData. The btrfs
//     subvolume table and rsync's unshared size live there, so the host never
//     has to know what a subvolume is.
//
// Tags and retention deliberately stay OUT of the engine. The O/B/H/D/W/M tag
// set and the count_* limits are Timeshift policy, not storage mechanics: the
// scheduler decides when and with which tag, and hands the engine a
// RetentionPolicy to enforce. A new engine inherits the scheduling behaviour
// rather than reimplementing it.
package engines

import (
	"context"
	"errors"
	"time"
)

// Errors an engine may return that callers distinguish.
var (
	// ErrNotAvailable means the repository cannot be reached right now: the
	// device is not attached, the remote host is down, the path is gone.
	ErrNotAvailable = errors.New("engines: repository not available")

	// ErrNotSupported means the engine cannot do what was asked. Check Caps
	// first; this is the backstop.
	ErrNotSupported = errors.New("engines: operation not supported by this engine")

	// ErrNoSnapshot means the named snapshot is not in the repository.
	ErrNoSnapshot = errors.New("engines: no such snapshot")
)

// Engine is a way of storing snapshots.
type Engine interface {
	// ID is the stable key written to timeshift.json. Never translated.
	ID() string

	// DisplayName is shown in a UI.
	DisplayName() string

	// Caps describes what this engine can do.
	Caps() Caps

	// Open connects to a repository. A failure to reach it is
	// ErrNotAvailable, not a reason to refuse to construct.
	Open(ctx context.Context, loc Location, deps Deps) (Repository, error)
}

// Caps is what a client asks instead of recognising an engine by name.
type Caps struct {
	// Incremental means a new snapshot only stores what changed.
	Incremental bool
	// Remote means the repository can live on another host.
	Remote bool
	// Browse means individual files inside a snapshot can be listed and read.
	Browse bool
	// UnsharedSize means the engine can report per-snapshot exclusive size --
	// the "Unique" column. rsync computes it with a hardlink walk; an engine
	// with content-addressed storage may not be able to at all.
	UnsharedSize bool
	// WholeVolumeRestore means restore swaps a whole subvolume rather than
	// transferring files, so there is no per-file progress to report.
	WholeVolumeRestore bool
	// Encryption means the engine encrypts at rest by itself.
	Encryption bool
}

// Location is a configured place to store snapshots. Exactly one of Device or
// SSH is meaningful, per Type.
type Location struct {
	// Name identifies the location. "default" until named locations exist; the
	// field is here so adding them later is additive rather than a protocol
	// break.
	Name string

	// Type is "local" or "ssh", matching backup_location_type.
	Type string

	// DeviceUUID is the local block device holding the repository.
	DeviceUUID string

	// MountPath is where the repository lives once mounted, or the remote path
	// for an SSH location.
	MountPath string

	// SSH carries the remote parameters. Zero for a local location.
	SSH SSHLocation

	// BtrfsMode selects subvolume snapshots over file transfer. Only the
	// timeshift engine reads this; it exists on Location rather than in
	// EngineOptions because the host has to know too -- a btrfs repository
	// cannot be remote, and the GUI greys out the choice.
	BtrfsMode bool
}

// SSHLocation is a remote repository reached with rsync over ssh.
type SSHLocation struct {
	User string
	Host string
	Port int
	Path string

	// KeyFile is the identity to use; empty means the engine's default.
	KeyFile string

	// FakeSuper uses rsync --fake-super, which stores ownership in extended
	// attributes when the remote account is not root. Without it rsync drops
	// ownership silently, which is a restored system with every file owned by
	// the backup user.
	FakeSuper bool
}

// Deps is what the host lends an engine. Passing these rather than reaching for
// globals is the whole difference from the Vala core, where SnapshotRepo called
// back into the god object and Subvolume read four of its fields.
type Deps struct {
	// Runner executes external commands.
	Runner Runner

	// Log is the session logger.
	Log Logger

	// Auth answers credential prompts -- a LUKS passphrase, an SSH key
	// password. May be nil, which means unattended: an engine that needs a
	// secret then fails cleanly instead of blocking on a prompt nobody will
	// see.
	Auth AuthProvider

	// TempDir is a writable scratch directory. rsync opens --log-file and
	// --exclude-from on the CLIENT side, so for a remote repository both have
	// to be written here and uploaded afterwards.
	TempDir string

	// MountRoot is where the engine may mount things, normally
	// /run/timeshift/<pid>.
	MountRoot string
}

// Runner is sysexec.Runner, restated here so this package does not depend on
// the concrete implementation.
type Runner interface {
	Run(ctx context.Context, argv []string, stdin string) (exitCode int, stdout, stderr string, err error)
	Stream(ctx context.Context, argv []string, onLine func(stream, line string)) (exitCode int, err error)
}

// Logger is the subset of slog an engine needs.
type Logger interface {
	Debug(msg string, args ...any)
	Info(msg string, args ...any)
	Warn(msg string, args ...any)
	Error(msg string, args ...any)
}

// AuthProvider answers a credential request. The daemon implements it by asking
// its attached clients; a scheduled run with nobody attached returns an error,
// which is a clean failure rather than the Vala behaviour of having no one to
// prompt at all.
type AuthProvider interface {
	Passphrase(ctx context.Context, req PassphraseRequest) (string, error)
}

// PassphraseRequest describes what is being unlocked.
type PassphraseRequest struct {
	Kind   string // "luks" | "ssh-key"
	Target string // device path or key file
	Prompt string
}

// Repository is one open repository.
type Repository interface {
	// Status reports whether the repository is usable and why not.
	Status(ctx context.Context) (Status, error)

	// List returns every snapshot, oldest first.
	//
	// A transport failure must return an error and NOT an empty slice. The
	// Vala code learned this the hard way: a dropped SSH link made every
	// snapshot read as invalid and auto_remove() then deleted the entire
	// repository.
	List(ctx context.Context) ([]Snapshot, error)

	// FreeBytes is the space available for new snapshots.
	FreeBytes(ctx context.Context) (uint64, error)

	// Close releases connections and mounts.
	Close() error
}

// Status is a repository's health, and is what a client renders as its status
// card.
type Status struct {
	// Code is the machine-readable state.
	Code StatusCode

	// Message is a one-line summary, already translated by the host.
	Message string

	// Details is the supporting line, e.g. "9 snapshots, 29.9 TB free".
	Details string

	// Available means operations can be attempted.
	Available bool

	// HasSnapshots is whether the repository holds any.
	HasSnapshots bool
}

// StatusCode enumerates repository states.
//
// The numeric values match Vala's SnapshotLocationStatus so a log or a saved
// config from either side means the same thing.
type StatusCode int

const (
	StatusNotSelected           StatusCode = -2
	StatusNotAvailable          StatusCode = -1
	StatusHasSnapshotsHasSpace  StatusCode = 0
	StatusHasSnapshotsNoSpace   StatusCode = 1
	StatusNoSnapshotsNoSpace    StatusCode = 2
	StatusNoSnapshotsHasSpace   StatusCode = 3
	StatusReadOnlyFS            StatusCode = 4
	StatusHardlinksNotSupported StatusCode = 5
	StatusNoBtrfsSystem         StatusCode = 6
)

// Snapshot is one stored snapshot, in engine-neutral terms.
type Snapshot struct {
	// Name is the identity used everywhere, including over IPC: the
	// "%Y-%m-%d_%H-%M-%S" directory name.
	Name string

	// Path is where it lives, for display and for browse.
	Path string

	// Created is when it was taken.
	Created time.Time

	// Tags are the retention levels it belongs to: ondemand, boot, hourly,
	// daily, weekly, monthly.
	Tags []string

	// Description is the user's or the guard's comment.
	Description string

	// SysUUID is the root device the snapshot came from, and SysDistro the
	// distribution string. A snapshot whose SysUUID differs from the running
	// system's is one taken on another machine.
	SysUUID   string
	SysDistro string

	// AppVersion is the Timeshift that wrote it.
	AppVersion string

	// FileCount is how many files it holds, where the engine knows.
	FileCount int64

	// SizeBytes is its apparent size; UnsharedBytes the part not shared with
	// any neighbour. Both are -1 when not computed.
	SizeBytes     int64
	UnsharedBytes int64

	// Live marks the snapshot taken automatically just before a restore.
	Live bool

	// Valid is false for a snapshot whose control file is missing or
	// unreadable. Invalid snapshots are listed, not silently hidden -- a
	// repository that looks empty is how data gets deleted.
	Valid bool

	// MarkedForDeletion is set by a client and acted on by the next prune.
	MarkedForDeletion bool

	// EngineData carries whatever the engine needs and the host does not
	// understand: the btrfs subvolume table, rsync's log paths.
	EngineData map[string]any
}

// HasTag reports membership of a retention level.
func (s Snapshot) HasTag(tag string) bool {
	for _, t := range s.Tags {
		if t == tag {
			return true
		}
	}
	return false
}
