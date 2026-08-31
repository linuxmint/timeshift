package schedule

import (
	"context"
	"log/slog"
	"sync"
	"time"
)

/* The ticker that replaces cron.
 *
 * cron ran the whole CLI once an hour to ask a question whose answer was almost
 * always "nothing". Here a goroutine asks the same question, and the interval
 * can be short because a tick that finds nothing due costs one directory
 * listing.
 *
 * Ticking often is safe precisely BECAUSE the decisions are age comparisons
 * rather than a calendar: "is the newest hourly snapshot more than an hour old"
 * gives the same answer whether it is asked once an hour or twelve times, and
 * only one of those twelve can find it true. That property is what makes the
 * loop idempotent, and it is worth stating because the obvious alternative --
 * firing on the hour boundary -- silently skips an hour whenever the machine is
 * asleep or the daemon restarts across it. cron had exactly that failure and
 * the age comparisons were how the original worked around it.
 *
 * Losing cron does lose something real: cron ran whether or not our code was
 * healthy, and a dead timeshiftd now means no snapshots at all with nothing to
 * notice. That is what LastRun is for -- a client can say "the scheduler has
 * not run since Tuesday" instead of showing a stale list that looks fine.
 */

// DefaultInterval is how often the scheduler wakes. Short enough that an hourly
// snapshot lands near its hour, long enough that a repository at the end of an
// SSH link is not polled constantly.
const DefaultInterval = 10 * time.Minute

// Status is what the scheduler has been doing, for a client to display.
type Status struct {
	// Enabled reports whether any level is scheduled.
	Enabled bool `json:"enabled"`

	// Running reports whether the loop is alive at all. A false here with
	// Enabled true is the failure mode that losing cron introduced.
	Running bool `json:"running"`

	// LastRun is when a check last completed, zero if never.
	LastRun time.Time `json:"last_run,omitempty"`

	// LastError is why the last check failed, empty on success.
	LastError string `json:"last_error,omitempty"`

	// LastResult summarises what the last check decided.
	LastResult string `json:"last_result,omitempty"`

	// NextRun is when the next tick is expected.
	NextRun time.Time `json:"next_run,omitempty"`

	// Interval is the tick period.
	IntervalSeconds int64 `json:"interval_seconds"`
}

// CheckFunc performs one scheduled check. trigger is "startup", "tick" or
// "request", and is logged so an operator can tell an automatic snapshot from
// one someone asked for.
type CheckFunc func(ctx context.Context, trigger string) (result string, err error)

// Ticker drives scheduled checks.
type Ticker struct {
	// Interval is the tick period; DefaultInterval when zero.
	Interval time.Duration

	// StartupDelay holds the first check back after the daemon starts. The
	// boot snapshot is the reason: at boot the machine is busy bringing up
	// every other service, and rsyncing the root filesystem into the middle of
	// that makes the boot visibly slower. The original spelled this
	// "@reboot root sleep 10m".
	StartupDelay time.Duration

	// Enabled reports whether scheduling is configured on. It is read on every
	// tick rather than captured, so a configuration change takes effect
	// without a restart.
	Enabled func() bool

	// Paused reports whether snapshots are suspended.
	Paused func() (bool, string)

	// Check runs one check.
	Check CheckFunc

	Log *slog.Logger

	// now is overridable for tests.
	now func() time.Time

	mu     sync.Mutex
	status Status
	// wake carries out-of-band check requests.
	wake chan string
}

// Run drives the loop until the context is cancelled.
func (t *Ticker) Run(ctx context.Context) {
	interval := t.Interval
	if interval <= 0 {
		interval = DefaultInterval
	}
	now := t.now
	if now == nil {
		now = time.Now
	}

	t.mu.Lock()
	if t.wake == nil {
		t.wake = make(chan string, 1)
	}
	wake := t.wake
	t.status.Running = true
	t.status.IntervalSeconds = int64(interval / time.Second)
	t.status.NextRun = now().Add(t.StartupDelay)
	t.mu.Unlock()

	defer func() {
		t.mu.Lock()
		t.status.Running = false
		t.mu.Unlock()
	}()

	// The startup delay is a one-shot before the regular cadence begins.
	if t.StartupDelay > 0 {
		select {
		case <-ctx.Done():
			return
		case trigger := <-wake:
			t.runOnce(ctx, trigger, now)
		case <-time.After(t.StartupDelay):
			t.runOnce(ctx, "startup", now)
		}
	} else {
		t.runOnce(ctx, "startup", now)
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		t.mu.Lock()
		t.status.NextRun = now().Add(interval)
		t.mu.Unlock()

		select {
		case <-ctx.Done():
			return
		case trigger := <-wake:
			t.runOnce(ctx, trigger, now)
		case <-ticker.C:
			t.runOnce(ctx, "tick", now)
		}
	}
}

// RequestCheck asks for a check now. It never blocks: a request arriving while
// one is already queued is the same request.
func (t *Ticker) RequestCheck(trigger string) {
	t.mu.Lock()
	if t.wake == nil {
		t.wake = make(chan string, 1)
	}
	wake := t.wake
	t.mu.Unlock()

	select {
	case wake <- trigger:
	default:
	}
}

// Status reports what the scheduler has been doing.
func (t *Ticker) Status() Status {
	t.mu.Lock()
	defer t.mu.Unlock()
	s := t.status
	if t.Enabled != nil {
		s.Enabled = t.Enabled()
	}
	return s
}

func (t *Ticker) runOnce(ctx context.Context, trigger string, now func() time.Time) {
	log := t.Log
	if log == nil {
		log = slog.Default()
	}

	if t.Enabled != nil && !t.Enabled() {
		t.record(now(), "scheduled snapshots are disabled", nil)
		log.Debug("scheduled check skipped", "trigger", trigger, "reason", "disabled")
		return
	}

	/* The pause setting is honoured here and not in the engine. A pause is a
	 * statement about automatic snapshots -- "do not back up while I am
	 * reinstalling the world" -- and was never meant to stop someone asking
	 * for one explicitly, which is why the original tested it only in scripted
	 * mode. */
	if t.Paused != nil {
		if paused, until := t.Paused(); paused {
			t.record(now(), "snapshots are paused "+until, nil)
			log.Info("scheduled check skipped", "trigger", trigger, "reason", "paused", "until", until)
			return
		}
	}

	log.Debug("scheduled check starting", "trigger", trigger)
	result, err := t.Check(ctx, trigger)
	t.record(now(), result, err)
	if err != nil {
		log.Error("scheduled check failed", "trigger", trigger, "err", err)
		return
	}
	log.Info("scheduled check finished", "trigger", trigger, "result", result)
}

func (t *Ticker) record(at time.Time, result string, err error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.status.LastRun = at
	t.status.LastResult = result
	if err != nil {
		t.status.LastError = err.Error()
	} else {
		t.status.LastError = ""
	}
}
