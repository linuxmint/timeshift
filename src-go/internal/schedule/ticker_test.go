package schedule

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"
)

func quietLog() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// checkRecorder counts checks and reports each trigger.
type checkRecorder struct {
	mu       sync.Mutex
	triggers []string
	err      error
	fired    chan struct{}
}

func newRecorder() *checkRecorder {
	return &checkRecorder{fired: make(chan struct{}, 16)}
}

func (c *checkRecorder) fn(_ context.Context, trigger string) (string, error) {
	c.mu.Lock()
	c.triggers = append(c.triggers, trigger)
	err := c.err
	c.mu.Unlock()
	select {
	case c.fired <- struct{}{}:
	default:
	}
	return "checked", err
}

func (c *checkRecorder) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.triggers)
}

func (c *checkRecorder) await(t *testing.T, n int) {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for c.count() < n {
		select {
		case <-c.fired:
		case <-deadline:
			t.Fatalf("only %d of %d checks fired", c.count(), n)
		}
	}
}

func TestTickerRunsOnStartupAndOnEveryTick(t *testing.T) {
	rec := newRecorder()
	tk := &Ticker{
		Interval: 5 * time.Millisecond,
		Enabled:  func() bool { return true },
		Check:    rec.fn,
		Log:      quietLog(),
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go tk.Run(ctx)

	rec.await(t, 3)

	rec.mu.Lock()
	first := rec.triggers[0]
	rec.mu.Unlock()
	if first != "startup" {
		t.Fatalf("first check trigger = %q, want startup", first)
	}
}

// The startup delay exists so a boot snapshot does not compete with everything
// else the machine is starting.
func TestTickerHoldsBackTheFirstCheck(t *testing.T) {
	rec := newRecorder()
	tk := &Ticker{
		Interval:     time.Hour,
		StartupDelay: 30 * time.Second,
		Enabled:      func() bool { return true },
		Check:        rec.fn,
		Log:          quietLog(),
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go tk.Run(ctx)

	time.Sleep(50 * time.Millisecond)
	if n := rec.count(); n != 0 {
		t.Fatalf("%d checks ran during the startup delay", n)
	}

	// A request still gets through the delay, which is what makes the delay
	// safe to make long.
	tk.RequestCheck("request")
	rec.await(t, 1)
}

func TestTickerSkipsWhenDisabledOrPaused(t *testing.T) {
	t.Run("disabled", func(t *testing.T) {
		rec := newRecorder()
		tk := &Ticker{
			Interval: 5 * time.Millisecond,
			Enabled:  func() bool { return false },
			Check:    rec.fn,
			Log:      quietLog(),
		}
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		go tk.Run(ctx)

		time.Sleep(60 * time.Millisecond)
		if n := rec.count(); n != 0 {
			t.Fatalf("%d checks ran with scheduling disabled", n)
		}
		if got := tk.Status().LastResult; got != "scheduled snapshots are disabled" {
			t.Fatalf("status does not explain the skip: %q", got)
		}
	})

	t.Run("paused", func(t *testing.T) {
		rec := newRecorder()
		tk := &Ticker{
			Interval: 5 * time.Millisecond,
			Enabled:  func() bool { return true },
			Paused:   func() (bool, string) { return true, "until 18:00" },
			Check:    rec.fn,
			Log:      quietLog(),
		}
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		go tk.Run(ctx)

		time.Sleep(60 * time.Millisecond)
		if n := rec.count(); n != 0 {
			t.Fatalf("%d checks ran while paused", n)
		}
	})
}

// Losing cron means losing a scheduler that ran whether or not our code was
// healthy. Status is the replacement, so a failure has to be visible in it.
func TestTickerReportsAFailedCheck(t *testing.T) {
	rec := newRecorder()
	rec.err = errors.New("the backup device is not connected")

	tk := &Ticker{
		Interval: time.Hour,
		Enabled:  func() bool { return true },
		Check:    rec.fn,
		Log:      quietLog(),
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go tk.Run(ctx)
	rec.await(t, 1)

	// The status write happens just after the check returns.
	deadline := time.After(2 * time.Second)
	for {
		st := tk.Status()
		if st.LastError != "" {
			if st.LastError != rec.err.Error() {
				t.Fatalf("LastError = %q", st.LastError)
			}
			if st.LastRun.IsZero() {
				t.Fatal("LastRun is zero after a check")
			}
			return
		}
		select {
		case <-deadline:
			t.Fatal("the failure never reached the status")
		case <-time.After(5 * time.Millisecond):
		}
	}
}

func TestTickerStopsWithTheContext(t *testing.T) {
	rec := newRecorder()
	tk := &Ticker{
		Interval: 5 * time.Millisecond,
		Enabled:  func() bool { return true },
		Check:    rec.fn,
		Log:      quietLog(),
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { tk.Run(ctx); close(done) }()

	rec.await(t, 1)
	cancel()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return after the context was cancelled")
	}
	if tk.Status().Running {
		t.Fatal("status still reports the scheduler as running")
	}
}
