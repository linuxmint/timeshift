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

/* ProtocolVersion is bumped when the wire format changes in a way a client can
 * RELY on, and a client checks it rather than misinterpreting.
 *
 * 2 added LocationOverride. That is not a cosmetic addition: JSON ignores
 * unknown fields, so a version-1 daemon handed an override silently used the
 * CONFIGURED repository instead -- and for `--delete-all --snapshot-device X`
 * that means listing and deleting from the wrong place with no error at all.
 * A field a client depends on being understood needs a version behind it.
 */
const ProtocolVersion = 2

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
	MethodDevicesUnlock          = "devices.unlock"
	MethodDevicesLock            = "devices.lock"
	MethodRepoStatus             = "repo.status"
	MethodRepoReload             = "repo.reload"
	MethodRepoSelect             = "repo.select"
	MethodRepoDropMaster         = "repo.drop_master"
	MethodRepoSSHScanHost        = "repo.ssh.scan_host"
	MethodRepoSSHSetupKey        = "repo.ssh.setup_key"
	MethodRepoSSHTest            = "repo.ssh.test"
	MethodSnapshotsList          = "snapshots.list"
	MethodSnapshotsUpdate        = "snapshots.update"
	MethodSnapshotsBrowse        = "snapshots.browse"
	MethodSnapshotsBrowseRelease = "snapshots.browse_release"
	MethodLogParse               = "log.parse"
	MethodLogEntries             = "log.entries"
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
	MethodRecoveryStatus         = "recovery.status"
	MethodRecoveryEnable         = "recovery.enable"
	MethodRecoveryDisable        = "recovery.disable"
	MethodRecoveryInstall        = "recovery.install"
)

// SystemInfo answers system.info.
type SystemInfo struct {
	Version         string       `json:"version"`
	ProtocolVersion int          `json:"protocol_version"`
	Engine          string       `json:"engine"`
	Engines         []EngineInfo `json:"engines"`
	ReadOnly        bool         `json:"read_only"`
	ActiveJob       string       `json:"active_job,omitempty"`

	/* Live reports that this machine booted from removable media.
	 *
	 * Distinct from ReadOnly, which is about the CALLER's permissions. This is
	 * a property of the machine: there is no installed system here to
	 * snapshot, so creating one is refused however privileged the caller is.
	 * Restoring is still allowed -- that is what a rescue environment is for.
	 */
	Live bool `json:"live,omitempty"`
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

/* RecoveryStatus reports the press-R recovery environment.
 *
 * Fields carries the tool's own KEY=VALUE output verbatim, so a client can show
 * something useful even for keys added by a newer timeshift-recovery than this
 * daemon knows about. The named fields are the ones a UI branches on.
 */
type RecoveryStatus struct {
	// Available is false when the timeshift-recovery package is not installed,
	// which is an ordinary state rather than an error.
	Available bool `json:"available"`

	Installed   bool   `json:"installed"`
	Disabled    bool   `json:"disabled"`
	Stale       bool   `json:"stale"`
	HostVersion string `json:"host_version,omitempty"`
	EnvVersion  string `json:"env_version,omitempty"`
	Target      string `json:"target,omitempty"`

	Fields map[string]string `json:"fields,omitempty"`
}

// RecoveryVerbResult confirms an instant enable or disable.
type RecoveryVerbResult struct {
	Verb string `json:"verb"`
	OK   bool   `json:"ok"`
}

// RecoveryInstallParams builds and installs the environment. Empty fields mean
// the tool's own defaults.
type RecoveryInstallParams struct {
	Target string `json:"target,omitempty"`
	Size   string `json:"size,omitempty"`
}

// RepoStatusParams may point at a repository other than the configured one.
type RepoStatusParams struct {
	Location *LocationOverride `json:"location,omitempty"`
}

// SnapshotsListParams may point at a repository other than the configured one.
type SnapshotsListParams struct {
	Location *LocationOverride `json:"location,omitempty"`
}

/* LocationOverride points one request at a repository other than the
 * configured one, without changing what is configured.
 *
 * This is `timeshift --list --snapshot-device /dev/sdb1` and its relatives.
 * Vala implements them by setting the same fields it would have loaded and not
 * saving them, which is the right shape: an override is a config that was never
 * written down.
 *
 * It travels over the wire rather than being applied client-side because
 * `--list` prefers the daemon and falls back to opening the repository itself.
 * An override that worked only on the fallback path would make one command mean
 * two different things depending on whether the daemon happened to be running.
 */
type LocationOverride struct {
	Device     string `json:"device,omitempty"`
	DeviceUUID string `json:"device_uuid,omitempty"`
	URL        string `json:"url,omitempty"`
	KeyFile    string `json:"key_file,omitempty"`
	Port       int    `json:"port,omitempty"`

	/* BtrfsMode is a POINTER so that "leave it alone" and "force it off" are
	 * different requests. A plain bool cannot express --rsync. */
	BtrfsMode *bool `json:"btrfs_mode,omitempty"`
}

// Empty reports an override that asks for nothing.
func (o *LocationOverride) Empty() bool {
	return o == nil || (o.Device == "" && o.DeviceUUID == "" && o.URL == "" &&
		o.KeyFile == "" && o.Port == 0 && o.BtrfsMode == nil)
}

/* RepoSelectParams chooses where snapshots are stored.
 *
 * Exactly one of Device/DeviceUUID or URL. DryRun reports the verdict without
 * writing anything, which is what a Location page wants while a person clicks
 * around a device list.
 */
type RepoSelectParams struct {
	Device     string `json:"device,omitempty"`
	DeviceUUID string `json:"device_uuid,omitempty"`
	URL        string `json:"url,omitempty"`
	DryRun     bool   `json:"dry_run,omitempty"`
}

/* RepoSelectResult says whether the place can hold snapshots, and why not.
 *
 * Reason exists because Main.check_device_for_backup() answered with a boolean,
 * which is why the GUI could only say no without saying why.
 */
type RepoSelectResult struct {
	Type       string `json:"type"`
	Device     string `json:"device,omitempty"`
	DeviceUUID string `json:"device_uuid,omitempty"`
	URL        string `json:"url,omitempty"`
	Usable     bool   `json:"usable"`
	Reason     string `json:"reason,omitempty"`
	Saved      bool   `json:"saved"`
}

// SSHScanHostParams fetches a remote's host key.
type SSHScanHostParams struct {
	Host string `json:"host"`
	Port int    `json:"port,omitempty"`
}

/* SSHScanHostResult is the host key and the fingerprint to show a person.
 *
 * Shown BEFORE any password is sent: otherwise the first connection is
 * trust-on-first-use with a password already in flight.
 */
type SSHScanHostResult struct {
	Host        string `json:"host"`
	Line        string `json:"line"`
	Fingerprint string `json:"fingerprint"`
}

/* SSHSetupKeyParams provisions key-based login to a remote repository.
 *
 * URL, KeyFile and Port are optional: empty means the configured location. An
 * explicit URL is how a Location page tests credentials for a repository that
 * has not been saved yet, rather than having to save a broken one to find out
 * it is broken.
 *
 * HostKeyLine is the line from SSHScanHostResult, passed back to say "the
 * person saw this fingerprint and accepted it". Empty means nothing is
 * trusted, and a host that is not already in known_hosts will be refused.
 *
 * Password is used only if the key does not already authenticate. It goes to
 * ssh through SSH_ASKPASS in the child's environment, never in argv.
 */
type SSHSetupKeyParams struct {
	URL         string `json:"url,omitempty"`
	KeyFile     string `json:"key_file,omitempty"`
	Port        int    `json:"port,omitempty"`
	HostKeyLine string `json:"host_key_line,omitempty"`
	Password    string `json:"password,omitempty"`
}

// SSHSetupKeyResult says what actually happened, step by step, because each
// step can fail in a way a person has to see.
type SSHSetupKeyResult struct {
	KeyFile        string `json:"key_file"`
	KeyCreated     bool   `json:"key_created"`
	HostKeyTrusted bool   `json:"host_key_trusted"`
	Installed      bool   `json:"installed"`
	Verified       bool   `json:"verified"`

	// AlreadyWorking means the key authenticated before anything was done, so
	// no password was needed and nothing was installed.
	AlreadyWorking bool `json:"already_working"`

	/* StaleKeysRemoved counts this machine's OLD keys deleted from the remote
	 * account once the new one was proven to work.
	 *
	 * ssh-copy-id appends, so without this a reinstalled machine leaves every
	 * key it ever installed still granting access, with the private half gone.
	 * Additive: a client talking to a daemon that predates it reads zero and
	 * simply says nothing, which is the right degradation for a tidy-up. */
	StaleKeysRemoved int `json:"stale_keys_removed,omitempty"`
}

// SSHTestParams checks a location. Empty fields mean the configured one.
type SSHTestParams struct {
	URL     string `json:"url,omitempty"`
	KeyFile string `json:"key_file,omitempty"`
	Port    int    `json:"port,omitempty"`
}

// SSHTestResult reports reachability in terms a person can act on.
type SSHTestResult struct {
	Host    string `json:"host"`
	OK      bool   `json:"ok"`
	Message string `json:"message"`
}

// DropMasterResult reports whether there was a control master to tear down.
type DropMasterResult struct {
	Dropped bool `json:"dropped"`
}

/* DeviceUnlockParams opens a LUKS container.
 *
 * The passphrase is collected by the CLIENT, which is the only party that can
 * reach a person. It travels on stdin from here to cryptsetup and is never put
 * in argv, where /proc/<pid>/cmdline would expose it to anything on the
 * machine, and never into a log line.
 */
type DeviceUnlockParams struct {
	// Device is a path, kernel name or mapper name, as devices.list reports.
	Device string `json:"device"`

	// Name is the device-mapper name to create. Defaults to "<kname>_crypt",
	// which is what Device.vala has always used, so a container unlocked by
	// either build appears at the same /dev/mapper path.
	Name string `json:"name,omitempty"`

	Passphrase string `json:"passphrase,omitempty"`
}

// DeviceUnlockResult is the mapper device now standing on the container.
type DeviceUnlockResult struct {
	Device     string `json:"device"`
	MappedName string `json:"mapped_name"`
	Path       string `json:"path,omitempty"`
	UUID       string `json:"uuid,omitempty"`
	FSType     string `json:"fstype,omitempty"`

	// AlreadyOpen means someone had unlocked it first. Success, not an error:
	// the caller wanted a usable device and there is one.
	AlreadyOpen bool `json:"already_open"`
}

// DeviceLockParams closes a container by its mapper name.
type DeviceLockParams struct {
	Name string `json:"name"`
}

// DeviceLockResult confirms which one was closed.
type DeviceLockResult struct {
	Name string `json:"name"`
}

// LogEntriesMaxLimit caps one page of a parsed log.
//
// A real snapshot log holds a couple of hundred thousand entries, so an
// unbounded page is a download rather than a response.
const LogEntriesMaxLimit = 5000

/* LogParseParams names the log to read.
 *
 * Either Path -- which must be under /var/log/timeshift, because the daemon is
 * root and this would otherwise be an arbitrary-file-read primitive -- or
 * Snapshot, naming a snapshot whose own rsync log is wanted.
 */
type LogParseParams struct {
	Path     string `json:"path,omitempty"`
	Snapshot string `json:"snapshot,omitempty"`

	// Name is the log inside the snapshot; "rsync-log" when empty.
	Name string `json:"name,omitempty"`
}

// LogParseResult is the job doing the parsing, and the file it resolved to.
//
// The path is returned because log.entries is keyed by it, and for a snapshot
// the client did not name it.
type LogParseResult struct {
	Job  string `json:"job"`
	Path string `json:"path"`
}

// LogEntriesParams asks for one page of a parsed log.
type LogEntriesParams struct {
	Path   string `json:"path"`
	Offset int    `json:"offset,omitempty"`
	Limit  int    `json:"limit,omitempty"`

	// Kinds filters by change kind. Empty means everything. Filtering happens
	// on this side: the point of paging is not to send what is not wanted.
	Kinds []string `json:"kinds,omitempty"`
}

// LogEntry is one changed path.
type LogEntry struct {
	Path string `json:"path"`
	Kind string `json:"kind"`
}

// LogEntriesResult is a page, plus the totals a summary needs.
type LogEntriesResult struct {
	Path    string         `json:"path"`
	Total   int            `json:"total"`
	Lines   int64          `json:"lines"`
	Counts  map[string]int `json:"counts"`
	Offset  int            `json:"offset"`
	Entries []LogEntry     `json:"entries"`
	More    bool           `json:"more"`
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
/* DeviceInfo is one block device as devices.list reports it.
 *
 * Flat, with PKName naming the parent, rather than nested children: a client
 * building a Gtk.TreeListModel asks for children lazily and would have to take
 * the nesting apart again, and a flat list survives a device whose parent was
 * filtered out by whatever rule the client is applying.
 *
 * HasLinuxFilesystem is reported rather than applied. It is the rule the
 * console listing filters on, and a client that wants that listing can apply
 * it -- but a client drawing the disk tree needs the rows it rejects, because
 * a disk has no filesystem and is exactly what the partitions hang from.
 */
type DeviceInfo struct {
	Path      string `json:"path"`
	Name      string `json:"name"`
	KName     string `json:"kname"`
	PKName    string `json:"pkname"`
	UUID      string `json:"uuid"`
	Label     string `json:"label"`
	PartLabel string `json:"partlabel"`
	Type      string `json:"type"`
	FSType    string `json:"fstype"`
	Vendor    string `json:"vendor"`
	Model     string `json:"model"`
	Serial    string `json:"serial"`
	Revision  string `json:"revision"`

	SizeBytes int64 `json:"size_bytes"`
	FreeBytes int64 `json:"free_bytes"`

	/* UsedBytes travels with FreeBytes because a client cannot derive it.
	 *
	 * Size is the partition; used and free come from statfs and do not add up
	 * to it -- there are reserved blocks in between. A client needing "how full
	 * is this" has to be told both. It is also how a caller tells an UNMOUNTED
	 * device from a full one: neither has free space, but only a mounted one
	 * has used space, and df cannot answer for something that is not mounted.
	 */
	UsedBytes int64 `json:"used_bytes"`

	Mounted bool `json:"mounted"`

	MountPoints        []string `json:"mount_points"`
	HasLinuxFilesystem bool     `json:"has_linux_filesystem"`
	ReadOnly           bool     `json:"read_only"`
	Removable          bool     `json:"removable"`
}

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
