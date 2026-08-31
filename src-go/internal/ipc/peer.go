package ipc

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"os/user"
	"strconv"
	"strings"
	"syscall"
)

/* Who is on the other end of the socket.
 *
 * SO_PEERCRED is the kernel's answer, taken at connect time and not forgeable
 * by the client -- which is why it is used rather than anything the client
 * tells us about itself.
 */

// Peer is the identity of a connected client.
type Peer struct {
	UID int
	GID int
	PID int

	// ReadOnly means this peer may call only the methods marked read-only:
	// it can watch a backup, it cannot start or delete one.
	ReadOnly bool
}

// String is for log lines.
func (p Peer) String() string {
	mode := "rw"
	if p.ReadOnly {
		mode = "ro"
	}
	return fmt.Sprintf("uid=%d pid=%d %s", p.UID, p.PID, mode)
}

// ErrDenied is returned for a connection from a uid with no access at all.
type ErrDenied struct{ Peer Peer }

func (e ErrDenied) Error() string {
	return fmt.Sprintf("ipc: connection refused for uid %d", e.Peer.UID)
}

// Authorizer decides what a connecting peer may do. Returning an error refuses
// the connection outright.
//
// Separated from reading the credentials so the policy is a value rather than a
// hard-wired rule: the daemon uses DefaultAuthorizer, and a different
// environment -- or a test -- can supply its own without reimplementing
// SO_PEERCRED.
type Authorizer func(Peer) (Peer, error)

// DefaultAuthorizer is the daemon's policy.
//
// root gets everything. A member of the timeshift group gets the read-only
// subset -- enough to watch an apt-driven backup without pkexec, which is the
// case this whole daemon exists for. Anyone else is refused outright.
func DefaultAuthorizer(groupGID int) Authorizer {
	return func(p Peer) (Peer, error) {
		if p.UID == 0 {
			return p, nil
		}
		if groupGID >= 0 && inGroup(p, groupGID) {
			p.ReadOnly = true
			return p, nil
		}
		return p, ErrDenied{Peer: p}
	}
}

// peerCreds reads the kernel's view of who is on the other end. Taken at
// connect time and not forgeable by the client, which is why it is used rather
// than anything the client says about itself.
func peerCreds(conn *net.UnixConn) (Peer, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return Peer{}, fmt.Errorf("ipc: syscall conn: %w", err)
	}

	var ucred *syscall.Ucred
	var soErr error
	if err := raw.Control(func(fd uintptr) {
		ucred, soErr = syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	}); err != nil {
		return Peer{}, fmt.Errorf("ipc: control: %w", err)
	}
	if soErr != nil {
		return Peer{}, fmt.Errorf("ipc: SO_PEERCRED: %w", soErr)
	}

	return Peer{UID: int(ucred.Uid), GID: int(ucred.Gid), PID: int(ucred.Pid)}, nil
}

/* Group membership.
 *
 * SO_PEERCRED reports only the primary gid, and a user's primary group is
 * almost never the one being granted here -- so the supplementary groups have
 * to come from /proc/<pid>/status.
 *
 * That introduces a pid-reuse window: between the kernel recording the pid and
 * us reading /proc, the process could in principle have exited and its pid been
 * reused. Verifying that /proc's Uid and Gid still match what SO_PEERCRED
 * reported closes almost all of it -- the replacement process would have to
 * belong to the same user, in which case it would have the same group
 * membership anyway, and the answer is the same.
 */
func inGroup(p Peer, gid int) bool {
	if p.GID == gid {
		return true
	}

	f, err := os.Open(fmt.Sprintf("/proc/%d/status", p.PID))
	if err != nil {
		return false
	}
	defer f.Close()

	var (
		groups   []int
		uidMatch bool
		gidMatch bool
	)
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "Uid:"):
			// Real, effective, saved, filesystem. SO_PEERCRED reports the
			// effective uid.
			if f := strings.Fields(line); len(f) > 2 {
				if n, err := strconv.Atoi(f[2]); err == nil && n == p.UID {
					uidMatch = true
				}
			}
		case strings.HasPrefix(line, "Gid:"):
			if f := strings.Fields(line); len(f) > 2 {
				if n, err := strconv.Atoi(f[2]); err == nil && n == p.GID {
					gidMatch = true
				}
			}
		case strings.HasPrefix(line, "Groups:"):
			for _, g := range strings.Fields(strings.TrimPrefix(line, "Groups:")) {
				if n, err := strconv.Atoi(g); err == nil {
					groups = append(groups, n)
				}
			}
		}
	}

	// The pid must still be the process we were told about.
	if !uidMatch || !gidMatch {
		return false
	}
	for _, g := range groups {
		if g == gid {
			return true
		}
	}
	return false
}

// LookupGroupGID resolves the read-only group. A missing group is not an error:
// it simply means nobody but root can connect, which is a valid configuration
// and the one in place until debian/postinst creates it.
func LookupGroupGID(name string) int {
	g, err := user.LookupGroup(name)
	if err != nil {
		return -1
	}
	gid, err := strconv.Atoi(g.Gid)
	if err != nil {
		return -1
	}
	return gid
}
