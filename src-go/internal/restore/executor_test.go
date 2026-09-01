package restore

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

/* These run the real generated scripts with real rsync against real
 * directories.
 *
 * A test with a mocked rsync proves the mock agrees with the mock. Only an
 * actual run catches a quoting mistake, a marker that never fires, or an
 * ordering error -- and ordering is the whole safety argument here.
 */

// execRunner runs commands for real.
type execRunner struct{}

func (execRunner) Run(ctx context.Context, argv []string, dir string) (int, string, string, error) {
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = dir
	var out, errb strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errb
	err := cmd.Run()
	if ee, ok := err.(*exec.ExitError); ok {
		return ee.ExitCode(), out.String(), errb.String(), nil
	}
	if err != nil {
		return -1, out.String(), errb.String(), err
	}
	return 0, out.String(), errb.String(), nil
}

/* fakeMountRunner runs every command for real EXCEPT mount and umount.
 *
 * Mounting needs a block device and root, which would make these tests skip on
 * the machine where they are most useful. Faking exactly those two keeps
 * everything that matters real -- rsync, the scripts, the ordering -- while the
 * target directory stands in for a mounted filesystem.
 *
 * The calls are recorded, because the ORDER is the safety argument: the target
 * must be mounted before the alias check, and the alias check before anything
 * is deleted.
 */
type fakeMountRunner struct {
	real execRunner

	// refuseUnmount makes umount fail, which is how the "target still mounted"
	// path is reached without leaving a real mount behind.
	refuseUnmount bool

	calls []string
}

func (f *fakeMountRunner) Run(ctx context.Context, argv []string, dir string) (int, string, string, error) {
	if len(argv) > 0 && (argv[0] == "mount" || argv[0] == "umount" || argv[0] == "fsck") {
		f.calls = append(f.calls, strings.Join(argv, " "))
		if argv[0] == "umount" && f.refuseUnmount {
			return 32, "", "target is busy", nil
		}
		return 0, "", "", nil
	}
	return f.real.Run(ctx, argv, dir)
}

// bashRunner satisfies ScriptRunner without touching /run.
type bashRunner struct{ dir string }

func (b bashRunner) RunScript(ctx context.Context, script string, onLine func(string)) (int, error) {
	path := filepath.Join(b.dir, "script.sh")
	if err := os.WriteFile(path, []byte("#!/bin/bash\n"+script), 0700); err != nil {
		return -1, err
	}
	cmd := exec.CommandContext(ctx, "bash", path)
	out, err := cmd.CombinedOutput()
	for _, line := range strings.Split(string(out), "\n") {
		if line != "" {
			onLine(line)
		}
	}
	if ee, ok := err.(*exec.ExitError); ok {
		return ee.ExitCode(), nil
	}
	if err != nil {
		return -1, err
	}
	return 0, nil
}

// recorder collects what the executor reported.
type recorder struct {
	phases   []string
	notes    []string
	warnings []string
	lines    int
}

func (r *recorder) SetPhases([]Phase)             {}
func (r *recorder) Phase(k string)                { r.phases = append(r.phases, k) }
func (r *recorder) Progress(int64, int64, string) { r.lines++ }
func (r *recorder) Log(string)                    {}
func (r *recorder) Note(m string)                 { r.notes = append(r.notes, m) }
func (r *recorder) Warn(m string)                 { r.warnings = append(r.warnings, m) }

// stageRestore builds a snapshot and a target that is NOT the running system.
func stageRestore(t *testing.T) (snapshot, target, work string) {
	t.Helper()

	work = t.TempDir()
	snapshotDir := filepath.Join(work, "snapshot")
	// A real snapshot keeps its payload under localhost/, with the control
	// files beside it. The separation matters: the readability probe lists the
	// payload, and anything written beside it must not count towards it.
	snapshot = snapshotDir
	payload := filepath.Join(snapshotDir, "localhost")
	target = filepath.Join(work, "target")

	for _, d := range []string{
		filepath.Join(payload, "etc"),
		filepath.Join(payload, "usr", "bin"),
		filepath.Join(payload, "var", "log", "timeshift"),
		filepath.Join(target, "etc"),
	} {
		if err := os.MkdirAll(d, 0755); err != nil {
			t.Fatal(err)
		}
	}

	write := func(p, s string) {
		if err := os.WriteFile(p, []byte(s), 0644); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(payload, "etc", "hostname"), "restored-host\n")
	write(filepath.Join(payload, "etc", "fstab"),
		"UUID=old-root / ext4 defaults 0 1\nUUID=old-home /home ext4 defaults 0 2\n")
	write(filepath.Join(payload, "usr", "bin", "thing"), "binary\n")

	// A file that exists only on the target: --delete must remove it.
	write(filepath.Join(target, "etc", "leftover"), "from the old system\n")

	return snapshot, target, work
}

func planFor(t *testing.T, snapshot, target, work string, tweak func(*Request)) *Plan {
	t.Helper()

	req := Request{
		SnapshotName: "2026-03-15_12-00-00",
		SnapshotPath: filepath.Join(snapshot, "localhost"),
		SnapshotDir:  snapshot,
		Mounts: []MountEntry{
			{MountPoint: "/", DeviceUUID: "root-uuid", DevicePath: "/dev/fake1"},
		},
		MountRoot:    target,
		TempDir:      work,
		FSTypeByUUID: map[string]string{"root-uuid": "ext4"},
		HooksDir:     filepath.Join(work, "hooks"),
		Excludes:     []string{"/var/log/timeshift/**", "/timeshift/*"},
	}
	if tweak != nil {
		tweak(&req)
	}

	p, err := BuildPlan(req)
	if err != nil {
		t.Fatalf("BuildPlan: %v", err)
	}
	if p.Report.Blocked() {
		t.Fatalf("plan blocked: %+v", p.Report.Rows)
	}
	return p
}

// executorFor builds an Executor with mount and umount faked.
func executorFor(work string, rep Reporter) (*Executor, *fakeMountRunner) {
	fake := &fakeMountRunner{}
	return &Executor{
		Commands: fake,
		Scripts:  bashRunner{dir: work},
		Reporter: rep,
	}, fake
}

func TestExecutorRestoresAndFixesFsTab(t *testing.T) {
	snapshot, target, work := stageRestore(t)
	p := planFor(t, snapshot, target, work, nil)

	rep := &recorder{}
	ex, fake := executorFor(work, rep)

	res, err := ex.Run(context.Background(), p)
	if err != nil {
		t.Fatalf("Run: %v (messages %v)", err, res.Messages)
	}

	if res.Outcome == OutcomeFailed {
		t.Fatalf("restore failed: %v", res.Messages)
	}

	if got := readOr(t, filepath.Join(target, "etc", "hostname")); got != "restored-host\n" {
		t.Errorf("the snapshot's hostname was not restored: %q", got)
	}
	if _, err := os.Stat(filepath.Join(target, "etc", "leftover")); !os.IsNotExist(err) {
		t.Error("--delete did not remove a file that exists only on the target")
	}

	// fstab must now name the device the restore actually used, not the one
	// the snapshot was taken from. Otherwise the system boots to an initramfs
	// prompt looking for a UUID that is not there.
	fstab := readOr(t, filepath.Join(target, "etc", "fstab"))
	if !strings.Contains(fstab, "UUID=root-uuid") {
		t.Errorf("fstab was not rewritten:\n%s", fstab)
	}
	if strings.Contains(fstab, "UUID=old-root") {
		t.Errorf("fstab still names the snapshot's old root:\n%s", fstab)
	}

	// The target must have been mounted before anything ran, and released
	// afterwards -- the unmount is what gates the fsck.
	if len(fake.calls) < 2 {
		t.Fatalf("expected a mount and an unmount, got %v", fake.calls)
	}
	if !strings.HasPrefix(fake.calls[0], "mount ") {
		t.Errorf("the first command was not a mount: %q", fake.calls[0])
	}
	// The unmount must come before the fsck, not merely happen: "fsck -y" on a
	// mounted filesystem answers yes to "you WILL cause SEVERE damage".
	umountAt, fsckAt := -1, -1
	for i, c := range fake.calls {
		switch {
		case strings.HasPrefix(c, "umount ") && umountAt < 0:
			umountAt = i
		case strings.HasPrefix(c, "fsck ") && fsckAt < 0:
			fsckAt = i
		}
	}
	if umountAt < 0 {
		t.Errorf("the target was not unmounted: %v", fake.calls)
	}
	if fsckAt >= 0 && fsckAt < umountAt {
		t.Errorf("fsck ran before the unmount: %v", fake.calls)
	}
	if !res.Unmounted {
		t.Error("the result does not report the target as unmounted, so fsck would be skipped")
	}
}

// The check that stops an empty or unreadable snapshot from erasing the target.
func TestExecutorRefusesAnEmptySource(t *testing.T) {
	_, target, work := stageRestore(t)

	// An empty payload inside an otherwise ordinary snapshot directory: this is
	// exactly the shape that must be refused, and the shape that passes if the
	// exclude list is written into the probed tree first.
	empty := filepath.Join(work, "empty-snapshot")
	if err := os.MkdirAll(filepath.Join(empty, "localhost"), 0755); err != nil {
		t.Fatal(err)
	}

	p := planFor(t, empty, target, work, nil)
	ex, _ := executorFor(work, &recorder{})

	_, err := ex.Run(context.Background(), p)
	if err == nil {
		t.Fatal("an empty snapshot was accepted as a restore source")
	}
	if !strings.Contains(err.Error(), "Nothing was changed on the target") {
		t.Fatalf("the error does not say the target is intact: %v", err)
	}

	// And it must really be intact.
	if _, statErr := os.Stat(filepath.Join(target, "etc", "leftover")); statErr != nil {
		t.Fatal("the target was modified despite the refusal")
	}
}

// An unwritable exclude list must stop the restore. rsync answers 23 both for
// "a few files were skipped" and for "I could not open the exclude file", and
// 23 is the warn-and-continue path.
func TestExecutorRefusesWhenTheExcludeListCannotBeWritten(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: a read-only directory would not stop the write")
	}

	snapshot, target, work := stageRestore(t)
	p := planFor(t, snapshot, target, work, nil)

	// Make the exclude list's directory unwritable.
	dir := filepath.Dir(p.ExcludeFile)
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0755) })

	ex, _ := executorFor(work, &recorder{})
	if _, err := ex.Run(context.Background(), p); err == nil {
		t.Fatal("the restore continued with no exclude list")
	}
}

func TestExecutorDryRunChangesNothing(t *testing.T) {
	snapshot, target, work := stageRestore(t)
	p := planFor(t, snapshot, target, work, func(r *Request) { r.DryRun = true })

	rep := &recorder{}
	ex, _ := executorFor(work, rep)

	res, err := ex.Run(context.Background(), p)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	if _, err := os.Stat(filepath.Join(target, "etc", "leftover")); err != nil {
		t.Error("a dry run deleted a file from the target")
	}
	if _, err := os.Stat(filepath.Join(target, "etc", "fstab")); !os.IsNotExist(err) {
		t.Error("a dry run created the target's fstab")
	}
	if _, err := os.Stat(filepath.Join(target, "etc", "hostname")); !os.IsNotExist(err) {
		t.Error("a dry run copied a file onto the target")
	}

	// The line count is the whole point of a dry run: it is the denominator
	// the real run's progress bar needs.
	if res.LineCount == 0 {
		t.Error("a dry run produced no line count, so a real run has no denominator")
	}
}

func readOr(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read %s: %v", p, err)
	}
	return string(b)
}

/* fsck must not run on a filesystem that is still mounted.
 *
 * "fsck -y" answers yes to e2fsck's "The filesystem is mounted. If you continue
 * you WILL cause SEVERE damage", so the guard is the whole point of the step.
 */
func TestFsckIsSkippedWhenTheTargetIsStillMounted(t *testing.T) {
	snapshot, target, work := stageRestore(t)
	p := planFor(t, snapshot, target, work, nil)

	rep := &recorder{}
	fake := &fakeMountRunner{refuseUnmount: true}
	ex := &Executor{Commands: fake, Scripts: bashRunner{dir: work}, Reporter: rep}

	res, err := ex.Run(context.Background(), p)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Unmounted {
		t.Fatal("the result claims the target unmounted when umount refused")
	}

	for _, c := range fake.calls {
		if strings.HasPrefix(c, "fsck") {
			t.Fatalf("fsck ran against a still-mounted target: %q", c)
		}
	}

	found := false
	for _, w := range rep.warnings {
		if strings.Contains(w, "still mounted") {
			found = true
		}
	}
	if !found {
		t.Errorf("the skip was not explained: %v", rep.warnings)
	}
}

func TestFsckRunsOnASuccessfulRestore(t *testing.T) {
	snapshot, target, work := stageRestore(t)
	p := planFor(t, snapshot, target, work, nil)

	rep := &recorder{}
	ex, fake := executorFor(work, rep)

	if _, err := ex.Run(context.Background(), p); err != nil {
		t.Fatalf("Run: %v", err)
	}

	var checked []string
	for _, c := range fake.calls {
		if strings.HasPrefix(c, "fsck ") {
			checked = append(checked, c)
		}
	}
	if len(checked) == 0 {
		t.Fatalf("no file system check ran after a successful restore: %v", fake.calls)
	}
	if !strings.Contains(checked[0], "-y") {
		t.Errorf("fsck was not run non-interactively: %q", checked[0])
	}
}
