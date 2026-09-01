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
	"encoding/json"
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
}

/* WholeVolumeRestore and Encryption used to be declared here. Nothing set
 * them and nothing read them, and a capability in that state is worse than an
 * absent one: it reads as a firm "no" to any client that branches on it. That
 * is not hypothetical -- Browse was declared TRUE with no browse method behind
 * it, which would have made a client show a button that returns unknown_method.
 *
 * WholeVolumeRestore also cannot be answered here even in principle. Whether a
 * restore swaps a subvolume or transfers files depends on the REPOSITORY's mode,
 * which is not known until Open, and Caps belongs to the Engine. Reintroducing
 * it means putting it where the answer exists, not where it was convenient.
 *
 * Add a capability back in the same change that gives it both a setter and a
 * reader. */

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
	// ---- reading ----

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

	/* ConsoleStatus is the engine's own header presentation, opaque to the
	 * host: a location's description is engine-shaped ("Mode: RSYNC", a device
	 * and UUID, a remote URL) and the host has no business knowing which. It
	 * travels as raw JSON for the same reason Snapshot.EngineData does, and is
	 * decoded by whoever renders it. */
	ConsoleStatus(ctx context.Context, deviceName, deviceUUID string) (json.RawMessage, error)

	// ReadSnapshotFile reads one file from inside a snapshot, e.g. its fstab.
	ReadSnapshotFile(ctx context.Context, snapshotPath, name string) ([]byte, error)

	// ---- writing ----

	// Create takes a snapshot.
	Create(ctx context.Context, req CreateRequest, rep Reporter) (Snapshot, error)

	// Delete removes snapshots. See DeleteOptions for why the caller has to
	// say whether a person asked for this.
	Delete(ctx context.Context, names []string, opts DeleteOptions, rep Reporter) error

	// Estimate measures what a snapshot would transfer, returning the size in
	// bytes and the line count that is the progress denominator for a real run.
	Estimate(ctx context.Context, req EstimateRequest, rep Reporter) (bytes, lines int64, err error)

	// SetTags replaces a snapshot's retention levels.
	SetTags(ctx context.Context, name string, tags []string) error

	// AddTag adds one retention level, used by the scheduler's rotation.
	AddTag(ctx context.Context, name, tag string) error

	// SetDescription sets a snapshot's comment.
	SetDescription(ctx context.Context, name, description string) error

	// SetMarkedForDeletion flags a snapshot for removal.
	SetMarkedForDeletion(ctx context.Context, name string, marked bool) error

	// ---- restore ----

	/* TransferSource describes how to READ a snapshot's payload, which is the
	 * only thing the host restore path needs from the engine. Everything after
	 * the transfer -- fstab, bootloader, initramfs -- belongs to the host and
	 * does not care which engine produced the files. */
	TransferSource(payloadPath string) TransferSource

	// ---- browsing ----

	/* Browse makes a snapshot's files readable at a local path, mounting it
	 * first if the repository is remote. asUID/asGID own that mount: the
	 * daemon runs as root and the file manager does not, so a root-owned mount
	 * is one the person cannot read.
	 *
	 * It does NOT open anything. That needs the desktop user's session, which
	 * the daemon may not have, and belongs to the client. */
	Browse(ctx context.Context, snapshotPath string, asUID, asGID int) (BrowseMount, error)

	// ReleaseBrowse unmounts what Browse mounted. A no-op for a path that was
	// never mounted, because releasing one would unmount the repository.
	ReleaseBrowse(ctx context.Context, mountPoint string) error

	// ---- transport ----

	/* DropMaster tears down any multiplexed transport connection the engine is
	 * holding, reporting whether there was one.
	 *
	 * This is an escape hatch, not housekeeping. A client attaching to a WEDGED
	 * ssh ControlMaster never calls connect(2), so ConnectTimeout never
	 * applies and it waits forever on a connection that is already dead. The
	 * restore script does this itself on a transport failure; this exposes the
	 * same lever to a person watching a stuck operation.
	 */
	DropMaster(ctx context.Context) (dropped bool, err error)

	// ---- lifecycle ----

	/* SetFirstSnapshotSize supplies the estimated size of a first snapshot, so
	 * free-space checks mean something on a repository that holds none yet. */
	SetFirstSnapshotSize(n uint64)

	// Close releases connections and mounts.
	Close() error
}

// CreateRequest is what to snapshot.
type CreateRequest struct {
	// Tags are the retention levels this snapshot belongs to.
	Tags []string

	// Comments is the description. apt-snapshot-guard puts the apt command
	// line here.
	Comments string

	// Source is the tree to copy, "/" in every real use.
	Source string

	// Excludes are the filter rules, already ordered by the host.
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

	/* IncludeBtrfsHome asks a subvolume-based engine to take "@home" as well
	 * as "@".
	 *
	 * It is a request rather than a capability because it is the user's
	 * choice, not the storage's: home may be a separate filesystem the user
	 * does not want copied, and an engine that cannot act on it ignores it.
	 */
	IncludeBtrfsHome bool
}

// EstimateRequest is what to measure.
type EstimateRequest struct {
	Source   string
	Excludes []string
}

// DeleteOptions says why a deletion is happening.
//
// The zero value is the guarded one, on purpose: a caller that has not thought
// about it gets the safe behaviour.
type DeleteOptions struct {
	/* Explicit marks a deletion a PERSON asked for by name, which may remove
	 * anything. An automatic deletion -- retention, prune -- may not remove a
	 * snapshot the repository merely believes is invalid.
	 *
	 * "Invalid" is not evidence. A dropped SSH link makes every snapshot in a
	 * remote repository read as invalid, and the Vala code learned this by
	 * having auto_remove() delete an entire repository afterwards. Positive
	 * evidence that a snapshot is incomplete is the ABSENCE of its control
	 * file. */
	Explicit bool
}

// BrowseMount is a snapshot made readable at a local path.
type BrowseMount struct {
	// Path is where to look.
	Path string

	// Mounted is true when something was mounted and must later be released.
	Mounted bool
}

// TransferSource is how the host reads a snapshot's payload.
type TransferSource struct {
	// Path is the source argument, host-prefixed for a remote repository.
	Path string

	// RSH is the transport command, empty for a local repository.
	RSH string

	// RemoteShellPath is the --rsync-path value, when the remote needs one.
	RemoteShellPath string
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

/* Reporting.
 *
 * These types live here rather than in the daemon's job package so an engine
 * depends on nothing above it. The daemon adapts its own Reporter onto this
 * interface; an engine cannot tell the difference, and cannot learn whether
 * anybody is watching -- which is the whole point.
 */

// Phase is one step of an operation, for the checklist a client draws. Key is
// untranslated ASCII so matching stays locale-independent; Title is for people.
type Phase struct {
	Key   string
	Title string
}

// Progress is what a client renders while work runs.
type Progress struct {
	// Percent is 0..1. Zero with Total zero means indeterminate.
	Percent float64
	Count   int64
	Total   int64
	// ETASeconds is -1 when it cannot be estimated yet.
	ETASeconds int64
	StatusLine string
	Counters   map[string]int64
}

// Reporter is the only channel an engine has to the outside world.
type Reporter interface {
	SetPhases(phases []Phase)
	Phase(key string)
	Progress(p Progress)
	Log(line string)
	Note(msg string)
	Warn(msg string)
	Cancelled() bool
}

// NopReporter discards everything, for callers that just want the result.
type NopReporter struct{}

func (NopReporter) SetPhases([]Phase) {}
func (NopReporter) Phase(string)      {}
func (NopReporter) Progress(Progress) {}
func (NopReporter) Log(string)        {}
func (NopReporter) Note(string)       {}
func (NopReporter) Warn(string)       {}
func (NopReporter) Cancelled() bool   { return false }
