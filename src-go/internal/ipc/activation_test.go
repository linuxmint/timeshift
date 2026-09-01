package ipc

import (
	"net"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
)

// withEnv sets LISTEN_PID/LISTEN_FDS for one call and restores afterwards.
func withEnv(t *testing.T, pid, fds string) {
	t.Helper()
	os.Setenv("LISTEN_PID", pid)
	os.Setenv("LISTEN_FDS", fds)
	t.Cleanup(func() {
		os.Unsetenv("LISTEN_PID")
		os.Unsetenv("LISTEN_FDS")
	})
}

func TestNoSystemdMeansNoListeners(t *testing.T) {
	os.Unsetenv("LISTEN_PID")
	os.Unsetenv("LISTEN_FDS")
	lns, err := ListenersFromSystemd()
	if err != nil {
		t.Fatalf("absence of systemd must not be an error: %v", err)
	}
	if lns != nil {
		t.Fatalf("want no listeners, got %d", len(lns))
	}
}

/* LISTEN_PID naming another process must be ignored.
 *
 * The variables are inherited by children, so a process that is NOT the
 * service would otherwise try to adopt descriptors that mean something else
 * entirely -- or nothing at all.
 */
func TestListenPIDForAnotherProcessIsIgnored(t *testing.T) {
	withEnv(t, strconv.Itoa(os.Getpid()+1), "1")
	lns, err := ListenersFromSystemd()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if lns != nil {
		t.Fatal("descriptors meant for another pid must not be adopted")
	}
}

// The variables must not survive the call, or an exec'd child sees them.
func TestEnvironmentIsClearedAfterReading(t *testing.T) {
	withEnv(t, strconv.Itoa(os.Getpid()+1), "1")
	ListenersFromSystemd()
	for _, k := range []string{"LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES"} {
		if _, ok := os.LookupEnv(k); ok {
			t.Errorf("%s survived the read", k)
		}
	}
}

/* The real path: a socket bound by "systemd" and handed over as fd 3.
 *
 * Built by binding a listener, dup'ing it onto fd 3, and setting the
 * variables the way systemd would -- which is as close to the real handover as
 * a test can get without systemd.
 */
func TestAdoptsAnInheritedSocket(t *testing.T) {
	dir := t.TempDir()
	sockPath := filepath.Join(dir, "test.sock")

	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	f, err := ln.(*net.UnixListener).File()
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	/* Hand it over on a descriptor of our own choosing.
	 *
	 * systemd always uses fd 3, but fd 3 in a Go test binary is the harness's
	 * own log: dup'ing a socket over it breaks `go test` in a way that only
	 * shows up after every assertion has passed ("can't write testlog.txt:
	 * bad file descriptor"). Moving the base for the duration tests exactly
	 * the same code without fighting for a descriptor somebody else owns.
	 */
	const testFD = 20
	if err := dup2(int(f.Fd()), testFD); err != nil {
		t.Skipf("cannot dup onto fd %d: %v", testFD, err)
	}
	defer syscall.Close(testFD)

	orig := listenFDsStart
	listenFDsStart = testFD
	defer func() { listenFDsStart = orig }()

	withEnv(t, strconv.Itoa(os.Getpid()), "1")

	lns, err := ListenersFromSystemd()
	if err != nil {
		t.Fatalf("adopting the inherited socket failed: %v", err)
	}
	if len(lns) != 1 {
		t.Fatalf("want 1 listener, got %d", len(lns))
	}
	defer lns[0].Close()

	// It must be the same socket: a client connecting to the path is accepted.
	done := make(chan error, 1)
	go func() {
		c, err := lns[0].Accept()
		if err == nil {
			c.Close()
		}
		done <- err
	}()

	c, err := net.Dial("unix", sockPath)
	if err != nil {
		t.Fatalf("could not connect to the adopted socket: %v", err)
	}
	c.Close()
	if err := <-done; err != nil {
		t.Fatalf("adopted listener did not accept: %v", err)
	}
}
