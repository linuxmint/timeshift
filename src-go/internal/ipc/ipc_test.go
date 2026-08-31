package ipc

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/jobs"
)

// testServer starts a server on a temp socket with the given methods, with
// every peer authorized read-write.
func testServer(t *testing.T, q *jobs.Queue, methods map[string]Method) *Server {
	return testServerAuth(t, q, methods, func(p Peer) (Peer, error) { return p, nil })
}

// testServerAuth is testServer with an explicit policy. The policy is set
// before Serve() starts: changing it afterwards would be a data race with the
// accept goroutine.
func testServerAuth(t *testing.T, q *jobs.Queue, methods map[string]Method, auth Authorizer) *Server {
	t.Helper()
	// A unix socket path is capped at 108 bytes by sockaddr_un; t.TempDir()
	// names are long, so keep the file name short.
	dir, err := os.MkdirTemp("", "ts")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })

	s := &Server{
		Path:     filepath.Join(dir, "s"),
		GroupGID: -1,
		Methods:  methods,
		Queue:    q,
		// The test process is not root, so the daemon's own policy would refuse
		// it. Supplying the policy is exactly why Authorize is a field.
		Authorize: auth,
	}
	if err := s.Listen(); err != nil {
		t.Fatal(err)
	}
	go s.Serve()
	t.Cleanup(func() { s.Close() })
	return s
}

func TestCallAndResult(t *testing.T) {
	s := testServer(t, nil, map[string]Method{
		"echo": {ReadOnly: true, Fn: func(_ context.Context, _ *Conn, p json.RawMessage) (any, error) {
			var in struct {
				Text string `json:"text"`
			}
			json.Unmarshal(p, &in)
			return map[string]string{"text": in.Text + "!"}, nil
		}},
	})

	c, err := Dial(s.Path)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	var out struct {
		Text string `json:"text"`
	}
	if err := c.Call("echo", map[string]string{"text": "hello"}, &out); err != nil {
		t.Fatal(err)
	}
	if out.Text != "hello!" {
		t.Errorf("text = %q", out.Text)
	}
}

func TestErrorsCarryCodes(t *testing.T) {
	s := testServer(t, nil, map[string]Method{
		"boom": {ReadOnly: true, Fn: func(_ context.Context, _ *Conn, _ json.RawMessage) (any, error) {
			return nil, Errf(CodeNotFound, "no such snapshot %q", "2026-01-01")
		}},
		"raw": {ReadOnly: true, Fn: func(_ context.Context, _ *Conn, _ json.RawMessage) (any, error) {
			return nil, errors.New("something went wrong inside")
		}},
	})

	c, _ := Dial(s.Path)
	defer c.Close()

	err := c.Call("boom", nil, nil)
	var ipcErr *Error
	if !errors.As(err, &ipcErr) {
		t.Fatalf("err = %v, want an *Error", err)
	}
	if ipcErr.Code != CodeNotFound || !strings.Contains(ipcErr.Message, "2026-01-01") {
		t.Errorf("error = %+v", ipcErr)
	}

	// A plain error becomes an internal error rather than leaking as a panic.
	err = c.Call("raw", nil, nil)
	if !errors.As(err, &ipcErr) || ipcErr.Code != CodeInternal {
		t.Errorf("err = %v, want an internal error", err)
	}

	if err := c.Call("nope", nil, nil); !errors.As(err, &ipcErr) || ipcErr.Code != CodeUnknownMethod {
		t.Errorf("unknown method err = %v", err)
	}
}

func TestConcurrentCallsAreDemultiplexed(t *testing.T) {
	s := testServer(t, nil, map[string]Method{
		"slow": {ReadOnly: true, Fn: func(_ context.Context, _ *Conn, p json.RawMessage) (any, error) {
			var in struct {
				N int `json:"n"`
			}
			json.Unmarshal(p, &in)
			// Reverse the delays so replies come back out of order.
			time.Sleep(time.Duration(10-in.N) * 5 * time.Millisecond)
			return map[string]int{"n": in.N}, nil
		}},
	})

	c, _ := Dial(s.Path)
	defer c.Close()

	type res struct {
		want int
		got  int
		err  error
	}
	results := make(chan res, 10)
	for i := 0; i < 10; i++ {
		go func(n int) {
			var out struct {
				N int `json:"n"`
			}
			err := c.Call("slow", map[string]int{"n": n}, &out)
			results <- res{want: n, got: out.N, err: err}
		}(i)
	}
	for i := 0; i < 10; i++ {
		r := <-results
		if r.err != nil {
			t.Errorf("call %d: %v", r.want, r.err)
		}
		if r.got != r.want {
			t.Errorf("reply mismatched: got %d for request %d", r.got, r.want)
		}
	}
}

// The scenario the whole daemon exists for, end to end over the socket: submit
// work, attach a SECOND client while it runs, and watch it live.
func TestSecondClientWatchesRunningJob(t *testing.T) {
	q := jobs.NewQueue(4)
	defer q.Close()

	released := make(chan struct{})
	halfway := make(chan struct{})

	methods := map[string]Method{
		MethodSnapshotCreate: {Fn: func(_ context.Context, _ *Conn, _ json.RawMessage) (any, error) {
			job, err := q.Submit(jobs.KindCreate, func(ctx context.Context, r jobs.Reporter) (jobs.Outcome, error) {
				r.SetPhases([]jobs.Phase{{Key: "sync", Title: "Copying"}})
				r.Phase("sync")
				for i := 1; i <= 3; i++ {
					r.Log(fmt.Sprintf("before-%d", i))
				}
				close(halfway)
				<-released
				for i := 4; i <= 6; i++ {
					r.Log(fmt.Sprintf("after-%d", i))
				}
				r.Progress(jobs.Progress{Count: 6, Total: 6, Percent: 1})
				return jobs.OutcomeOK, nil
			})
			if err != nil {
				return nil, Errf(CodeBusy, "%v", err)
			}
			return JobRef{Job: job.ID}, nil
		}},
		MethodJobsSubscribe: {ReadOnly: true, Fn: func(_ context.Context, c *Conn, p json.RawMessage) (any, error) {
			var in SubscribeParams
			json.Unmarshal(p, &in)
			snap, sub, err := q.Attach(in.Job, in.WithLog)
			if err != nil {
				return nil, Errf(CodeNotFound, "%v", err)
			}
			c.Subscribe(sub)
			return snap, nil
		}},
	}
	s := testServer(t, q, methods)

	// Client one -- stand-in for apt-snapshot-guard -- starts the snapshot.
	guard, err := Dial(s.Path)
	if err != nil {
		t.Fatal(err)
	}
	defer guard.Close()

	var ref JobRef
	if err := guard.Call(MethodSnapshotCreate, CreateParams{Tags: []string{"ondemand"}}, &ref); err != nil {
		t.Fatal(err)
	}
	if ref.Job == "" {
		t.Fatal("no job id returned")
	}

	<-halfway

	// Client two -- stand-in for the GUI -- attaches while it runs. In the Vala
	// build this is where AppLock refuses the process outright.
	gui, err := Dial(s.Path)
	if err != nil {
		t.Fatal(err)
	}
	defer gui.Close()

	snap, err := gui.Subscribe(SubscribeParams{Job: ref.Job, WithLog: true})
	if err != nil {
		t.Fatal(err)
	}
	if snap.State != jobs.StateRunning {
		t.Errorf("snapshot state = %s, want running", snap.State)
	}
	if snap.Phase != "sync" {
		t.Errorf("snapshot phase = %q", snap.Phase)
	}
	if len(snap.LogTail) != 3 {
		t.Fatalf("replayed %d log lines, want the 3 already emitted: %v", len(snap.LogTail), snap.LogTail)
	}

	close(released)

	var live []string
	var finished bool
	deadline := time.After(10 * time.Second)
	for !finished {
		select {
		case e, ok := <-gui.Events():
			if !ok {
				t.Fatal("event stream closed before the job finished")
			}
			switch e.Type {
			case jobs.EventLog:
				live = append(live, e.Line)
			case jobs.EventFinished:
				finished = true
				if e.Outcome != jobs.OutcomeOK {
					t.Errorf("outcome = %s", e.Outcome)
				}
			}
		case <-deadline:
			t.Fatal("timed out waiting for the job to finish")
		}
	}

	if len(live) != 3 || live[0] != "after-4" || live[2] != "after-6" {
		t.Errorf("live lines = %v, want after-4..after-6", live)
	}
}

// Killing the watcher must not disturb the work.
func TestWatcherDisconnectDoesNotStopTheJob(t *testing.T) {
	q := jobs.NewQueue(4)
	defer q.Close()

	release := make(chan struct{})
	job, _ := q.Submit(jobs.KindCreate, func(ctx context.Context, r jobs.Reporter) (jobs.Outcome, error) {
		<-release
		return jobs.OutcomeOK, nil
	})

	s := testServer(t, q, map[string]Method{
		MethodJobsSubscribe: {ReadOnly: true, Fn: func(_ context.Context, c *Conn, p json.RawMessage) (any, error) {
			var in SubscribeParams
			json.Unmarshal(p, &in)
			snap, sub, err := q.Attach(in.Job, in.WithLog)
			if err != nil {
				return nil, Errf(CodeNotFound, "%v", err)
			}
			c.Subscribe(sub)
			return snap, nil
		}},
	})

	gui, _ := Dial(s.Path)
	if _, err := gui.Subscribe(SubscribeParams{Job: job.ID, WithLog: true}); err != nil {
		t.Fatal(err)
	}
	gui.Close() // the GUI is killed

	close(release)

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if job.State().Terminal() {
			break
		}
		time.Sleep(2 * time.Millisecond)
	}
	if job.Snapshot(false).State != jobs.StateFinished {
		t.Error("the job did not finish after its watcher disconnected")
	}
}

// The read-only tier: a group member may watch, but not start or delete.
func TestReadOnlyPeerIsDenied(t *testing.T) {
	// Arrive as a group member would: authorized, but read-only.
	s := testServerAuth(t, nil, map[string]Method{
		"watch": {ReadOnly: true, Fn: func(_ context.Context, _ *Conn, _ json.RawMessage) (any, error) {
			return "ok", nil
		}},
		"mutate": {Fn: func(_ context.Context, _ *Conn, _ json.RawMessage) (any, error) {
			return "ok", nil
		}},
	}, func(p Peer) (Peer, error) {
		p.ReadOnly = true
		return p, nil
	})

	c, _ := Dial(s.Path)
	defer c.Close()

	var out string
	if err := c.Call("watch", nil, &out); err != nil {
		t.Errorf("a read-only peer must be able to watch: %v", err)
	}

	err := c.Call("mutate", nil, nil)
	var ipcErr *Error
	if !errors.As(err, &ipcErr) || ipcErr.Code != CodeDenied {
		t.Errorf("mutating call err = %v, want denied", err)
	}
}

func TestSocketPermissions(t *testing.T) {
	s := testServer(t, nil, nil)
	fi, err := os.Stat(s.Path)
	if err != nil {
		t.Fatal(err)
	}
	// GroupGID is -1 in the test, so root-only.
	if fi.Mode().Perm() != 0600 {
		t.Errorf("socket mode = %v, want 0600 with no group configured", fi.Mode().Perm())
	}
}

// A socket left by a killed daemon must not stop the next one starting.
func TestStaleSocketIsReplaced(t *testing.T) {
	dir, _ := os.MkdirTemp("", "ts")
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "s")

	os.WriteFile(path, []byte("stale"), 0600)

	s := &Server{Path: path, GroupGID: -1, Methods: map[string]Method{},
		Authorize: func(p Peer) (Peer, error) { return p, nil }}
	if err := s.Listen(); err != nil {
		t.Fatalf("a stale socket file should be replaced, not fatal: %v", err)
	}
	s.Close()
}

func TestDialNoDaemon(t *testing.T) {
	_, err := Dial(filepath.Join(t.TempDir(), "absent.sock"))
	if !errors.Is(err, ErrNoDaemon) {
		t.Errorf("err = %v, want ErrNoDaemon", err)
	}
}

func TestMalformedRequestDoesNotKillTheConnection(t *testing.T) {
	s := testServer(t, nil, map[string]Method{
		"ping": {ReadOnly: true, Fn: func(_ context.Context, _ *Conn, _ json.RawMessage) (any, error) {
			return "pong", nil
		}},
	})

	raw, err := dialRaw(s.Path)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()

	// Garbage, then a valid request on the same connection.
	fmt.Fprintln(raw, "{not json at all")
	fmt.Fprintln(raw, `{"id":1,"method":"ping"}`)

	dec := json.NewDecoder(raw)
	var first, second Response
	if err := dec.Decode(&first); err != nil {
		t.Fatal(err)
	}
	if first.Error == nil || first.Error.Code != CodeBadRequest {
		t.Errorf("first response = %+v, want a bad_request error", first)
	}
	if err := dec.Decode(&second); err != nil {
		t.Fatalf("the connection died after malformed input: %v", err)
	}
	if second.Result != "pong" {
		t.Errorf("second response = %+v", second)
	}
}

func TestClientDoneOnServerClose(t *testing.T) {
	s := testServer(t, nil, map[string]Method{})
	c, err := Dial(s.Path)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()

	select {
	case <-c.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("client did not notice the daemon going away")
	}
}
