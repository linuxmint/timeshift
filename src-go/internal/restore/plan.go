package restore

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

/* The plan.
 *
 * Everything a restore will do, decided and checkable BEFORE anything is
 * mounted, written or deleted. A restore is the one operation in Timeshift
 * where a wrong decision destroys data rather than producing a wrong answer, so
 * the decisions are separated from the doing: a client can print this, a person
 * can read it, and a test can assert on it without a disk.
 *
 * Nothing in this file touches the system.
 */

// Request is what the caller asked for.
type Request struct {
	// SnapshotName is the snapshot's directory name, and SnapshotPath the
	// payload to copy FROM -- <snapshot>/localhost, with a host prefix for a
	// remote repository.
	SnapshotName string
	SnapshotPath string

	/* SnapshotDir is the snapshot directory itself, the PARENT of the payload.
	 *
	 * It is a separate field and not derived, because the two must not be the
	 * same directory. The exclude list and the log are written here, and the
	 * readability probe lists the payload: putting them in one directory means
	 * the file we just wrote counts towards the probe's "at least two entries",
	 * so an EMPTY snapshot passes the check that exists to catch an empty
	 * snapshot -- and is then copied over the target with --delete. */
	SnapshotDir string

	// Mounts are the target selections: which device goes at which mount
	// point. An entry with no device is left on the root filesystem.
	Mounts []MountEntry

	// CurrentSystem restores over the running system. The transfer is the same;
	// what differs is that there is no chroot, no unmount at the end, and the
	// script reboots.
	CurrentSystem bool

	// ESPCandidates are the partitions that could serve as /boot/efi, used to
	// fill one in when the snapshot needs one and none was chosen.
	ESPCandidates []MountEntry

	// SnapshotNeedsESP is true when the snapshot's own fstab has a /boot/efi
	// entry. A system that booted with an ESP will not boot without one.
	SnapshotNeedsESP bool

	ReinstallGrub   bool
	GrubDevice      string
	UpdateInitramfs bool
	UpdateGrubMenu  bool

	// DryRun compares without writing. It is also how the progress denominator
	// for a real run is measured.
	DryRun bool

	// Excludes are the restore filter rules, already ordered.
	Excludes []string

	// Remote marks a snapshot on another host, with RSH the -e command.
	Remote    bool
	RSH       string
	RsyncPath string

	// HooksDir is run with run-parts after the bootloader steps.
	HooksDir string

	// FSTypeByUUID gives each target device's filesystem type. fstab needs it
	// and the mount plan does not carry it -- and getting it wrong leaves a
	// subvol= option on an ext4 entry, which makes mount fail outright.
	FSTypeByUUID map[string]string

	// EncryptedDevices are the LUKS containers the restore mounted through.
	// crypttab must name the container, not the unlocked device inside it.
	EncryptedDevices []EncryptedDevice

	// MountRoot is where target filesystems are mounted, normally
	// /run/timeshift/<pid>/restore.
	MountRoot string

	// TempDir is used for the exclude list and log when neither can live on the
	// target or beside the snapshot.
	TempDir string
}

// Plan is a validated Request plus everything derived from it.
type Plan struct {
	Request

	// Report is the layout check. A blocked report must not be executed.
	Report LayoutReport

	// Folded lists mount points collapsed because they would have mounted one
	// device twice at nested points.
	Folded []string

	// TargetPath is where files are written: "/" for the running system,
	// otherwise the mount root, with a trailing slash.
	TargetPath string

	/* Where the three files live.
	 *
	 * LogFile goes ON THE TARGET whenever there is one. TEMP_DIR is tmpfs in a
	 * recovery environment and an -aiir log of a whole root filesystem is
	 * hundreds of megabytes of RAM; when that tmpfs fills, the failure sentinel
	 * -- which lives beside this file and is the one signal that stops a failed
	 * restore from installing a bootloader -- cannot be written either.
	 * Fail-closed must not depend on free RAM. It is safe on the target because
	 * /var/log/timeshift/* is in the restore exclude list and --delete-excluded
	 * is off, so rsync leaves it alone; it also means the log survives the
	 * reboot, on the restored system.
	 */
	LogFile     string
	StepLogFile string
	FailedFlag  string
	ExcludeFile string

	// The two generated scripts, and the phases they will announce.
	SyncScript   string
	FinishScript string
	Phases       []Phase

	finish FinishScriptOptions
}

// BuildPlan validates a request and derives everything from it.
//
// A returned error means the restore must not start. A returned Plan whose
// Report is Blocked() means the same thing; the difference is that the report
// explains itself row by row and the error does not.
func BuildPlan(req Request) (*Plan, error) {

	if req.SnapshotPath == "" {
		return nil, fmt.Errorf("restore: no snapshot to restore")
	}
	if req.MountRoot == "" && !req.CurrentSystem {
		return nil, fmt.Errorf("restore: no mount root for the target")
	}

	p := &Plan{Request: req}

	/* Three safety layers, applied in order, and they must stay independent.
	 * The first two reason about intent; VerifyNoAliasedMounts, which runs
	 * later against the mounted result, reasons about reality. */
	entries, folded := FoldAliasedMountEntries(req.Mounts)
	p.Folded = folded

	entries, _ = NormalizeESPSelection(entries, req.ESPCandidates)
	p.Mounts = entries

	p.Report = Validate(ValidateOptions{
		Entries:          entries,
		CurrentSystem:    req.CurrentSystem,
		SnapshotNeedsESP: req.SnapshotNeedsESP,
	})
	if p.Report.Blocked() {
		return p, nil
	}

	if req.CurrentSystem {
		p.TargetPath = "/"
	} else {
		p.TargetPath = withTrailingSlash(req.MountRoot)
	}

	p.deriveePaths()

	p.SyncScript = BuildSyncScript(SyncScriptOptions{
		Source:        withTrailingSlash(req.SnapshotPath),
		Target:        p.TargetPath,
		LogFile:       p.LogFile,
		ExcludeFile:   p.ExcludeFile,
		FailedFlag:    p.FailedFlag,
		DryRun:        req.DryRun,
		CurrentSystem: req.CurrentSystem,
		Remote:        req.Remote,
		RSH:           req.RSH,
		RsyncPath:     req.RsyncPath,
	})

	hooks := req.HooksDir
	if hooks == "" {
		hooks = DefaultHooksDir
	}

	p.finish = FinishScriptOptions{
		TargetPath:      targetForFinish(p.TargetPath, req.CurrentSystem),
		CurrentSystem:   req.CurrentSystem,
		StepLogFile:     p.StepLogFile,
		ReinstallGrub:   req.ReinstallGrub,
		GrubDevice:      req.GrubDevice,
		NeedsESP:        req.SnapshotNeedsESP,
		UpdateInitramfs: req.UpdateInitramfs,
		UpdateGrubMenu:  req.UpdateGrubMenu,
		HooksDir:        hooks,
	}
	p.FinishScript = BuildFinishScript(p.finish)

	p.Phases = append(SyncPhases(req.DryRun), FinishPhases(p.finish)...)
	if !req.DryRun && !req.CurrentSystem {
		// The user waits through it, so it is listed. It is skipped at run time
		// if the restore failed or the target would not unmount, which the
		// checklist cannot know in advance.
		p.Phases = append(p.Phases, Phase{Key: "fsck", Title: "Checking file systems"})
	}
	if req.DryRun {
		// A dry run stops after the transfer: nothing is fixed, nothing is
		// installed, nothing reboots.
		p.Phases = SyncPhases(true)
	}

	return p, nil
}

/* deriveePaths decides where the log, the sentinel and the exclude list live.
 *
 * The exclude list and the log are opened by rsync on the CLIENT side even when
 * the source is remote, so neither may be a path inside a remote snapshot:
 * rsync warns, ignores it and still exits 0, which for the exclude list means a
 * restore that silently ignores every exclusion.
 */
func (p *Plan) deriveePaths() {

	switch {
	case !p.CurrentSystem && p.TargetPath != "":
		// On the target, where it survives the reboot and cannot exhaust tmpfs.
		p.LogFile = filepath.Join(p.TargetPath, "var/log/timeshift/rsync-log-restore")
	case p.Remote:
		p.LogFile = filepath.Join(p.TempDir, "rsync-log-restore")
	default:
		p.LogFile = filepath.Join(p.snapshotDir(), "rsync-log-restore")
	}

	dir := filepath.Dir(p.LogFile)
	p.StepLogFile = filepath.Join(dir, "restore-steps.log")
	p.FailedFlag = filepath.Join(dir, ".timeshift-restore-failed")

	if p.Remote {
		p.ExcludeFile = filepath.Join(p.TempDir, "exclude-restore.list")
	} else {
		p.ExcludeFile = filepath.Join(p.snapshotDir(), "exclude-restore.list")
	}
}

// snapshotDir is the snapshot directory, falling back to the payload's parent.
func (p *Plan) snapshotDir() string {
	if p.SnapshotDir != "" {
		return p.SnapshotDir
	}
	return filepath.Dir(strings.TrimSuffix(p.SnapshotPath, "/"))
}

// targetForFinish is the chroot target, empty when there is none.
func targetForFinish(targetPath string, currentSystem bool) string {
	if currentSystem {
		return ""
	}
	return targetPath
}

// Describe renders the plan for a person to read before approving it.
//
// This is not decoration. A restore writes over a whole filesystem, and the
// only defence against restoring to the wrong disk is someone recognising it in
// a list before saying yes.
func (p *Plan) Describe() string {
	var b strings.Builder

	fmt.Fprintf(&b, "Snapshot:  %s\n", p.SnapshotName)
	if p.CurrentSystem {
		fmt.Fprintf(&b, "Target:    the running system\n")
	} else {
		fmt.Fprintf(&b, "Target:    %s\n", p.MountRoot)
	}
	if p.DryRun {
		fmt.Fprintf(&b, "Mode:      DRY RUN -- nothing will be written\n")
	}

	b.WriteString("\nDevices:\n")
	for _, row := range p.Report.Rows {
		marker := " "
		if row.Blocking {
			marker = "!"
		}
		fmt.Fprintf(&b, " %s %-12s %-24s %s\n", marker, row.MountPoint, row.Assigned, row.Status)
	}

	for _, note := range p.Report.Notes {
		b.WriteString("  " + note + "\n")
	}
	for _, f := range p.Folded {
		fmt.Fprintf(&b, "  (%s is on the same device and is not mounted separately)\n", f)
	}

	if !p.DryRun {
		b.WriteString("\nAfterwards:\n")
		for _, ph := range p.Phases {
			b.WriteString("  " + ph.Title + "\n")
		}
	}

	return b.String()
}

// PrepareDirs creates the directories the scripts write into.
//
// rsync will not create the directory its --log-file lives in, and a missing
// one makes it exit 23 -- which is the warn-and-continue path, so the restore
// would carry on to the bootloader steps having logged nothing.
func (p *Plan) PrepareDirs() error {
	for _, dir := range []string{filepath.Dir(p.LogFile), filepath.Dir(p.ExcludeFile)} {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return fmt.Errorf("restore: mkdir %s: %w", dir, err)
		}
	}
	return nil
}

/* ClearStaleState removes what a previous failed attempt left behind.
 *
 * The sentinel above all: .timeshift-restore-failed is checked after the
 * transfer to decide whether the bootloader steps may run, so one left over
 * from last time would abort a restore that had in fact just succeeded.
 */
func (p *Plan) ClearStaleState() {
	for _, f := range []string{
		p.FailedFlag,
		p.LogFile,
		p.LogFile + "-changes",
		p.LogFile + ".gz",
		p.StepLogFile,
	} {
		os.Remove(f)
	}
}
