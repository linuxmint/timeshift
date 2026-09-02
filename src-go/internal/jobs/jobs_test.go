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

// fakeWriteLock records what the queue asked for and can be held open, so a
// test can observe a job waiting rather than racing it.
type fakeWriteLock struct {
	mu       sync.Mutex
	taken    []string
	held     bool
	release  chan struct{}
	announce string
}

func (f *fakeWriteLock) Acquire(ctx context.Context, what string, waiting func(string)) (func(), error) {
	f.mu.Lock()
	f.taken = append(f.taken, what)
	gate := f.release
	held := f.held
	msg := f.announce
	f.mu.Unlock()

	if held {
		if waiting != nil {
			waiting(msg)
		}
		select {
		case <-gate:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return func() {}, nil
}

// The queue must take the write lock for work that writes the repository and
// leave it alone for work that only reads. Blocking an estimate behind another
// Timeshift would be AppLock's mistake again: refusing harmless work.
func TestWriteLockIsTakenOnlyForMutatingJobs(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()

	lock := &fakeWriteLock{}
	q.SetWriteLock(lock)

	/* Every kind, so a new one added later is a decision rather than an
	 * accident. Recovery builds a root filesystem and writes GRUB; it touches
	 * no snapshots, so blocking it behind a backup would be AppLock's mistake
	 * again -- refusing work that does not conflict. */
	for _, kind := range []Kind{
		KindCreate, KindDelete, KindRestore,
		KindEstimate, KindParseLog, KindRecovery,
	} {
		j, err := q.Submit(kind, func(ctx context.Context, r Reporter) (Outcome, error) {
			return OutcomeOK, nil
		})
		if err != nil {
			t.Fatalf("submit %s: %v", kind, err)
		}
		<-j.Done()
	}

	lock.mu.Lock()
	got := append([]string(nil), lock.taken...)
	lock.mu.Unlock()

	want := []string{"create", "delete", "restore"}
	if len(got) != len(want) {
		t.Fatalf("lock taken for %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("lock taken for %v, want %v", got, want)
		}
	}
}

// A job blocked on the lock is running and reporting, not silently hung: the
// holder is named in the job's messages so a person can see what to wait for.
func TestAJobWaitingOnTheLockSaysWhy(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()

	lock := &fakeWriteLock{
		held:     true,
		release:  make(chan struct{}),
		announce: "restore (pid 4242)",
	}
	q.SetWriteLock(lock)

	ran := make(chan struct{})
	j, err := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		close(ran)
		return OutcomeOK, nil
	})
	if err != nil {
		t.Fatalf("submit: %v", err)
	}

	select {
	case <-ran:
		t.Fatal("the job ran while the repository lock was held by someone else")
	case <-time.After(150 * time.Millisecond):
	}

	close(lock.release)
	<-j.Done()

	snap := j.Snapshot(false)
	found := false
	for _, m := range snap.Messages {
		if strings.Contains(m, "restore (pid 4242)") {
			found = true
		}
	}
	if !found {
		t.Fatalf("job never said who it was waiting for; messages = %v", snap.Messages)
	}
}

// Failing to take the lock fails the job. It must never fall through and write
// the repository anyway.
func TestAJobFailsWhenTheLockCannotBeTaken(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()

	q.SetWriteLock(errWriteLock{})

	ran := false
	j, err := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		ran = true
		return OutcomeOK, nil
	})
	if err != nil {
		t.Fatalf("submit: %v", err)
	}
	<-j.Done()

	if ran {
		t.Fatal("the job wrote the repository despite failing to take the lock")
	}
	if snap := j.Snapshot(false); snap.State != StateFailed {
		t.Fatalf("state = %s, want %s", snap.State, StateFailed)
	}
}

type errWriteLock struct{}

func (errWriteLock) Acquire(ctx context.Context, what string, waiting func(string)) (func(), error) {
	return nil, errors.New("no lock for you")
}

/* A refused submission must not remove somebody else's job.
 *
 * The bug this pins: Submit registered the job, then tried to enqueue, then on
 * a full queue rolled back with `q.order = q.order[:len(q.order)-1]` -- which
 * assumes the caller is still the last element. Two concurrent submits break
 * that assumption and the truncate deletes the OTHER job's id, so a job that
 * runs is missing from jobs.list and cannot be found or watched.
 *
 * Every job that Submit reports as accepted must appear in List.
 */
func TestRefusedSubmitDoesNotDropAnotherJob(t *testing.T) {
	/* Many rounds, deliberately.
	 *
	 * The defect is a race between two Submits, so a single round detects it
	 * only occasionally -- measured at 2 failures in 40 runs against the buggy
	 * version, which is the kind of flaky test that gets deleted rather than
	 * believed. Repeating the contention inside the test makes it reliable:
	 * the same measurement against 200 rounds fails every time.
	 */
	for round := 0; round < 200; round++ {
		block := make(chan struct{})
		q := NewQueue(2)

		// Occupy the worker so the queue can actually fill up.
		if _, err := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
			<-block
			return OutcomeOK, nil
		}); err != nil {
			t.Fatal(err)
		}

		var wg sync.WaitGroup
		var mu sync.Mutex
		var accepted []string

		for i := 0; i < 8; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				j, err := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
					return OutcomeOK, nil
				})
				if err != nil {
					return // ErrQueueFull is a legitimate answer
				}
				mu.Lock()
				accepted = append(accepted, j.ID)
				mu.Unlock()
			}()
		}
		wg.Wait()

		listed := map[string]bool{}
		for _, j := range q.List() {
			listed[j.ID] = true
		}
		for _, id := range accepted {
			if !listed[id] {
				close(block)
				q.Close()
				t.Fatalf("round %d: job %s was accepted by Submit but is missing from List",
					round, id)
			}
		}

		close(block)
		q.Close()
	}
}

/* The job table must not grow forever.
 *
 * A daemon whose lifetime is measured in months runs a scheduled check every
 * ten minutes, and every job it ever ran used to be retained along with its own
 * ring buffer of log lines. Nothing removed anything.
 */
func TestFinishedJobsAreEvicted(t *testing.T) {
	q := NewQueue(2)
	defer q.Close()
	q.retain = 5

	for i := 0; i < 40; i++ {
		j, err := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
			return OutcomeOK, nil
		})
		if err != nil {
			// A full queue is fine; wait for the worker and retry.
			time.Sleep(time.Millisecond)
			continue
		}
		<-j.Done()
	}

	if got := len(q.List()); got > q.retain {
		t.Errorf("kept %d jobs, want at most %d", got, q.retain)
	}
	if len(q.List()) == 0 {
		t.Error("eviction must keep the recent jobs, not drop everything")
	}
}

/* A running job is never evicted, however far over the cap the table is.
 *
 * Dropping it would take away the thing a client attaches to -- and the job
 * apt is blocking on is exactly the one most likely to still be running.
 */
func TestEvictionSparesTheRunningJob(t *testing.T) {
	q := NewQueue(2)
	defer q.Close()
	q.retain = 2

	block := make(chan struct{})
	running, err := q.Submit(KindCreate, func(ctx context.Context, r Reporter) (Outcome, error) {
		<-block
		return OutcomeOK, nil
	})
	if err != nil {
		t.Fatal(err)
	}

	// Push well past the cap with jobs that finish immediately.
	for i := 0; i < 20; i++ {
		j, err := q.Submit(KindEstimate, func(ctx context.Context, r Reporter) (Outcome, error) {
			return OutcomeOK, nil
		})
		if err != nil {
			time.Sleep(time.Millisecond)
			continue
		}
		_ = j
	}

	if _, err := q.Get(running.ID); err != nil {
		t.Fatalf("the running job was evicted: %v", err)
	}

	close(block)
	<-running.Done()
}

/* Every event a job publishes names its kind.
 *
 * A client following everything -- jobs.subscribe with an empty job, which is
 * the case the daemon exists for -- otherwise learns that something started
 * and never what it was, and cannot decide whether the repository it is
 * showing has just changed. Chasing the kind with jobs.get is a race that a
 * short job wins: a delete finishes in milliseconds.
 */
func TestEveryEventCarriesTheKind(t *testing.T) {
	q := NewQueue(4)
	defer q.Close()

	sub := q.Hub().Subscribe(SubscribeOptions{WithLog: true})
	defer sub.Close()

	_, err := q.Submit(KindDelete, func(_ context.Context, r Reporter) (Outcome, error) {
		r.SetPhases([]Phase{{Key: "remove", Title: "Removing"}})
		r.Phase("remove")
		r.Progress(Progress{Percent: 1, Count: 1, Total: 1})
		r.Log("a line")
		return OutcomeOK, nil
	})
	if err != nil {
		t.Fatal(err)
	}

	events := drain(sub, func(e Event) bool { return e.Type == EventFinished })

	seen := map[string]bool{}
	for _, e := range events {
		if e.Job == "" {
			continue // hub-wide events (config.changed) have no job and no kind
		}
		seen[e.Type] = true
		if e.Kind != KindDelete {
			t.Errorf("%s carries kind %q, want %q", e.Type, e.Kind, KindDelete)
		}
	}
	for _, want := range []string{EventStarted, EventPhase, EventProgress, EventLog, EventFinished} {
		if !seen[want] {
			t.Errorf("never saw a %s event", want)
		}
	}
}
