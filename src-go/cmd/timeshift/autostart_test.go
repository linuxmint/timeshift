package main

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/ipc"
)

/* The policy half: when autostart must NOT be attempted.
 *
 * Both refusals matter for the same reason. A private --socket names a daemon
 * the caller is running themselves, almost always against a throwaway config,
 * and starting the system daemon because that socket was missing would silently
 * point the command at the real repository.
 */
func TestAutostartRefusesAPrivateSocket(t *testing.T) {
	dir := t.TempDir()
	if err := autostartDaemon(filepath.Join(dir, "private.sock")); !errors.Is(err, errNoAutostart) {
		t.Fatalf("a private socket should not autostart; got %v", err)
	}
}

func TestAutostartRefusesWhenNotRoot(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root; this refusal only applies to an unprivileged caller")
	}
	// The default socket, so only the euid check can refuse it.
	if err := autostartDaemon(ipc.SocketPath); !errors.Is(err, errNoAutostart) {
		t.Fatalf("a non-root caller should not autostart; got %v", err)
	}
}

/* The mechanism half.
 *
 * spawnDaemon has to detach, so the proof is that the child ran at all after
 * the call returned -- not that we could wait for it.
 */
func TestSpawnDaemonRunsTheBinaryDetached(t *testing.T) {
	dir := t.TempDir()
	marker := filepath.Join(dir, "ran")
	stub := filepath.Join(dir, "timeshiftd")

	script := "#!/bin/sh\nexec touch " + marker + "\n"
	if err := os.WriteFile(stub, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	old := daemonBinary
	daemonBinary = stub
	defer func() { daemonBinary = old }()

	if err := spawnDaemon(); err != nil {
		t.Fatalf("spawnDaemon: %v", err)
	}

	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(marker); err == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("the spawned daemon never ran")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestSpawnDaemonReportsAMissingBinary(t *testing.T) {
	old := daemonBinary
	daemonBinary = filepath.Join(t.TempDir(), "absent")
	defer func() { daemonBinary = old }()

	err := spawnDaemon()
	if err == nil {
		t.Fatal("a missing daemon must be reported, not ignored")
	}
	// The message has to name what was looked for, or the reader cannot act.
	if got := err.Error(); got == "" || !contains(got, "not installed") {
		t.Fatalf("unhelpful error: %q", got)
	}
}

/* waitForSocket must test reachability, not existence.
 *
 * A daemon that died leaves the socket FILE behind, and stat-ing would report
 * that stale file as success -- turning "the daemon is not running" into a
 * connection error one layer further down, where it reads like a bug.
 */
func TestWaitForSocketIgnoresAStaleFile(t *testing.T) {
	stale := filepath.Join(t.TempDir(), "daemon.sock")
	if err := os.WriteFile(stale, nil, 0o600); err != nil {
		t.Fatal(err)
	}

	old := socketWait
	socketWait = 150 * time.Millisecond
	defer func() { socketWait = old }()

	if waitForSocket(stale) {
		t.Fatal("a plain file that happens to have the socket's name is not a daemon")
	}
}

func TestWaitForSocketSeesAListener(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	old := socketWait
	socketWait = 2 * time.Second
	defer func() { socketWait = old }()

	if !waitForSocket(path) {
		t.Fatal("a live listener should be seen")
	}
}

/* daemonPath prefers a daemon beside this executable, so a build running from
 * the source tree uses its own rather than the installed one. */
func TestDaemonPathPrefersTheOneBesideUs(t *testing.T) {
	dir := t.TempDir()
	installed := filepath.Join(dir, "installed-timeshiftd")
	if err := os.WriteFile(installed, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	old := daemonBinary
	daemonBinary = installed
	defer func() { daemonBinary = old }()

	self, err := os.Executable()
	if err != nil {
		t.Skip("cannot locate the test binary")
	}
	beside := filepath.Join(filepath.Dir(self), "timeshiftd")
	if _, err := os.Stat(beside); err == nil {
		t.Skip("something is already named timeshiftd beside the test binary")
	}
	if err := os.WriteFile(beside, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Skipf("cannot write beside the test binary: %v", err)
	}
	defer os.Remove(beside)

	if got := daemonPath(); got != beside {
		t.Fatalf("daemonPath() = %q, want the one beside us %q", got, beside)
	}
}

func TestIsExecutableRejectsADirectory(t *testing.T) {
	if isExecutable(t.TempDir()) {
		t.Fatal("a directory has the execute bit and is not a program")
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
