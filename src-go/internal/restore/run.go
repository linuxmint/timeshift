package restore

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

/* Executing a plan.
 *
 * The order below is not arbitrary and is the part most worth reading. Every
 * step before the transfer exists so that a restore which is going to fail
 * fails while the target is still intact -- because once rsync --delete has
 * run, the target is whatever the snapshot said it should be, and a mistake is
 * no longer recoverable from the target.
 *
 *   1. mount the target
 *   2. verify no aliased mounts        <- against reality, after mounting
 *   3. probe that the source is readable and non-empty
 *   4. write the exclude list, CHECKED
 *   5. clear stale state
 *   6. transfer
 *   7. fstab and crypttab
 *   8. the finish script: chroot, bootloader, initramfs, hooks
 *   9. unmount, and only then fsck
 *
 * Steps 2, 3 and 4 each guard against a different way rsync answers 23 -- the
 * warn-and-continue exit code -- after having already deleted the target.
 */

// Reporter receives progress. It is the only way this package talks outward.
type Reporter interface {
	SetPhases(phases []Phase)
	Phase(key string)
	Progress(count, total int64, line string)
	Log(line string)
	Note(msg string)
	Warn(msg string)
}

// nopReporter discards everything, for callers that do not care.
type nopReporter struct{}

func (nopReporter) SetPhases([]Phase)             {}
func (nopReporter) Phase(string)                  {}
func (nopReporter) Progress(int64, int64, string) {}
func (nopReporter) Log(string)                    {}
func (nopReporter) Note(string)                   {}
func (nopReporter) Warn(string)                   {}

// ScriptRunner runs a generated shell script, streaming its output.
type ScriptRunner interface {
	RunScript(ctx context.Context, script string, onLine func(string)) (code int, err error)
}

// Result is what a restore did.
type Result struct {
	Outcome  Outcome
	Messages []string

	// LineCount is how many itemise lines the transfer produced. For a dry run
	// this is the denominator a real run should be given.
	LineCount int64

	// Unmounted reports whether the target was released. False means the fsck
	// was skipped, which is deliberate.
	Unmounted bool

	// RebootRequired is true when the running system was restored and the
	// script did not already reboot.
	RebootRequired bool
}

// Executor carries out a plan. Named apart from Runner, which is the command
// interface this package shares with the rest of the tree.
type Executor struct {
	Commands Runner
	Scripts  ScriptRunner
	Reporter Reporter

	// EstimatedLines is the progress denominator, from a previous dry run.
	// Zero means an indeterminate bar rather than a wrong one.
	EstimatedLines int64

	// SourceProbe, when set, replaces the default rsync --list-only probe.
	// Tests use it; nothing else should.
	SourceProbe func(ctx context.Context) error

	mounter *Mounter
}

// Run executes the plan and returns what happened.
func (r *Executor) Run(ctx context.Context, p *Plan) (Result, error) {

	rep := r.Reporter
	if rep == nil {
		rep = nopReporter{}
	}
	rep.SetPhases(p.Phases)

	var result Result

	if p.Report.Blocked() {
		return result, fmt.Errorf("restore: the plan cannot be carried out; see the layout report")
	}

	// 1. Mount the target.
	if !p.CurrentSystem {
		r.mounter = &Mounter{Runner: r.Commands, Root: p.MountRoot}
		if _, err := r.mounter.MountTargets(ctx, p.Mounts); err != nil {
			return result, err
		}
		defer func() {
			// Only if we got far enough to need it; the success path unmounts
			// explicitly so it can report whether it worked.
			if r.mounter != nil && len(r.mounter.Mounted()) > 0 {
				r.mounter.Unmount(ctx)
			}
		}()
	}

	/* 2. Against reality, not against the plan.
	 *
	 * This stats the mounted result and refuses if any nested mount point IS
	 * the target root, comparing (st_dev, st_ino) rather than consulting the
	 * mount list -- so it catches an alias arriving by ANY route, including one
	 * the plan could not have predicted. It runs after mounting and before
	 * anything is deleted. */
	if err := VerifyNoAliasedMounts(p.TargetPath, p.Mounts, p.CurrentSystem); err != nil {
		return result, err
	}

	/* 3. Fail-closed, and BEFORE anything of ours is written.
	 *
	 * An empty or unreadable snapshot would be copied over the target with
	 * --delete, erasing the system it was meant to restore. The probe demands
	 * at least two entries, because a bare "." always lists.
	 *
	 * It runs before the exclude list is written, and that ordering is load
	 * bearing: anything we create inside the probed tree first would count
	 * towards those two entries, so an empty snapshot would pass the check that
	 * exists to catch an empty snapshot. The exclude file lives in the snapshot
	 * DIRECTORY while the probe lists the payload beneath it, so they cannot
	 * collide either -- two independent reasons, because this is the check
	 * standing between a typo and an erased disk.
	 */
	if err := r.probeSource(ctx, p); err != nil {
		return result, err
	}

	/* 4. The exclude list, and the write is CHECKED.
	 *
	 * rsync answers 23 both for "a few files were skipped" and for "I could not
	 * open the exclude file", and 23 is the warn-and-continue path. Checking
	 * the write here is what keeps those two apart -- otherwise a restore that
	 * ignored every exclusion would look like a restore with a few warnings. */
	if err := p.PrepareDirs(); err != nil {
		return result, err
	}
	if err := os.WriteFile(p.ExcludeFile, []byte(excludeContents(p.Excludes)), 0644); err != nil {
		return result, fmt.Errorf(
			"restore: the list of files to exclude could not be written to %s: %w. Nothing was changed on the target",
			p.ExcludeFile, err)
	}

	// 5. Anything left from a previous attempt, the sentinel above all.
	p.ClearStaleState()

	// 6. The transfer.
	tracker := NewTracker(p.Phases)
	var lines int64

	code, err := r.Scripts.RunScript(ctx, p.SyncScript, func(line string) {
		if ev, ok := ParseMarker(line); ok {
			r.handleMarker(rep, tracker, ev, &result)
			return
		}
		lines++
		rep.Progress(lines, r.EstimatedLines, line)
		rep.Log(line)
	})
	result.LineCount = lines

	if err != nil {
		return result, err
	}

	/* The sentinel is authoritative, not the exit code.
	 *
	 * The script touches it and exits 1 on an unrecoverable rsync failure, but
	 * a script killed outright would exit non-zero with no sentinel, and a
	 * script that hit the warn path exits 0 with warnings recorded. Both
	 * signals are consulted. */
	if _, statErr := os.Stat(p.FailedFlag); statErr == nil {
		result.Outcome = OutcomeFailed
		result.Messages = append(result.Messages,
			"The target is INCOMPLETE and must not be booted. Re-run the restore.")
		return result, fmt.Errorf("restore: the transfer failed")
	}
	if code != 0 {
		result.Outcome = OutcomeFailed
		return result, fmt.Errorf("restore: the transfer exited %d", code)
	}

	if p.DryRun {
		// Nothing was written, so there is nothing to fix, install or unmount.
		if result.Outcome == "" {
			result.Outcome = OutcomeOK
		}
		result.Unmounted = true
		return result, nil
	}

	// 7 and 8. Fixing the system, in Go and then in shell.
	if err := r.finishSystem(ctx, p, rep, tracker, &result); err != nil {
		return result, err
	}

	// 9. Release the target, and only then consider fsck.
	if !p.CurrentSystem && r.mounter != nil {
		unmounted, umErr := r.mounter.Unmount(ctx)
		result.Unmounted = unmounted
		r.mounter = nil
		if !unmounted {
			/* fsck is skipped, on purpose and loudly. "fsck -y" on a mounted
			 * filesystem answers yes to "you WILL cause SEVERE damage". */
			rep.Warn("Skipping the file system check: the target is still mounted")
			if umErr != nil {
				result.Messages = append(result.Messages, umErr.Error())
			}
		}
	} else {
		result.Unmounted = true
	}

	if result.Outcome == "" {
		result.Outcome = OutcomeOK
	}

	r.checkFilesystems(ctx, p, rep, &result)

	result.RebootRequired = p.CurrentSystem

	return result, nil
}

// finishSystem rewrites fstab and crypttab, then runs the finish script.
func (r *Executor) finishSystem(ctx context.Context, p *Plan, rep Reporter, tracker *Tracker, result *Result) error {

	if !p.CurrentSystem && p.TargetPath != "" {
		rep.Phase("fix_fstab")
		if err := r.fixTables(p); err != nil {
			/* Reported, not fatal. The files are copied and the bootloader
			 * steps still matter; a system with a stale fstab boots to an
			 * initramfs prompt, which is recoverable, whereas skipping GRUB
			 * leaves nothing to boot at all. */
			rep.Warn(err.Error())
			result.Messages = append(result.Messages, err.Error())
			if result.Outcome == "" {
				result.Outcome = OutcomeWarnings
			}
		}
		rep.Phase("parse_log")
	}

	code, err := r.Scripts.RunScript(ctx, p.FinishScript, func(line string) {
		if ev, ok := ParseMarker(line); ok {
			r.handleMarker(rep, tracker, ev, result)
			return
		}
		rep.Log(line)
	})
	if err != nil {
		return err
	}
	if code != 0 {
		if result.Outcome != OutcomeFailed {
			result.Outcome = OutcomeWarnings
		}
		result.Messages = append(result.Messages,
			fmt.Sprintf("Some post-restore steps did not complete (exit %d). See %s.",
				code, p.StepLogFile))
	}
	return nil
}

// fixTables rewrites the restored system's fstab and crypttab.
func (r *Executor) fixTables(p *Plan) error {

	fstabPath := filepath.Join(p.TargetPath, "etc/fstab")

	raw, err := os.ReadFile(fstabPath)
	if err != nil {
		return fmt.Errorf("restore: could not read %s: %w", fstabPath, err)
	}

	entries := FixFsTab(ParseFsTab(string(raw)), p.Mounts, p.FSTypeByUUID)
	if err := os.WriteFile(fstabPath, []byte(RenderFsTab(entries, true)), 0644); err != nil {
		return fmt.Errorf("restore: could not write %s: %w", fstabPath, err)
	}

	/* crypttab only if the restored system has one. Creating one where there
	 * was none would make the initramfs wait for a device that does not exist. */
	crypttabPath := filepath.Join(p.TargetPath, "etc/crypttab")
	rawCrypt, err := os.ReadFile(crypttabPath)
	if err != nil {
		return nil
	}

	cryptEntries := FixCryptTab(ParseCryptTab(string(rawCrypt)), p.EncryptedDevices)
	if err := os.WriteFile(crypttabPath, []byte(RenderCryptTab(cryptEntries)), 0644); err != nil {
		return fmt.Errorf("restore: could not write %s: %w", crypttabPath, err)
	}
	return nil
}

// handleMarker turns a script marker into a report.
func (r *Executor) handleMarker(rep Reporter, tracker *Tracker, ev Event, result *Result) {
	switch ev.Kind {
	case KindPhase:
		rep.Phase(ev.Phase)

	case KindReconnect:
		rep.Note(fmt.Sprintf(
			"Connection lost (attempt %d, rsync exit %d). The transfer resumes where it stopped; nothing already copied is lost.",
			ev.Attempt, ev.Code))

	case KindWarnings:
		/* Warnings, not failure. rsync 23 is almost always a permission or
		 * special-file problem, which retrying cannot fix -- and the files that
		 * did transfer are on the target, so the finish steps still matter. */
		if result.Outcome != OutcomeFailed {
			result.Outcome = OutcomeWarnings
		}
		result.Messages = append(result.Messages,
			"Some files could not be transferred. The restore continued; check the log.")

	case KindFailed:
		result.Outcome = OutcomeFailed
		result.Messages = append(result.Messages,
			fmt.Sprintf("The transfer failed (rsync exit %d).", ev.Code))

	case KindStepFailed:
		/* A post-restore step failing is a warning, never a failure: the files
		 * are already restored. Saying "restore failed" because run-parts
		 * returned non-zero would send someone to redo a transfer that worked. */
		if result.Outcome != OutcomeFailed {
			result.Outcome = OutcomeWarnings
		}
		result.Messages = append(result.Messages,
			fmt.Sprintf("A post-restore step did not complete: %s (exit %d).", ev.Step, ev.StepCode))
	}
}

/* probeSource asks whether the snapshot can be read and contains anything.
 *
 * rsync reports a missing source directory, an unreadable one and a handful of
 * skipped files all as exit 23, and 23 is the carry-on path -- by which point
 * --delete has already run against the target. So the source is listed first,
 * and a source that is missing OR empty stops the restore while the target is
 * still whole.
 *
 * Two entries, not one: a bare "." always lists.
 */
func (r *Executor) probeSource(ctx context.Context, p *Plan) error {

	if r.SourceProbe != nil {
		return r.SourceProbe(ctx)
	}

	script := SourceProbeScript(withTrailingSlash(p.SnapshotPath), p.RSH, p.Remote)

	ok := false
	_, err := r.Scripts.RunScript(ctx, script, func(line string) {
		if strings.Contains(line, SourceOKMarker) {
			ok = true
		}
	})
	if err != nil {
		return fmt.Errorf("restore: could not read the snapshot at %s: %w. Nothing was changed on the target",
			p.SnapshotPath, err)
	}
	if !ok {
		return fmt.Errorf(
			"restore: the snapshot at %s is missing, unreadable or empty. Nothing was changed on the target",
			p.SnapshotPath)
	}
	return nil
}

func excludeContents(list []string) string {
	var b strings.Builder
	for _, p := range list {
		if strings.TrimSpace(p) == "" {
			continue
		}
		b.WriteString(p)
		b.WriteByte('\n')
	}
	return b.String()
}

/* checkFilesystems runs fsck on each restored device.
 *
 * A restore rewrites a filesystem wholesale, and a fault that was tolerable
 * while the old contents were in place can surface as an unbootable disk. This
 * is the last chance to find one while there is still a working system to fix
 * it from.
 *
 * Three conditions before a single fsck runs, and every one has a reason:
 *
 *   - Only when the restore SUCCEEDED. Checking a target that was left half
 *     written wastes time on a filesystem that is going to be rewritten.
 *   - Only when the target UNMOUNTED. "fsck -y" answers yes to e2fsck's
 *     "The filesystem is mounted. If you continue you WILL cause SEVERE
 *     damage", so this must never run against something still in use.
 *   - Never for a restore of the running system, which by definition cannot be
 *     unmounted.
 *
 * Each device is re-checked individually against /proc/mounts as well, because
 * "the target unmounted" is a statement about the mount root and a device could
 * still be mounted somewhere else entirely.
 */
func (r *Executor) checkFilesystems(ctx context.Context, p *Plan, rep Reporter, result *Result) {

	if p.CurrentSystem || p.DryRun {
		return
	}
	if result.Outcome == OutcomeFailed {
		rep.Note("Skipping the file system check: the restore did not complete")
		return
	}
	if !result.Unmounted {
		// Already reported by the caller, which knows why.
		return
	}

	mounted, err := mountedDevices()
	if err != nil {
		rep.Warn("Skipping the file system check: could not read /proc/mounts")
		return
	}

	rep.Phase("fsck")

	for _, m := range p.Mounts {
		if !m.Assigned() || m.DevicePath == "" {
			continue
		}
		if mounted[m.DevicePath] {
			rep.Warn(fmt.Sprintf("Not checking %s: it is still mounted", m.DevicePath))
			continue
		}

		code, _, stderr, err := r.Commands.Run(ctx, []string{"fsck", "-y", m.DevicePath}, "")
		switch {
		case err != nil:
			rep.Warn(fmt.Sprintf("Could not check %s: %v", m.DevicePath, err))

		/* fsck's exit code is a bit field. 1 means errors were found and
		 * CORRECTED, which is a success for our purposes -- it is what -y is
		 * for. Anything above that is a problem worth reporting. */
		case code == 0:
			rep.Log(fmt.Sprintf("%s: clean", m.DevicePath))
		case code == 1:
			rep.Note(fmt.Sprintf("%s: errors were found and corrected", m.DevicePath))
		default:
			msg := fmt.Sprintf("%s: the file system check reported a problem (exit %d)", m.DevicePath, code)
			if s := strings.TrimSpace(stderr); s != "" {
				msg += ": " + s
			}
			rep.Warn(msg)
			result.Messages = append(result.Messages, msg)
			if result.Outcome != OutcomeFailed {
				result.Outcome = OutcomeWarnings
			}
		}
	}
}

// mountedDevices reads which device paths are currently mounted.
func mountedDevices() (map[string]bool, error) {
	raw, err := os.ReadFile("/proc/mounts")
	if err != nil {
		return nil, err
	}
	out := map[string]bool{}
	for _, line := range strings.Split(string(raw), "\n") {
		if f := strings.Fields(line); len(f) >= 2 {
			out[f[0]] = true
		}
	}
	return out, nil
}
