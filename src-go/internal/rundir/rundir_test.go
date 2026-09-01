package rundir

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeRunner records umount calls and can be told which ones fail.
type fakeRunner struct {
	calls []string
	fail  map[string]bool
}

func (f *fakeRunner) Run(ctx context.Context, argv []string, dir string) (int, string, string, error) {
	f.calls = append(f.calls, strings.Join(argv, " "))
	if f.fail[strings.Join(argv, " ")] {
		return 32, "", "target is busy", nil
	}
	return 0, "", "", nil
}

// harness builds a fake /run/timeshift and a fake /proc/mounts over it.
type harness struct {
	root   string
	mounts string
	runner *fakeRunner
	alive  map[int]bool
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	dir := t.TempDir()
	h := &harness{
		root:   filepath.Join(dir, "run"),
		mounts: filepath.Join(dir, "mounts"),
		runner: &fakeRunner{fail: map[string]bool{}},
		alive:  map[int]bool{},
	}
	if err := os.MkdirAll(h.root, 0o755); err != nil {
		t.Fatal(err)
	}
	h.setMounts()
	return h
}

func (h *harness) setMounts(points ...string) {
	var b strings.Builder
	for _, p := range points {
		b.WriteString("/dev/sda1 " + p + " ext4 rw 0 0\n")
	}
	os.WriteFile(h.mounts, []byte(b.String()), 0o644)
}

func (h *harness) reaper() *Reaper {
	return &Reaper{
		Runner:     h.runner,
		Root:       h.root,
		Self:       999999,
		MountsFile: h.mounts,
		Alive:      func(pid int) bool { return h.alive[pid] },
	}
}

func (h *harness) mkdir(t *testing.T, parts ...string) string {
	t.Helper()
	p := filepath.Join(append([]string{h.root}, parts...)...)
	if err := os.MkdirAll(p, 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

/* THE test.
 *
 * The daemon's socket lives in the directory being swept. A reaper that walked
 * everything rather than only numeric-pid subdirectories would delete the
 * socket it is about to listen on -- turning a tidy-up into an outage. The
 * repository write lock is in there too, and removing it would break the
 * flock the Vala core is holding on the same path. */
func TestTheSocketAndTheLockAreNeverTouched(t *testing.T) {
	h := newHarness(t)

	sock := filepath.Join(h.root, "daemon.sock")
	lock := filepath.Join(h.root, "repo.lock")
	for _, f := range []string{sock, lock} {
		if err := os.WriteFile(f, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// A directory that merely looks suggestive is still not a pid.
	notAPid := h.mkdir(t, "browse")

	h.mkdir(t, "4242")
	h.alive[4242] = false

	rep := h.reaper().Reap(context.Background())

	for _, f := range []string{sock, lock, notAPid} {
		if _, err := os.Stat(f); err != nil {
			t.Errorf("reaper removed %s: %v", filepath.Base(f), err)
		}
	}
	if len(rep.Removed) != 1 || !strings.HasSuffix(rep.Removed[0], "4242") {
		t.Errorf("Removed = %v, want just the dead pid directory", rep.Removed)
	}
}

func TestALiveRunIsLeftAlone(t *testing.T) {
	h := newHarness(t)
	h.mkdir(t, "111")
	h.alive[111] = true

	rep := h.reaper().Reap(context.Background())

	if !rep.Empty() {
		t.Fatalf("swept a living run: %+v", rep)
	}
	if _, err := os.Stat(filepath.Join(h.root, "111")); err != nil {
		t.Errorf("removed a living run's directory: %v", err)
	}
}

func TestOurOwnDirectoryIsLeftAlone(t *testing.T) {
	h := newHarness(t)
	h.mkdir(t, "999999") // matches Self
	// Even though the Alive map says it is dead, self wins.
	h.alive[999999] = false

	rep := h.reaper().Reap(context.Background())

	if !rep.Empty() {
		t.Fatalf("swept our own directory: %+v", rep)
	}
}

// Nested mounts must come apart innermost first: /boot/efi is inside the root
// it sits under, and unmounting the parent first leaves the child stranded.
func TestNestedMountsAreReleasedDeepestFirst(t *testing.T) {
	h := newHarness(t)
	dead := h.mkdir(t, "500", "restore")
	h.mkdir(t, "500", "restore", "boot", "efi")
	h.alive[500] = false

	h.setMounts(dead, filepath.Join(dead, "home"), filepath.Join(dead, "boot", "efi"))

	rep := h.reaper().Reap(context.Background())

	if len(rep.Unmounted) != 3 {
		t.Fatalf("Unmounted = %v, want three mount points", rep.Unmounted)
	}
	deepest := rep.Unmounted[0]
	if !strings.HasSuffix(deepest, "boot/efi") {
		t.Errorf("released %s first, want the deepest mount", deepest)
	}
	if !strings.HasSuffix(rep.Unmounted[len(rep.Unmounted)-1], "restore") {
		t.Errorf("released %s last, want the outermost mount", rep.Unmounted[len(rep.Unmounted)-1])
	}
}

// A ControlMaster killed rather than shut down leaves a socket behind. rmdir
// cannot remove a socket, so without this the directory could never be reaped
// -- and a recycled pid would point a new run's ControlPath at the old socket.
func TestOrphanedSSHSocketsAreRemoved(t *testing.T) {
	h := newHarness(t)
	dir := h.mkdir(t, "600")
	sshSock := filepath.Join(dir, "ssh-backup@host:22")
	if err := os.WriteFile(sshSock, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	h.alive[600] = false

	rep := h.reaper().Reap(context.Background())

	if len(rep.Removed) != 1 {
		t.Fatalf("Removed = %v, Kept = %v; want the directory gone", rep.Removed, rep.Kept)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Errorf("directory survived: %v", err)
	}
}

// A mount that will not come apart must leave the directory in place. Removing
// through a live mount point would delete into a real filesystem.
func TestADirectoryWithAStuckMountIsKeptNotForced(t *testing.T) {
	h := newHarness(t)
	dir := h.mkdir(t, "700", "restore")
	h.alive[700] = false
	h.setMounts(dir)

	h.runner.fail["umount "+dir] = true
	h.runner.fail["umount -l "+dir] = true

	// Something inside it, as a live mount would have.
	if err := os.WriteFile(filepath.Join(dir, "occupied"), nil, 0o644); err != nil {
		t.Fatal(err)
	}

	rep := h.reaper().Reap(context.Background())

	if len(rep.Removed) != 0 {
		t.Errorf("Removed = %v, want nothing removed", rep.Removed)
	}
	if len(rep.Kept) != 1 {
		t.Errorf("Kept = %v, want the run directory kept", rep.Kept)
	}
	if len(rep.Problems) == 0 {
		t.Error("a stuck unmount was not reported")
	}
	if _, err := os.Stat(filepath.Join(dir, "occupied")); err != nil {
		t.Errorf("reaper deleted through a mount point: %v", err)
	}
}

// A busy unmount is retried lazily before being given up on: the holder is a
// process that no longer exists, so leaving it to detach beats leaving it
// mounted for the life of the boot.
func TestABusyUnmountIsRetriedLazily(t *testing.T) {
	h := newHarness(t)
	dir := h.mkdir(t, "800", "browse")
	h.alive[800] = false
	h.setMounts(dir)
	h.runner.fail["umount "+dir] = true

	rep := h.reaper().Reap(context.Background())

	want := []string{"umount " + dir, "umount -l " + dir}
	if len(h.runner.calls) != 2 || h.runner.calls[0] != want[0] || h.runner.calls[1] != want[1] {
		t.Fatalf("calls = %v, want %v", h.runner.calls, want)
	}
	if len(rep.Unmounted) != 1 {
		t.Errorf("Unmounted = %v, want the lazy unmount counted", rep.Unmounted)
	}
}

func TestNothingToDoIsSilent(t *testing.T) {
	h := newHarness(t)
	if rep := h.reaper().Reap(context.Background()); !rep.Empty() {
		t.Fatalf("empty run dir produced %+v", rep)
	}
}

func TestMissingRootIsNotAnError(t *testing.T) {
	r := &Reaper{Runner: &fakeRunner{}, Root: filepath.Join(t.TempDir(), "nope"), Self: 1}
	if rep := r.Reap(context.Background()); !rep.Empty() {
		t.Fatalf("missing root produced %+v", rep)
	}
}

func TestUnescapeMount(t *testing.T) {
	cases := map[string]string{
		`/run/timeshift/1/restore`:       "/run/timeshift/1/restore",
		`/mnt/my\040disk`:                "/mnt/my disk",
		`/mnt/a\011b`:                    "/mnt/a\tb",
		`/mnt/back\134slash`:             `/mnt/back\slash`,
		`/mnt/trailing\`:                 `/mnt/trailing\`,
		`/run/timeshift/2/browse/a\040b`: "/run/timeshift/2/browse/a b",
	}
	for in, want := range cases {
		if got := unescapeMount(in); got != want {
			t.Errorf("unescapeMount(%q) = %q, want %q", in, got, want)
		}
	}
}

// A mount point containing a space must still be matched and unmounted.
func TestAMountPointWithASpaceIsStillFound(t *testing.T) {
	h := newHarness(t)
	dir := h.mkdir(t, "900", "browse")
	h.alive[900] = false

	spaced := filepath.Join(dir, "My Backup")
	os.WriteFile(h.mounts, []byte("/dev/sdb1 "+strings.ReplaceAll(spaced, " ", `\040`)+" ext4 rw 0 0\n"), 0o644)

	rep := h.reaper().Reap(context.Background())

	if len(rep.Unmounted) != 1 || rep.Unmounted[0] != spaced {
		t.Fatalf("Unmounted = %v, want %q", rep.Unmounted, spaced)
	}
}
