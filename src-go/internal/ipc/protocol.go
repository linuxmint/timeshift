// Package ipc is the wire protocol between timeshiftd and its clients.
//
// One JSON object per line, both directions, over a unix socket. No bus: this
// has to work under pkexec, inside the recovery environment, and forwarded over
// ssh, and a session bus is available in none of those. It also has to work
// when several clients are attached at once, which is the entire point.
//
//	-> {"id":1,"method":"snapshot.create","params":{"tags":["O"]}}
//	<- {"id":1,"result":{"job":"j-7"}}
//	<- {"event":"job.progress","job":"j-7","progress":{...}}
//	<- {"event":"job.finished","job":"j-7","outcome":"ok"}
//
// Responses carry the request's id; events carry none. A client tells them
// apart by which field is present.
package ipc

import (
	"encoding/json"
	"fmt"
)

// SocketPath is where the daemon listens.
//
// Under /run/timeshift alongside the per-pid mount directories. Anything
// sweeping that directory for stale state must only touch numeric-pid
// subdirectories, or it will delete the socket out from under the daemon.
const SocketPath = "/run/timeshift/daemon.sock"

// Group is the system group granted read-only access. Members can watch a
// running backup without pkexec; everything that changes state still needs root.
const Group = "timeshift"

// ProtocolVersion is bumped when the wire format changes incompatibly. A client
// checks it in system.info and refuses rather than misinterpreting.
const ProtocolVersion = 1

// Request is a call from a client.
type Request struct {
	ID     int64           `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params,omitempty"`
}

// Response answers exactly one Request.
type Response struct {
	ID     int64  `json:"id"`
	Result any    `json:"result,omitempty"`
	Error  *Error `json:"error,omitempty"`
}

// Error is a failed call. Code is stable and machine-readable; Message is for
// people.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

// Error codes.
const (
	CodeBadRequest    = "bad_request"
	CodeUnknownMethod = "unknown_method"
	CodeDenied        = "denied"
	CodeNotFound      = "not_found"
	CodeUnavailable   = "unavailable"
	CodeInternal      = "internal"
	CodeBusy          = "busy"
)

// Errf builds an Error.
func Errf(code, format string, args ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...)}
}

// Method names. Keeping them as constants means a typo is a compile error on
// both sides rather than an unknown_method at runtime.
const (
	MethodSystemInfo             = "system.info"
	MethodEnginesList            = "engines.list"
	MethodConfigGet              = "config.get"
	MethodConfigSet              = "config.set"
	MethodDevicesList            = "devices.list"
	MethodRepoStatus             = "repo.status"
	MethodRepoReload             = "repo.reload"
	MethodSnapshotsList          = "snapshots.list"
	MethodSnapshotsUpdate        = "snapshots.update"
	MethodSnapshotsBrowse        = "snapshots.browse"
	MethodSnapshotsBrowseRelease = "snapshots.browse_release"
	MethodSnapshotCreate         = "snapshot.create"
	MethodSnapshotDelete         = "snapshot.delete"
	MethodSnapshotRestore        = "snapshot.restore"
	MethodRestorePlan            = "restore.plan"
	MethodEstimateRun            = "estimate.run"
	MethodScheduleCheck          = "schedule.check"
	MethodScheduleStatus         = "schedule.status"
	MethodJobsList               = "jobs.list"
	MethodJobsGet                = "jobs.get"
	MethodJobsSubscribe          = "jobs.subscribe"
	MethodJobsCancel             = "jobs.cancel"
	MethodJobsPause              = "jobs.pause"
	MethodJobsResume             = "jobs.resume"
)

// SystemInfo answers system.info.
type SystemInfo struct {
	Version         string       `json:"version"`
	ProtocolVersion int          `json:"protocol_version"`
	Engine          string       `json:"engine"`
	Engines         []EngineInfo `json:"engines"`
	ReadOnly        bool         `json:"read_only"`
	ActiveJob       string       `json:"active_job,omitempty"`
}

// EngineInfo describes one registered storage engine.
type EngineInfo struct {
	ID          string `json:"id"`
	DisplayName string `json:"display_name"`
	Caps        Caps   `json:"caps"`
}

// Caps is the engine capability set, mirrored onto the wire so a client can ask
// what an engine can do instead of recognising its name.
type Caps struct {
	Incremental  bool `json:"incremental"`
	Remote       bool `json:"remote"`
	Browse       bool `json:"browse"`
	UnsharedSize bool `json:"unshared_size"`
}

// CreateParams is snapshot.create's input.
type CreateParams struct {
	// Tags are retention levels: ondemand, boot, hourly, daily, weekly,
	// monthly. Empty means ondemand.
	Tags []string `json:"tags,omitempty"`

	// Comments is the snapshot description. apt-snapshot-guard puts the apt
	// command line here.
	Comments string `json:"comments,omitempty"`

	// Location names which configured repository to use. Empty is "default".
	Location string `json:"location,omitempty"`

	// AttachExisting returns the running create's job id instead of queueing a
	// second one. This is what lets two apt frontends racing to snapshot end
	// up watching the same job rather than taking two snapshots.
	AttachExisting bool `json:"attach_existing,omitempty"`
}

// JobRef is returned by anything that starts work.
type JobRef struct {
	Job string `json:"job"`

	// Existing is true when AttachExisting matched a job already running.
	Existing bool `json:"existing,omitempty"`
}

// DeleteParams is snapshot.delete's input.
type DeleteParams struct {
	// Names are snapshot directory names.
	Names    []string `json:"names"`
	Location string   `json:"location,omitempty"`
}

// SubscribeParams is jobs.subscribe's input.
type SubscribeParams struct {
	// Job limits the stream to one job. Empty follows every job.
	Job string `json:"job,omitempty"`

	// WithLog includes job.log events, one per file on a restore. Opt-in.
	WithLog bool `json:"with_log,omitempty"`
}

/* ConfigSetParams is a PARTIAL configuration update.
 *
 * Only the named keys change. A whole-config write would mean a client one
 * version behind silently reverting every key it does not know about, which is
 * precisely the failure the Vala GUI already has against timeshift.json.
 *
 * Keys are the on-disk names ("schedule_hourly", "count_daily"), and values
 * carry the on-disk shapes: every scalar is a JSON *string* ("true", "5"), and
 * the two exclude lists are arrays. A real boolean or number is refused rather
 * than quietly dropped.
 */
type ConfigSetParams struct {
	Values map[string]json.RawMessage `json:"values"`
}

/* BrowseParams asks for a snapshot's files to be made readable.
 *
 * UID/GID say who the mount is for. A client running as root under pkexec must
 * pass the DESKTOP user's ids, because the file manager it goes on to spawn is
 * not root and cannot read a root-owned mount. Left at zero, the daemon uses
 * the calling peer's own ids, which is right for anyone talking to it directly.
 */
type BrowseParams struct {
	Snapshot string `json:"snapshot"`
	UID      int    `json:"uid,omitempty"`
	GID      int    `json:"gid,omitempty"`
}

// BrowseResult is where to look.
type BrowseResult struct {
	Path     string `json:"path"`
	Snapshot string `json:"snapshot,omitempty"`

	/* Mounted says whether releasing is required. False for a local
	 * repository, whose snapshot is already a path on a mounted filesystem --
	 * releasing that would unmount the repository. */
	Mounted bool `json:"mounted"`
}

// BrowseReleaseParams unmounts a browse mount.
type BrowseReleaseParams struct {
	Path string `json:"path"`
}

// RepoStatus is what repo.status returns: the repository's health, plus the
// fields a console header needs to describe where it is.
//
// View is the engine's own presentation struct rather than a copy of it, so the
// CLI can render a socket-sourced header through exactly the same function it
// uses for an in-process one. `timeshift --list` is verified byte-for-byte
// against the Vala binary, and a second renderer is a second thing to keep
// identical.
type RepoStatus struct {
	Code         int    `json:"code"`
	Message      string `json:"message"`
	Details      string `json:"details"`
	Available    bool   `json:"available"`
	HasSnapshots bool   `json:"has_snapshots"`

	/* View is the engine's own header presentation, opaque here.
	 *
	 * Deliberately raw: the wire layer must not import a specific engine, and
	 * this follows the same rule as Snapshot.EngineData -- engine-shaped
	 * detail travels through the protocol without the protocol understanding
	 * it. The CLI decodes it with the engine's own type, so there is exactly
	 * one definition of the shape and one renderer for it. */
	View json.RawMessage `json:"view"`
}

/* SnapshotsUpdateParams edits a snapshot's metadata.
 *
 * Every field is a pointer so that "not mentioned" and "set to empty" are
 * different requests. Clearing a comment has to be expressible, and it looks
 * identical to omitting the field once the pointer is gone.
 */
type SnapshotsUpdateParams struct {
	Name string `json:"name"`

	Comments *string   `json:"comments,omitempty"`
	Tags     *[]string `json:"tags,omitempty"`

	// MarkedForDeletion writes or removes the sidecar marker the next prune
	// acts on. It is a marker rather than an immediate delete so a client can
	// queue several and change its mind.
	MarkedForDeletion *bool `json:"marked_for_deletion,omitempty"`
}

/* RestoreParams describes a restore.
 *
 * Mounts is optional: when empty the daemon builds the default selection from
 * the snapshot's own fstab, which is what the restored system expects. A client
 * that wants something else sends the whole selection rather than a patch, so
 * there is exactly one description of where every filesystem lands and no way
 * to end up with half of two plans.
 */
type RestoreParams struct {
	Snapshot string `json:"snapshot"`

	// Mounts maps a mount point to a device path or "UUID=x". An entry mapped
	// to the empty string is deliberately left on the root filesystem.
	Mounts map[string]string `json:"mounts,omitempty"`

	/* CurrentSystem restores over the running system.
	 *
	 * It must be asked for explicitly. Defaulting to it would mean a client
	 * that forgot to name a target overwrites the machine it is running on,
	 * and there is no undo for that. */
	CurrentSystem bool `json:"current_system,omitempty"`

	// DryRun compares without writing, and measures the progress denominator
	// for a real run.
	DryRun bool `json:"dry_run,omitempty"`

	// SkipGrub leaves the bootloader alone, GrubDevice overrides where it goes.
	SkipGrub   bool   `json:"skip_grub,omitempty"`
	GrubDevice string `json:"grub_device,omitempty"`

	// EstimatedLines is the denominator from a previous dry run.
	EstimatedLines int64 `json:"estimated_lines,omitempty"`
}

// RestorePlanResult is the reviewable plan: what would happen, and whether it
// may proceed.
type RestorePlanResult struct {
	Snapshot string `json:"snapshot"`
	Target   string `json:"target"`

	// Rows is the device table, one line per mount point.
	Rows []RestorePlanRow `json:"rows"`

	// Phases are the steps the restore will take, in order.
	Phases []string `json:"phases"`

	// Notes explain anything folded away or filled in.
	Notes []string `json:"notes,omitempty"`

	// Blocked means the restore must not start. Blockers says why.
	Blocked  bool     `json:"blocked"`
	Blockers []string `json:"blockers,omitempty"`

	// Summary is the whole thing rendered for a person to read.
	Summary string `json:"summary"`
}

// RestorePlanRow is one mount point in the plan.
type RestorePlanRow struct {
	MountPoint string `json:"mount_point"`
	Device     string `json:"device"`
	Status     string `json:"status"`
	Blocking   bool   `json:"blocking"`
}

// JobRefParams addresses one job.
type JobRefParams struct {
	Job string `json:"job"`
}
