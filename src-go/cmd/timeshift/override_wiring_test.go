package main

import (
	"bufio"
	"encoding/json"
	"net"
	"path/filepath"
	"sync"
	"testing"

	"github.com/makeafide/timeshift/src-go/internal/ipc"
)

/* The location override, from the flag to the request that acts on it.
 *
 * These are wiring tests, and wiring is exactly what was broken: every piece
 * existed and was individually correct. LocationOverride was defined, the CLI
 * parsed --snapshot-device into it, applyOverride turned it into a config and
 * openRepoOverridden opened it. Only nothing connected the two halves for any
 * verb that WRITES, so the flag reached repo.status and snapshots.list and
 * stopped there.
 *
 * A daemon-side test cannot catch that -- the daemon behaves correctly on the
 * override it is given, and it was never given one. The assertion has to be
 * made on the request that leaves the client.
 */

// recordingDaemon is the smallest daemon that runDeleteAll will talk to.
type recordingDaemon struct {
	mu       sync.Mutex
	requests map[string]json.RawMessage
	ln       net.Listener
}

func newRecordingDaemon(t *testing.T) *recordingDaemon {
	t.Helper()
	path := filepath.Join(t.TempDir(), "d.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	d := &recordingDaemon{requests: map[string]json.RawMessage{}, ln: ln}
	go d.serve()
	t.Cleanup(func() { ln.Close() })
	return d
}

func (d *recordingDaemon) path() string { return d.ln.Addr().String() }

func (d *recordingDaemon) seen(method string) json.RawMessage {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.requests[method]
}

func (d *recordingDaemon) serve() {
	for {
		conn, err := d.ln.Accept()
		if err != nil {
			return
		}
		go d.handle(conn)
	}
}

func (d *recordingDaemon) handle(conn net.Conn) {
	defer conn.Close()
	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	enc := json.NewEncoder(conn)

	for sc.Scan() {
		var req ipc.Request
		if err := json.Unmarshal(sc.Bytes(), &req); err != nil {
			return
		}

		d.mu.Lock()
		d.requests[req.Method] = req.Params
		d.mu.Unlock()

		var result any
		switch req.Method {
		case ipc.MethodSystemInfo:
			result = ipc.SystemInfo{ProtocolVersion: ipc.ProtocolVersion}
		case ipc.MethodSnapshotsList:
			// engines.Snapshot has no json tags, so the wire carries Go field
			// names. Encoding a bare map keeps this test independent of that.
			result = []map[string]any{{"Name": "2026-01-01_00-00-00"}}
		case ipc.MethodSnapshotDelete, ipc.MethodSnapshotCreate, ipc.MethodEstimateRun:
			result = ipc.JobRef{Job: "j-1"}
		case ipc.MethodJobsSubscribe:
			// Terminal on arrival, so watchJob returns without an event stream.
			result = map[string]any{"id": "j-1", "state": "finished", "outcome": "ok"}
		default:
			result = map[string]any{}
		}
		if err := enc.Encode(ipc.Response{ID: req.ID, Result: result}); err != nil {
			return
		}
	}
}

func deviceOverride(uuid string) *ipc.LocationOverride {
	return &ipc.LocationOverride{DeviceUUID: uuid}
}

// locationOf pulls the override back out of a recorded request.
func locationOf(t *testing.T, raw json.RawMessage) *ipc.LocationOverride {
	t.Helper()
	if raw == nil {
		t.Fatal("the method was never called")
	}
	var got struct {
		Location *ipc.LocationOverride `json:"location"`
	}
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	return got.Location
}

/* THE regression test.
 *
 * --delete-all listed from the overridden repository, printed those snapshot
 * names for confirmation, and then sent the delete with no override at all --
 * so the daemon removed snapshots of those names from the CONFIGURED
 * repository. Snapshots are named by timestamp, so the names commonly exist in
 * both: it did not fail, it deleted the wrong copies.
 */
func TestDeleteAllDeletesFromTheRepositoryItListed(t *testing.T) {
	d := newRecordingDaemon(t)
	ov := deviceOverride("1111-2222")

	if rc := runDeleteAll(d.path(), ov, true, true); rc != 0 {
		t.Fatalf("runDeleteAll returned %d", rc)
	}

	listed := locationOf(t, d.seen(ipc.MethodSnapshotsList))
	deleted := locationOf(t, d.seen(ipc.MethodSnapshotDelete))

	if listed == nil || listed.DeviceUUID != "1111-2222" {
		t.Fatalf("the listing did not carry the override: %+v", listed)
	}
	if deleted == nil {
		t.Fatal("the DELETE carried no override: it would remove snapshots " +
			"of these names from the configured repository")
	}
	if deleted.DeviceUUID != listed.DeviceUUID {
		t.Errorf("delete targeted %q but the confirmation described %q",
			deleted.DeviceUUID, listed.DeviceUUID)
	}
}

func TestCreateCarriesTheOverride(t *testing.T) {
	d := newRecordingDaemon(t)

	if rc := runCreate(d.path(), ipc.CreateParams{
		Tags: []string{"ondemand"}, Location: deviceOverride("aaaa"),
	}, true); rc != 0 {
		t.Fatalf("runCreate returned %d", rc)
	}

	got := locationOf(t, d.seen(ipc.MethodSnapshotCreate))
	if got == nil || got.DeviceUUID != "aaaa" {
		t.Fatalf("create did not carry the override: %+v", got)
	}
}

func TestEstimateCarriesTheOverride(t *testing.T) {
	d := newRecordingDaemon(t)

	if rc := runEstimate(d.path(), deviceOverride("bbbb"), true); rc != 0 {
		t.Fatalf("runEstimate returned %d", rc)
	}

	got := locationOf(t, d.seen(ipc.MethodEstimateRun))
	if got == nil || got.DeviceUUID != "bbbb" {
		t.Fatalf("estimate did not carry the override: %+v", got)
	}
}

func TestDeleteCarriesTheOverride(t *testing.T) {
	d := newRecordingDaemon(t)

	if rc := runDelete(d.path(), []string{"2026-01-01_00-00-00"}, deviceOverride("cccc"), true); rc != 0 {
		t.Fatalf("runDelete returned %d", rc)
	}

	got := locationOf(t, d.seen(ipc.MethodSnapshotDelete))
	if got == nil || got.DeviceUUID != "cccc" {
		t.Fatalf("delete did not carry the override: %+v", got)
	}
}

/* An override on a verb that cannot honour it is refused, not ignored.
 *
 * The allow-list is deliberate: a verb added later is refused until somebody
 * decides what an override means for it. Silently ignoring is what the previous
 * protocol version did, for every writing verb, for its whole life.
 */
func TestOverrideAppliesOnlyWhereItIsHonoured(t *testing.T) {
	for _, m := range []string{"list-snapshots", "list-devices", "create",
		"estimate", "delete", "delete-all", "setup-ssh-key"} {
		if !overrideApplies(m) {
			t.Errorf("--%s opens a repository and must honour the override", m)
		}
	}
	for _, m := range []string{"restore", "check", "watch", "cancel",
		"schedule-status", "recovery-install", "recovery-status"} {
		if overrideApplies(m) {
			t.Errorf("--%s does not read the override and must refuse it", m)
		}
	}
}

/* Attaching to a running job and naming a different repository are mutually
 * exclusive: the job already in flight may be writing somewhere else, and
 * reporting it as this request's snapshot is the same lie in a new place. */
func TestAnOverriddenCreateDoesNotAttachToARunningJob(t *testing.T) {
	d := newRecordingDaemon(t)

	if rc := runCreate(d.path(), ipc.CreateParams{
		Location: deviceOverride("dddd"), AttachExisting: false,
	}, true); rc != 0 {
		t.Fatalf("runCreate returned %d", rc)
	}

	var got ipc.CreateParams
	if err := json.Unmarshal(d.seen(ipc.MethodSnapshotCreate), &got); err != nil {
		t.Fatal(err)
	}
	if got.AttachExisting {
		t.Error("an overridden create asked to attach to a job that may be " +
			"writing to a different repository")
	}
}
