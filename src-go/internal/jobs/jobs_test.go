package jobs

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"
)

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func drain(sub *Subscription, until func(Event) bool) []Event {
	var got []Event
	timeout := time.After(5 * time.Second)
	for {
		select {
		case e, ok := <-sub.C:
			if !ok {
				return got
			}
			got = append(got, e)
			if until(e) {
				return got
			}
		case <-timeout:
			return got
		}
	}
}

func TestRunToCompletion(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()

	job, err := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		r.SetPhases([]Phase{{Key: "prepare", Title: "Preparing"}, {Key: "sync", Title: "Copying"}})
		r.Phase("prepare")
		r.Phase("sync")
		r.Progress(Progress{Percent: 1, Count: 10, Total: 10})
		r.Log("a line")
		return OutcomeOK, nil
	})
	if err != nil {
		t.Fatal(err)
	}

	waitFor(t, "job to finish", func() bool { return job.State().Terminal() })

	s := job.Snapshot(true)
	if s.State != StateFinished {
		t.Errorf("state = %s", s.State)
	}
	if s.Outcome != OutcomeOK {
		t.Errorf("outcome = %s", s.Outcome)
	}
	if s.Phase != "sync" || len(s.Phases) != 2 {
		t.Errorf("phases = %+v / %q", s.Phases, s.Phase)
	}
	if len(s.LogTail) != 1 || s.LogTail[0] != "a line" {
		t.Errorf("log tail = %v", s.LogTail)
	}
	if s.Started.IsZero() || s.Finished.IsZero() {
		t.Error("timestamps not recorded")
	}
}

// THE test. A client attaching halfway through must see the work already done,
// then the rest live -- with no gap between the two. In the Vala build this is
// impossible: AppLock refuses the second process outright.
func TestLateSubscriberSeesEverything(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()

	released := make(chan struct{})
	halfway := make(chan struct{})

	job, err := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		r.SetPhases([]Phase{{Key: "sync", Title: "Copying"}})
		r.Phase("sync")
		for i := 1; i <= 5; i++ {
			r.Log(fmt.Sprintf("before-%d", i))
			r.Progress(Progress{Count: int64(i), Total: 10})
		}
		close(halfway)
		<-released
		for i := 6; i <= 10; i++ {
			r.Log(fmt.Sprintf("after-%d", i))
			r.Progress(Progress{Count: int64(i), Total: 10})
		}
		return OutcomeOK, nil
	})
	if err != nil {
		t.Fatal(err)
	}

	<-halfway

	// Attach now, with the job already half done.
	snap, sub, err := q.Attach(job.ID, true)
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Close()

	if snap.State != StateRunning {
		t.Errorf("snapshot state = %s, want running", snap.State)
	}
	if snap.Progress.Count != 5 {
		t.Errorf("snapshot count = %d, want the 5 already done", snap.Progress.Count)
	}
	if snap.Phase != "sync" {
		t.Errorf("snapshot phase = %q", snap.Phase)
	}
	// The replay: everything logged before we arrived.
	if len(snap.LogTail) != 5 {
		t.Fatalf("log tail has %d lines, want the 5 already emitted", len(snap.LogTail))
	}
	if snap.LogTail[0] != "before-1" || snap.LogTail[4] != "before-5" {
		t.Errorf("log tail = %v", snap.LogTail)
	}

	close(released)

	events := drain(sub, func(e Event) bool { return e.Type == EventFinished })

	var live []string
	var finished bool
	for _, e := range events {
		if e.Type == EventLog {
			live = append(live, e.Line)
		}
		if e.Type == EventFinished {
			finished = true
		}
	}
	if !finished {
		t.Fatal("never saw job.finished")
	}
	// And the live half, with nothing missing between snapshot and stream.
	if len(live) != 5 || live[0] != "after-6" || live[4] != "after-10" {
		t.Errorf("live log lines = %v, want after-6..after-10", live)
	}
}

// Killing the watcher must not touch the work. This is the other half of the
// motivating scenario: close the GUI, the backup carries on.
func TestClosingSubscriberDoesNotStopTheJob(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()

	release := make(chan struct{})
	job, _ := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		<-release
		r.Log("finished anyway")
		return OutcomeOK, nil
	})

	_, sub, err := q.Attach(job.ID, true)
	if err != nil {
		t.Fatal(err)
	}
	sub.Close() // the client goes away

	close(release)
	waitFor(t, "job to finish without its watcher", func() bool { return job.State().Terminal() })

	if job.Snapshot(false).State != StateFinished {
		t.Error("the job did not complete after its subscriber left")
	}
}

// A subscriber that stops reading must be dropped, never waited for: a stuck
// GUI cannot be allowed to stall a backup.
func TestSlowSubscriberIsDroppedNotWaitedFor(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()

	sub := q.Hub().Subscribe(SubscribeOptions{WithLog: true})
	defer sub.Close()

	done := make(chan struct{})
	job, _ := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		// Far more than the subscriber buffer, and nobody is reading.
		for i := 0; i < subscriberBuffer*4; i++ {
			r.Log(fmt.Sprintf("line-%d", i))
		}
		close(done)
		return OutcomeOK, nil
	})

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("publishing blocked on a subscriber that stopped reading")
	}

	waitFor(t, "job to finish", func() bool { return job.State().Terminal() })
	if sub.Dropped() == 0 {
		t.Error("a subscriber that never read should have had events dropped")
	}
}

// One at a time, in order. This single writer is what replaces AppLock.
func TestJobsRunOneAtATimeInOrder(t *testing.T) {
	q := NewQueue(8)
	defer q.Close()

	var mu sync.Mutex
	var order []string
	var concurrent, maxConcurrent int

	for i := 0; i < 5; i++ {
		name := fmt.Sprintf("job-%d", i)
		_, err := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
			mu.Lock()
			concurrent++
			if concurrent > maxConcurrent {
				maxConcurrent = concurrent
			}
			order = append(order, name)
			mu.Unlock()

			time.Sleep(5 * time.Millisecond)

			mu.Lock()
			concurrent--
			mu.Unlock()
			return OutcomeOK, nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}

	waitFor(t, "all jobs to finish", func() bool {
		mu.Lock()
		defer mu.Unlock()
		return len(order) == 5
	})

	if maxConcurrent != 1 {
		t.Errorf("%d jobs ran at once; the queue must serialise them", maxConcurrent)
	}
	for i, name := range order {
		if name != fmt.Sprintf("job-%d", i) {
			t.Errorf("ran out of order: %v", order)
			break
		}
	}
}

// A second create while one is running is queued, and the caller is handed its
// id -- rather than being refused the way AppLock refuses a second process.
func TestActiveJobIsVisible(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()

	release := make(chan struct{})
	first, _ := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		<-release
		return OutcomeOK, nil
	})

	waitFor(t, "first job to start", func() bool { return q.Active() != nil })

	if q.Active().ID != first.ID {
		t.Errorf("Active = %v, want the running job", q.Active())
	}

	second, err := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		return OutcomeOK, nil
	})
	if err != nil {
		t.Fatalf("a second submission must be queued, not refused: %v", err)
	}
	if second.State() != StateQueued {
		t.Errorf("second job state = %s, want queued", second.State())
	}

	close(release)
	waitFor(t, "both to finish", func() bool {
		return first.State().Terminal() && second.State().Terminal()
	})
}

func TestQueueFull(t *testing.T) {
	q := NewQueue(1)
	defer q.Close()

	release := make(chan struct{})
	defer close(release)

	// One runs, one waits, the third has nowhere to go.
	q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		<-release
		return OutcomeOK, nil
	})
	waitFor(t, "first to start", func() bool { return q.Active() != nil })
	q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) { return OutcomeOK, nil })

	if _, err := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		return OutcomeOK, nil
	}); !errors.Is(err, ErrQueueFull) {
		t.Errorf("err = %v, want ErrQueueFull", err)
	}

	// A refused job must not be left in the listing.
	for _, s := range q.List() {
		if s.State == StateQueued && len(q.List()) > 2 {
			t.Error("a refused submission was left in the job list")
		}
	}
}

func TestCancel(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()

	started := make(chan struct{})
	job, _ := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		close(started)
		<-ctx.Done()
		// A cancelled runner reports the error, which is what marks the job
		// cancelled rather than merely finished.
		return OutcomeFailed, ctx.Err()
	})

	<-started
	job.Cancel()

	waitFor(t, "job to be cancelled", func() bool { return job.State().Terminal() })
	if got := job.Snapshot(false).State; got != StateCancelled {
		t.Errorf("state = %s, want cancelled", got)
	}
}

func TestReporterCancelledFlag(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()

	started := make(chan struct{})
	sawCancel := make(chan bool, 1)

	job, _ := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		close(started)
		for i := 0; i < 500; i++ {
			if r.Cancelled() {
				sawCancel <- true
				return OutcomeFailed, ctx.Err()
			}
			time.Sleep(2 * time.Millisecond)
		}
		sawCancel <- false
		return OutcomeOK, nil
	})

	<-started
	job.Cancel()

	if !<-sawCancel {
		t.Error("Cancelled() never reported true after Cancel()")
	}
}

// Warnings are a real outcome, not a failure. rsync exit 23 -- files that
// vanished mid-copy -- is normal when backing up a running system.
func TestWarningsSurvive(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()

	job, _ := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		r.Warn("some files vanished during transfer")
		return OutcomeOK, nil
	})
	waitFor(t, "finish", func() bool { return job.State().Terminal() })

	s := job.Snapshot(false)
	if s.Outcome != OutcomeWarnings {
		t.Errorf("outcome = %s, want warnings", s.Outcome)
	}
	if s.State != StateFinished {
		t.Errorf("state = %s; warnings are not a failure", s.State)
	}
	if len(s.Messages) != 1 {
		t.Errorf("messages = %v", s.Messages)
	}
}

func TestFailure(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()

	job, _ := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		return OutcomeFailed, errors.New("the disk went away")
	})
	waitFor(t, "finish", func() bool { return job.State().Terminal() })

	s := job.Snapshot(false)
	if s.State != StateFailed || s.Outcome != OutcomeFailed {
		t.Errorf("state=%s outcome=%s", s.State, s.Outcome)
	}
	if !strings.Contains(s.Error, "disk went away") {
		t.Errorf("error = %q", s.Error)
	}
}

// A panic in an engine must not take the daemon down: every other client's view
// of every other job depends on this process staying up.
func TestPanicIsContained(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()

	job, _ := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		panic("engine went wrong")
	})
	waitFor(t, "finish", func() bool { return job.State().Terminal() })

	s := job.Snapshot(false)
	if s.State != StateFailed {
		t.Errorf("state = %s, want failed", s.State)
	}
	if !strings.Contains(s.Error, "panic") {
		t.Errorf("error = %q, should name the panic", s.Error)
	}

	// And the queue still works.
	next, err := q.Submit(KindEstimate, func(ctx context.Context, r Reporter) (Outcome, error) {
		return OutcomeOK, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the next job to run", func() bool { return next.State().Terminal() })
}

// Log events are high volume, so a status-only subscriber must not get them.
func TestLogEventsAreOptIn(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()

	quiet := q.Hub().Subscribe(SubscribeOptions{})
	defer quiet.Close()

	job, _ := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		r.Log("noisy")
		return OutcomeOK, nil
	})
	waitFor(t, "finish", func() bool { return job.State().Terminal() })

	for _, e := range drain(quiet, func(e Event) bool { return e.Type == EventFinished }) {
		if e.Type == EventLog {
			t.Error("a subscriber that did not ask for logs received one")
		}
	}
}

func TestSubscriptionFilteredByJob(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()

	release := make(chan struct{})
	first, _ := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		<-release
		return OutcomeOK, nil
	})
	waitFor(t, "first to start", func() bool { return q.Active() != nil })

	sub := q.Hub().Subscribe(SubscribeOptions{JobID: first.ID})
	defer sub.Close()

	second, _ := q.Submit(KindDelete, func(ctx context.Context, r Reporter) (Outcome, error) {
		r.Progress(Progress{Count: 1, Total: 1})
		return OutcomeOK, nil
	})

	close(release)
	waitFor(t, "both to finish", func() bool {
		return first.State().Terminal() && second.State().Terminal()
	})

	for _, e := range drain(sub, func(e Event) bool {
		return e.Type == EventFinished && e.Job == first.ID
	}) {
		if e.Job != first.ID {
			t.Errorf("received an event for %s on a subscription filtered to %s", e.Job, first.ID)
		}
	}
}

func TestGetAndList(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()

	a, _ := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) { return OutcomeOK, nil })
	waitFor(t, "a to finish", func() bool { return a.State().Terminal() })
	b, _ := q.Submit(KindDelete, func(ctx context.Context, r Reporter) (Outcome, error) { return OutcomeOK, nil })
	waitFor(t, "b to finish", func() bool { return b.State().Terminal() })

	if _, err := q.Get(a.ID); err != nil {
		t.Errorf("Get(%s): %v", a.ID, err)
	}
	if _, err := q.Get("j-nope"); !errors.Is(err, ErrNoSuchJob) {
		t.Errorf("Get of an unknown id = %v, want ErrNoSuchJob", err)
	}

	list := q.List()
	if len(list) != 2 || list[0].ID != a.ID || list[1].ID != b.ID {
		t.Errorf("List = %+v, want oldest first", list)
	}
}

func TestAttachUnknownJob(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()
	if _, _, err := q.Attach("j-nope", false); !errors.Is(err, ErrNoSuchJob) {
		t.Errorf("err = %v, want ErrNoSuchJob", err)
	}
}

// Several clients watching the same job all see it.
func TestManySubscribers(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()

	release := make(chan struct{})
	job, _ := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		<-release
		r.Progress(Progress{Count: 1, Total: 1})
		return OutcomeOK, nil
	})
	waitFor(t, "job to start", func() bool { return q.Active() != nil })

	const n = 8
	subs := make([]*Subscription, n)
	for i := range subs {
		_, s, err := q.Attach(job.ID, false)
		if err != nil {
			t.Fatal(err)
		}
		subs[i] = s
		defer s.Close()
	}
	if got := q.Hub().Subscribers(); got != n {
		t.Errorf("Subscribers = %d, want %d", got, n)
	}

	close(release)

	for i, s := range subs {
		saw := false
		for _, e := range drain(s, func(e Event) bool { return e.Type == EventFinished }) {
			if e.Type == EventFinished {
				saw = true
			}
		}
		if !saw {
			t.Errorf("subscriber %d never saw the job finish", i)
		}
	}
}
