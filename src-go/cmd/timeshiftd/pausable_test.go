package main

import (
	"context"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/sysexec"
)

// procStat returns a pid's state letter and process-group id from /proc.
//
// The comm field is parenthesised and may itself contain spaces, so everything
// is read relative to its closing bracket rather than by field index.
func procStat(pid int) (state string, pgrp int, ok bool) {
	raw, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return "", 0, false
	}
	s := string(raw)
	i := strings.LastIndex(s, ")")
	if i < 0 || i+2 > len(s) {
		return "", 0, false
	}
	f := strings.Fields(s[i+2:])
	if len(f) < 3 {
		return "", 0, false
	}
	pgrp, _ = strconv.Atoi(f[2])
	return f[0], pgrp, true
}

// groupStates returns the state letter of every process in pgid.
func groupStates(pgid int) map[int]string {
	out := map[int]string{}
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return out
	}
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		if state, pg, ok := procStat(pid); ok && pg == pgid {
			out[pid] = state
		}
	}
	return out
}

// currentProcess waits for the runner to have something running.
func currentProcess(t *testing.T, r *pausableRunner) *sysexec.Process {
	t.Helper()
	for i := 0; i < 200; i++ {
		r.mu.Lock()
		p := r.current
		r.mu.Unlock()
		if p != nil {
			return p
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("no command ever started")
	return nil
}

// allStopped reports whether every process in the group is stopped (state T).
func allStopped(pgid int) bool {
	states := groupStates(pgid)
	if len(states) == 0 {
		return false
	}
	for _, s := range states {
		if s != "T" {
			return false
		}
	}
	return true
}

/* Pause has to actually stop the work, and it has to stop ALL of it.
 *
 * Job.Pause() on its own sets a flag and publishes a state change; rsync keeps
 * running. Serving jobs.pause on top of that flag alone would give a client a
 * Pause button that appears to work while the backup carries on -- the same
 * shape of lie as advertising a capability with no method behind it.
 *
 * The assertion is against the kernel's view of the whole process GROUP, not
 * our own flag and not just the leader: a transfer is rsync plus ssh plus the
 * shell that started them, and signalling only the parent leaves the copy
 * running. That is why sysexec puts every child in its own process group.
 */
func TestPauseSuspendsTheWholeProcessGroup(t *testing.T) {
	r := newPausableRunner(sysexec.NewSimple(sysexec.New(nil)))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan struct{})
	go func() {
		defer close(done)
		// sh stays alive around the sleep, so there are two processes to stop.
		r.Stream(ctx, []string{"sh", "-c", "echo going; sleep 30"}, func(string, string) {})
	}()

	p := currentProcess(t, r)
	_, pgid, ok := procStat(p.Pid())
	if !ok {
		t.Fatal("could not read the process state")
	}

	if err := r.Pause(); err != nil {
		t.Fatalf("Pause: %v", err)
	}

	stopped := false
	for i := 0; i < 100; i++ {
		if allStopped(pgid) {
			stopped = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !stopped {
		t.Fatalf("the process group was not stopped: %v", groupStates(pgid))
	}
	if n := len(groupStates(pgid)); n < 2 {
		t.Errorf("expected the shell and its child in the group, saw %d process(es)", n)
	}

	if err := r.Resume(); err != nil {
		t.Fatalf("Resume: %v", err)
	}
	running := false
	for i := 0; i < 100; i++ {
		if !allStopped(pgid) {
			running = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !running {
		t.Fatalf("the process group was still stopped after Resume: %v", groupStates(pgid))
	}

	cancel()
	<-done
}

/* A job paused BETWEEN two commands must come back suspended, not quietly
 * resume by starting the next one. The flag is kept separate from the process
 * for exactly this: rsync finishing is not consent to carry on. */
func TestPausingBetweenCommandsHoldsTheNextOne(t *testing.T) {
	r := newPausableRunner(sysexec.NewSimple(sysexec.New(nil)))

	if err := r.Pause(); err != nil {
		t.Fatalf("Pause with nothing running: %v", err)
	}
	if !r.Paused() {
		t.Fatal("Paused() = false after Pause")
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan struct{})
	go func() {
		defer close(done)
		r.Stream(ctx, []string{"sh", "-c", "sleep 30"}, func(string, string) {})
	}()

	p := currentProcess(t, r)
	_, pgid, _ := procStat(p.Pid())

	stopped := false
	for i := 0; i < 100; i++ {
		if allStopped(pgid) {
			stopped = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !stopped {
		t.Fatalf("the next command ran despite the job being paused: %v", groupStates(pgid))
	}

	r.Resume()
	cancel()
	<-done
}

// Pausing with nothing running is a legitimate moment -- between two commands
// of the same job -- not an error.
func TestPauseAndResumeWithNothingRunning(t *testing.T) {
	r := newPausableRunner(sysexec.NewSimple(sysexec.New(nil)))
	if err := r.Pause(); err != nil {
		t.Errorf("Pause: %v", err)
	}
	if err := r.Resume(); err != nil {
		t.Errorf("Resume: %v", err)
	}
	if r.Paused() {
		t.Error("still paused after Resume")
	}
}
