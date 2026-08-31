package timeshift

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/engines"
)

// execRunner runs commands for real. The btrfs tests need a real filesystem;
// mocking btrfs would only prove the mock agrees with itself.
type execRunner struct{}

func (execRunner) Run(ctx context.Context, argv []string, stdin string) (int, string, string, error) {
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var out, errb strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errb
	err := cmd.Run()
	if ee, ok := err.(*exec.ExitError); ok {
		return ee.ExitCode(), out.String(), errb.String(), nil
	}
	if err != nil {
		return -1, out.String(), errb.String(), err
	}
	return 0, out.String(), errb.String(), nil
}

/* A real btrfs filesystem on a loopback file.
 *
 * Needs root, so it skips when not available. Everything here is torn down;
 * nothing touches a real disk.
 */
func btrfsMount(t *testing.T) (mount string, runner Runner) {
	t.Helper()
	if os.Geteuid() != 0 {
		t.Skip("needs root to mount a loopback filesystem")
	}
	if _, err := exec.LookPath("mkfs.btrfs"); err != nil {
		t.Skip("btrfs-progs not installed")
	}

	// Short path: a loop mount under a long temp dir is fine, but keep it tidy.
	dir, err := os.MkdirTemp("", "tsbtrfs")
	if err != nil {
		t.Fatal(err)
	}
	img := filepath.Join(dir, "fs.img")
	mount = filepath.Join(dir, "mnt")
	if err := os.MkdirAll(mount, 0755); err != nil {
		t.Fatal(err)
	}

	// btrfs needs a little room; 512M is comfortably above its floor.
	if out, err := exec.Command("truncate", "-s", "512M", img).CombinedOutput(); err != nil {
		t.Fatalf("truncate: %v %s", err, out)
	}
	if out, err := exec.Command("mkfs.btrfs", "-q", "-f", img).CombinedOutput(); err != nil {
		t.Fatalf("mkfs.btrfs: %v %s", err, out)
	}
	if out, err := exec.Command("mount", "-o", "loop", img, mount).CombinedOutput(); err != nil {
		t.Fatalf("mount: %v %s", err, out)
	}

	t.Cleanup(func() {
		exec.Command("umount", mount).Run()
		os.RemoveAll(dir)
	})
	return mount, execRunner{}
}

func TestBtrfsAgainstRealFilesystem(t *testing.T) {
	mount, runner := btrfsMount(t)
	ctx := context.Background()

	// The Ubuntu-style layout this engine understands.
	for _, name := range []string{SubvolRoot, SubvolHome} {
		out, err := exec.Command("btrfs", "subvolume", "create", filepath.Join(mount, name)).CombinedOutput()
		if err != nil {
			t.Fatalf("create %s: %v %s", name, err, out)
		}
	}
	os.WriteFile(filepath.Join(mount, SubvolRoot, "marker"), []byte("original\n"), 0644)

	t.Run("layout validation", func(t *testing.T) {
		if err := ValidateLayout(ctx, runner, mount, true); err != nil {
			t.Errorf("a valid layout was rejected: %v", err)
		}
	})

	t.Run("list reports ids", func(t *testing.T) {
		subs, err := ListSubvolumes(ctx, runner, mount)
		if err != nil {
			t.Fatal(err)
		}
		root, ok := subs[SubvolRoot]
		if !ok {
			t.Fatalf("@ missing from %v", subs)
		}
		// The id is what the qgroup is named after, so it has to be real.
		if root.ID <= 0 {
			t.Errorf("@ has id %d; the qgroup cleanup needs a real id", root.ID)
		}
	})

	snapDir := filepath.Join(mount, "timeshift-btrfs", "snapshots", "2026-01-01_00-00-00")
	if err := os.MkdirAll(snapDir, 0755); err != nil {
		t.Fatal(err)
	}

	t.Run("snapshot is instant and shares data", func(t *testing.T) {
		dst := filepath.Join(snapDir, SubvolRoot)
		if err := SnapshotSubvolume(ctx, runner, filepath.Join(mount, SubvolRoot), dst); err != nil {
			t.Fatalf("snapshot: %v", err)
		}
		if !IsSubvolume(ctx, runner, dst) {
			t.Error("the snapshot is not a subvolume")
		}
		body, _ := os.ReadFile(filepath.Join(dst, "marker"))
		if string(body) != "original\n" {
			t.Errorf("the snapshot does not carry the original content: %q", body)
		}

		// Writing to the original must not change the snapshot: that is the
		// whole point of copy-on-write.
		os.WriteFile(filepath.Join(mount, SubvolRoot, "marker"), []byte("changed\n"), 0644)
		body, _ = os.ReadFile(filepath.Join(dst, "marker"))
		if string(body) != "original\n" {
			t.Errorf("writing to the source changed the snapshot: %q", body)
		}
	})

	t.Run("nested subvolume is handled", func(t *testing.T) {
		// A snapshot directory containing a subvolume of its own name is
		// exactly the case that makes a plain delete fail.
		outer := filepath.Join(mount, "nested-case")
		if out, err := exec.Command("btrfs", "subvolume", "create", outer).CombinedOutput(); err != nil {
			t.Fatalf("create: %v %s", err, out)
		}
		inner := filepath.Join(outer, "nested-case")
		if out, err := exec.Command("btrfs", "subvolume", "create", inner).CombinedOutput(); err != nil {
			t.Fatalf("create nested: %v %s", err, out)
		}

		caps, err := DetectBtrfsCaps(ctx, runner)
		if err != nil {
			t.Fatal(err)
		}
		sv := Subvolume{Name: "nested-case", Path: outer, MountPath: mount}
		if err := DeleteSubvolume(ctx, runner, sv, DeleteOptions{Caps: caps}); err != nil {
			t.Fatalf("delete with a nested subvolume: %v", err)
		}
		if _, err := os.Stat(outer); err == nil {
			t.Error("the subvolume still exists after deletion")
		}
	})

	// An ordinary directory of the matching name must NOT be treated as a
	// subvolume -- deleting it as one would fail, or worse, succeed.
	t.Run("ordinary directory is not mistaken for a subvolume", func(t *testing.T) {
		outer := filepath.Join(mount, "plain-case")
		if out, err := exec.Command("btrfs", "subvolume", "create", outer).CombinedOutput(); err != nil {
			t.Fatalf("create: %v %s", err, out)
		}
		plain := filepath.Join(outer, "plain-case")
		if err := os.MkdirAll(plain, 0755); err != nil {
			t.Fatal(err)
		}
		if IsSubvolume(ctx, runner, plain) {
			t.Fatal("an ordinary directory was reported as a subvolume")
		}

		caps, _ := DetectBtrfsCaps(ctx, runner)
		sv := Subvolume{Name: "plain-case", Path: outer, MountPath: mount}
		// btrfs refuses to delete a subvolume containing a plain directory
		// unless --recursive is available, so accept either outcome; what
		// matters is that IsSubvolume told the truth.
		_ = DeleteSubvolume(ctx, runner, sv, DeleteOptions{Caps: caps})
	})

	t.Run("restore refuses to overwrite a live subvolume", func(t *testing.T) {
		src := filepath.Join(snapDir, SubvolRoot)
		// @ is still there, so a restore onto it must be refused.
		err := RestoreSubvolume(ctx, runner, src, filepath.Join(mount, SubvolRoot))
		if err == nil {
			t.Fatal("restoring over a live subvolume was allowed; it would destroy what is there")
		}

		// Move the live one aside, as the pre-restore snapshot does, and then
		// it works.
		aside := filepath.Join(mount, "@-aside")
		if out, e := exec.Command("mv", filepath.Join(mount, SubvolRoot), aside).CombinedOutput(); e != nil {
			t.Fatalf("mv: %v %s", e, out)
		}
		if err := RestoreSubvolume(ctx, runner, src, filepath.Join(mount, SubvolRoot)); err != nil {
			t.Fatalf("restore after moving the live subvolume aside: %v", err)
		}
		body, _ := os.ReadFile(filepath.Join(mount, SubvolRoot, "marker"))
		if string(body) != "original\n" {
			t.Errorf("the restored subvolume has the wrong content: %q", body)
		}
	})

	t.Run("layout validation rejects a foreign layout", func(t *testing.T) {
		other, r2 := btrfsMount(t)
		if err := ValidateLayout(ctx, r2, other, false); err == nil {
			t.Error("a filesystem with no @ subvolume was accepted")
		}
	})
}

// The qgroup sequence, against a real filesystem with quotas actually enabled.
func TestQGroupCleanup(t *testing.T) {
	mount, runner := btrfsMount(t)
	ctx := context.Background()

	if out, err := exec.Command("btrfs", "quota", "enable", mount).CombinedOutput(); err != nil {
		t.Skipf("cannot enable quotas: %v %s", err, out)
	}

	target := filepath.Join(mount, "doomed")
	if out, err := exec.Command("btrfs", "subvolume", "create", target).CombinedOutput(); err != nil {
		t.Fatalf("create: %v %s", err, out)
	}

	subs, err := ListSubvolumes(ctx, runner, mount)
	if err != nil {
		t.Fatal(err)
	}
	sv := subs["doomed"]
	if sv.ID <= 0 {
		t.Fatalf("no id for the subvolume: %+v", sv)
	}
	sv.MountPath = mount

	caps, _ := DetectBtrfsCaps(ctx, runner)
	if err := DeleteSubvolume(ctx, runner, sv, DeleteOptions{Caps: caps}); err != nil {
		t.Fatalf("delete: %v", err)
	}

	// The sequence must complete rather than hang. Bounded, unlike the Vala
	// loops, because a daemon serving other clients cannot wait forever.
	/* Three minutes, not thirty seconds. `btrfs subvolume sync` blocks until
	 * the cleaner thread has removed the subvolume, which runs on the commit
	 * interval: measured at 31.0s for a single empty subvolume here. A 30s
	 * budget passes or fails depending on where in that interval the test
	 * happens to land. */
	start := time.Now()
	if err := CleanupQGroup(ctx, runner, sv, mount, QGroupCleanupOptions{
		Timeout:  3 * time.Minute,
		Interval: 200 * time.Millisecond,
	}); err != nil {
		t.Errorf("qgroup cleanup: %v", err)
	}
	t.Logf("qgroup cleanup took %s (most of it btrfs subvolume sync)", time.Since(start).Round(time.Second))

	// And the stale qgroup is gone: they accumulate otherwise and every
	// `qgroup show` gets slower.
	_, stdout, _, _ := runner.Run(ctx, []string{"btrfs", "qgroup", "show", "-f", mount}, "")
	if strings.Contains(stdout, fmt.Sprintf("0/%d ", sv.ID)) {
		t.Errorf("qgroup 0/%d survived the cleanup:\n%s", sv.ID, stdout)
	}
}

// The bounded wait must give up rather than block forever.
func TestQGroupCleanupTimesOut(t *testing.T) {
	failing := stubRunner{code: 1, stderr: "still busy"}
	sv := Subvolume{Name: "@", ID: 257, MountPath: "/mnt/fs"}

	start := time.Now()
	err := CleanupQGroup(context.Background(), failing, sv, "/mnt/fs", QGroupCleanupOptions{
		Timeout:  200 * time.Millisecond,
		Interval: 20 * time.Millisecond,
	})
	if err == nil {
		t.Fatal("a step that never succeeds must eventually give up")
	}
	if time.Since(start) > 3*time.Second {
		t.Errorf("gave up after %s; the timeout is not being honoured", time.Since(start))
	}
}

type stubRunner struct {
	code   int
	stdout string
	stderr string
}

func (s stubRunner) Run(context.Context, []string, string) (int, string, string, error) {
	return s.code, s.stdout, s.stderr, nil
}

// Version parsing decides whether --recursive is passed, and passing it to a
// btrfs-progs that does not know it fails the delete.
func TestParseBtrfsVersion(t *testing.T) {
	cases := map[string][2]int{
		"btrfs-progs v6.17.1\n": {6, 17},
		"btrfs-progs v6.12\n":   {6, 12},
		"btrfs-progs v5.16.2\n": {5, 16},
		"btrfs-progs v7.0\n":    {7, 0},
		"nonsense":              {0, 0},
	}
	for out, want := range cases {
		major, minor := parseBtrfsVersion(out)
		if major != want[0] || minor != want[1] {
			t.Errorf("parseBtrfsVersion(%q) = %d.%d, want %d.%d", out, major, minor, want[0], want[1])
		}
	}
}

func TestRecursiveDeleteGate(t *testing.T) {
	cases := []struct {
		version string
		want    bool
	}{
		{"btrfs-progs v6.17.1", true},
		{"btrfs-progs v6.12", true},  // --recursive arrived here
		{"btrfs-progs v6.11", false}, // and not before
		{"btrfs-progs v5.99", false},
		{"btrfs-progs v7.0", true},
	}
	for _, c := range cases {
		caps, err := DetectBtrfsCaps(context.Background(), stubRunner{stdout: c.version})
		if err != nil {
			t.Fatal(err)
		}
		if caps.RecursiveDelete != c.want {
			t.Errorf("%s: RecursiveDelete = %v, want %v", c.version, caps.RecursiveDelete, c.want)
		}
	}
}

func TestParseSubvolumeList(t *testing.T) {
	out := `ID 256 gen 9 top level 5 path @
ID 257 gen 12 top level 5 path @home
ID 258 gen 14 top level 256 path timeshift-btrfs/snapshots/2026-01-01_00-00-00/@
`
	subs := parseSubvolumeList(out, "/mnt/fs")
	if len(subs) != 3 {
		t.Fatalf("parsed %d subvolumes: %v", len(subs), subs)
	}
	if subs["@"].ID != 256 || subs["@"].Path != "/mnt/fs/@" {
		t.Errorf("@ = %+v", subs["@"])
	}
	if subs["@home"].ID != 257 {
		t.Errorf("@home id = %d", subs["@home"].ID)
	}
	// A nested path is kept whole, not truncated at the first slash.
	if _, ok := subs["timeshift-btrfs/snapshots/2026-01-01_00-00-00/@"]; !ok {
		t.Errorf("a nested subvolume path was mangled: %v", subs)
	}
}

func TestPlanBtrfsSnapshot(t *testing.T) {
	plan := PlanBtrfsSnapshot("/mnt/fs/timeshift-btrfs/snapshots", "2026-01-01_00-00-00", true)
	if plan.Subvolumes[SubvolRoot] != "/mnt/fs/timeshift-btrfs/snapshots/2026-01-01_00-00-00/@" {
		t.Errorf("@ path = %q", plan.Subvolumes[SubvolRoot])
	}
	if _, ok := plan.Subvolumes[SubvolHome]; !ok {
		t.Error("@home was requested but not planned")
	}

	plan = PlanBtrfsSnapshot("/mnt/fs/snaps", "n", false)
	if _, ok := plan.Subvolumes[SubvolHome]; ok {
		t.Error("@home was planned when it was not requested")
	}
}

// Only @ and @home. A repository with other names is refused rather than
// half-handled.
func TestSupportedSubvolumes(t *testing.T) {
	for _, ok := range []string{"@", "@home"} {
		if !IsSupportedSubvolume(ok) {
			t.Errorf("%q should be supported", ok)
		}
	}
	for _, no := range []string{"@srv", "root", "", "@Home", "home"} {
		if IsSupportedSubvolume(no) {
			t.Errorf("%q should not be supported", no)
		}
	}
}

// btrfs and a remote repository cannot be combined. The Vala core turned btrfs
// off silently during config load, so a user who chose both got rsync snapshots
// and was never told.
func TestBtrfsAndRemoteConflict(t *testing.T) {
	e := Engine{}

	err := e.ValidateLocation(engines.Location{Type: "ssh", BtrfsMode: true})
	if err == nil {
		t.Fatal("btrfs on a remote location must be reported as a conflict")
	}
	if !errors.Is(err, ErrBtrfsRemote) {
		t.Errorf("err = %v, want ErrBtrfsRemote", err)
	}

	for _, ok := range []engines.Location{
		{Type: "ssh", BtrfsMode: false},
		{Type: "local", BtrfsMode: true},
		{Type: "local", BtrfsMode: false},
	} {
		if err := e.ValidateLocation(ok); err != nil {
			t.Errorf("%+v was rejected: %v", ok, err)
		}
	}
}

// And the backstop: opening a remote location with btrfs requested must not
// produce a repository that thinks it is in btrfs mode.
func TestOpenForcesBtrfsOffForRemote(t *testing.T) {
	repository, err := Engine{}.Open(context.Background(), engines.Location{
		Type:      "ssh",
		BtrfsMode: true,
		SSH:       engines.SSHLocation{User: "u", Host: "h", Path: "/srv"},
	}, engines.Deps{Runner: nopRunner{}})
	if err != nil {
		t.Fatal(err)
	}
	defer repository.Close()

	repo := repository.(*Repo)
	if repo.BtrfsMode {
		t.Error("a remote repository must never be in btrfs mode")
	}
	// And the path reflects it: rsync snapshots live under timeshift/, not
	// timeshift-btrfs/.
	if !strings.Contains(repo.SnapshotsPath(), "/timeshift/snapshots") {
		t.Errorf("snapshots path = %q", repo.SnapshotsPath())
	}
}

type nopRunner struct{}

func (nopRunner) Run(context.Context, []string, string) (int, string, string, error) {
	return 0, "", "", nil
}
func (nopRunner) Stream(context.Context, []string, func(string, string)) (int, error) {
	return 0, nil
}
