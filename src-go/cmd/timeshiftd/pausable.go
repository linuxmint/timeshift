package main

import (
	"context"
	"errors"
	"sync"

	"github.com/makeafide/timeshift/src-go/internal/sysexec"
)

/* Pausing a job, for real.
 *
 * Job.Pause() sets a flag and publishes a state change, and by itself that is
 * all it does -- rsync keeps running. Exposing jobs.pause over IPC on top of
 * that flag would be the same defect as advertising Caps.Browse with no browse
 * method: a client would show a Pause button, the button would appear to work,
 * and the backup would carry on.
 *
 * What actually suspends a transfer is SIGSTOP to the child's process GROUP,
 * which sysexec.Process already does -- rsync over ssh is several processes and
 * signalling only the parent leaves the transfer running. The missing piece was
 * that Simple.Stream starts a process and never lets anyone else see it.
 *
 * This wrapper keeps the one currently running. A single slot is not a
 * simplification: the queue runs exactly one mutating job at a time, so there
 * is never a second process to track. The `paused` flag is separate from it so
 * that a job paused BETWEEN two commands -- rsync finished, the next has not
 * started -- comes back suspended rather than quietly resuming.
 */
type pausableRunner struct {
	inner sysexec.Simple

	mu      sync.Mutex
	current *sysexec.Process
	paused  bool
}

func newPausableRunner(inner sysexec.Simple) *pausableRunner {
	return &pausableRunner{inner: inner}
}

// ErrNothingRunning reports a pause or resume with no process to act on.
var ErrNothingRunning = errors.New("no command is running")

func (r *pausableRunner) Run(ctx context.Context, argv []string, stdin string) (int, string, string, error) {
	return r.inner.Run(ctx, argv, stdin)
}

// RunEnv passes through. Not pausable, and does not need to be: its one caller
// is ssh-copy-id, which is interactive and short.
func (r *pausableRunner) RunEnv(ctx context.Context, argv []string, stdin string, env []string) (int, string, string, error) {
	return r.inner.RunEnv(ctx, argv, stdin, env)
}

func (r *pausableRunner) Stream(ctx context.Context, argv []string, onLine func(stream, line string)) (int, error) {
	p, err := r.inner.E.Start(ctx, sysexec.Cmd{Argv: argv}, sysexec.Handler{
		Stdout: func(l string) { onLine("stdout", l) },
		Stderr: func(l string) { onLine("stderr", l) },
	})
	if err != nil {
		return -1, err
	}

	r.mu.Lock()
	r.current = p
	wantPaused := r.paused
	r.mu.Unlock()

	// A job paused while nothing was running must not restart by starting the
	// next command.
	if wantPaused {
		_ = p.Pause()
	}

	res, waitErr := p.Wait()

	r.mu.Lock()
	if r.current == p {
		r.current = nil
	}
	r.mu.Unlock()

	return res.ExitCode, waitErr
}

// Pause suspends whatever is running, and arms the flag so the next command
// starts suspended too.
func (r *pausableRunner) Pause() error {
	r.mu.Lock()
	r.paused = true
	p := r.current
	r.mu.Unlock()

	if p == nil {
		// Not an error: between commands is a legitimate moment to pause, and
		// the flag has been set, so the next one starts stopped.
		return nil
	}
	return p.Pause()
}

// Resume continues a suspended job.
func (r *pausableRunner) Resume() error {
	r.mu.Lock()
	r.paused = false
	p := r.current
	r.mu.Unlock()

	if p == nil {
		return nil
	}
	return p.Resume()
}

// Paused reports whether work is currently suspended.
func (r *pausableRunner) Paused() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.paused
}
