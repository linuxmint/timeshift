package main

import (
	"bytes"
	"os"
	"strings"
	"testing"

	"github.com/makeafide/timeshift/src-go/internal/engines"
	"github.com/makeafide/timeshift/src-go/internal/ipc"
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

/* Every flag the Vala CLI accepts must be accepted here too, or a script that
 * works today breaks on the cutover.
 *
 * This checks the ARGUMENT LOOP, not the behaviour: each flag is passed with a
 * value where it needs one, and the loop must not report it as unrecognised.
 * A flag that is deliberately refused -- --clone, --backup -- is listed
 * separately below with the refusal it must give.
 */
func TestEveryValaFlagIsRecognised(t *testing.T) {
	cases := [][]string{
		{"--list"}, {"--list-snapshots"}, {"--list-devices"},
		{"--check"}, {"--create"}, {"--delete", "--snapshot", "x"}, {"--delete-all"},
		{"--restore", "--snapshot", "x"},
		{"--comment", "hi"}, {"--comments", "hi"},
		{"--tags", "ODW"},
		{"--skip-grub"}, {"--grub", "/dev/sda"}, {"--grub-device", "/dev/sda"},
		{"--target", "/dev/sda1"}, {"--target-device", "/dev/sda1"},
		{"--snapshot", "x"}, {"--snapshot-name", "x"},
		{"--snapshot-device", "/dev/sdb1"}, {"--backup-device", "/dev/sdb1"},
		{"--snapshot-url", "u@h:/p"}, {"--remote", "u@h:/p"},
		{"--ssh-key", "/k"}, {"--ssh-port", "2222"},
		{"--setup-ssh-key"},
		{"--recovery-status"}, {"--recovery-enable"}, {"--recovery-disable"},
		{"--btrfs"}, {"--rsync"},
		{"--scripted"}, {"--yes"}, {"--verbose"}, {"--quiet"}, {"--debug"},
	}
	for _, args := range cases {
		_, stderr := capture(t, func() { run(args) })
		if strings.Contains(stderr, "unrecognised option") {
			t.Errorf("run(%v) reported an unrecognised option: %s", args, strings.TrimSpace(stderr))
		}
	}
}

/* --clone mirrors the RUNNING system onto another device with no snapshot
 * involved, and the Go restore has no equivalent -- every path through it
 * starts from a snapshot. Accepting the flag and doing something else is the
 * one outcome that must not happen. */
func TestCloneIsRefusedRatherThanReinterpreted(t *testing.T) {
	var code int
	_, stderr := capture(t, func() { code = run([]string{"--clone", "--target", "/dev/sdb"}) })
	if code == 0 {
		t.Fatal("--clone was accepted")
	}
	if !strings.Contains(stderr, "not implemented") {
		t.Errorf("stderr = %q, want a clear refusal", stderr)
	}
	// And it must point somewhere useful rather than just saying no.
	if !strings.Contains(stderr, "/usr/bin/timeshift") {
		t.Errorf("the refusal did not say what to use instead: %q", stderr)
	}
}

// --backup and --backup-now are deprecated in the Vala CLI and an error there
// too. The message has to name the replacement, or a script author is stuck.
func TestDeprecatedBackupFlagsNameTheirReplacement(t *testing.T) {
	for _, flag := range []string{"--backup", "--backup-now"} {
		var code int
		_, stderr := capture(t, func() { code = run([]string{flag}) })
		if code == 0 {
			t.Errorf("%s was accepted", flag)
		}
		if !strings.Contains(stderr, "--check") || !strings.Contains(stderr, "--create") {
			t.Errorf("%s: stderr = %q, want both replacements named", flag, stderr)
		}
	}
}

// --ssh-port takes a port, and a value that is not one must be refused rather
// than silently becoming zero.
func TestSSHPortIsValidated(t *testing.T) {
	for _, bad := range []string{"nope", "0", "-1", "70000", ""} {
		var code int
		_, stderr := capture(t, func() { code = run([]string{"--list", "--ssh-port", bad}) })
		if code != 1 {
			t.Errorf("--ssh-port %q = %d, want 1", bad, code)
		}
		if !strings.Contains(stderr, "timeshift:") {
			t.Errorf("--ssh-port %q refused without saying why", bad)
		}
	}
}

/* --btrfs and --rsync must be distinguishable from "not mentioned". The
 * override carries a *bool for exactly that: a plain bool cannot express
 * --rsync, which is a request to force the mode OFF. */
func TestBtrfsAndRsyncAreThreeStates(t *testing.T) {
	var none, yes, no ipc.LocationOverride
	if !none.Empty() {
		t.Error("an override that asks for nothing is not Empty")
	}
	on, off := true, false
	yes.BtrfsMode, no.BtrfsMode = &on, &off
	if yes.Empty() || no.Empty() {
		t.Error("--btrfs / --rsync produced an empty override")
	}
	if overridePtr(none) != nil {
		t.Error("an empty override was sent over the wire")
	}
	if overridePtr(yes) == nil {
		t.Error("--btrfs was dropped")
	}
}
