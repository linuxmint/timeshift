package restore

import (
	"strings"
	"testing"
)

func basicRequest() Request {
	return Request{
		SnapshotName: "2026-03-15_12-00-00",
		SnapshotPath: "/mnt/backup/timeshift/snapshots/2026-03-15_12-00-00/localhost",
		Mounts: []MountEntry{
			{MountPoint: "/", DeviceUUID: "root-uuid", DevicePath: "/dev/sda2"},
			{MountPoint: "/home", DeviceUUID: "home-uuid", DevicePath: "/dev/sda3"},
		},
		MountRoot:       "/run/timeshift/1/restore",
		TempDir:         "/run/timeshift/1",
		ReinstallGrub:   true,
		GrubDevice:      "/dev/sda",
		UpdateInitramfs: true,
		UpdateGrubMenu:  true,
		Excludes:        []string{"/var/log/timeshift/**", "/timeshift/*"},
	}
}

func TestBuildPlanDerivesPaths(t *testing.T) {
	p, err := BuildPlan(basicRequest())
	if err != nil {
		t.Fatalf("BuildPlan: %v", err)
	}
	if p.Report.Blocked() {
		t.Fatalf("a complete plan was blocked: %+v", p.Report.Rows)
	}

	/* The log belongs ON THE TARGET. TEMP_DIR is tmpfs in a recovery
	 * environment and an -aiir log of a root filesystem is hundreds of
	 * megabytes; when that fills, the failure sentinel beside it cannot be
	 * written either, and fail-closed must not depend on free RAM. */
	if !strings.HasPrefix(p.LogFile, "/run/timeshift/1/restore/") {
		t.Errorf("log file is not on the target: %s", p.LogFile)
	}
	if !strings.HasSuffix(p.LogFile, "var/log/timeshift/rsync-log-restore") {
		t.Errorf("unexpected log path: %s", p.LogFile)
	}

	// The sentinel and the step log live beside the log, wherever that is.
	if got := strings.TrimSuffix(p.FailedFlag, "/.timeshift-restore-failed"); got == p.FailedFlag {
		t.Errorf("sentinel is not named as expected: %s", p.FailedFlag)
	}
	if !strings.HasPrefix(p.FailedFlag, "/run/timeshift/1/restore/") {
		t.Errorf("sentinel is not beside the log: %s", p.FailedFlag)
	}
}

// A remote snapshot's exclude list and log are opened by rsync on the CLIENT
// side. Pointing either inside a remote snapshot makes rsync warn, ignore it
// and still exit 0 -- which for the exclude list is a restore that silently
// applies no exclusions at all.
func TestRemotePlanKeepsClientFilesLocal(t *testing.T) {
	req := basicRequest()
	req.Remote = true
	req.RSH = "ssh -o BatchMode=yes"
	req.SnapshotPath = "backup@host:/srv/timeshift/snapshots/x/localhost"

	p, err := BuildPlan(req)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(p.ExcludeFile, "backup@host:") {
		t.Fatalf("exclude file is on the remote: %s", p.ExcludeFile)
	}
	if !strings.HasPrefix(p.ExcludeFile, "/run/timeshift/1") &&
		!strings.HasPrefix(p.ExcludeFile, "/run/timeshift/1/restore") {
		t.Fatalf("exclude file is not local: %s", p.ExcludeFile)
	}
	if !strings.Contains(p.SyncScript, "--numeric-ids") {
		t.Error("a remote transfer must use --numeric-ids or uid/gid are mapped by name across hosts")
	}
}

func TestCurrentSystemPlanHasNoChroot(t *testing.T) {
	req := basicRequest()
	req.CurrentSystem = true

	p, err := BuildPlan(req)
	if err != nil {
		t.Fatal(err)
	}
	if p.TargetPath != "/" {
		t.Fatalf("target = %q, want /", p.TargetPath)
	}
	if strings.Contains(p.FinishScript, "chroot") {
		t.Error("restoring the running system must not chroot")
	}
	if !strings.Contains(p.FinishScript, "reboot") {
		t.Error("restoring the running system must end by rebooting")
	}
}

// A dry run must not promise steps it will not take.
func TestDryRunPlanStopsAfterTheTransfer(t *testing.T) {
	req := basicRequest()
	req.DryRun = true

	p, err := BuildPlan(req)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(p.SyncScript, "--dry-run") {
		t.Error("the sync script is not a dry run")
	}
	for _, ph := range p.Phases {
		switch ph.Key {
		case "grub_install", "initramfs", "grub_menu", "reboot", "chroot_bind":
			t.Fatalf("a dry run promised the phase %q", ph.Key)
		}
	}
}

// A plan with no root device must be blocked, not merely noted: a missing root
// gives a system that does not boot at all.
func TestPlanWithoutRootIsBlocked(t *testing.T) {
	req := basicRequest()
	req.Mounts = []MountEntry{{MountPoint: "/home", DeviceUUID: "home-uuid"}}

	p, err := BuildPlan(req)
	if err != nil {
		t.Fatal(err)
	}
	if !p.Report.Blocked() {
		t.Fatal("a plan with no root device was allowed")
	}
}

func TestBuildPlanRefusesAnEmptyRequest(t *testing.T) {
	if _, err := BuildPlan(Request{}); err == nil {
		t.Fatal("a request with no snapshot was accepted")
	}
}

// The description is the last thing between a person and overwriting a disk, so
// it has to name the disk.
func TestDescribeNamesTheDevices(t *testing.T) {
	p, err := BuildPlan(basicRequest())
	if err != nil {
		t.Fatal(err)
	}
	text := p.Describe()

	for _, want := range []string{"2026-03-15_12-00-00", "/dev/sda2", "/home"} {
		if !strings.Contains(text, want) {
			t.Errorf("the summary does not mention %q:\n%s", want, text)
		}
	}
}
