package restore

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A plain prefix test would call /boot-backup a child of /boot, and folding
// those together would unmount a filesystem nobody asked about.
func TestMountPointIsUnder(t *testing.T) {
	cases := []struct {
		child, parent string
		want          bool
	}{
		{"/boot", "/", true},
		{"/", "/", false},
		{"/boot/efi", "/boot", true},
		{"/boot", "/boot", true},
		{"/boot-backup", "/boot", false},
		{"/bootstrap", "/boot", false},
		{"/home/user", "/home", true},
		{"/homework", "/home", false},
		{"/var", "/usr", false},
	}
	for _, c := range cases {
		if got := MountPointIsUnder(c.child, c.parent); got != c.want {
			t.Errorf("MountPointIsUnder(%q, %q) = %v, want %v", c.child, c.parent, got, c.want)
		}
	}
}

// Two entries pointing at the same device at nested points would mount it
// twice; the child is folded onto the parent.
func TestFoldAliasedEntries(t *testing.T) {
	entries := []MountEntry{
		{MountPoint: "/", DeviceUUID: "root-uuid", DevicePath: "/dev/sda2"},
		{MountPoint: "/home", DeviceUUID: "root-uuid", DevicePath: "/dev/sda2"},
		{MountPoint: "/boot", DeviceUUID: "boot-uuid", DevicePath: "/dev/sda1"},
	}
	out, notes := FoldAliasedMountEntries(entries)

	var home MountEntry
	for _, e := range out {
		if e.MountPoint == "/home" {
			home = e
		}
	}
	if home.Assigned() {
		t.Error("/home on the same device as / should have been folded")
	}
	if len(notes) != 1 || !strings.Contains(notes[0], "/home") {
		t.Errorf("the fold was not explained: %v", notes)
	}

	// A genuinely separate device is untouched.
	for _, e := range out {
		if e.MountPoint == "/boot" && !e.Assigned() {
			t.Error("/boot is on its own device and must not be folded")
		}
	}
}

// The entry keeps its row with no device, rather than being removed: that is
// what "Keep on Root Device" stores, and removing it would make the dropdown
// vanish if the user stepped back.
func TestFoldKeepsTheRow(t *testing.T) {
	entries := []MountEntry{
		{MountPoint: "/", DeviceUUID: "u", DevicePath: "/dev/sda2"},
		{MountPoint: "/home", DeviceUUID: "u", DevicePath: "/dev/sda2"},
	}
	out, _ := FoldAliasedMountEntries(entries)
	if len(out) != 2 {
		t.Fatalf("folding removed a row: %d entries left", len(out))
	}
}

// Folding /boot/efi onto the root is not a shorthand: it means no ESP is
// mounted, the payload lands as ordinary files on ext4, and grub-install fails
// with "cannot find EFI directory".
func TestESPIsNeverFolded(t *testing.T) {
	entries := []MountEntry{
		{MountPoint: "/", DeviceUUID: "u", DevicePath: "/dev/sda2"},
		{MountPoint: "/boot/efi", DeviceUUID: "u", DevicePath: "/dev/sda2"},
	}
	out, _ := FoldAliasedMountEntries(entries)
	for _, e := range out {
		if e.MountPoint == "/boot/efi" && !e.Assigned() {
			t.Error("the ESP must never be folded away; Validate reports it as an error instead")
		}
	}
}

// Only an alias if they would be mounted the same way: two subvolumes of one
// btrfs device are different filesystems in every way that matters.
func TestDifferentOptionsAreNotAliases(t *testing.T) {
	entries := []MountEntry{
		{MountPoint: "/", DeviceUUID: "u", DevicePath: "/dev/sda2", Options: "subvol=@"},
		{MountPoint: "/home", DeviceUUID: "u", DevicePath: "/dev/sda2", Options: "subvol=@home"},
	}
	out, notes := FoldAliasedMountEntries(entries)
	for _, e := range out {
		if e.MountPoint == "/home" && !e.Assigned() {
			t.Error("different mount options mean different filesystems; this must not fold")
		}
	}
	if len(notes) != 0 {
		t.Errorf("nothing should have been folded: %v", notes)
	}
}

// Only / and /boot/efi can block. A missing /home gives a bootable system with
// an empty home; a missing root gives a system that does not boot.
func TestOnlyRootAndESPBlock(t *testing.T) {
	report := Validate(ValidateOptions{
		Entries: []MountEntry{
			{MountPoint: "/", DeviceUUID: "u", DevicePath: "/dev/sda2", DiskPath: "/dev/sda"},
			{MountPoint: "/home"}, // no device: keep on root
		},
	})
	if report.Blocked() {
		t.Errorf("an unassigned /home must not block: %+v", report.Rows)
	}

	report = Validate(ValidateOptions{Entries: []MountEntry{{MountPoint: "/home"}}})
	if !report.Blocked() {
		t.Error("a restore with no root device must block")
	}
}

func TestESPValidation(t *testing.T) {
	root := MountEntry{MountPoint: "/", DeviceUUID: "r", DevicePath: "/dev/sda2", DiskPath: "/dev/sda"}

	// Needed but absent.
	r := Validate(ValidateOptions{SnapshotNeedsESP: true, Entries: []MountEntry{root}})
	if !r.Blocked() {
		t.Error("a snapshot needing an ESP with none selected must block")
	}

	// Selected but not actually an ESP.
	r = Validate(ValidateOptions{SnapshotNeedsESP: true, Entries: []MountEntry{
		root,
		{MountPoint: "/boot/efi", DeviceUUID: "x", DevicePath: "/dev/sda3", IsESP: false, DiskPath: "/dev/sda"},
	}})
	if !r.Blocked() {
		t.Error("a non-ESP selected as the ESP must block")
	}

	// On a different disk: boots only while both are attached.
	r = Validate(ValidateOptions{SnapshotNeedsESP: true, Entries: []MountEntry{
		root,
		{MountPoint: "/boot/efi", DeviceUUID: "e", DevicePath: "/dev/sdb1", IsESP: true, DiskPath: "/dev/sdb"},
	}})
	if !r.Blocked() {
		t.Error("an ESP on a different disk than the root must block")
	}

	// Correct.
	r = Validate(ValidateOptions{SnapshotNeedsESP: true, Entries: []MountEntry{
		root,
		{MountPoint: "/boot/efi", DeviceUUID: "e", DevicePath: "/dev/sda1", IsESP: true, DiskPath: "/dev/sda"},
	}})
	if r.Blocked() {
		t.Errorf("a correct ESP must not block: %+v", r.Rows)
	}

	// A snapshot that does not use UEFI needs no ESP at all.
	r = Validate(ValidateOptions{SnapshotNeedsESP: false, Entries: []MountEntry{root}})
	if r.Blocked() {
		t.Error("a non-UEFI snapshot must not require an ESP")
	}
}

func TestNormalizeESPSelection(t *testing.T) {
	root := MountEntry{MountPoint: "/", DeviceUUID: "r", DevicePath: "/dev/sda2", DiskPath: "/dev/sda"}
	candidates := []MountEntry{
		{DeviceUUID: "esp-a", DevicePath: "/dev/sda1", IsESP: true, DiskPath: "/dev/sda"},
		{DeviceUUID: "esp-b", DevicePath: "/dev/sdb1", IsESP: true, DiskPath: "/dev/sdb"},
	}

	// Nothing selected: pick the one on the root's disk.
	out, note := NormalizeESPSelection([]MountEntry{root, {MountPoint: "/boot/efi"}}, candidates)
	if got := findEntry(out, "/boot/efi"); got.DevicePath != "/dev/sda1" {
		t.Errorf("auto-pick chose %q, want the ESP on the root's disk", got.DevicePath)
	}
	if note == "" {
		t.Error("an automatic choice must be explained")
	}

	// Selected on the wrong disk: replaced.
	out, note = NormalizeESPSelection([]MountEntry{root,
		{MountPoint: "/boot/efi", DeviceUUID: "esp-b", DevicePath: "/dev/sdb1", IsESP: true, DiskPath: "/dev/sdb"},
	}, candidates)
	if got := findEntry(out, "/boot/efi"); got.DevicePath != "/dev/sda1" {
		t.Errorf("an ESP on the wrong disk was kept: %q", got.DevicePath)
	}
	if !strings.Contains(note, "/dev/sdb1") {
		t.Errorf("the replacement must name what it replaced: %q", note)
	}

	// A correct selection is left alone.
	out, note = NormalizeESPSelection([]MountEntry{root,
		{MountPoint: "/boot/efi", DeviceUUID: "esp-a", DevicePath: "/dev/sda1", IsESP: true, DiskPath: "/dev/sda"},
	}, candidates)
	if note != "" {
		t.Errorf("a correct selection should not be changed: %q", note)
	}

	// Nothing usable: cleared, so Validate blocks with a clear message.
	out, _ = NormalizeESPSelection([]MountEntry{root,
		{MountPoint: "/boot/efi", DeviceUUID: "x", DevicePath: "/dev/sdc9", IsESP: false, DiskPath: "/dev/sdc"},
	}, nil)
	if findEntry(out, "/boot/efi").Assigned() {
		t.Error("an unusable ESP must be cleared rather than left in place")
	}
}

func findEntry(entries []MountEntry, mp string) MountEntry {
	for _, e := range entries {
		if e.MountPoint == mp {
			return e
		}
	}
	return MountEntry{}
}

/* The backstop. This is the check that stops a restore from deleting a
 * filesystem through a mount point that IS the target root. */
func TestVerifyNoAliasedMounts(t *testing.T) {
	target := t.TempDir()
	os.MkdirAll(filepath.Join(target, "home"), 0755)
	os.MkdirAll(filepath.Join(target, "boot"), 0755)

	entries := []MountEntry{
		{MountPoint: "/"},
		{MountPoint: "/home"},
		{MountPoint: "/boot"},
	}

	// An ordinary layout: subdirectories share st_dev with the target but never
	// st_ino.
	if err := VerifyNoAliasedMounts(target+"/", entries, false); err != nil {
		t.Errorf("an ordinary layout was rejected: %v", err)
	}

	// A mount point that resolves to the target root itself.
	os.Remove(filepath.Join(target, "home"))
	if err := os.Symlink(target, filepath.Join(target, "home")); err != nil {
		t.Skipf("cannot create the alias: %v", err)
	}
	err := VerifyNoAliasedMounts(target+"/", entries, false)
	if err == nil {
		t.Fatal("an aliased mount point was NOT detected -- a restore would delete the target through it")
	}
	if !errors.Is(err, ErrAliasedMount) {
		t.Errorf("err = %v, want ErrAliasedMount", err)
	}
	// The message has to say what to do about it.
	if !strings.Contains(err.Error(), "Keep on Root Device") {
		t.Errorf("the error must name the remedy: %v", err)
	}
	if !strings.Contains(err.Error(), "Nothing was changed") {
		t.Errorf("the error must say nothing was changed: %v", err)
	}
}

// Restoring in place mounts nothing; / is the target by definition.
func TestVerifySkipsCurrentSystem(t *testing.T) {
	if err := VerifyNoAliasedMounts("", []MountEntry{{MountPoint: "/home"}}, true); err != nil {
		t.Errorf("the current-system path needs no check: %v", err)
	}
}

// An unreadable target is a failure, not something to proceed past.
func TestVerifyUnreadableTarget(t *testing.T) {
	err := VerifyNoAliasedMounts("/definitely/not/here/", []MountEntry{{MountPoint: "/"}}, false)
	if err == nil {
		t.Error("an unreadable restore target must be an error")
	}
}

// A mount point that does not exist yet is fine: the transfer creates it.
func TestVerifyAbsentMountPoint(t *testing.T) {
	target := t.TempDir()
	err := VerifyNoAliasedMounts(target+"/", []MountEntry{
		{MountPoint: "/"},
		{MountPoint: "/not-created-yet"},
	}, false)
	if err != nil {
		t.Errorf("an absent mount point is not an alias: %v", err)
	}
}
