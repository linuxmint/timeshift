package timeshift

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A local repository must NOT be mounted. The snapshot is already a directory
// on a mounted filesystem, and reporting Mounted would invite a release that
// unmounts the repository itself.
func TestBrowsingALocalSnapshotMountsNothing(t *testing.T) {
	repo, root := testRepo(t)
	repo.Deps.MountRoot = filepath.Join(t.TempDir(), "run")
	seedSnapshot(t, root, "2026-08-20_09-00-01", []string{"ondemand"}, "")

	dir := snapshotDir(root, "2026-08-20_09-00-01")
	m, err := repo.Browse(context.Background(), dir, 1000, 1000)
	if err != nil {
		t.Fatalf("Browse: %v", err)
	}
	if m.Mounted {
		t.Error("a local snapshot was reported as mounted")
	}
	if m.Path != dir {
		t.Errorf("Path = %q, want %q", m.Path, dir)
	}

	// Releasing it must be a no-op rather than an unmount of the repository.
	if err := repo.ReleaseBrowse(context.Background(), dir); err != nil {
		t.Errorf("ReleaseBrowse: %v", err)
	}
	if _, err := os.Stat(dir); err != nil {
		t.Errorf("releasing a local browse removed the snapshot: %v", err)
	}
}

// The mount point is derived from the snapshot path, so browsing the same
// snapshot twice reuses one mount and two different ones cannot collide.
func TestBrowseMountPointIsStableAndDistinct(t *testing.T) {
	repo, _ := testRepo(t)
	repo.Deps.MountRoot = "/run/timeshift/1234"

	a1 := repo.BrowseMountPoint("/mnt/repo/timeshift/snapshots/A")
	a2 := repo.BrowseMountPoint("/mnt/repo/timeshift/snapshots/A")
	b := repo.BrowseMountPoint("/mnt/repo/timeshift/snapshots/B")

	if a1 != a2 {
		t.Errorf("the same snapshot produced two mount points: %q and %q", a1, a2)
	}
	if a1 == b {
		t.Error("two snapshots share a mount point")
	}
	if !strings.HasPrefix(a1, "/run/timeshift/1234/browse/") {
		t.Errorf("mount point %q is not under the run directory's browse dir", a1)
	}
	// Long enough to be distinct, short enough to be a directory name.
	if base := filepath.Base(a1); len(base) != 12 {
		t.Errorf("mount point name %q is not the expected digest length", base)
	}
}

func TestBrowseNeedsARunDirectory(t *testing.T) {
	repo, _ := testRepo(t)
	repo.Deps.MountRoot = ""
	if got := repo.BrowseMountPoint("/anything"); got != "" {
		t.Errorf("BrowseMountPoint with no run dir = %q, want empty", got)
	}
}

/* The sshfs command is built as argv, never as a shell string.
 *
 * Every value in it comes from a config file, and the Vala version assembled it
 * by concatenation with escape_single_quote() around each one -- which is one
 * missed call away from arbitrary code as root. These assertions are about the
 * options that are load-bearing rather than the whole line.
 */
func TestSSHFSCommandIsSafeAndReadOnly(t *testing.T) {
	b := &SSHBackend{
		User: "backup", Host: "nas.example", Port: 2222,
		Path: "/srv/snap", KeyFile: "/etc/timeshift/ssh/id_ed25519",
	}
	argv := sshfsArgv(b, "/srv/snap/timeshift/snapshots/A", "/run/timeshift/1/browse/abc", 1000, 1000)

	joined := strings.Join(argv, " ")
	for _, want := range []string{
		"ro",                              // browsing must never alter a snapshot
		"allow_other,default_permissions", // the desktop user reads a root mount
		"uid=1000,gid=1000",
		"BatchMode=yes",                // never prompt from a daemon
		"IdentitiesOnly=yes",           // an agent must not pre-empt our key
		"ssh_command=ssh -F /dev/null", // root's ssh_config must not rewrite this
		"IdentityFile=/etc/timeshift/ssh/id_ed25519",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("sshfs argv is missing %q:\n%v", want, argv)
		}
	}

	if argv[len(argv)-1] != "/run/timeshift/1/browse/abc" {
		t.Errorf("last argument = %q, want the mount point", argv[len(argv)-1])
	}
	if src := argv[len(argv)-2]; src != "backup@nas.example:/srv/snap/timeshift/snapshots/A" {
		t.Errorf("source = %q", src)
	}

	// A non-default port must be passed, and a default one must not be.
	if !strings.Contains(joined, "-p 2222") {
		t.Errorf("port was not passed: %v", argv)
	}
	b.Port = 22
	if strings.Contains(strings.Join(sshfsArgv(b, "/x", "/y", 0, 0), " "), "-p 22") {
		t.Error("the default port was passed explicitly")
	}

	// No shell metacharacters are interpreted, because there is no shell: every
	// element is its own argv entry.
	b.Path = "/srv/snap; rm -rf /"
	got := sshfsArgv(b, b.Path, "/y", 0, 0)
	if got[len(got)-2] != "backup@nas.example:/srv/snap; rm -rf /" {
		t.Errorf("path was reinterpreted: %q", got[len(got)-2])
	}
}

// A remote repository with no key cannot be browsed, and must say so rather
// than producing an sshfs command that prompts or fails obscurely.
func TestBrowsingARemoteWithNoKeyIsRefused(t *testing.T) {
	repo, _ := testRepo(t)
	repo.Deps.MountRoot = filepath.Join(t.TempDir(), "run")
	repo.Backend = &SSHBackend{User: "backup", Host: "nas.example", Path: "/srv/snap"}

	if _, err := repo.Browse(context.Background(), "/srv/snap/x", 0, 0); err == nil {
		t.Fatal("browsing without a key was allowed")
	} else if !strings.Contains(err.Error(), "SSH key") {
		t.Errorf("error did not name the missing key: %v", err)
	}
}
