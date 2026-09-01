package main

import (
	"os"
	"path/filepath"
	"testing"
)

/* browse_release must only ever unmount something this daemon mounted.
 *
 * Without the check it is an unmount-anything method reachable over the socket:
 * hand it "/" and it would try. These are the ways a caller could try to point
 * it somewhere else.
 */
func TestBrowseReleaseAcceptsOnlyOurOwnMounts(t *testing.T) {
	root := "/run/timeshift/1234"

	refused := []string{
		"",
		"/",
		"/home/osouf",
		"/run/timeshift/1234",         // the browse dir's parent
		"/run/timeshift/1234/browse",  // the browse dir itself is not a mount
		"/run/timeshift/1234/restore", // a restore target, emphatically not ours
		"/run/timeshift/9999/browse/abc",
		"/run/timeshift/1234/browse/../../../etc",
		"/run/timeshift/1234/browse/../restore",
		"/etc/shadow",
		"relative/path",
		"/run/timeshift/1234/browsers/abc", // prefix that is not a path boundary
	}
	for _, p := range refused {
		if got, ok := browseReleasePath(root, p); ok {
			t.Errorf("browseReleasePath(%q) accepted, resolved to %q", p, got)
		}
	}

	accepted := map[string]string{
		"/run/timeshift/1234/browse/abc123456789":   "/run/timeshift/1234/browse/abc123456789",
		"/run/timeshift/1234/browse/abc123456789/":  "/run/timeshift/1234/browse/abc123456789",
		"/run/timeshift/1234//browse//abc123456789": "/run/timeshift/1234/browse/abc123456789",
		"/run/timeshift/1234/browse/a/deeper/path":  "/run/timeshift/1234/browse/a/deeper/path",
	}
	for in, want := range accepted {
		got, ok := browseReleasePath(root, in)
		if !ok {
			t.Errorf("browseReleasePath(%q) was refused", in)
			continue
		}
		if got != want {
			t.Errorf("browseReleasePath(%q) = %q, want %q", in, got, want)
		}
	}
}

/* A symlink that merely LIVES in the browse directory must not stand in for a
 * path inside it. The check is about where the target is, not where the name
 * is, which is why symlinks are resolved before the prefix test. */
func TestBrowseReleaseResolvesSymlinksBeforeChecking(t *testing.T) {
	tmp := t.TempDir()
	root := filepath.Join(tmp, "run")
	browse := filepath.Join(root, "browse")
	if err := os.MkdirAll(browse, 0o755); err != nil {
		t.Fatal(err)
	}

	// Somewhere it must never reach.
	outside := filepath.Join(tmp, "elsewhere")
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatal(err)
	}

	link := filepath.Join(browse, "escape")
	if err := os.Symlink(outside, link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	if got, ok := browseReleasePath(root, link); ok {
		t.Fatalf("a symlink out of the browse directory was accepted, resolved to %q", got)
	}

	// A real directory in the same place is fine.
	real := filepath.Join(browse, "abc123456789")
	if err := os.MkdirAll(real, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, ok := browseReleasePath(root, real); !ok {
		t.Error("a genuine browse mount point was refused")
	}
}
