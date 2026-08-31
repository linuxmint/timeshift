package sysexec

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func runner() *Exec { return New(nil) }

// The defect this package exists to fix. TeeJee's exec_script_sync() wrapped
// every command in a script ending `echo $? > status`, so the script's own exit
// status was that of a successful echo and the function returned 0 no matter
// what happened. Real exit codes are the baseline everything else depends on.
func TestExitCodeIsReal(t *testing.T) {
	for _, code := range []int{0, 1, 2, 23, 24, 42, 127} {
		res, err := runner().Run(context.Background(), Cmd{
			Argv: []string{"sh", "-c", "exit " + itoa(code)},
		})
		if err != nil {
			t.Fatalf("exit %d: %v", code, err)
		}
		if res.ExitCode != code {
			t.Errorf("exit %d reported as %d", code, res.ExitCode)
		}
	}
}

// rsync's 23 and 24 are not failures to every caller, so a non-zero exit must
// not be surfaced as a Go error -- callers have to be able to inspect it.
func TestNonZeroExitIsNotAnError(t *testing.T) {
	res, err := runner().Run(context.Background(), Cmd{Argv: []string{"sh", "-c", "exit 24"}})
	if err != nil {
		t.Fatalf("a non-zero exit must not be an error: %v", err)
	}
	if !res.Failed() {
		t.Error("Failed() should be true for exit 24")
	}
	if res.ExitCode != 24 {
		t.Errorf("ExitCode = %d", res.ExitCode)
	}
}

func TestMissingExecutable(t *testing.T) {
	_, err := runner().Run(context.Background(), Cmd{Argv: []string{"definitely-not-a-real-binary-xyz"}})
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("err = %v, want ErrNotFound", err)
	}
}

func TestEmptyArgv(t *testing.T) {
	if _, err := runner().Run(context.Background(), Cmd{}); err == nil {
		t.Error("empty argv must be rejected")
	}
}

func TestStdoutAndStderrSeparated(t *testing.T) {
	res, err := runner().Run(context.Background(), Cmd{
		Argv: []string{"sh", "-c", "echo to-out; echo to-err >&2"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(res.Stdout, "to-out") || strings.Contains(res.Stdout, "to-err") {
		t.Errorf("stdout = %q", res.Stdout)
	}
	if !strings.Contains(res.Stderr, "to-err") || strings.Contains(res.Stderr, "to-out") {
		t.Errorf("stderr = %q", res.Stderr)
	}
}

// A command that printed to stdout and then failed used to report only the
// stdout, hiding the actual reason.
func TestOutputPrefersStderrOnFailure(t *testing.T) {
	res, _ := runner().Run(context.Background(), Cmd{
		Argv: []string{"sh", "-c", "echo progress; echo the-real-reason >&2; exit 1"},
	})
	if !strings.Contains(res.Output(), "the-real-reason") {
		t.Errorf("Output() = %q, want the stderr", res.Output())
	}

	ok, _ := runner().Run(context.Background(), Cmd{Argv: []string{"sh", "-c", "echo fine"}})
	if !strings.Contains(ok.Output(), "fine") {
		t.Errorf("Output() on success = %q, want stdout", ok.Output())
	}
}

// The passphrase path: as an argument it would sit in /proc/<pid>/cmdline,
// readable by anything, for the life of the process.
func TestStdin(t *testing.T) {
	res, err := runner().Run(context.Background(), Cmd{
		Argv:  []string{"cat"},
		Stdin: "secret-passphrase\n",
	})
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(res.Stdout) != "secret-passphrase" {
		t.Errorf("stdout = %q", res.Stdout)
	}
}

// Every parser in this tree reads command output positionally. A translated df
// or lsblk breaks all of them, which is why the C locale is forced.
func TestDefaultEnvForcesCLocale(t *testing.T) {
	res, err := runner().Run(context.Background(), Cmd{
		Argv: []string{"sh", "-c", "echo LANG=$LANG LC_ALL=$LC_ALL"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(res.Stdout, "LANG=C") {
		t.Errorf("LANG not forced: %q", res.Stdout)
	}
	if !strings.Contains(res.Stdout, "LC_ALL=C.UTF-8") {
		t.Errorf("LC_ALL not forced: %q", res.Stdout)
	}
}

func TestExplicitEnvReplaces(t *testing.T) {
	res, err := runner().Run(context.Background(), Cmd{
		Argv: []string{"sh", "-c", "echo [$MARKER]"},
		Env:  []string{"MARKER=set-by-test", "PATH=" + os.Getenv("PATH")},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(res.Stdout, "[set-by-test]") {
		t.Errorf("stdout = %q", res.Stdout)
	}
}

func TestDir(t *testing.T) {
	dir := t.TempDir()
	res, err := runner().Run(context.Background(), Cmd{Argv: []string{"pwd"}, Dir: dir})
	if err != nil {
		t.Fatal(err)
	}
	// macOS-style /private prefixes do not apply here, but resolve anyway.
	want, _ := filepath.EvalSymlinks(dir)
	got, _ := filepath.EvalSymlinks(strings.TrimSpace(res.Stdout))
	if got != want {
		t.Errorf("pwd = %q, want %q", got, want)
	}
}

// Progress is driven by counting lines as they arrive, so the handler must see
// each one exactly once, in order, before Wait returns.
func TestStreamingHandlerSeesEveryLine(t *testing.T) {
	var mu sync.Mutex
	var got []string

	p, err := runner().Start(context.Background(), Cmd{
		Argv: []string{"sh", "-c", "for i in $(seq 1 500); do echo line-$i; done"},
	}, Handler{
		Stdout: func(l string) {
			mu.Lock()
			got = append(got, l)
			mu.Unlock()
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := p.Wait(); err != nil {
		t.Fatal(err)
	}

	if len(got) != 500 {
		t.Fatalf("handler saw %d lines, want 500", len(got))
	}
	if got[0] != "line-1" || got[499] != "line-500" {
		t.Errorf("order wrong: first=%q last=%q", got[0], got[499])
	}
}

// A path longer than the scanner's starting buffer must not truncate: rsync
// emits deep paths and a silently dropped line is a silently wrong progress
// count.
func TestLongLine(t *testing.T) {
	long := strings.Repeat("d/", 40000) + "file.txt"
	var got string
	p, err := runner().Start(context.Background(), Cmd{
		Argv: []string{"sh", "-c", "printf '%s\\n' \"$0\"", long},
	}, Handler{Stdout: func(l string) { got = l }})
	if err != nil {
		t.Fatal(err)
	}
	p.Wait()
	if got != long {
		t.Errorf("long line truncated: got %d bytes, want %d", len(got), len(long))
	}
}

func TestStop(t *testing.T) {
	p, err := runner().Start(context.Background(), Cmd{
		Argv: []string{"sh", "-c", "sleep 30"},
	}, Handler{})
	if err != nil {
		t.Fatal(err)
	}

	go func() {
		time.Sleep(100 * time.Millisecond)
		p.Stop()
	}()

	done := make(chan struct{})
	go func() { p.Wait(); close(done) }()

	select {
	case <-done:
	case <-time.After(10 * time.Second):
		p.Kill()
		t.Fatal("Stop did not terminate the child")
	}
}

// SIGTERM delivered to a stopped process is queued and does nothing until it
// runs again, so cancelling a paused backup would hang forever without the
// SIGCONT that Stop sends first.
func TestStopWhilePaused(t *testing.T) {
	p, err := runner().Start(context.Background(), Cmd{
		Argv: []string{"sh", "-c", "sleep 30"},
	}, Handler{})
	if err != nil {
		t.Fatal(err)
	}

	if err := p.Pause(); err != nil {
		t.Fatal(err)
	}
	if !p.Paused() {
		t.Error("Paused() false after Pause()")
	}

	done := make(chan struct{})
	go func() { p.Wait(); close(done) }()

	time.Sleep(100 * time.Millisecond)
	if err := p.Stop(); err != nil {
		t.Fatal(err)
	}

	select {
	case <-done:
	case <-time.After(10 * time.Second):
		p.Kill()
		t.Fatal("a paused child could not be stopped")
	}
}

func TestPauseResume(t *testing.T) {
	p, err := runner().Start(context.Background(), Cmd{
		Argv: []string{"sh", "-c", "sleep 30"},
	}, Handler{})
	if err != nil {
		t.Fatal(err)
	}
	defer p.Kill()

	if err := p.Pause(); err != nil {
		t.Fatal(err)
	}
	if !p.Paused() {
		t.Error("Paused() should be true")
	}
	if err := p.Resume(); err != nil {
		t.Fatal(err)
	}
	if p.Paused() {
		t.Error("Paused() should be false after Resume")
	}
}

// rsync over ssh forks a child; signalling only the leader leaves that child
// running and holding the connection open.
func TestKillReachesTheWholeGroup(t *testing.T) {
	dir := t.TempDir()
	marker := filepath.Join(dir, "grandchild-alive")

	// The grandchild outlives its parent shell unless the whole group is
	// signalled; it would then create the marker.
	script := "sh -c 'sleep 2; touch " + marker + "' & sleep 30"

	p, err := runner().Start(context.Background(), Cmd{Argv: []string{"sh", "-c", script}}, Handler{})
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(200 * time.Millisecond)
	if err := p.Kill(); err != nil {
		t.Fatal(err)
	}
	p.Wait()

	time.Sleep(3 * time.Second)
	if _, err := os.Stat(marker); err == nil {
		t.Error("a grandchild survived Kill; the process group was not signalled")
	}
}

func TestContextCancelKills(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	p, err := runner().Start(ctx, Cmd{Argv: []string{"sh", "-c", "sleep 30"}}, Handler{})
	if err != nil {
		t.Fatal(err)
	}

	done := make(chan struct{})
	go func() { p.Wait(); close(done) }()

	time.Sleep(100 * time.Millisecond)
	cancel()

	select {
	case <-done:
	case <-time.After(10 * time.Second):
		p.Kill()
		t.Fatal("cancelling the context did not kill the child")
	}
}

func TestNiceAndIOIdleDoNotBreakTheRun(t *testing.T) {
	// Whether the syscalls are permitted depends on privilege; what must hold
	// is that asking for them never stops the command running.
	res, err := runner().Run(context.Background(), Cmd{
		Argv:   []string{"sh", "-c", "echo ok"},
		Nice:   5,
		IOIdle: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(res.Stdout) != "ok" {
		t.Errorf("stdout = %q", res.Stdout)
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}
