package timeshift

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/makeafide/timeshift/src-go/internal/engines"
	"github.com/makeafide/timeshift/src-go/internal/sysexec"
)

// recordingReporter captures what an operation said, so a test can assert the
// refusal was explained rather than silent.
type recordingReporter struct {
	warnings []string
	notes    []string
}

func (r *recordingReporter) SetPhases([]engines.Phase) {}
func (r *recordingReporter) Phase(string)              {}
func (r *recordingReporter) Progress(engines.Progress) {}
func (r *recordingReporter) Log(string)                {}
func (r *recordingReporter) Note(m string)             { r.notes = append(r.notes, m) }
func (r *recordingReporter) Warn(m string)             { r.warnings = append(r.warnings, m) }
func (r *recordingReporter) Cancelled() bool           { return false }

func snapshotDir(root, name string) string {
	return filepath.Join(root, "timeshift", "snapshots", name)
}

func exists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

/* SnapshotRepo.remove_invalid() refuses to delete anything that still has an
 * info.json, and the reason is that "invalid" is not evidence of anything. A
 * dropped SSH link makes every snapshot in a remote repository read as invalid,
 * and the Vala code found this out by having auto_remove() delete the whole
 * repository afterwards.
 *
 * Nothing in the Go tree prunes invalid snapshots yet, so this guard refuses
 * nothing today. It is written now so that whoever adds a prune step inherits
 * it instead of rediscovering why it is needed. */
func TestAnAutomaticDeleteRefusesASnapshotThatStillHasAControlFile(t *testing.T) {
	repo, root := testRepo(t)

	// Valid on disk, then made to read as invalid the way a partial read does:
	// exclude.list gone, control file intact.
	seedSnapshot(t, root, "2026-08-20_09-00-01", []string{"ondemand"}, "keep me")
	dir := snapshotDir(root, "2026-08-20_09-00-01")
	if err := os.Remove(filepath.Join(dir, "exclude.list")); err != nil {
		t.Fatal(err)
	}

	list, err := repo.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0].Valid {
		t.Fatalf("fixture did not produce an invalid snapshot: %+v", list)
	}

	rep := &recordingReporter{}
	if err := repo.Delete(context.Background(), []string{"2026-08-20_09-00-01"}, engines.DeleteOptions{}, rep); err != nil {
		t.Fatalf("Delete: %v", err)
	}

	if !exists(dir) {
		t.Fatal("an automatic delete removed a snapshot that still had its control file")
	}
	if len(rep.warnings) != 1 || !strings.Contains(rep.warnings[0], "control file") {
		t.Errorf("refusal was not explained: %v", rep.warnings)
	}
}

// A person who names a snapshot may delete it, whatever the repository thinks
// of it. The guard is against software acting on a guess, not against people.
func TestAnExplicitDeleteRemovesAnInvalidSnapshot(t *testing.T) {
	repo, root := testRepo(t)
	repo.Deps.Runner = realRunner{}

	seedSnapshot(t, root, "2026-08-20_09-00-01", []string{"ondemand"}, "")
	dir := snapshotDir(root, "2026-08-20_09-00-01")
	os.Remove(filepath.Join(dir, "exclude.list"))

	rep := &recordingReporter{}
	if err := repo.Delete(context.Background(), []string{"2026-08-20_09-00-01"}, engines.DeleteOptions{Explicit: true}, rep); err != nil {
		t.Fatalf("Delete: %v", err)
	}

	if exists(dir) {
		t.Fatal("an explicit delete left the snapshot in place")
	}
	if len(rep.warnings) != 0 {
		t.Errorf("explicit delete warned unnecessarily: %v", rep.warnings)
	}
}

// A snapshot with no control file at all IS positive evidence of an incomplete
// run, and an automatic caller may remove it.
func TestAnAutomaticDeleteRemovesASnapshotWithNoControlFile(t *testing.T) {
	repo, root := testRepo(t)
	repo.Deps.Runner = realRunner{}

	dir := snapshotDir(root, "2026-08-20_09-00-01")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}

	rep := &recordingReporter{}
	if err := repo.Delete(context.Background(), []string{"2026-08-20_09-00-01"}, engines.DeleteOptions{}, rep); err != nil {
		t.Fatalf("Delete: %v", err)
	}

	if exists(dir) {
		t.Fatal("an incomplete snapshot was kept")
	}
}

// A valid snapshot losing its last tag is the ordinary retention deletion, and
// must not be blocked by the guard.
func TestAnAutomaticDeleteRemovesAValidSnapshot(t *testing.T) {
	repo, root := testRepo(t)
	repo.Deps.Runner = realRunner{}

	seedSnapshot(t, root, "2026-08-20_09-00-01", []string{"hourly"}, "")
	dir := snapshotDir(root, "2026-08-20_09-00-01")

	rep := &recordingReporter{}
	if err := repo.Delete(context.Background(), []string{"2026-08-20_09-00-01"}, engines.DeleteOptions{}, rep); err != nil {
		t.Fatalf("Delete: %v", err)
	}

	if exists(dir) {
		t.Fatal("retention could not delete a valid snapshot")
	}
	if len(rep.warnings) != 0 {
		t.Errorf("unexpected warnings: %v", rep.warnings)
	}
}

/* If the snapshot list cannot be read, an automatic caller cannot tell a broken
 * snapshot from an unreachable repository -- which is the exact condition the
 * guard exists for. It must refuse the whole deletion rather than proceed on a
 * list it does not have. */
func TestAnAutomaticDeleteRefusesWhenTheListCannotBeRead(t *testing.T) {
	repo, root := testRepo(t)
	repo.Backend = unreadableBackend{Backend: &LocalBackend{}}
	_ = root

	rep := &recordingReporter{}
	err := repo.Delete(context.Background(), []string{"2026-08-20_09-00-01"}, engines.DeleteOptions{}, rep)
	if err == nil {
		t.Fatal("deleted without a readable snapshot list")
	}
	if !strings.Contains(err.Error(), "readable snapshot list") {
		t.Errorf("error did not explain itself: %v", err)
	}
}

// unreadableBackend fails the listing the way a dropped connection does.
type unreadableBackend struct{ Backend }

func (u unreadableBackend) DirExists(context.Context, string) bool { return true }
func (u unreadableBackend) ListSubdirs(context.Context, string) ([]string, error) {
	return nil, context.DeadlineExceeded
}

/* Deletion really removes the tree, so these tests run the real rm rather than
 * asserting on an argv. A guard that returns the right value while the files
 * stay on disk is exactly the bug worth catching. */
type realRunner struct{}

func (realRunner) Run(ctx context.Context, argv []string, stdin string) (int, string, string, error) {
	return sysexec.NewSimple(sysexec.New(nil)).Run(ctx, argv, stdin)
}

func (realRunner) Stream(ctx context.Context, argv []string, onLine func(stream, line string)) (int, error) {
	return sysexec.NewSimple(sysexec.New(nil)).Stream(ctx, argv, onLine)
}

/* Open must create its run directory, for a REMOTE repository above all.
 *
 * A local repository gets one on the way to mounting its device, so this was
 * missed: a remote one never touched it, and ssh's ControlPath lives there.
 * The result was
 *
 *   unix_listener: cannot bind to path /run/timeshift/<pid>/ssh-...:
 *   No such file or directory
 *
 * followed by "Remote location not available" and an empty listing -- which a
 * script cannot tell apart from a repository with no snapshots. The daemon uses
 * the same per-pid path, so it could not reach a remote repository either.
 */
func TestOpenCreatesItsRunDirectory(t *testing.T) {
	mountRoot := filepath.Join(t.TempDir(), "run", "timeshift", "12345")

	repo, err := Engine{}.Open(context.Background(), engines.Location{
		Type: "ssh",
		SSH:  engines.SSHLocation{User: "backup", Host: "example.invalid", Path: "/srv/snap"},
	}, engines.Deps{Runner: realRunner{}, MountRoot: mountRoot})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer repo.Close()

	info, err := os.Stat(mountRoot)
	if err != nil {
		t.Fatalf("Open did not create its run directory: %v", err)
	}
	if !info.IsDir() {
		t.Fatal("run directory is not a directory")
	}

	/* 0700: the ssh control socket lives in here, and anyone who can open it
	 * can ride the authenticated connection. */
	if perm := info.Mode().Perm(); perm != 0o700 {
		t.Errorf("run directory mode = %o, want 700", perm)
	}
}

// A local repository must get the same treatment, so the ordering of the two
// branches in Open cannot quietly matter.
func TestOpenCreatesItsRunDirectoryForALocalRepository(t *testing.T) {
	mountRoot := filepath.Join(t.TempDir(), "run", "timeshift", "12345")

	repo, err := Engine{}.Open(context.Background(),
		engines.Location{Type: "local", MountPath: t.TempDir()},
		engines.Deps{Runner: realRunner{}, MountRoot: mountRoot})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer repo.Close()

	if _, err := os.Stat(mountRoot); err != nil {
		t.Fatalf("Open did not create its run directory: %v", err)
	}
}
