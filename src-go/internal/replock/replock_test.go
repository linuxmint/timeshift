package replock

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func lockPath(t *testing.T) string {
	t.Helper()
	return filepath.Join(t.TempDir(), "repo.lock")
}

func TestAcquireAndRelease(t *testing.T) {
	p := lockPath(t)

	l, _, err := TryAcquire(p, "create")
	if err != nil {
		t.Fatalf("first acquire: %v", err)
	}

	/* flock is held per open file description, so a second open in this same
	 * process contends exactly as another process would. That is what makes
	 * the guarantee testable without spawning anything. */
	if _, holder, err := TryAcquire(p, "delete"); !errors.Is(err, ErrHeld) {
		t.Fatalf("second acquire = %v, want ErrHeld", err)
	} else {
		if holder.PID != os.Getpid() {
			t.Errorf("holder pid = %d, want %d", holder.PID, os.Getpid())
		}
		if holder.What != "create" {
			t.Errorf("holder what = %q, want %q", holder.What, "create")
		}
	}

	if err := l.Release(); err != nil {
		t.Fatalf("release: %v", err)
	}

	second, _, err := TryAcquire(p, "delete")
	if err != nil {
		t.Fatalf("acquire after release: %v", err)
	}
	second.Release()
}

// A holder that dies without releasing must not wedge the repository forever.
// This is the reason for flock over AppLock's check-then-write: the kernel
// drops the lock when the fd closes, so there is no stale-pid guess to make --
// and no chance of guessing against a pid the kernel has since recycled.
func TestAKilledHolderReleasesTheLock(t *testing.T) {
	p := lockPath(t)

	l, _, err := TryAcquire(p, "create")
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}

	// Close the descriptor without Release(), which is what a SIGKILL does.
	if err := l.f.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	next, _, err := TryAcquire(p, "delete")
	if err != nil {
		t.Fatalf("acquire after a killed holder: %v", err)
	}
	next.Release()
}

func TestReleaseIsIdempotentAndNilSafe(t *testing.T) {
	p := lockPath(t)

	l, _, err := TryAcquire(p, "create")
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	if err := l.Release(); err != nil {
		t.Fatalf("first release: %v", err)
	}
	if err := l.Release(); err != nil {
		t.Fatalf("second release: %v", err)
	}

	var nilLock *Lock
	if err := nilLock.Release(); err != nil {
		t.Fatalf("nil release: %v", err)
	}
}

// The lock file is never unlinked. Removing it would let a waiter create and
// lock a fresh inode while the original holder still holds the old one, so both
// would believe they hold "the" lock.
func TestReleaseDoesNotRemoveTheFile(t *testing.T) {
	p := lockPath(t)

	l, _, err := TryAcquire(p, "create")
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	l.Release()

	if _, err := os.Stat(p); err != nil {
		t.Fatalf("lock file gone after release: %v", err)
	}
}

func TestAcquireWaitsThenSucceeds(t *testing.T) {
	p := lockPath(t)

	held, _, err := TryAcquire(p, "restore")
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}

	var announced []Holder
	done := make(chan error, 1)
	go func() {
		l, err := Acquire(context.Background(), p, "create", func(h Holder) {
			announced = append(announced, h)
		})
		if l != nil {
			l.Release()
		}
		done <- err
	}()

	time.Sleep(1500 * time.Millisecond)
	held.Release()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("waiting acquire: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("waiting acquire never returned")
	}

	if len(announced) == 0 {
		t.Fatal("waiting caller was never told who held the lock")
	}
	if announced[0].What != "restore" {
		t.Errorf("announced holder = %q, want %q", announced[0].What, "restore")
	}
}

func TestAcquireHonoursContext(t *testing.T) {
	p := lockPath(t)

	held, _, err := TryAcquire(p, "restore")
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	defer held.Release()

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	if _, err := Acquire(ctx, p, "create", nil); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Acquire = %v, want DeadlineExceeded", err)
	}
}

// AppLock did txt.split(";")[1] with no length check, which indexes off the end
// of the array for a file holding anything without a semicolon. Nothing about
// a malformed diagnostic line is worth failing an acquisition over.
func TestMalformedHolderLineIsTolerated(t *testing.T) {
	for _, content := range []string{"", "garbage", ";", "notapid;create", "\n\n", strings.Repeat("x", 4096)} {
		p := lockPath(t)
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}

		l, _, err := TryAcquire(p, "create")
		if err != nil {
			t.Fatalf("acquire over %q: %v", content, err)
		}
		l.Release()
	}
}

func TestHolderString(t *testing.T) {
	cases := []struct {
		h    Holder
		want string
	}{
		{Holder{PID: 42, What: "create"}, "create (pid 42)"},
		{Holder{PID: 0, What: "create"}, "create"},
		{Holder{}, "an operation"},
		{Holder{PID: 7}, "an operation (pid 7)"},
	}
	for _, c := range cases {
		if got := c.h.String(); got != c.want {
			t.Errorf("Holder%+v.String() = %q, want %q", c.h, got, c.want)
		}
	}
}

/* The lock is only worth anything if a DIFFERENT process sees it, in a
 * different language. The Vala core takes the same lock through an extern
 * flock(2) (src/Utility/RepoLock.vala), and there is no way to call that from a
 * Go test -- so flock(1) from util-linux stands in as a neutral third party.
 * It uses flock(2) and nothing else, so agreeing with it is exactly the
 * property the Vala side depends on.
 *
 * This is also what pins the choice of flock over fcntl record locks: the two
 * do not see each other at all, so a future change to fcntl here would keep
 * every in-process test passing while silently letting both cores write the
 * repository at once. */
func TestAnotherProcessSeesTheLock(t *testing.T) {
	if _, err := exec.LookPath("flock"); err != nil {
		t.Skip("flock(1) not available")
	}
	p := lockPath(t)

	l, _, err := TryAcquire(p, "create")
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}

	// While we hold it, an outside process must be refused.
	if err := exec.Command("flock", "-n", p, "-c", "true").Run(); err == nil {
		t.Fatal("flock(1) took a lock we are holding")
	}

	l.Release()

	// Once released, it must succeed.
	if err := exec.Command("flock", "-n", p, "-c", "true").Run(); err != nil {
		t.Fatalf("flock(1) refused a released lock: %v", err)
	}
}

func TestWeSeeAnotherProcessesLock(t *testing.T) {
	if _, err := exec.LookPath("flock"); err != nil {
		t.Skip("flock(1) not available")
	}
	p := lockPath(t)

	/* Hold the lock from outside, and signal from inside the held section so
	 * this test never asserts against a flock(1) that has not taken it yet.
	 *
	 * The ready file matters: polling TryAcquire to find out whether flock has
	 * started would take the lock ourselves on the first pass, and flock would
	 * then block behind us while we blocked waiting for it. */
	ready := filepath.Join(filepath.Dir(p), "ready")
	cmd := exec.Command("flock", p, "-c", "touch "+ready+"; sleep 10")
	if err := cmd.Start(); err != nil {
		t.Fatalf("start flock(1): %v", err)
	}
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()

	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(ready); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("flock(1) never took the lock")
		}
		time.Sleep(20 * time.Millisecond)
	}

	l, holder, err := TryAcquire(p, "create")
	if err == nil {
		l.Release()
		t.Fatal("took a lock flock(1) is holding")
	}
	if !errors.Is(err, ErrHeld) {
		t.Fatalf("TryAcquire = %v, want ErrHeld", err)
	}

	// flock(1) writes nothing into the file, so there is no holder to report.
	// A missing description must read as neutral, never as an empty string.
	if got := holder.String(); got != "an operation" {
		t.Errorf("holder = %q, want the neutral description", got)
	}
}
