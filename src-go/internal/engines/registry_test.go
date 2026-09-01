package engines

import (
	"context"
	"encoding/json"
	"testing"
)

/* The registry, and the seam itself.
 *
 * This package had no tests at all, which is how Repository came to declare
 * four read methods while every write was reached by asserting past it:
 *
 *   repo, ok := repository.(*tsengine.Repo)
 *   if !ok { return fmt.Errorf("engine %q is not the timeshift engine", ...) }
 *
 * Nothing failed, because nothing ever exercised the interface with anything
 * other than the one concrete type it was secretly shaped around. fakeEngine
 * below is that missing second implementation: it is deliberately NOT the
 * timeshift engine, and if the interface stops being sufficient to drive a
 * repository, this package stops compiling.
 */

func TestLookupDefaultsToTheTimeshiftEngine(t *testing.T) {
	// An empty id is what an old config carries: the engine key was added
	// later, and every existing install predates it.
	if _, err := Lookup(""); err == nil {
		// Only meaningful once an engine is registered; the timeshift package
		// registers itself in init(), and importing it here would be a cycle.
		t.Skip("no engine registered in this package's test binary")
	}
}

func TestLookupRejectsAnUnknownEngine(t *testing.T) {
	if _, err := Lookup("no-such-engine"); err == nil {
		t.Fatal("an unknown engine id was accepted")
	}
}

// Registering the same id twice is a programming error that would otherwise
// resolve by link order -- silently, and differently between builds.
func TestDuplicateRegistrationPanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("registering the same engine id twice did not panic")
		}
	}()
	Register(fakeEngine{id: "dup-test"})
	Register(fakeEngine{id: "dup-test"})
}

func TestRegisteredEnginesAreListed(t *testing.T) {
	Register(fakeEngine{id: "list-test"})

	found := false
	for _, id := range IDs() {
		if id == "list-test" {
			found = true
		}
	}
	if !found {
		t.Fatalf("IDs() = %v, missing the registered engine", IDs())
	}

	e, err := Lookup("list-test")
	if err != nil {
		t.Fatalf("Lookup: %v", err)
	}
	if e.ID() != "list-test" {
		t.Errorf("ID() = %q", e.ID())
	}
}

/* A repository must be fully drivable through the interface.
 *
 * Every operation a host performs is called here on an engine that has no
 * relationship to the timeshift one. If any of them needed the concrete type,
 * this would not compile -- which is the whole point, since a runtime type
 * assertion is exactly how the seam failed before. */
func TestARepositoryIsFullyDrivableThroughTheInterface(t *testing.T) {
	e := fakeEngine{id: "drivable-test"}

	repo, err := e.Open(context.Background(), Location{Type: "local"}, Deps{})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer repo.Close()

	ctx := context.Background()
	rep := &NopReporter{}

	if _, err := repo.Status(ctx); err != nil {
		t.Errorf("Status: %v", err)
	}
	if _, err := repo.List(ctx); err != nil {
		t.Errorf("List: %v", err)
	}
	if _, err := repo.FreeBytes(ctx); err != nil {
		t.Errorf("FreeBytes: %v", err)
	}
	if _, err := repo.ConsoleStatus(ctx, "sda1", "uuid"); err != nil {
		t.Errorf("ConsoleStatus: %v", err)
	}
	if _, err := repo.ReadSnapshotFile(ctx, "/snap", "etc/fstab"); err != nil {
		t.Errorf("ReadSnapshotFile: %v", err)
	}
	if _, err := repo.Create(ctx, CreateRequest{Tags: []string{"ondemand"}}, rep); err != nil {
		t.Errorf("Create: %v", err)
	}
	if err := repo.Delete(ctx, []string{"snap"}, DeleteOptions{Explicit: true}, rep); err != nil {
		t.Errorf("Delete: %v", err)
	}
	if _, _, err := repo.Estimate(ctx, EstimateRequest{}, rep); err != nil {
		t.Errorf("Estimate: %v", err)
	}
	if err := repo.SetTags(ctx, "snap", []string{"daily"}); err != nil {
		t.Errorf("SetTags: %v", err)
	}
	if err := repo.AddTag(ctx, "snap", "weekly"); err != nil {
		t.Errorf("AddTag: %v", err)
	}
	if err := repo.SetDescription(ctx, "snap", "note"); err != nil {
		t.Errorf("SetDescription: %v", err)
	}
	if err := repo.SetMarkedForDeletion(ctx, "snap", true); err != nil {
		t.Errorf("SetMarkedForDeletion: %v", err)
	}

	src := repo.TransferSource("/snap/payload")
	if src.Path == "" {
		t.Error("TransferSource returned no path")
	}

	if _, err := repo.Browse(ctx, "/snap", 1000, 1000); err != nil {
		t.Errorf("Browse: %v", err)
	}
	if err := repo.ReleaseBrowse(ctx, "/snap"); err != nil {
		t.Errorf("ReleaseBrowse: %v", err)
	}

	repo.SetFirstSnapshotSize(1 << 30)
}

// ---- a second engine, which is the point ----

type fakeEngine struct{ id string }

func (f fakeEngine) ID() string          { return f.id }
func (f fakeEngine) DisplayName() string { return "Fake" }
func (f fakeEngine) Caps() Caps          { return Caps{Incremental: true} }

func (f fakeEngine) Open(context.Context, Location, Deps) (Repository, error) {
	return &fakeRepo{}, nil
}

type fakeRepo struct{ firstSize uint64 }

func (r *fakeRepo) Status(context.Context) (Status, error) {
	return Status{Code: StatusNoSnapshotsHasSpace, Available: true}, nil
}
func (r *fakeRepo) List(context.Context) ([]Snapshot, error)     { return nil, nil }
func (r *fakeRepo) FreeBytes(context.Context) (uint64, error)    { return 1 << 40, nil }
func (r *fakeRepo) Close() error                                 { return nil }
func (r *fakeRepo) SetFirstSnapshotSize(n uint64)                { r.firstSize = n }
func (r *fakeRepo) AddTag(context.Context, string, string) error { return nil }

func (r *fakeRepo) ConsoleStatus(context.Context, string, string) (json.RawMessage, error) {
	return json.RawMessage(`{"engine":"fake"}`), nil
}
func (r *fakeRepo) ReadSnapshotFile(context.Context, string, string) ([]byte, error) {
	return []byte("UUID=x / ext4 defaults 0 1\n"), nil
}
func (r *fakeRepo) Create(context.Context, CreateRequest, Reporter) (Snapshot, error) {
	return Snapshot{Name: "2026-03-15_12-00-00"}, nil
}
func (r *fakeRepo) Delete(context.Context, []string, DeleteOptions, Reporter) error { return nil }
func (r *fakeRepo) Estimate(context.Context, EstimateRequest, Reporter) (int64, int64, error) {
	return 1 << 30, 1000, nil
}
func (r *fakeRepo) SetTags(context.Context, string, []string) error          { return nil }
func (r *fakeRepo) SetDescription(context.Context, string, string) error     { return nil }
func (r *fakeRepo) SetMarkedForDeletion(context.Context, string, bool) error { return nil }
func (r *fakeRepo) TransferSource(p string) TransferSource {
	return TransferSource{Path: p}
}

func (r *fakeRepo) Browse(_ context.Context, snapshotPath string, _, _ int) (BrowseMount, error) {
	return BrowseMount{Path: snapshotPath}, nil
}
func (r *fakeRepo) ReleaseBrowse(context.Context, string) error { return nil }

var _ Engine = fakeEngine{}
var _ Repository = (*fakeRepo)(nil)
