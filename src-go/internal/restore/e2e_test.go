package restore

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

/* End to end: generate the transfer script, RUN it with real rsync against a
 * real directory, and check both the files and the marker stream.
 *
 * Everything else in this package tests the script as text. This tests it as a
 * program, which is the only way to find a quoting mistake, a marker that never
 * fires, or a flag rsync rejects.
 */

// stageSnapshot builds a miniature snapshot payload and a target to restore it
// over, including a file that only exists in the target and so must be deleted.
func stageSnapshot(t *testing.T) (source, target, work string) {
	t.Helper()
	root := t.TempDir()

	source = filepath.Join(root, "snapshot", "localhost")
	target = filepath.Join(root, "target")
	work = filepath.Join(root, "work")
	for _, d := range []string{
		filepath.Join(source, "etc"),
		filepath.Join(source, "usr", "bin"),
		filepath.Join(source, "var", "log", "timeshift"),
		filepath.Join(target, "etc"),
		work,
	} {
		if err := os.MkdirAll(d, 0755); err != nil {
			t.Fatal(err)
		}
	}

	write := func(p, body string) {
		if err := os.WriteFile(p, []byte(body), 0644); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(source, "etc", "hostname"), "restored-host\n")
	write(filepath.Join(source, "etc", "fstab"), "UUID=aaa / ext4 defaults 0 1\n")
	write(filepath.Join(source, "usr", "bin", "thing"), "#!/bin/sh\necho thing\n")
	// A path with a space, because that is what breaks a mis-quoted script.
	write(filepath.Join(source, "etc", "a file with spaces.conf"), "key = value\n")

	// In the target only: --delete must remove it.
	write(filepath.Join(target, "etc", "leftover.conf"), "should not survive\n")
	// And one whose content differs, which must be overwritten.
	write(filepath.Join(target, "etc", "hostname"), "old-host\n")

	return source, target, work
}

// runScript writes the script and runs it, returning its output lines.
func runScript(t *testing.T, script string) ([]string, int) {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "restore.sh")
	if err := os.WriteFile(p, []byte("#!/bin/bash\n"+script), 0755); err != nil {
		t.Fatal(err)
	}

	cmd := exec.Command("bash", p)
	out, err := cmd.CombinedOutput()

	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatalf("could not run the script: %v", err)
	}

	var lines []string
	sc := bufio.NewScanner(strings.NewReader(string(out)))
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	return lines, code
}

func TestSyncScriptActuallyRestores(t *testing.T) {
	source, target, work := stageSnapshot(t)

	excludeFile := filepath.Join(work, "exclude-restore.list")
	// Exclude the restore's own log directory, as a real restore does.
	os.WriteFile(excludeFile, []byte("/var/log/timeshift/*\n"), 0644)

	script := BuildSyncScript(SyncScriptOptions{
		Source:      source + "/",
		Target:      target + "/",
		LogFile:     filepath.Join(work, "rsync-log-restore"),
		ExcludeFile: excludeFile,
		FailedFlag:  filepath.Join(work, ".timeshift-restore-failed"),
	})

	lines, code := runScript(t, script)
	if code != 0 {
		t.Fatalf("the restore script exited %d:\n%s", code, strings.Join(lines, "\n"))
	}

	// The files arrived.
	if got := readFile(t, filepath.Join(target, "etc", "hostname")); got != "restored-host\n" {
		t.Errorf("hostname = %q, the snapshot's copy should have won", got)
	}
	if got := readFile(t, filepath.Join(target, "usr", "bin", "thing")); !strings.Contains(got, "echo thing") {
		t.Errorf("a new file did not arrive: %q", got)
	}
	// A path with a space survived the quoting.
	if got := readFile(t, filepath.Join(target, "etc", "a file with spaces.conf")); got != "key = value\n" {
		t.Errorf("a path with spaces did not arrive: %q", got)
	}
	// --delete removed what was only in the target.
	if _, err := os.Stat(filepath.Join(target, "etc", "leftover.conf")); err == nil {
		t.Error("--delete did not remove a file that is not in the snapshot")
	}

	// The markers fired, in order, and the tracker read them.
	tracker := NewTracker(SyncPhases(false))
	var markers []string
	for _, l := range lines {
		if tracker.Line(l) {
			markers = append(markers, l)
		}
	}
	if tracker.Outcome != OutcomeOK {
		t.Errorf("outcome = %s, want ok. markers: %v", tracker.Outcome, markers)
	}
	if tracker.Current != "flush" {
		t.Errorf("final phase = %q, want flush", tracker.Current)
	}
	for _, want := range []string{"prepare", "sync_files", "flush"} {
		if !containsMarker(markers, PhaseMarker+want) {
			t.Errorf("phase %q was never announced. got: %v", want, markers)
		}
	}
	// The failure sentinel must NOT exist after a clean run.
	if _, err := os.Stat(filepath.Join(work, ".timeshift-restore-failed")); err == nil {
		t.Error("the failure sentinel was touched by a successful restore")
	}
}

// A dry run must change nothing at all.
func TestDryRunChangesNothing(t *testing.T) {
	source, target, work := stageSnapshot(t)
	before := readFile(t, filepath.Join(target, "etc", "hostname"))

	excludeFile := filepath.Join(work, "exclude.list")
	os.WriteFile(excludeFile, []byte("\n"), 0644)

	script := BuildSyncScript(SyncScriptOptions{
		Source:      source + "/",
		Target:      target + "/",
		LogFile:     filepath.Join(work, "log"),
		ExcludeFile: excludeFile,
		FailedFlag:  filepath.Join(work, ".failed"),
		DryRun:      true,
	})

	lines, code := runScript(t, script)
	if code != 0 {
		t.Fatalf("dry run exited %d:\n%s", code, strings.Join(lines, "\n"))
	}

	if got := readFile(t, filepath.Join(target, "etc", "hostname")); got != before {
		t.Errorf("a dry run modified the target: %q -> %q", before, got)
	}
	if _, err := os.Stat(filepath.Join(target, "etc", "leftover.conf")); err != nil {
		t.Error("a dry run deleted a file")
	}
	if _, err := os.Stat(filepath.Join(target, "usr")); err == nil {
		t.Error("a dry run created a directory")
	}

	// It still counts: the line count IS the denominator for the real run.
	if len(lines) < 5 {
		t.Errorf("a dry run should still itemise; only %d lines", len(lines))
	}
}

// The exclude file must actually be honoured -- a restore that ignores it would
// delete the paths the snapshot deliberately does not contain.
func TestExcludesAreHonoured(t *testing.T) {
	source, target, work := stageSnapshot(t)

	// Only in the target, and excluded: --delete must NOT remove it.
	os.MkdirAll(filepath.Join(target, "var", "log", "timeshift"), 0755)
	keep := filepath.Join(target, "var", "log", "timeshift", "previous-restore.log")
	os.WriteFile(keep, []byte("keep me\n"), 0644)

	excludeFile := filepath.Join(work, "exclude.list")
	os.WriteFile(excludeFile, []byte("/var/log/timeshift/*\n"), 0644)

	script := BuildSyncScript(SyncScriptOptions{
		Source:      source + "/",
		Target:      target + "/",
		LogFile:     filepath.Join(work, "log"),
		ExcludeFile: excludeFile,
		FailedFlag:  filepath.Join(work, ".failed"),
	})
	if lines, code := runScript(t, script); code != 0 {
		t.Fatalf("exited %d:\n%s", code, strings.Join(lines, "\n"))
	}

	if _, err := os.Stat(keep); err != nil {
		t.Error("an excluded path was deleted; --delete-excluded must stay off")
	}
}

/* The exit-code policy, tested by stubbing rsync.
 *
 * Driving real rsync into each of these states is unreliable -- a missing
 * source gives 23, not the "anything else" branch -- and the policy is what
 * matters: which codes retry, which warn and continue, and which abort before
 * the finish steps ever run.
 */
func TestRetryPolicyByExitCode(t *testing.T) {
	work := t.TempDir()
	sentinel := filepath.Join(work, ".timeshift-restore-failed")

	opts := SyncScriptOptions{
		Source: "/unused/", Target: "/unused/",
		LogFile: filepath.Join(work, "log"), ExcludeFile: filepath.Join(work, "ex"),
		FailedFlag: sentinel,
	}

	cases := []struct {
		code        int
		wantOutcome Outcome
		wantAbort   bool
	}{
		{0, OutcomeOK, false},
		// 24 is files vanishing mid-copy, which is routine on a live system.
		{24, OutcomeOK, false},
		// 23 warns and carries on to the finish steps: retrying cannot fix a
		// permission problem and would re-scan the whole tree.
		{23, OutcomeWarnings, false},
		// Anything else is terminal: the target is incomplete.
		{1, OutcomeFailed, true},
		{11, OutcomeFailed, true},
	}

	for _, c := range cases {
		os.Remove(sentinel)

		// Stub rsync, then run the real retry block against it.
		script := fmt.Sprintf("ts_run_rsync() { return %d; }\n", c.code) + retryBlock(opts)
		lines, exit := runScript(t, script)

		tracker := NewTracker(SyncPhases(false))
		for _, l := range lines {
			tracker.Line(l)
		}

		if tracker.Outcome != c.wantOutcome {
			t.Errorf("exit %d: outcome = %s, want %s (%v)", c.code, tracker.Outcome, c.wantOutcome, lines)
		}

		_, sentinelErr := os.Stat(sentinel)
		if c.wantAbort {
			if exit == 0 {
				t.Errorf("exit %d: the script exited 0; it must abort", c.code)
			}
			if sentinelErr != nil {
				t.Errorf("exit %d: the failure sentinel was not touched", c.code)
			}
		} else {
			if exit != 0 {
				t.Errorf("exit %d: the script exited %d; it should continue", c.code, exit)
			}
			if sentinelErr == nil {
				t.Errorf("exit %d: the sentinel was touched by a non-fatal result", c.code)
			}
		}
	}
}

// A transport failure retries rather than giving up, and re-announces the phase
// so the reconnect banner clears.
func TestTransportFailureRetries(t *testing.T) {
	work := t.TempDir()
	opts := SyncScriptOptions{
		Source: "/unused/", Target: "/unused/",
		LogFile: filepath.Join(work, "log"), ExcludeFile: filepath.Join(work, "ex"),
		FailedFlag: filepath.Join(work, ".failed"),
	}

	/* Fail with 255 once, then succeed. A counter file rather than a shell
	 * variable because the loop body runs in the same shell but the stub has to
	 * remember across calls in a way that is obvious in the test. */
	counter := filepath.Join(work, "attempts")
	stub := fmt.Sprintf(`ts_run_rsync() {
  n=$(cat %q 2>/dev/null || echo 0)
  n=$((n + 1))
  echo $n > %q
  if [ $n -eq 1 ]; then return 255; fi
  return 0
}
`, counter, counter)

	lines, exit := runScript(t, stub+retryBlock(opts))
	if exit != 0 {
		t.Fatalf("the retry did not recover: exit %d\n%s", exit, strings.Join(lines, "\n"))
	}

	tracker := NewTracker(SyncPhases(false))
	var sawReconnect bool
	for _, l := range lines {
		if tracker.Line(l) && strings.HasPrefix(l, ReconnectMarker) {
			sawReconnect = true
		}
	}
	if !sawReconnect {
		t.Errorf("a transport failure did not announce a reconnect: %v", lines)
	}
	if tracker.ReconnectCode != 255 || tracker.ReconnectCount != 1 {
		t.Errorf("reconnect reported attempt %d code %d, want 1/255",
			tracker.ReconnectCount, tracker.ReconnectCode)
	}
	// The phase is re-announced on retry, which is what clears the banner.
	if tracker.Reconnecting {
		t.Error("the reconnect banner was never cleared by a re-announced phase")
	}
	if tracker.Outcome != OutcomeOK {
		t.Errorf("outcome = %s after a successful retry", tracker.Outcome)
	}
	if n := readFile(t, counter); strings.TrimSpace(n) != "2" {
		t.Errorf("rsync ran %s times, want 2", strings.TrimSpace(n))
	}
}

// The finish script's guards must work when actually run: a step that fails has
// to announce itself rather than pass silently.
func TestFinishScriptStepFailureIsAnnounced(t *testing.T) {
	work := t.TempDir()

	script := BuildFinishScript(FinishScriptOptions{
		StepLogFile: filepath.Join(work, "restore-steps.log"),
		// No grub, no initramfs: just the helpers, the sync and the hooks.
		HooksDir: filepath.Join(work, "hooks.d"),
	})
	// Add a step that fails, exactly as a real one would be invoked.
	script += "ts_step deliberate false\n"

	lines, _ := runScript(t, script)

	tracker := NewTracker(FinishPhases(FinishScriptOptions{}))
	for _, l := range lines {
		tracker.Line(l)
	}
	if tracker.FailedStep != "deliberate" {
		t.Errorf("a failed step was not announced: %v", lines)
	}
	if tracker.FailedStepCode != 1 {
		t.Errorf("step exit code = %d, want 1", tracker.FailedStepCode)
	}
	// A failed finish step is a warning: the files ARE restored.
	if tracker.Outcome != OutcomeWarnings {
		t.Errorf("outcome = %s, want warnings", tracker.Outcome)
	}
	// And the reason must reach the step log, which survives the reboot.
	body := readFile(t, filepath.Join(work, "restore-steps.log"))
	if !strings.Contains(body, "deliberate failed with exit code 1") {
		t.Errorf("the step log does not record the failure: %q", body)
	}
}

// The source-readability probe is fail-closed: it must stay silent for an empty
// directory, because copying that with --delete would erase the target.
func TestSourceProbeFailsClosed(t *testing.T) {
	root := t.TempDir()
	empty := filepath.Join(root, "empty")
	full := filepath.Join(root, "full")
	os.MkdirAll(empty, 0755)
	os.MkdirAll(filepath.Join(full, "etc"), 0755)
	os.WriteFile(filepath.Join(full, "etc", "hostname"), []byte("x\n"), 0644)

	lines, _ := runScript(t, SourceProbeScript(empty+"/", "", false))
	if containsMarker(lines, SourceOKMarker) {
		t.Error("the probe passed an EMPTY source; restoring it would erase the target")
	}

	lines, _ = runScript(t, SourceProbeScript(full+"/", "", false))
	if !containsMarker(lines, SourceOKMarker) {
		t.Errorf("the probe rejected a populated source: %v", lines)
	}

	lines, _ = runScript(t, SourceProbeScript(filepath.Join(root, "absent")+"/", "", false))
	if containsMarker(lines, SourceOKMarker) {
		t.Error("the probe passed a source that does not exist")
	}
}

func readFile(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return string(b)
}

func containsMarker(lines []string, marker string) bool {
	for _, l := range lines {
		if strings.HasPrefix(strings.TrimSpace(l), marker) {
			return true
		}
	}
	return false
}
