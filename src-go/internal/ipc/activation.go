package ipc

import (
	"fmt"
	"net"
	"os"
	"strconv"
	"syscall"
)

/* systemd socket activation.
 *
 * When systemd starts a service from a .socket unit it has already created,
 * bound and listened on the socket, and passes it to the child as an inherited
 * file descriptor. The service must USE that descriptor: binding its own at the
 * same path would either fail or -- worse -- replace the socket systemd is
 * still queueing connections on, so the connection that triggered the start
 * would be lost.
 *
 * This is the sd_listen_fds(3) protocol, twenty lines of it, rather than a
 * dependency. The same reasoning as cmd/timeshiftd/notify.go, which implements
 * sd_notify for the same reason.
 *
 * Why activation matters here at all: apt-snapshot-guard is fail-closed and
 * blocks dpkg, and it can only use the daemon when the socket already exists.
 * With activation there is no "the daemon is not running" case to fall back
 * from -- connecting starts it.
 */

/* listenFDsStart is the first descriptor systemd passes, by convention.
 *
 * A variable rather than a constant only so tests can move it. fd 3 in a Go
 * test binary already belongs to the test harness's own log, and a test that
 * dups a socket onto it breaks `go test` itself in a way that surfaces long
 * after every assertion has passed ("can't write testlog.txt: bad file
 * descriptor"). Production never changes it.
 */
var listenFDsStart = 3

/* ListenersFromSystemd returns the sockets systemd passed to this process, or
 * nil when it did not start us from a .socket unit.
 *
 * LISTEN_PID guards against the variables being inherited by a grandchild: they
 * are set for the service's own pid, and anything they leak into must ignore
 * them. The variables are unset once read so an exec'd child cannot be confused
 * by them either.
 */
func ListenersFromSystemd() ([]net.Listener, error) {
	pidStr := os.Getenv("LISTEN_PID")
	countStr := os.Getenv("LISTEN_FDS")
	os.Unsetenv("LISTEN_PID")
	os.Unsetenv("LISTEN_FDS")
	os.Unsetenv("LISTEN_FDNAMES")

	if pidStr == "" || countStr == "" {
		return nil, nil
	}
	pid, err := strconv.Atoi(pidStr)
	if err != nil || pid != os.Getpid() {
		// Meant for someone else. Not an error: it just means we were not
		// socket-activated.
		return nil, nil
	}
	count, err := strconv.Atoi(countStr)
	if err != nil || count < 1 {
		return nil, nil
	}

	listeners := make([]net.Listener, 0, count)
	for i := 0; i < count; i++ {
		fd := listenFDsStart + i
		// The descriptors must not survive into anything we exec -- rsync, ssh
		// and every restore script are spawned by this process.
		syscall.CloseOnExec(fd)

		f := os.NewFile(uintptr(fd), fmt.Sprintf("systemd-socket-%d", i))
		if f == nil {
			return nil, fmt.Errorf("ipc: fd %d passed by systemd is not usable", fd)
		}
		ln, err := net.FileListener(f)
		// FileListener dups the descriptor, so ours is now surplus.
		f.Close()
		if err != nil {
			return nil, fmt.Errorf("ipc: fd %d passed by systemd is not a listening socket: %w", fd, err)
		}
		listeners = append(listeners, ln)
	}
	return listeners, nil
}
