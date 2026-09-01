package timeshift

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// seedSnapshot writes a minimal but valid snapshot directory.
func seedSnapshot(t *testing.T, root, name string, tags []string, comment string) {
	t.Helper()

	dir := filepath.Join(root, "timeshift", "snapshots", name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}

	created, err := time.ParseInLocation(NameLayout, name, time.Local)
	if err != nil {
		t.Fatal(err)
	}

	c := &ControlFile{
		Created:       created,
		SysUUID:       "sys",
		SysDistro:     "Test 1.0",
		AppVersion:    "test",
		FileCount:     42,
		Tags:          tags,
		Description:   comment,
		Type:          "rsync",
		SizeBytes:     -1,
		UnsharedBytes: -1,
	}
	if err := os.WriteFile(filepath.Join(dir, "info.json"), c.Marshal(), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "exclude.list"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
}

func testRepo(t *testing.T) (*Repo, string) {
	t.Helper()
	root := t.TempDir()
	return &Repo{Backend: &LocalBackend{}, MountPath: root}, root
}

func snapshotNamed(t *testing.T, r *Repo, name string) (tags []string, description string) {
	t.Helper()
	list, err := r.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range list {
		if s.Name == name {
			return s.Tags, s.Description
		}
	}
	t.Fatalf("no snapshot named %q", name)
	return nil, ""
}

func TestSetTagsAndDescription(t *testing.T) {
	repo, root := testRepo(t)
	name := "2026-03-15_12-00-00"
	seedSnapshot(t, root, name, []string{"ondemand"}, "")

	ctx := context.Background()

	if err := repo.AddTag(ctx, name, "hourly"); err != nil {
		t.Fatalf("AddTag: %v", err)
	}
	tags, _ := snapshotNamed(t, repo, name)
	if strings.Join(tags, " ") != "ondemand hourly" {
		t.Fatalf("tags = %v, want retention order", tags)
	}

	// Adding the same tag twice must not duplicate it: the tag list is
	// rendered into a one-letter column and "O H H" is not a thing.
	if err := repo.AddTag(ctx, name, "hourly"); err != nil {
		t.Fatal(err)
	}
	if tags, _ = snapshotNamed(t, repo, name); len(tags) != 2 {
		t.Fatalf("tags = %v after adding a duplicate", tags)
	}

	if err := repo.SetDescription(ctx, name, "before the kernel upgrade"); err != nil {
		t.Fatalf("SetDescription: %v", err)
	}
	_, desc := snapshotNamed(t, repo, name)
	if desc != "before the kernel upgrade" {
		t.Fatalf("description = %q", desc)
	}

	if err := repo.SetTags(ctx, name, []string{"monthly", "boot"}); err != nil {
		t.Fatalf("SetTags: %v", err)
	}
	tags, desc = snapshotNamed(t, repo, name)
	if strings.Join(tags, " ") != "boot monthly" {
		t.Fatalf("tags = %v, want them sorted into retention order", tags)
	}
	if desc != "before the kernel upgrade" {
		t.Fatal("editing tags lost the description")
	}
}

/* An edit must start from the file, not from a listing.
 *
 * A control file carries fields a listing does not surface, and rewriting it
 * from the listing would quietly drop them -- which for file_count and the
 * size figures means a snapshot that reports nothing about itself afterwards.
 */
func TestEditingTagsPreservesTheRestOfTheControlFile(t *testing.T) {
	repo, root := testRepo(t)
	name := "2026-03-15_12-00-00"
	seedSnapshot(t, root, name, []string{"ondemand"}, "")

	if err := repo.AddTag(context.Background(), name, "daily"); err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(filepath.Join(root, "timeshift", "snapshots", name, "info.json"))
	if err != nil {
		t.Fatal(err)
	}
	c, err := ParseControlFile(raw)
	if err != nil {
		t.Fatal(err)
	}

	if c.FileCount != 42 {
		t.Errorf("file_count = %d, want 42", c.FileCount)
	}
	if c.SysDistro != "Test 1.0" {
		t.Errorf("sys-distro = %q", c.SysDistro)
	}
	if c.Created.IsZero() {
		t.Error("created was lost")
	}
}

func TestMarkForDeletionIsASidecarFile(t *testing.T) {
	repo, root := testRepo(t)
	name := "2026-03-15_12-00-00"
	seedSnapshot(t, root, name, []string{"ondemand"}, "")

	ctx := context.Background()
	marker := filepath.Join(root, "timeshift", "snapshots", name, "delete")

	if err := repo.SetMarkedForDeletion(ctx, name, true); err != nil {
		t.Fatalf("mark: %v", err)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("the marker file was not written: %v", err)
	}

	list, err := repo.List(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !list[0].MarkedForDeletion {
		t.Fatal("the listing does not report the snapshot as marked")
	}

	if err := repo.SetMarkedForDeletion(ctx, name, false); err != nil {
		t.Fatalf("unmark: %v", err)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("the marker file survived being cleared")
	}

	// Clearing a marker that is not there is the normal case, not a failure.
	if err := repo.SetMarkedForDeletion(ctx, name, false); err != nil {
		t.Fatalf("clearing an absent marker failed: %v", err)
	}
}

func TestEditingAnUnknownSnapshotFails(t *testing.T) {
	repo, _ := testRepo(t)
	if err := repo.AddTag(context.Background(), "2026-01-01_00-00-00", "hourly"); err == nil {
		t.Fatal("editing a snapshot that does not exist was accepted")
	}
}
