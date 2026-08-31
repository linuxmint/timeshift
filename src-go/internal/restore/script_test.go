package restore

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func syncOpts() SyncScriptOptions {
	return SyncScriptOptions{
		Source:      "/run/timeshift/1/backup/timeshift/snapshots/2026-01-01_00-00-00/localhost/",
		Target:      "/run/timeshift/1/restore/",
		LogFile:     "/run/timeshift/1/restore/var/log/timeshift/rsync-log-restore",
		ExcludeFile: "/tmp/ts/exclude-restore.list",
		FailedFlag:  "/run/timeshift/1/restore/var/log/timeshift/.timeshift-restore-failed",
	}
}

// Every generated script must be valid shell. Nothing else in the test suite
// would catch a quoting mistake, and a quoting mistake here rewrites a
// filesystem.
func TestGeneratedScriptsAreValidBash(t *testing.T) {
	scripts := map[string]string{
		"sync/local":     BuildSyncScript(syncOpts()),
		"sync/dry-run":   BuildSyncScript(withDry(syncOpts())),
		"sync/current":   BuildSyncScript(withCurrent(syncOpts())),
		"sync/remote":    BuildSyncScript(withRemote(syncOpts())),
		"finish/other":   BuildFinishScript(finishOpts()),
		"finish/current": BuildFinishScript(finishCurrent()),
		"finish/no-grub": BuildFinishScript(FinishScriptOptions{StepLogFile: "/tmp/steps.log"}),
		"finish/esp":     BuildFinishScript(withESP(finishOpts())),
		"probe/remote":   SourceProbeScript("h:/srv/snap/localhost/", "ssh -o BatchMode=yes", true),
		"probe/local":    SourceProbeScript("/srv/snap/localhost/", "", false),
	}
	for name, script := range scripts {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			p := filepath.Join(dir, "s.sh")
			// bash, not sh: ts_step uses PIPESTATUS.
			if err := os.WriteFile(p, []byte("#!/bin/bash\n"+script), 0755); err != nil {
				t.Fatal(err)
			}
			out, err := exec.Command("bash", "-n", p).CombinedOutput()
			if err != nil {
				t.Errorf("bash -n rejected the script: %v\n%s\n---\n%s", err, out, script)
			}
		})
	}
}

func withDry(o SyncScriptOptions) SyncScriptOptions { o.DryRun = true; return o }
func withCurrent(o SyncScriptOptions) SyncScriptOptions {
	o.CurrentSystem = true
	o.Target = "/"
	return o
}
func withRemote(o SyncScriptOptions) SyncScriptOptions {
	o.Remote = true
	o.Source = "backup@host:/srv/snap/localhost/"
	o.RSH = "ssh -o BatchMode=yes -o ControlPath='/run/timeshift/ssh-abc'"
	o.RsyncPath = "rsync --fake-super"
	o.ReachabilityCommand = "ssh -o BatchMode=yes -o ConnectTimeout=10 backup@host true"
	o.DropMasterCommand = "ssh -O exit backup@host 2>/dev/null || true"
	return o
}

func finishOpts() FinishScriptOptions {
	return FinishScriptOptions{
		TargetPath:      "/run/timeshift/1/restore/",
		StepLogFile:     "/run/timeshift/1/restore/var/log/timeshift/restore-steps.log",
		ReinstallGrub:   true,
		GrubDevice:      "/dev/sda",
		UpdateInitramfs: true,
		UpdateGrubMenu:  true,
	}
}

func finishCurrent() FinishScriptOptions {
	o := finishOpts()
	o.CurrentSystem = true
	o.TargetPath = ""
	return o
}

func withESP(o FinishScriptOptions) FinishScriptOptions { o.NeedsESP = true; return o }

// The rsync flags are not interchangeable with the backup's, and each letter
// earns its place.
func TestSyncScriptFlags(t *testing.T) {
	s := BuildSyncScript(syncOpts())

	if !strings.Contains(s, "rsync -aiirXH --force --delete --delete-before") {
		t.Errorf("flag set wrong:\n%s", s)
	}
	// --delete-before, not --delete-after: space is freed before the new copy
	// needs it.
	if strings.Contains(s, "--delete-after") {
		t.Error("a restore deletes BEFORE, so the target does not need room for both copies")
	}
	// --partial-dir, never bare --partial: --partial leaves a TRUNCATED file at
	// its real path, which on a system restore is the corruption this prevents.
	if !strings.Contains(s, "--partial-dir=.timeshift-partial") {
		t.Error("missing --partial-dir")
	}
	if strings.Contains(s, "--partial ") {
		t.Error("bare --partial would leave truncated files at their real paths")
	}
	if !strings.Contains(s, "--timeout=120") {
		t.Error("missing --timeout")
	}
}

// A dry run must not carry --partial-dir (nothing is written to resume) and
// must stop before the flush.
func TestDryRunScript(t *testing.T) {
	s := BuildSyncScript(withDry(syncOpts()))
	if !strings.Contains(s, "--dry-run") {
		t.Error("missing --dry-run")
	}
	if strings.Contains(s, "--partial-dir") {
		t.Error("a dry run writes nothing and has nothing to resume")
	}
	if strings.Contains(s, PhaseMarker+"flush") {
		t.Error("a dry run has nothing to flush")
	}
	phases := SyncPhases(true)
	if len(phases) != 2 || phases[1].Title != "Comparing files" {
		t.Errorf("dry-run phases = %+v", phases)
	}
}

func TestRemoteSyncScript(t *testing.T) {
	s := BuildSyncScript(withRemote(syncOpts()))

	// Across the SSH boundary rsync would otherwise map uid and gid by NAME.
	if !strings.Contains(s, "--numeric-ids") {
		t.Error("missing --numeric-ids for a remote source")
	}
	if !strings.Contains(s, "--rsync-path='rsync --fake-super'") {
		t.Errorf("missing or unquoted --rsync-path:\n%s", s)
	}
	// The -e value contains single quotes, which must survive quoting.
	if !strings.Contains(s, `-e 'ssh -o BatchMode=yes -o ControlPath='\''/run/timeshift/ssh-abc'\'''`) {
		t.Errorf("the -e option was not quoted correctly:\n%s", s)
	}
}

// The retry policy is the difference between a dropped link costing thirty
// seconds and costing an hour of copying.
func TestRetryBlockPolicy(t *testing.T) {
	s := BuildSyncScript(withRemote(syncOpts()))

	if !strings.Contains(s, "0|24) break ;;") {
		t.Error("0 and 24 must both end the loop as success")
	}
	if !strings.Contains(s, "    23)") || !strings.Contains(s, WarningsMarker) {
		t.Error("23 must warn and continue to the finish steps, not retry")
	}
	if !strings.Contains(s, "10|12|30|35|255)") {
		t.Error("the transport codes must be retried")
	}
	if !strings.Contains(s, FailedMarker) || !strings.Contains(s, "exit 1") {
		t.Error("any other code must abort before the finish steps")
	}
	// The sentinel is the only signal the console path has.
	if !strings.Contains(s, "touch '/run/timeshift/1/restore/var/log/timeshift/.timeshift-restore-failed'") {
		t.Errorf("the failure sentinel is not touched:\n%s", s)
	}

	// Dropping the master before probing: a client attaching to a wedged
	// master never calls connect(), so ConnectTimeout does not apply.
	dropAt := strings.Index(s, "ssh -O exit")
	probeAt := strings.Index(s, "ts_wait=0")
	if dropAt < 0 || probeAt < 0 || dropAt > probeAt {
		t.Error("the ssh master must be dropped BEFORE the reachability probe")
	}
	// And the phase is re-announced so the reconnect banner clears.
	if strings.Count(s, PhaseMarker+"sync_files") < 2 {
		t.Error("the phase must be re-announced after a reconnect")
	}
}

// A local restore has no master to drop and no host to probe, so it just waits.
func TestRetryBlockLocal(t *testing.T) {
	s := BuildSyncScript(syncOpts())
	if strings.Contains(s, "ts_wait") {
		t.Error("a local restore has no host to probe")
	}
	if !strings.Contains(s, "sleep 5") {
		t.Error("a local retry should still pause")
	}
}

// Fail-closed: an empty or unreadable snapshot copied with --delete would erase
// the system it was meant to restore. One entry is not enough, because a bare
// "." always lists.
func TestSourceProbeRequiresTwoEntries(t *testing.T) {
	s := SourceProbeScript("/srv/snap/localhost/", "", false)
	if !strings.Contains(s, "-ge 2") {
		t.Errorf("the probe must require at least two entries:\n%s", s)
	}
	if !strings.Contains(s, SourceOKMarker) {
		t.Error("the probe must announce success")
	}
}

func TestFinishScriptStepGuard(t *testing.T) {
	s := BuildFinishScript(finishOpts())

	// PIPESTATUS, not $?: the pipe through tee would otherwise report tee's
	// status and every failure would look like a success.
	if !strings.Contains(s, "ts_rc=${PIPESTATUS[0]}") {
		t.Error("ts_step must read PIPESTATUS, not the status of tee")
	}
	if !strings.Contains(s, StepFailedMarker) {
		t.Error("a failed step must be announced")
	}
	if !strings.Contains(s, "tee -a \"$TS_STEP_LOG\"") {
		t.Error("each step's own output must reach the log as well as the pane")
	}
}

// --rbind, not --bind: /sys/firmware/efi/efivars is a mount of its own, and
// without it grub-install skips the UEFI boot entry.
func TestChrootBindUsesRbind(t *testing.T) {
	s := BuildFinishScript(finishOpts())
	if !strings.Contains(s, "mount --rbind") {
		t.Error("missing --rbind")
	}
	if !strings.Contains(s, "umount -R") {
		t.Error("the cleanup must match the --rbind with -R")
	}
	// A target with no shell should say so once, not fail every chroot.
	if !strings.Contains(s, "chroot_bind:1") {
		t.Error("missing the no-shell guard")
	}
}

// Which tool to use is asked of the RESTORED system, not read from its distro
// id -- the distro test used to run before rsync, when the target is empty.
func TestFinishScriptUsesFeatureDetection(t *testing.T) {
	s := BuildFinishScript(finishOpts())

	for _, want := range []string{
		"if ts_has grub-install; then",
		"elif ts_has grub2-install; then",
		"if ts_has dracut; then",
		"elif ts_has update-initramfs; then",
		"elif ts_has mkinitcpio; then",
		"if ts_has update-grub; then",
		"elif ts_has grub2-mkconfig; then",
		"elif ts_has grub-mkconfig; then",
	} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q", want)
		}
	}
	// Every chain ends with a 127 rather than silently doing nothing.
	for _, want := range []string{"grub_install:127", "initramfs:127", "grub_menu:127"} {
		if !strings.Contains(s, want) {
			t.Errorf("missing the not-found branch %q", want)
		}
	}
	// dracut must be asked for a non-hostonly image: a hostonly rebuild would
	// bake in the RECOVERY environment's devices.
	if !strings.Contains(s, "dracut --force --no-hostonly --regenerate-all") {
		t.Error("dracut must be --no-hostonly")
	}
}

// grub-install aborts with a bare 1 and no useful message when /boot/efi is a
// directory rather than a mount point.
func TestESPGuard(t *testing.T) {
	with := BuildFinishScript(withESP(finishOpts()))
	if !strings.Contains(with, "mountpoint -q") {
		t.Error("a snapshot needing an ESP must check one is mounted")
	}
	if !strings.Contains(with, "grub_install:1") {
		t.Error("the ESP guard must announce its own failure")
	}

	without := BuildFinishScript(finishOpts())
	if strings.Contains(without, "mountpoint -q") {
		t.Error("a snapshot with no ESP entry should not gain the check")
	}

	// The running system's ESP is already mounted; the guard is for a target.
	current := withESP(finishCurrent())
	if strings.Contains(BuildFinishScript(current), "mountpoint -q") {
		t.Error("the guard is for a target, not the running system")
	}
}

func TestCurrentSystemScript(t *testing.T) {
	s := BuildFinishScript(finishCurrent())

	if strings.Contains(s, "chroot") && !strings.Contains(s, "ts_has() {\n   sh -c") {
		t.Error("a current-system restore must not chroot")
	}
	if !strings.Contains(s, "reboot -f") {
		t.Error("a current-system restore ends by rebooting")
	}
	if strings.Contains(s, "mount --rbind") {
		t.Error("nothing to bind-mount when restoring in place")
	}

	other := BuildFinishScript(finishOpts())
	if strings.Contains(other, "reboot -f") {
		t.Error("restoring to another device must NOT reboot this one")
	}
}

// The checklist must list exactly the steps that will run, not every step that
// could -- a client draws it straight from this.
func TestFinishPhasesMatchTheScript(t *testing.T) {
	cases := []struct {
		name string
		opts FinishScriptOptions
	}{
		{"full", finishOpts()},
		{"current", finishCurrent()},
		{"minimal", FinishScriptOptions{StepLogFile: "/tmp/s.log"}},
		{"grub only", FinishScriptOptions{StepLogFile: "/tmp/s.log", ReinstallGrub: true, GrubDevice: "/dev/sda"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			script := BuildFinishScript(c.opts)
			for _, p := range FinishPhases(c.opts) {
				// fix_fstab and parse_log happen in Go, not in the script.
				if p.Key == "fix_fstab" || p.Key == "parse_log" {
					continue
				}
				if !strings.Contains(script, PhaseMarker+p.Key) {
					t.Errorf("phase %q is in the checklist but never announced", p.Key)
				}
			}
			// And nothing is announced that is not in the checklist.
			listed := map[string]bool{}
			for _, p := range FinishPhases(c.opts) {
				listed[p.Key] = true
			}
			for _, line := range strings.Split(script, "\n") {
				if i := strings.Index(line, PhaseMarker); i >= 0 {
					key := strings.TrimSuffix(strings.TrimPrefix(line[i:], PhaseMarker), "'")
					if !listed[key] {
						t.Errorf("phase %q is announced but not in the checklist", key)
					}
				}
			}
		})
	}
}

// Paths with spaces and quotes must survive into the script, because a
// mis-quoted path here rewrites the wrong thing.
func TestAwkwardPathsAreQuoted(t *testing.T) {
	o := syncOpts()
	o.Source = "/mnt/my drive/snap/localhost/"
	o.Target = "/mnt/it's here/"
	o.ExcludeFile = "/tmp/a b/exclude.list"
	s := BuildSyncScript(o)

	if !strings.Contains(s, `'/mnt/my drive/snap/localhost/'`) {
		t.Errorf("a source with a space was not quoted:\n%s", s)
	}
	if !strings.Contains(s, `'/mnt/it'\''s here/'`) {
		t.Errorf("a target with a quote was not escaped:\n%s", s)
	}

	dir := t.TempDir()
	p := filepath.Join(dir, "s.sh")
	os.WriteFile(p, []byte("#!/bin/bash\n"+s), 0755)
	if out, err := exec.Command("bash", "-n", p).CombinedOutput(); err != nil {
		t.Errorf("awkward paths produced invalid shell: %v\n%s", err, out)
	}
}
