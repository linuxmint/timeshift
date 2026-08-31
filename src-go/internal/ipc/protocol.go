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
	MethodSystemInfo     = "system.info"
	MethodEnginesList    = "engines.list"
	MethodConfigGet      = "config.get"
	MethodDevicesList    = "devices.list"
	MethodRepoStatus     = "repo.status"
	MethodSnapshotsList  = "snapshots.list"
	MethodSnapshotCreate = "snapshot.create"
	MethodSnapshotDelete = "snapshot.delete"
	MethodEstimateRun    = "estimate.run"
	MethodScheduleCheck  = "schedule.check"
	MethodScheduleStatus = "schedule.status"
	MethodJobsList       = "jobs.list"
	MethodJobsGet        = "jobs.get"
	MethodJobsSubscribe  = "jobs.subscribe"
	MethodJobsCancel     = "jobs.cancel"
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
	Incremental        bool `json:"incremental"`
	Remote             bool `json:"remote"`
	Browse             bool `json:"browse"`
	UnsharedSize       bool `json:"unshared_size"`
	WholeVolumeRestore bool `json:"whole_volume_restore"`
	Encryption         bool `json:"encryption"`
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

// JobRefParams addresses one job.
type JobRefParams struct {
	Job string `json:"job"`
}
