// Package jobs runs Timeshift's long operations and lets any number of clients
// watch them.
//
// This is the package the whole port exists for. In the Vala build the state of
// a running backup lives in the fields of one process's Main object, so only
// that process can see it -- and AppLock refuses a second instance outright.
// Start a snapshot from apt-snapshot-guard and the GUI cannot be opened at all,
// let alone show you what is happening.
//
// Here a job is a first-class object with an id, and its progress is broadcast.
// A client that attaches halfway through is given the current state and the
// tail of the log before the live stream starts, so joining late looks the same
// as having been there. A client that goes away -- or is killed -- changes
// nothing about the job.
//
// Two rules make that safe:
//
//   - One worker goroutine runs one mutating job at a time, FIFO. That single
//     writer replaces AppLock, and it is enforced in one place rather than by
//     every caller remembering to take a lock.
//   - A subscriber that stops reading is DROPPED, never waited for. A stuck GUI
//     must not be able to stall a backup, which is exactly what would happen if
//     the job blocked writing to its channel.
package jobs

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/logging"
)

// State is where a job is in its life.
type State string

const (
	StateQueued    State = "queued"
	StateRunning   State = "running"
	StatePaused    State = "paused"
	StateFinished  State = "finished"
	StateCancelled State = "cancelled"
	StateFailed    State = "failed"
)

// Terminal reports whether no further change is possible.
func (s State) Terminal() bool {
	return s == StateFinished || s == StateCancelled || s == StateFailed
}

// Kind is what a job does.
type Kind string

const (
	KindCreate   Kind = "create"
	KindDelete   Kind = "delete"
	KindEstimate Kind = "estimate"
	KindRestore  Kind = "restore"
	KindParseLog Kind = "parse-log"
)

// Outcome is how a finished job turned out.
//
// WARNINGS is a real outcome and not a failure: rsync exit 23 means some files
// could not be transferred, which for a backup of a running system is normal --
// sockets and vanishing temp files. Treating it as failure would make almost
// every snapshot look broken.
type Outcome string

const (
	OutcomeOK       Outcome = "ok"
	OutcomeWarnings Outcome = "warnings"
	OutcomeFailed   Outcome = "failed"
)

// Phase is one step of a job, for the checklist a client draws.
//
// Key is untranslated ASCII because the restore script echoes it as
// "@@TS_PHASE:<key>" and the match has to be locale-independent. Title is for
// people.
type Phase struct {
	Key   string `json:"key"`
	Title string `json:"title"`
}

// Progress is the numbers a client renders.
type Progress struct {
	// Percent is 0..1. Zero with Total zero means "indeterminate, pulse".
	Percent float64 `json:"percent"`

	Count int64 `json:"count"`
	Total int64 `json:"total"`

	// ETASeconds is -1 when it cannot be estimated yet.
	ETASeconds int64 `json:"eta_seconds"`

	// StatusLine is the file or step being worked on right now.
	StatusLine string `json:"status_line"`

	// Counters is the rsync breakdown: created, deleted, modified and so on.
	Counters map[string]int64 `json:"counters,omitempty"`
}

// Snapshot is a job's complete state at one instant. It is what a late
// subscriber is handed before the live stream begins.
type Snapshot struct {
	ID       string    `json:"id"`
	Kind     Kind      `json:"kind"`
	State    State     `json:"state"`
	Phase    string    `json:"phase"`
	Phases   []Phase   `json:"phases"`
	Progress Progress  `json:"progress"`
	Outcome  Outcome   `json:"outcome,omitempty"`
	Messages []string  `json:"messages,omitempty"`
	Started  time.Time `json:"started"`
	Finished time.Time `json:"finished,omitempty"`

	// LogTail is the recent output, oldest first. Present only when the
	// subscriber asked for logs.
	LogTail []string `json:"log_tail,omitempty"`

	// Error is set when the job failed to run at all, as opposed to running
	// and reporting a bad outcome.
	Error string `json:"error,omitempty"`
}

// Event is one thing that happened to a job.
type Event struct {
	Type string `json:"event"`
	Job  string `json:"job"`

	State    State     `json:"state,omitempty"`
	Phase    string    `json:"phase,omitempty"`
	Phases   []Phase   `json:"phases,omitempty"`
	Progress *Progress `json:"progress,omitempty"`
	Line     string    `json:"line,omitempty"`
	Outcome  Outcome   `json:"outcome,omitempty"`
	Messages []string  `json:"messages,omitempty"`
	Error    string    `json:"error,omitempty"`
}

// Event type names, which are also the wire names.
const (
	EventStarted  = "job.started"
	EventPhase    = "job.phase"
	EventProgress = "job.progress"
	EventLog      = "job.log"
	EventFinished = "job.finished"

	/* Events that are not about a job.
	 *
	 * They carry no Job, so the hub delivers them only to subscribers
	 * following everything -- a client attached to one job wants that job, not
	 * a notification that somebody changed a setting.
	 *
	 * They exist so a second client redraws instead of showing stale state.
	 * With several clients attached at once, which is the point of the daemon,
	 * "I changed it here and the other window still says the old thing" is the
	 * obvious failure and this is what prevents it. */
	EventConfigChanged    = "config.changed"
	EventSnapshotsChanged = "snapshots.changed"
)

// Reporter is how the work being run talks back. It is the ONLY channel: an
// engine never learns whether anybody is watching.
type Reporter interface {
	// SetPhases publishes the checklist. Call once, before work starts.
	SetPhases(phases []Phase)
	// Phase marks the step now running.
	Phase(key string)
	// Progress publishes counters. Called often; cheap.
	Progress(p Progress)
	// Log records a line of output.
	Log(line string)
	// Note records a message for the summary.
	Note(msg string)
	// Warn records a message and downgrades the outcome to warnings.
	Warn(msg string)
	// Cancelled reports whether the job has been asked to stop, so a long loop
	// can bail out promptly.
	Cancelled() bool
}

// RunFunc is the actual work.
type RunFunc func(ctx context.Context, r Reporter) (Outcome, error)

// ErrQueueFull is returned when the queue will not take more work.
var ErrQueueFull = errors.New("jobs: queue is full")

// ErrNoSuchJob is returned for an unknown job id.
var ErrNoSuchJob = errors.New("jobs: no such job")

// logRingSize is how much output a job keeps for replay. A restore emits
// millions of lines; this is the tail a late joiner sees.
const logRingSize = 2000

// subscriberBuffer is how far a subscriber may fall behind before it is
// dropped. Generous enough for a GUI redraw, small enough that a dead client
// cannot pin memory.
const subscriberBuffer = 256

// Job is one unit of work.
type Job struct {
	ID   string
	Kind Kind

	mu       sync.RWMutex
	state    State
	phase    string
	phases   []Phase
	progress Progress
	outcome  Outcome
	messages []string
	started  time.Time
	finished time.Time
	err      error

	log *logging.Ring

	cancel context.CancelFunc

	// paused is signalled by Pause and awaited by the runner.
	pausedFlag atomic.Bool

	// done is closed when the job reaches a terminal state, so a caller can
	// wait for it without subscribing to the event stream. The scheduler is
	// the caller that needs this: it has to know a snapshot finished before it
	// reports the check done, and it wants no part of the event fan-out.
	done chan struct{}

	hub *Hub
}

// Snapshot returns the job's state. withLog includes the log tail.
func (j *Job) Snapshot(withLog bool) Snapshot {
	j.mu.RLock()
	defer j.mu.RUnlock()

	s := Snapshot{
		ID:       j.ID,
		Kind:     j.Kind,
		State:    j.state,
		Phase:    j.phase,
		Phases:   append([]Phase(nil), j.phases...),
		Progress: j.progress,
		Outcome:  j.outcome,
		Messages: append([]string(nil), j.messages...),
		Started:  j.started,
		Finished: j.finished,
	}
	if j.err != nil {
		s.Error = j.err.Error()
	}
	if withLog {
		s.LogTail = j.log.Lines()
	}
	return s
}

// Done is closed when the job reaches a terminal state.
func (j *Job) Done() <-chan struct{} { return j.done }

// State returns the current state.
func (j *Job) State() State {
	j.mu.RLock()
	defer j.mu.RUnlock()
	return j.state
}

// Cancel asks the job to stop.
func (j *Job) Cancel() {
	j.mu.Lock()
	if j.state.Terminal() {
		j.mu.Unlock()
		return
	}
	cancel := j.cancel
	j.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

// Pause and Resume gate a cooperative runner.
func (j *Job) Pause() {
	j.pausedFlag.Store(true)
	j.setState(StatePaused)
}

func (j *Job) Resume() {
	j.pausedFlag.Store(false)
	j.setState(StateRunning)
}

// Paused reports whether the job is suspended.
func (j *Job) Paused() bool { return j.pausedFlag.Load() }

func (j *Job) setState(s State) {
	j.mu.Lock()
	if j.state.Terminal() {
		j.mu.Unlock()
		return
	}
	j.state = s
	j.mu.Unlock()
	j.hub.publish(Event{Type: EventStarted, Job: j.ID, State: s})
}

// reporter is the Reporter handed to the RunFunc.
type reporter struct {
	job *Job
	ctx context.Context
}

func (r *reporter) SetPhases(phases []Phase) {
	r.job.mu.Lock()
	r.job.phases = append([]Phase(nil), phases...)
	r.job.mu.Unlock()
	r.job.hub.publish(Event{Type: EventPhase, Job: r.job.ID, Phases: phases})
}

func (r *reporter) Phase(key string) {
	r.job.mu.Lock()
	if r.job.phase == key {
		r.job.mu.Unlock()
		return
	}
	r.job.phase = key
	phases := append([]Phase(nil), r.job.phases...)
	r.job.mu.Unlock()
	r.job.hub.publish(Event{Type: EventPhase, Job: r.job.ID, Phase: key, Phases: phases})
}

func (r *reporter) Progress(p Progress) {
	r.job.mu.Lock()
	r.job.progress = p
	r.job.mu.Unlock()
	cp := p
	r.job.hub.publish(Event{Type: EventProgress, Job: r.job.ID, Progress: &cp})
}

func (r *reporter) Log(line string) {
	r.job.log.Add(line)
	r.job.hub.publish(Event{Type: EventLog, Job: r.job.ID, Line: line})
}

func (r *reporter) Note(msg string) {
	r.job.mu.Lock()
	r.job.messages = append(r.job.messages, msg)
	r.job.mu.Unlock()
}

func (r *reporter) Warn(msg string) {
	r.job.mu.Lock()
	r.job.messages = append(r.job.messages, msg)
	if r.job.outcome != OutcomeFailed {
		r.job.outcome = OutcomeWarnings
	}
	r.job.mu.Unlock()
}

func (r *reporter) Cancelled() bool {
	select {
	case <-r.ctx.Done():
		return true
	default:
		return false
	}
}

// Queue runs jobs one at a time.
type Queue struct {
	hub *Hub

	mu      sync.RWMutex
	jobs    map[string]*Job
	order   []string
	current *Job

	pending chan *pendingJob
	nextID  atomic.Int64

	closeOnce sync.Once
	done      chan struct{}
}

type pendingJob struct {
	job *Job
	run RunFunc
}

// NewQueue starts the worker.
//
// depth is how many jobs may wait behind the running one. apt-snapshot-guard
// blocks dpkg while it waits, so a queue that refuses work is better than one
// that grows without bound.
func NewQueue(depth int) *Queue {
	if depth < 1 {
		depth = 1
	}
	q := &Queue{
		hub:     NewHub(),
		jobs:    map[string]*Job{},
		pending: make(chan *pendingJob, depth),
		done:    make(chan struct{}),
	}
	go q.worker()
	return q
}

// Hub is the event fan-out.
func (q *Queue) Hub() *Hub { return q.hub }

// Submit queues work and returns its job immediately. The caller streams
// progress rather than blocking.
func (q *Queue) Submit(kind Kind, run RunFunc) (*Job, error) {
	j := &Job{
		ID:      fmt.Sprintf("j-%d", q.nextID.Add(1)),
		Kind:    kind,
		state:   StateQueued,
		outcome: OutcomeOK,
		log:     logging.NewRing(logRingSize),
		hub:     q.hub,
		done:    make(chan struct{}),
	}

	q.mu.Lock()
	q.jobs[j.ID] = j
	q.order = append(q.order, j.ID)
	q.mu.Unlock()

	select {
	case q.pending <- &pendingJob{job: j, run: run}:
		return j, nil
	default:
		q.mu.Lock()
		delete(q.jobs, j.ID)
		q.order = q.order[:len(q.order)-1]
		q.mu.Unlock()
		return nil, ErrQueueFull
	}
}

// Get returns a job by id.
func (q *Queue) Get(id string) (*Job, error) {
	q.mu.RLock()
	defer q.mu.RUnlock()
	j, ok := q.jobs[id]
	if !ok {
		return nil, ErrNoSuchJob
	}
	return j, nil
}

// List returns every job, oldest first.
func (q *Queue) List() []Snapshot {
	q.mu.RLock()
	defer q.mu.RUnlock()
	out := make([]Snapshot, 0, len(q.order))
	for _, id := range q.order {
		if j, ok := q.jobs[id]; ok {
			out = append(out, j.Snapshot(false))
		}
	}
	return out
}

// Active returns the running job, if any.
//
// This is what makes "a snapshot is already in progress, here it is" possible,
// where the Vala build could only say "another instance is running" and exit.
func (q *Queue) Active() *Job {
	q.mu.RLock()
	defer q.mu.RUnlock()
	return q.current
}

func (q *Queue) worker() {
	for {
		select {
		case <-q.done:
			return
		case p := <-q.pending:
			q.run(p)
		}
	}
}

func (q *Queue) run(p *pendingJob) {
	j := p.job

	ctx, cancel := context.WithCancel(context.Background())

	j.mu.Lock()
	j.state = StateRunning
	j.started = time.Now()
	j.cancel = cancel
	j.mu.Unlock()

	q.mu.Lock()
	q.current = j
	q.mu.Unlock()

	q.hub.publish(Event{Type: EventStarted, Job: j.ID, State: StateRunning})

	outcome, err := func() (o Outcome, err error) {
		/* A panic in an engine must not take the daemon down with it. Every
		 * other client's view of every other job depends on this process
		 * staying up. */
		defer func() {
			if r := recover(); r != nil {
				o, err = OutcomeFailed, fmt.Errorf("jobs: panic in %s job: %v", j.Kind, r)
			}
		}()
		return p.run(ctx, &reporter{job: j, ctx: ctx})
	}()

	/* Read the context BEFORE cancelling it. Our own deferred cancel would
	 * otherwise make ctx.Err() non-nil for every job, and any job that merely
	 * failed would be reported as cancelled. */
	cancelled := ctx.Err() != nil
	cancel()

	j.mu.Lock()
	j.finished = time.Now()
	j.err = err
	switch {
	case cancelled && err != nil:
		j.state = StateCancelled
		j.outcome = OutcomeFailed
	case err != nil:
		j.state = StateFailed
		j.outcome = OutcomeFailed
	default:
		j.state = StateFinished
		// A run that reported warnings keeps them; otherwise take its outcome.
		if outcome == OutcomeFailed || j.outcome != OutcomeWarnings {
			j.outcome = outcome
		}
	}
	final := Event{
		Type:     EventFinished,
		Job:      j.ID,
		State:    j.state,
		Outcome:  j.outcome,
		Messages: append([]string(nil), j.messages...),
	}
	if err != nil {
		final.Error = err.Error()
	}
	j.mu.Unlock()

	q.mu.Lock()
	q.current = nil
	q.mu.Unlock()

	close(j.done)
	q.hub.publish(final)
}

// Close stops the worker. Work already running is left to finish.
func (q *Queue) Close() {
	q.closeOnce.Do(func() {
		close(q.done)
		q.hub.Close()
	})
}
