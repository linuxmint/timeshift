package jobs

import (
	"sync"
	"sync/atomic"
)

/* The fan-out.
 *
 * The one rule that matters: publishing never blocks. A subscriber whose buffer
 * is full is dropped, not waited for. If it were the other way round, a GUI
 * that stopped reading -- because it was killed, or stopped at a breakpoint, or
 * simply busy redrawing -- would stall the backup it was watching. Watching
 * must never be able to affect the thing being watched.
 */

// Subscription is one client's view of the event stream.
type Subscription struct {
	// C delivers events until the subscription ends. It is closed when the
	// subscription is cancelled or the hub shuts down.
	C <-chan Event

	ch      chan Event
	hub     *Hub
	id      uint64
	jobID   string
	wantLog bool

	// dropped counts events discarded because this subscriber fell behind.
	// A client can be told it missed something rather than silently seeing a
	// gap.
	dropped atomic.Int64

	closeOnce sync.Once
}

// Dropped is how many events this subscriber missed by falling behind.
func (s *Subscription) Dropped() int64 { return s.dropped.Load() }

// Close ends the subscription.
func (s *Subscription) Close() {
	s.closeOnce.Do(func() {
		s.hub.remove(s.id)
		close(s.ch)
	})
}

// Hub broadcasts job events to subscribers.
type Hub struct {
	mu     sync.RWMutex
	subs   map[uint64]*Subscription
	nextID uint64
	closed bool
}

// NewHub returns an empty hub.
func NewHub() *Hub {
	return &Hub{subs: map[uint64]*Subscription{}}
}

// SubscribeOptions selects what a subscriber receives.
type SubscribeOptions struct {
	// JobID limits the stream to one job. Empty means every job.
	JobID string

	// WithLog includes job.log events, which are high volume: a restore emits
	// one per file. Opt-in so a status display does not pay for them.
	WithLog bool
}

// Subscribe registers a client.
func (h *Hub) Subscribe(o SubscribeOptions) *Subscription {
	ch := make(chan Event, subscriberBuffer)
	s := &Subscription{
		C:       ch,
		ch:      ch,
		hub:     h,
		jobID:   o.JobID,
		wantLog: o.WithLog,
	}

	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		close(ch)
		return s
	}
	h.nextID++
	s.id = h.nextID
	h.subs[s.id] = s
	h.mu.Unlock()

	return s
}

// Subscribers is how many clients are attached. Used to decide whether anyone
// is available to answer a credential prompt.
func (h *Hub) Subscribers() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.subs)
}

/* Publish emits an event that belongs to no job.
 *
 * Job events are published by the job itself; this is for the daemon to
 * announce that something else changed -- a setting, the snapshot list. It is
 * deliberately narrow: an event with a Job set would be indistinguishable from
 * one the job emitted, and a client cannot tell a real progress update from a
 * forged one.
 */
func (h *Hub) Publish(eventType string) {
	h.publish(Event{Type: eventType})
}

// publish sends an event to every interested subscriber.
//
// Never blocks: see the note at the top of this file.
func (h *Hub) publish(e Event) {
	h.mu.RLock()
	defer h.mu.RUnlock()

	for _, s := range h.subs {
		if s.jobID != "" && s.jobID != e.Job {
			continue
		}
		if e.Type == EventLog && !s.wantLog {
			continue
		}
		select {
		case s.ch <- e:
		default:
			// Behind and staying behind. Drop this one and keep going; the
			// subscriber can see the count and re-read the job's state.
			s.dropped.Add(1)
		}
	}
}

func (h *Hub) remove(id uint64) {
	h.mu.Lock()
	delete(h.subs, id)
	h.mu.Unlock()
}

// Close ends every subscription.
func (h *Hub) Close() {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return
	}
	h.closed = true
	subs := make([]*Subscription, 0, len(h.subs))
	for _, s := range h.subs {
		subs = append(subs, s)
	}
	h.subs = map[uint64]*Subscription{}
	h.mu.Unlock()

	for _, s := range subs {
		s.closeOnce.Do(func() { close(s.ch) })
	}
}

// Attach subscribes to a job and returns the job's current state alongside.
//
// This pair is the whole point of the package: the snapshot describes
// everything that has already happened, the channel carries everything that
// happens next, and there is no gap between them because the subscription is
// registered before the snapshot is taken.
func (q *Queue) Attach(jobID string, withLog bool) (Snapshot, *Subscription, error) {
	j, err := q.Get(jobID)
	if err != nil {
		return Snapshot{}, nil, err
	}
	sub := q.hub.Subscribe(SubscribeOptions{JobID: jobID, WithLog: withLog})
	return j.Snapshot(withLog), sub, nil
}
