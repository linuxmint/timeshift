package timeshift

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/makeafide/timeshift/src-go/internal/engines"
)

// captureReporter records what an operation said, so a test can assert on it.
type captureReporter struct {
	notes []string
	warns []string
}

func (c *captureReporter) SetPhases([]engines.Phase) {}
func (c *captureReporter) Phase(string)              {}
func (c *captureReporter) Progress(engines.Progress) {}
func (c *captureReporter) Log(string)                {}
func (c *captureReporter) Note(m string)             { c.notes = append(c.notes, m) }
func (c *captureReporter) Warn(m string)             { c.warns = append(c.warns, m) }
func (c *captureReporter) Cancelled() bool           { return false }

/* Create in btrfs mode must produce SUBVOLUMES.
 *
 * The defect this pins is the one a VM found: Repo.Create ignored BtrfsMode
 * entirely, so a repository reporting "Mode : BTRFS" and storing under
 * timeshift-btrfs/snapshots/ was filled with rsync snapshots -- localhost/,
 * an rsync-log, and "type" : "rsync" in the control file. The user was told
 * btrfs and given rsync.
 */
func TestBtrfsCreateMakesSubvolumesNotFiles(t *testing.T) {
	mount, runner := btrfsMount(t)
	ctx := context.Background()

	// The layout the engine handles, as it would be on a real system.
	for _, sv := range []string{SubvolRoot, SubvolHome} {
		mkSubvol(t, filepath.Join(mount, sv))
	}
	if err := os.WriteFile(filepath.Join(mount, SubvolRoot, "marker"), []byte("live"), 0644); err != nil {
		t.Fatal(err)
	}

	repo := &Repo{
		Deps:      engines.Deps{},
		BtrfsMode: true,
		MountPath: mount,
		Runner:    runner,
		Backend:   &LocalBackend{Runner: runner, Name: mount},
	}

	rep := &captureReporter{}
	snap, err := repo.Create(ctx, engines.CreateRequest{
		Tags:             []string{"ondemand"},
		Comments:         "btrfs test",
		SysUUID:          "test-uuid",
		AppVersion:       "test",
		IncludeBtrfsHome: true,
	}, rep)
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	// The thing that was wrong: these must be subvolumes.
	for _, sv := range []string{SubvolRoot, SubvolHome} {
		p := filepath.Join(snap.Path, sv)
		if !IsSubvolume(ctx, runner, p) {
			t.Errorf("%s is not a subvolume; btrfs mode produced files again", p)
		}
	}

	// And none of the rsync furniture should be there.
	for _, unwanted := range []string{"localhost", "rsync-log", "exclude.list"} {
		if _, err := os.Stat(filepath.Join(snap.Path, unwanted)); err == nil {
			t.Errorf("btrfs snapshot contains %q, which belongs to the rsync path", unwanted)
		}
	}

	raw, err := os.ReadFile(filepath.Join(snap.Path, "info.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"type" : "btrfs"`) {
		t.Errorf("control file does not record type btrfs:\n%s", raw)
	}

	// Copy-on-write: writing to the live subvolume must not change the snapshot.
	if err := os.WriteFile(filepath.Join(mount, SubvolRoot, "marker"), []byte("changed"), 0644); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(snap.Path, SubvolRoot, "marker"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "live" {
		t.Errorf("snapshot changed with the original: got %q, want %q", got, "live")
	}
}

/* Restore must swap subvolumes and keep the old ones.
 *
 * Keeping them is the point: replacing an entire system with no way back is
 * not a reasonable default, and the pre-restore snapshot is what makes a wrong
 * choice undoable.
 */
func TestBtrfsRestoreSwapsAndKeepsThePrevious(t *testing.T) {
	mount, runner := btrfsMount(t)
	ctx := context.Background()

	mkSubvol(t, filepath.Join(mount, SubvolRoot))
	if err := os.WriteFile(filepath.Join(mount, SubvolRoot, "state"), []byte("old"), 0644); err != nil {
		t.Fatal(err)
	}

	repo := &Repo{
		BtrfsMode: true, MountPath: mount, Runner: runner,
		Backend: &LocalBackend{Runner: runner, Name: mount},
	}
	rep := &captureReporter{}
	snap, err := repo.Create(ctx, engines.CreateRequest{
		Tags: []string{"ondemand"}, SysUUID: "u", AppVersion: "t",
	}, rep)
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	// Change the live system after the snapshot.
	if err := os.WriteFile(filepath.Join(mount, SubvolRoot, "state"), []byte("new"), 0644); err != nil {
		t.Fatal(err)
	}

	res, err := BtrfsRestore(ctx, runner, BtrfsRestoreOptions{
		MountPath:     mount,
		SnapshotDir:   snap.Path,
		SnapshotsPath: repo.SnapshotsPath(),
		SysUUID:       "u",
		AppVersion:    "t",
	}, rep)
	if err != nil {
		t.Fatalf("restore: %v", err)
	}

	got, err := os.ReadFile(filepath.Join(mount, SubvolRoot, "state"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "old" {
		t.Errorf("live subvolume was not restored: got %q, want %q", got, "old")
	}

	if res.PreRestoreName == "" {
		t.Fatal("no pre-restore snapshot was kept; the restore is not undoable")
	}
	prev := filepath.Join(repo.SnapshotsPath(), res.PreRestoreName, SubvolRoot)
	if !IsSubvolume(ctx, runner, prev) {
		t.Fatalf("the previous system was not kept as a subvolume at %s", prev)
	}
	kept, err := os.ReadFile(filepath.Join(prev, "state"))
	if err != nil {
		t.Fatal(err)
	}
	if string(kept) != "new" {
		t.Errorf("the pre-restore snapshot holds %q, want the state before the restore (%q)", kept, "new")
	}
}

/* Delete must remove subvolumes, not try to unlink them as files.
 *
 * `rm -rf` on a directory holding a subvolume fails partway through, which
 * leaves a snapshot whose info.json is gone -- so it reads as invalid, which
 * is the state nothing prunes without evidence.
 */
func TestBtrfsDeleteRemovesSubvolumes(t *testing.T) {
	mount, runner := btrfsMount(t)
	ctx := context.Background()

	mkSubvol(t, filepath.Join(mount, SubvolRoot))
	repo := &Repo{
		BtrfsMode: true, MountPath: mount, Runner: runner,
		Backend: &LocalBackend{Runner: runner, Name: mount},
	}
	rep := &captureReporter{}
	snap, err := repo.Create(ctx, engines.CreateRequest{
		Tags: []string{"ondemand"}, SysUUID: "u", AppVersion: "t",
	}, rep)
	if err != nil {
		t.Fatal(err)
	}

	if err := repo.Delete(ctx, []string{snap.Name}, engines.DeleteOptions{Explicit: true}, rep); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if _, err := os.Stat(snap.Path); !os.IsNotExist(err) {
		t.Errorf("%s still exists after delete (err=%v)", snap.Path, err)
	}
}

func mkSubvol(t *testing.T, p string) {
	t.Helper()
	if out, err := exec.Command("btrfs", "subvolume", "create", p).CombinedOutput(); err != nil {
		t.Fatalf("btrfs subvolume create %s: %v %s", p, err, out)
	}
}
