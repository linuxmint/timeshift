package timeshift

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"os"
	"path"
	"strconv"
	"strings"

	"github.com/makeafide/timeshift/src-go/internal/engines"
)

/* Browsing a snapshot's files.
 *
 * A local repository needs nothing: the snapshot is already a directory tree on
 * a mounted filesystem, so browsing it is opening a path.
 *
 * A remote one has to be mounted, and the reason it cannot be left to the
 * desktop is credentials. The key that opens the repository lives in
 * /etc/timeshift/ssh and is readable only by root, so the person at the
 * keyboard very often has no way to reach the host at all. Timeshift mounts it
 * with its own key and hands the mount to them.
 *
 * The daemon does the mounting; it does NOT open a file manager. That needs the
 * desktop user's session -- DISPLAY, their bus, their own file manager -- and
 * belongs to the client. The split matters because the daemon may have no
 * session at all.
 */

/* Browse makes a snapshot readable at a local path.
 *
 * asUID and asGID own the mount. They are the DESKTOP user's, not ours: the
 * daemon runs as root and the file manager does not, so a mount owned by root
 * is a mount the person cannot read. A caller that does not know passes 0 and
 * gets a root-owned mount, which is right for a root-only client.
 */
func (r *Repo) Browse(ctx context.Context, snapshotPath string, asUID, asGID int) (engines.BrowseMount, error) {
	if !r.Backend.IsRemote() {
		// Already a path on a mounted filesystem.
		return engines.BrowseMount{Path: snapshotPath, Mounted: false}, nil
	}

	ssh, ok := r.Backend.(*SSHBackend)
	if !ok {
		return engines.BrowseMount{}, fmt.Errorf("timeshift: this remote backend cannot be browsed")
	}
	if ssh.KeyFile == "" {
		return engines.BrowseMount{}, fmt.Errorf("timeshift: no SSH key is configured for this location")
	}

	mountPoint := r.BrowseMountPoint(snapshotPath)
	if mountPoint == "" {
		return engines.BrowseMount{}, fmt.Errorf("timeshift: no run directory for a browse mount")
	}

	// One mount per path, so browsing a second snapshot does not collide with
	// the first, and browsing the same one twice reuses it.
	if isMountPoint(mountPoint) {
		return engines.BrowseMount{Path: mountPoint, Mounted: true}, nil
	}

	if err := os.MkdirAll(mountPoint, 0o755); err != nil {
		return engines.BrowseMount{}, err
	}

	argv := sshfsArgv(ssh, snapshotPath, mountPoint, asUID, asGID)
	code, _, stderr, err := r.Deps.Runner.Run(ctx, argv, "")
	if err != nil {
		return engines.BrowseMount{}, err
	}
	if code != 0 {
		os.Remove(mountPoint)
		msg := strings.TrimSpace(stderr)
		if msg == "" {
			msg = "sshfs exited " + strconv.Itoa(code)
		}
		return engines.BrowseMount{}, fmt.Errorf("timeshift: could not mount the remote snapshot: %s", msg)
	}

	return engines.BrowseMount{Path: mountPoint, Mounted: true}, nil
}

// ReleaseBrowse unmounts a browse mount this package made.
func (r *Repo) ReleaseBrowse(ctx context.Context, mountPoint string) error {
	return ReleaseBrowseMount(ctx, r.Deps.Runner, mountPoint)
}

/* ReleaseBrowseMount unmounts a browse mount without a repository.
 *
 * Releasing needs a runner and a path and nothing else -- no backend, no
 * connection, no mounted repository. Requiring an open repository for it was a
 * real trap: for a local location Open MOUNTS the repository device, so
 * unplugging the disk a snapshot was being browsed from made Open fail, and
 * the browse mount could then never be released at all. Which is exactly the
 * situation browsing a removable disk creates.
 */
func ReleaseBrowseMount(ctx context.Context, runner engines.Runner, mountPoint string) error {
	/* Nothing mounted, nothing to unmount -- and no runner needed to say so.
	 * Checked before the runner, because a caller cleaning up a path that was
	 * never mounted (a local repository never mounts one) is the common case
	 * and must not require a command runner it has no use for. */
	if !isMountPoint(mountPoint) {
		os.Remove(mountPoint) // empty, harmless; a non-empty one is refused
		return nil
	}
	if runner == nil {
		return fmt.Errorf("timeshift: no command runner")
	}
	/* fusermount rather than umount: an sshfs mount made by root still belongs
	 * to FUSE, and umount(8) on a fuse mount works only for root anyway. Using
	 * the same tool that mounted it keeps the two symmetrical. */
	if code, _, stderr, err := runner.Run(ctx, []string{"fusermount", "-u", mountPoint}, ""); err != nil {
		return err
	} else if code != 0 {
		if code2, _, _, _ := runner.Run(ctx, []string{"umount", mountPoint}, ""); code2 != 0 {
			return fmt.Errorf("timeshift: could not release %s: %s", mountPoint, strings.TrimSpace(stderr))
		}
	}
	os.Remove(mountPoint)
	return nil
}

/* BrowseMountPoint is where a given snapshot path would be mounted.
 *
 * Under the run directory, named by a digest of the repository path rather than
 * the path itself: a snapshot path contains slashes and is far too long for a
 * directory name, and the digest makes "same path, same mount" automatic. */
func (r *Repo) BrowseMountPoint(snapshotPath string) string {
	root := r.Deps.MountRoot
	if root == "" {
		return ""
	}
	sum := sha1.Sum([]byte(snapshotPath))
	return path.Join(root, "browse", hex.EncodeToString(sum[:])[:12])
}

// sshfsArgv builds the mount command.
//
// Argv rather than a shell string: every value here comes from a config file,
// and escape_single_quote() around a host is one missed call away from
// arbitrary code as root.
func sshfsArgv(b *SSHBackend, repoPath, mountPoint string, asUID, asGID int) []string {
	argv := []string{
		"sshfs",

		// Browsing must never be able to alter a snapshot.
		"-o", "ro",

		/* allow_other is what lets the desktop user's file manager read a
		 * mount made by root. It needs user_allow_other in /etc/fuse.conf only
		 * for NON-root mounts -- see fuse.conf's own comment -- and this is
		 * always root, so no change to that file is required. */
		"-o", "allow_other,default_permissions",
		"-o", fmt.Sprintf("uid=%d,gid=%d", asUID, asGID),

		// The same discipline as the ssh options: no agent, no ssh_config, our
		// own known_hosts.
		"-o", "BatchMode=yes",
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "ConnectTimeout=10",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=3",
		"-o", "IdentitiesOnly=yes",
		"-o", "ssh_command=ssh -F /dev/null",
		"-o", "IdentityFile=" + b.KeyFile,
		"-o", "UserKnownHostsFile=" + KnownHostsFile(),
	}
	if b.Port != 0 && b.Port != 22 {
		argv = append(argv, "-p", strconv.Itoa(b.Port))
	}
	return append(argv, b.HostSpec()+":"+repoPath, mountPoint)
}

// isMountPoint reports whether p appears in /proc/mounts.
func isMountPoint(p string) bool {
	raw, err := os.ReadFile("/proc/mounts")
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(raw), "\n") {
		f := strings.Fields(line)
		if len(f) >= 2 && unescapeMountField(f[1]) == p {
			return true
		}
	}
	return false
}

// unescapeMountField decodes the octal escapes /proc/mounts uses.
func unescapeMountField(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+3 < len(s) {
			if v, err := strconv.ParseUint(s[i+1:i+4], 8, 8); err == nil {
				b.WriteByte(byte(v))
				i += 3
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}
