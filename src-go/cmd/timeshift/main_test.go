package main

import (
	"bytes"
	"os"
	"strings"
	"testing"

	"github.com/makeafide/timeshift/src-go/internal/engines"
)

// capture runs f with stdout and stderr redirected, and returns what they got.
func capture(t *testing.T, f func()) (stdout, stderr string) {
	t.Helper()
	oldOut, oldErr := os.Stdout, os.Stderr
	rOut, wOut, _ := os.Pipe()
	rErr, wErr, _ := os.Pipe()
	os.Stdout, os.Stderr = wOut, wErr

	done := make(chan [2]string, 1)
	go func() {
		var o, e bytes.Buffer
		o.ReadFrom(rOut)
		e.ReadFrom(rErr)
		done <- [2]string{o.String(), e.String()}
	}()

	f()

	wOut.Close()
	wErr.Close()
	os.Stdout, os.Stderr = oldOut, oldErr
	got := <-done
	return got[0], got[1]
}

/* Every value-taking flag in AppConsole.parse_arguments does args[++k] with no
 * bounds check, so `timeshift --target` with nothing after it indexes off the
 * end. The Go loop checks; this is what keeps it checking. */
func TestValueFlagsAtTheEndOfTheLineAreRefused(t *testing.T) {
	flags := []string{
		"--target", "--mount", "--grub-device", "--snapshot",
		"--tags", "--comments", "--job", "--socket", "--config",
	}
	for _, f := range flags {
		var code int
		_, stderr := capture(t, func() { code = run([]string{f}) })
		if code != 1 {
			t.Errorf("run(%q) = %d, want 1", f, code)
		}
		if !strings.Contains(stderr, "timeshift:") {
			t.Errorf("run(%q) refused without saying why: %q", f, stderr)
		}
	}
}

// An unrecognised option is an error, not something to skip past. A silently
// ignored flag looks identical to one that did not work.
func TestUnknownFlagIsRefused(t *testing.T) {
	var code int
	_, stderr := capture(t, func() { code = run([]string{"--list", "--frobnicate"}) })
	if code != 1 {
		t.Fatalf("run = %d, want 1", code)
	}
	if !strings.Contains(stderr, "unrecognised option") {
		t.Errorf("stderr = %q, want it to name the option", stderr)
	}
}

func TestHelpAndVersionExitZero(t *testing.T) {
	for _, args := range [][]string{{"--help"}, {"-h"}, {"--version"}} {
		var code int
		stdout, _ := capture(t, func() { code = run(args) })
		if code != 0 {
			t.Errorf("run(%v) = %d, want 0", args, code)
		}
		if strings.TrimSpace(stdout) == "" {
			t.Errorf("run(%v) printed nothing", args)
		}
	}
}

/* help2man builds timeshift.1 by running the binary, so --help has to keep the
 * shape it expects: a version line it can parse, and an options block. Breaking
 * this breaks the package build, not just the man page. */
func TestHelpStaysHelp2ManShaped(t *testing.T) {
	stdout, _ := capture(t, func() { run([]string{"--help"}) })
	for _, want := range []string{"Timeshift", "Syntax:", "Options:", "--restore", "--list"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("--help is missing %q", want)
		}
	}
}

/* Argument validation that lives in the mode dispatch runs AFTER the root
 * check, so this is only observable as root. Flags parsed in the loop itself --
 * --mount below, and the missing-value cases above -- are checked before it and
 * need no privilege. */
func TestDeleteWithoutASnapshotIsRefused(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("the root check refuses first when not root")
	}
	var code int
	_, stderr := capture(t, func() { code = run([]string{"--delete"}) })
	if code != 1 {
		t.Fatalf("run = %d, want 1", code)
	}
	if !strings.Contains(stderr, "--snapshot") {
		t.Errorf("stderr = %q, want it to name what is missing", stderr)
	}
}

// Whatever the reason, a refusal exits non-zero and explains itself.
func TestDeleteWithoutASnapshotNeverProceeds(t *testing.T) {
	var code int
	_, stderr := capture(t, func() { code = run([]string{"--delete"}) })
	if code == 0 {
		t.Fatal("--delete with no snapshot was accepted")
	}
	if strings.TrimSpace(stderr) == "" {
		t.Error("refused silently")
	}
}

func TestBadMountArgumentIsRefused(t *testing.T) {
	var code int
	_, stderr := capture(t, func() { code = run([]string{"--restore", "--mount", "nonsense"}) })
	if code != 1 {
		t.Fatalf("run = %d, want 1", code)
	}
	if !strings.Contains(stderr, "MOUNTPOINT=DEVICE") {
		t.Errorf("stderr = %q, want the expected format", stderr)
	}
}

/* An empty repository prints "No snapshots found" and the CLI exits 1. Scripts
 * depend on that exit code, and nothing pinned it until now: a refactor that
 * made it exit 0 would look like a tidy-up and silently change the contract. */
func TestAnEmptyRepositoryReportsNotFound(t *testing.T) {
	var buf bytes.Buffer
	if found := renderSnapshotTable(&buf, nil); found {
		t.Error("an empty repository reported snapshots")
	}
	if !strings.Contains(buf.String(), "No snapshots found") {
		t.Errorf("output = %q", buf.String())
	}
}

func TestANonEmptyRepositoryReportsFound(t *testing.T) {
	var buf bytes.Buffer
	snaps := []engines.Snapshot{{
		Name:          "2026-08-20_09-00-01",
		Tags:          []string{"ondemand"},
		SizeBytes:     -1,
		UnsharedBytes: -1,
		Description:   "before apt",
	}}
	if found := renderSnapshotTable(&buf, snaps); !found {
		t.Fatal("a populated repository reported nothing")
	}
	out := buf.String()
	for _, want := range []string{"2026-08-20_09-00-01", "before apt", "Num", "Unique"} {
		if !strings.Contains(out, want) {
			t.Errorf("output is missing %q:\n%s", want, out)
		}
	}
}

/* -1 means "not measured yet", which is not the same as a snapshot measured at
 * zero bytes. Both render empty, matching size_formatted's treatment of an
 * uncomputed value -- printing "0 B" would assert a measurement never taken. */
func TestUnmeasuredSizesRenderEmpty(t *testing.T) {
	if got := snapshotSize(-1); got != "" {
		t.Errorf("snapshotSize(-1) = %q, want empty", got)
	}
	if got := snapshotSize(0); got == "" {
		t.Errorf("snapshotSize(0) = %q, want a real size", got)
	}
}
