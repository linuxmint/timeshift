package main

import (
	"bytes"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/ipc"
)

/* The confirmation prompt is the last thing between a typo and an erased disk,
 * and until now nothing tested it. Every case here is a way the answer could be
 * read as consent when it was not. */

func confirm(t *testing.T, in string, o RestoreOptions, timeout time.Duration) (bool, string, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	plan := ipc.RestorePlanResult{Target: "/dev/sdb2"}
	ok := confirmRestoreOn(strings.NewReader(in), &out, &errOut, o, plan, timeout)
	return ok, out.String(), errOut.String()
}

func TestOnlyTheWordYesConfirms(t *testing.T) {
	cases := map[string]bool{
		"yes\n":        true,
		"  yes \n":     true,
		"y\n":          false,
		"Y\n":          false,
		"YES\n":        false, // deliberate: matching case-insensitively widens the target
		"yes please\n": false,
		"\n":           false,
		"no\n":         false,
		"1\n":          false,
		"":             false, // EOF straight away
	}
	for in, want := range cases {
		got, _, _ := confirm(t, in, RestoreOptions{}, time.Second)
		if got != want {
			t.Errorf("answer %q = %v, want %v", in, got, want)
		}
	}
}

// A bare Enter is how a y/N prompt gets answered by accident. This one must
// treat it as a refusal.
func TestABareEnterIsNotConsent(t *testing.T) {
	if ok, _, _ := confirm(t, "\n", RestoreOptions{}, time.Second); ok {
		t.Fatal("a bare Enter was accepted as consent")
	}
}

// An unattended run whose stdin is closed must refuse, and say so. Proceeding
// on "I could not ask" is how a script with a missing --yes erases a disk.
func TestClosedStdinRefusesAndSaysWhy(t *testing.T) {
	ok, _, errOut := confirm(t, "", RestoreOptions{}, time.Second)
	if ok {
		t.Fatal("proceeded with no answer")
	}
	if !strings.Contains(errOut, "--yes was not given") {
		t.Errorf("refusal was silent about the reason: %q", errOut)
	}
}

/* stdin that is open but silent is the case with no natural end. Without a
 * timeout the process blocks forever, which in a script is indistinguishable
 * from a restore that is taking a long time. */
func TestASilentStdinTimesOutRatherThanHanging(t *testing.T) {
	var out, errOut bytes.Buffer
	plan := ipc.RestorePlanResult{Target: "/dev/sdb2"}

	done := make(chan bool, 1)
	go func() {
		// A reader that never returns and never closes.
		done <- confirmRestoreOn(blockingReader{}, &out, &errOut, RestoreOptions{}, plan, 150*time.Millisecond)
	}()

	select {
	case ok := <-done:
		if ok {
			t.Fatal("timed-out prompt was treated as consent")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("prompt hung instead of timing out")
	}

	if !strings.Contains(errOut.String(), "no answer after") {
		t.Errorf("timeout was not explained: %q", errOut.String())
	}
}

type blockingReader struct{}

func (blockingReader) Read([]byte) (int, error) { select {} }

// --dry-run writes nothing, so there is nothing to agree to. Prompting anyway
// trains people to type yes.
func TestDryRunDoesNotPrompt(t *testing.T) {
	ok, out, _ := confirm(t, "", RestoreOptions{DryRun: true}, time.Second)
	if !ok {
		t.Fatal("dry run was refused")
	}
	if out != "" {
		t.Errorf("dry run prompted: %q", out)
	}
}

func TestYesAndScriptedSkipThePrompt(t *testing.T) {
	for _, o := range []RestoreOptions{{Yes: true}, {Scripted: true}} {
		ok, out, _ := confirm(t, "", o, time.Second)
		if !ok {
			t.Errorf("%+v was refused", o)
		}
		if out != "" {
			t.Errorf("%+v prompted anyway: %q", o, out)
		}
	}
}

// The warning has to name what is about to be destroyed. "Are you sure?" is
// how someone agrees to the wrong disk.
func TestThePromptNamesWhatItWillDestroy(t *testing.T) {
	_, out, _ := confirm(t, "no\n", RestoreOptions{}, time.Second)
	if !strings.Contains(out, "/dev/sdb2") {
		t.Errorf("prompt did not name the target: %q", out)
	}
	if !strings.Contains(out, "deleted") {
		t.Errorf("prompt did not say files would be deleted: %q", out)
	}
}

func TestRestoringTheRunningSystemSaysSo(t *testing.T) {
	_, out, _ := confirm(t, "no\n", RestoreOptions{CurrentSystem: true}, time.Second)
	if !strings.Contains(out, "RUNNING SYSTEM") {
		t.Errorf("prompt did not warn about the running system: %q", out)
	}
}

func TestParseMountArg(t *testing.T) {
	ok := map[string][2]string{
		"/home=/dev/sda3":          {"/home", "/dev/sda3"},
		"/boot/efi=/dev/nvme0n1p1": {"/boot/efi", "/dev/nvme0n1p1"},
		"/=/dev/sdb2":              {"/", "/dev/sdb2"},
		// An empty device is how a mount point is deliberately left unassigned.
		"/home=": {"/home", ""},
	}
	for in, want := range ok {
		mp, dev, err := parseMountArg(in)
		if err != nil {
			t.Errorf("parseMountArg(%q) errored: %v", in, err)
			continue
		}
		if mp != want[0] || dev != want[1] {
			t.Errorf("parseMountArg(%q) = %q,%q want %q,%q", in, mp, dev, want[0], want[1])
		}
	}

	bad := []string{"", "home=/dev/sda3", "/dev/sda3", "=/dev/sda3", "nonsense"}
	for _, in := range bad {
		if _, _, err := parseMountArg(in); err == nil {
			t.Errorf("parseMountArg(%q) was accepted", in)
		}
	}
}

var _ io.Reader = blockingReader{}
