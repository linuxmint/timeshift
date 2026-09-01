package sysexec

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMissingToolsFindsWhatIsAbsent(t *testing.T) {
	got := MissingTools([]string{"sh", "this-command-does-not-exist-9f3a"})
	if len(got) != 1 || got[0] != "this-command-does-not-exist-9f3a" {
		t.Fatalf("want only the absent command reported, got %v", got)
	}
}

// An absolute path is tested as a path, not looked up on PATH -- /sbin/blkid is
// on the required list in that form, and /sbin is not on every user's PATH.
func TestAbsolutePathsAreTestedAsPaths(t *testing.T) {
	dir := t.TempDir()
	tool := filepath.Join(dir, "tool")
	if err := os.WriteFile(tool, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := MissingTools([]string{tool}); len(got) != 0 {
		t.Fatalf("an existing executable path must not be reported missing: %v", got)
	}
	if got := MissingTools([]string{filepath.Join(dir, "absent")}); len(got) != 1 {
		t.Fatalf("an absent path must be reported: %v", got)
	}
}

// The real list must pass on any machine that can build this project.
func TestRequiredToolsArePresentHere(t *testing.T) {
	if err := CheckDependencies(); err != nil {
		t.Errorf("the required tools should be present on a development machine: %v", err)
	}
}

// The message must name every missing tool, so one fix covers all of them.
func TestErrorNamesEveryMissingTool(t *testing.T) {
	missing := MissingTools([]string{"absent-aaa-9f3a", "absent-bbb-9f3a"})
	if len(missing) != 2 {
		t.Fatalf("want both reported, got %v", missing)
	}
	joined := strings.Join(missing, ", ")
	for _, want := range []string{"absent-aaa-9f3a", "absent-bbb-9f3a"} {
		if !strings.Contains(joined, want) {
			t.Errorf("%q missing from %q", want, joined)
		}
	}
}
