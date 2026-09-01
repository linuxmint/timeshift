// Package replock serialises the operations that write a Timeshift repository.
//
// It exists because AppLock's granularity was always wrong, in both directions.
//
// AppLock refused a second *process*. That made it impossible to open the GUI
// while a cron-driven backup ran -- the defect this port exists to remove -- and
// it did not survive the port either: timeshiftd never took it, so a daemon
// backup and a Vala one could run into the same repository at the same time,
// each with --delete and each running its own retention pass. The old lock
// blocked the harmless case and the new queue missed the dangerous one.
//
// What actually has to be serialised is a *write*, not a process. So this lock
// is taken around create, delete and restore, by whichever core is performing
// them, and by nothing else. Readers -- a listing, a status card, a client
// watching a job -- never take it, which is what lets a second window open
// while a backup runs.
//
// The lock is flock(2) on a file under /run, so the kernel releases it if the
// holder is killed. That is the whole reason for not reproducing AppLock's
// check-then-write: a SIGKILLed Timeshift left a lock file behind that only a
// pid-liveness guess could clear, and the guess ran on a pid the kernel may
// since have recycled.
//
// Note that flock(2) and fcntl(2) record locks do not see each other. Both
// cores must use flock, and the Vala side does (src/Utility/RepoLock.vala).
package replock

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// DefaultPath is where the lock lives.
//
// /run is a tmpfs, so the file cannot survive a reboot and be mistaken for a
// live holder. It sits beside daemon.sock deliberately: both are runtime state
// belonging to whoever is currently operating the repository.
const DefaultPath = "/run/timeshift/repo.lock"

// ErrHeld reports that someone else is writing the repository.
var ErrHeld = errors.New("replock: another Timeshift operation is in progress")

// Holder is who holds the lock, for a message a person can act on.
//
// Best-effort: the fields come from the file's contents, which a holder writes
// after acquiring. A holder killed between the two leaves them empty, so a
// caller must render a missing What as "another operation" rather than "".
type Holder struct {
	PID  int
	What string
}

// String describes the holder in the shape the GUI already uses.
func (h Holder) String() string {
	what := h.What
	if what == "" {
		what = "an operation"
	}
	if h.PID > 0 {
		return fmt.Sprintf("%s (pid %d)", what, h.PID)
	}
	return what
}

// Lock is a held repository write lock.
type Lock struct {
	f *os.File
}

// TryAcquire takes the lock without waiting.
//
// It returns ErrHeld, and the holder when one could be read, if the lock is
// already taken.
func TryAcquire(path, what string) (*Lock, Holder, error) {
	if path == "" {
		path = DefaultPath
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, Holder{}, fmt.Errorf("replock: %w", err)
	}

	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, Holder{}, fmt.Errorf("replock: %w", err)
	}

	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		/* Read the holder BEFORE closing: the failed Flock is the proof that
		 * someone holds it, so whatever the file says is current rather than
		 * the leftovers of a dead run. */
		h := readHolder(f)
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, h, ErrHeld
		}
		return nil, h, fmt.Errorf("replock: %w", err)
	}

	/* Record who we are only after the kernel has agreed we hold it. The file
	 * is a diagnostic; the flock is the lock. */
	if err := f.Truncate(0); err == nil {
		if _, err := f.WriteAt([]byte(marshal(os.Getpid(), what)), 0); err != nil {
			// Not fatal: we hold the lock either way, we are just anonymous.
			_ = err
		}
	}

	return &Lock{f: f}, Holder{}, nil
}

// Acquire waits for the lock, reporting who it is waiting for.
//
// waiting, when set, is called once for each distinct holder observed, so a
// caller can tell a person why nothing is happening yet. It is never called if
// the lock is free.
func Acquire(ctx context.Context, path, what string, waiting func(Holder)) (*Lock, error) {
	var announced string

	for {
		l, holder, err := TryAcquire(path, what)
		if err == nil {
			return l, nil
		}
		if !errors.Is(err, ErrHeld) {
			return nil, err
		}

		if waiting != nil && holder.String() != announced {
			announced = holder.String()
			waiting(holder)
		}

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(time.Second):
		}
	}
}

// Release drops the lock.
//
// The file is truncated but never removed. Unlinking it would let a waiter open
// a fresh inode and lock that instead, so two processes would each hold "the"
// lock on different files -- the classic flock-plus-unlink race.
func (l *Lock) Release() error {
	if l == nil || l.f == nil {
		return nil
	}
	f := l.f
	l.f = nil

	_ = f.Truncate(0)
	err := syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// marshal renders the holder line.
//
// The format is AppLock's -- "<pid>;<what>" -- so a Vala build reading this
// file, or a person catting it, sees what it has always seen.
func marshal(pid int, what string) string {
	return strconv.Itoa(pid) + ";" + what
}

// readHolder parses the holder line, tolerating anything.
//
// AppLock split on ";" and indexed [1] unconditionally, which walks off the end
// of the array for a file with no semicolon. There is no shape of content here
// that is worth failing over: the caller has already established that the lock
// is held.
func readHolder(f *os.File) Holder {
	buf := make([]byte, 256)
	n, err := f.ReadAt(buf, 0)
	if n == 0 || (err != nil && n == 0) {
		return Holder{}
	}

	pid, what, _ := strings.Cut(strings.TrimSpace(string(buf[:n])), ";")
	h := Holder{What: strings.TrimSpace(what)}
	if v, err := strconv.Atoi(strings.TrimSpace(pid)); err == nil {
		h.PID = v
	}
	return h
}
