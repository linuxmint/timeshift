package restore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The real fstab from this machine, so the parser is checked against something
// nobody wrote to be parsed.
func TestParseRealFsTab(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "testdata", "fstab", "laptop.fstab"))
	if err != nil {
		t.Fatal(err)
	}
	entries := ParseFsTab(string(raw))

	var root, esp *FsTabEntry
	comments := 0
	for i := range entries {
		switch {
		case entries[i].IsComment:
			comments++
		case entries[i].MountPoint == "/":
			root = &entries[i]
		case entries[i].MountPoint == "/boot/efi":
			esp = &entries[i]
		}
	}
	if comments == 0 {
		t.Error("comments were not preserved")
	}
	if root == nil {
		t.Fatal("the root entry was not found")
	}
	/* Either form is valid and both occur: Ubuntu's installer writes
	 * /dev/disk/by-uuid/<uuid> on this machine, while a Timeshift restore
	 * rewrites entries as UUID=<uuid>. IsForSystemDirectory accepts both,
	 * which is what matters -- it decides whether an entry may be pruned. */
	if !strings.HasPrefix(root.Device, "UUID=") &&
		!strings.HasPrefix(root.Device, "/dev/") {
		t.Errorf("root device = %q, want a UUID= or /dev reference", root.Device)
	}
	if !root.IsForSystemDirectory() {
		t.Errorf("the root entry must count as a system directory: %+v", root)
	}
	if root.Type != "ext4" {
		t.Errorf("root type = %q", root.Type)
	}
	if esp == nil || esp.Type != "vfat" {
		t.Errorf("esp = %+v", esp)
	}
}

// A snapshot carries the fstab of the machine it came from. Restored onto other
// partitions every UUID is wrong, and the system boots to an initramfs prompt.
func TestFixFsTabRewritesUUIDs(t *testing.T) {
	entries := ParseFsTab(`# original
UUID=old-root / ext4 defaults 0 1
UUID=old-esp /boot/efi vfat umask=0077 0 1
`)
	mounts := []MountEntry{
		{MountPoint: "/", DeviceUUID: "new-root"},
		{MountPoint: "/boot/efi", DeviceUUID: "new-esp"},
	}
	fs := map[string]string{"new-root": "ext4", "new-esp": "vfat"}

	out := FixFsTab(entries, mounts, fs)
	rendered := RenderFsTab(out, true)

	if !strings.Contains(rendered, "UUID=new-root\t/\text4") {
		t.Errorf("root was not repointed:\n%s", rendered)
	}
	if !strings.Contains(rendered, "UUID=new-esp\t/boot/efi\tvfat") {
		t.Errorf("esp was not repointed:\n%s", rendered)
	}
	if strings.Contains(rendered, "old-root") || strings.Contains(rendered, "old-esp") {
		t.Errorf("an old UUID survived:\n%s", rendered)
	}
	// The user's own options are kept.
	if !strings.Contains(rendered, "umask=0077") {
		t.Errorf("mount options were lost:\n%s", rendered)
	}
	if !strings.Contains(rendered, "# original") {
		t.Errorf("the comment was lost:\n%s", rendered)
	}
}

// A subvol= option on a non-btrfs filesystem makes mount fail outright. It is
// left over from a snapshot taken on btrfs and restored onto ext4.
func TestSubvolStrippedOnNonBtrfs(t *testing.T) {
	entries := ParseFsTab("UUID=old / btrfs defaults,subvol=@ 0 1\n")
	out := FixFsTab(entries,
		[]MountEntry{{MountPoint: "/", DeviceUUID: "new"}},
		map[string]string{"new": "ext4"})

	rendered := RenderFsTab(out, false)
	if strings.Contains(rendered, "subvol") {
		t.Errorf("subvol= survived onto an ext4 entry:\n%s", rendered)
	}

	// On btrfs it must be kept: it is what selects the subvolume.
	out = FixFsTab(ParseFsTab("UUID=old / btrfs defaults,subvol=@ 0 1\n"),
		[]MountEntry{{MountPoint: "/", DeviceUUID: "new"}},
		map[string]string{"new": "btrfs"})
	if !strings.Contains(RenderFsTab(out, false), "subvol=@") {
		t.Error("subvol= was stripped from a btrfs entry")
	}
}

// A system entry the restore did not mount would make the restored system wait
// at boot for a device that is not there.
func TestUnmountedSystemEntriesRemoved(t *testing.T) {
	entries := ParseFsTab(`UUID=r / ext4 defaults 0 1
UUID=h /home ext4 defaults 0 2
UUID=d /mnt/data ext4 defaults 0 2
`)
	out := FixFsTab(entries,
		[]MountEntry{{MountPoint: "/", DeviceUUID: "new-root"}},
		map[string]string{"new-root": "ext4"})
	rendered := RenderFsTab(out, false)

	if strings.Contains(rendered, "/home") {
		t.Errorf("an unmounted system entry survived:\n%s", rendered)
	}
	// A data disk is not the restore's business to remove.
	if !strings.Contains(rendered, "/mnt/data") {
		t.Errorf("a non-system entry was removed:\n%s", rendered)
	}
}

// A mount point the snapshot's fstab never mentioned still needs an entry.
func TestNewMountPointGetsAnEntry(t *testing.T) {
	out := FixFsTab(ParseFsTab("UUID=r / ext4 defaults 0 1\n"),
		[]MountEntry{
			{MountPoint: "/", DeviceUUID: "new-root"},
			{MountPoint: "/home", DeviceUUID: "new-home"},
		},
		map[string]string{"new-root": "ext4", "new-home": "xfs"})

	rendered := RenderFsTab(out, false)
	if !strings.Contains(rendered, "UUID=new-home\t/home\txfs") {
		t.Errorf("a newly mounted directory got no entry:\n%s", rendered)
	}
}

// Parents must be mounted before their children.
func TestRenderSortsByMountPoint(t *testing.T) {
	out := FixFsTab(ParseFsTab(""),
		[]MountEntry{
			{MountPoint: "/boot/efi", DeviceUUID: "e"},
			{MountPoint: "/", DeviceUUID: "r"},
			{MountPoint: "/boot", DeviceUUID: "b"},
		},
		map[string]string{"e": "vfat", "r": "ext4", "b": "ext4"})

	rendered := RenderFsTab(out, false)
	iRoot := strings.Index(rendered, "\t/\t")
	iBoot := strings.Index(rendered, "\t/boot\t")
	iESP := strings.Index(rendered, "\t/boot/efi\t")
	if !(iRoot < iBoot && iBoot < iESP) {
		t.Errorf("entries are not ordered parent-first:\n%s", rendered)
	}
}

func TestIsForSystemDirectory(t *testing.T) {
	cases := []struct {
		device, mp string
		want       bool
	}{
		{"UUID=x", "/", true},
		{"UUID=x", "/home", true},
		{"/dev/sda1", "/boot", true},
		{"UUID=x", "/mnt/data", false},
		{"UUID=x", "/media/usb", false},
		{"none", "/proc", false},
		{"tmpfs", "/tmp", false}, // not a /dev or UUID= reference
		{"UUID=x", "relative", false},
	}
	for _, c := range cases {
		e := FsTabEntry{Device: c.device, MountPoint: c.mp}
		if got := e.IsForSystemDirectory(); got != c.want {
			t.Errorf("IsForSystemDirectory(%q %q) = %v, want %v", c.device, c.mp, got, c.want)
		}
	}
}

// nofail everywhere: a restored system that cannot find one encrypted volume
// should still boot far enough to be fixed, rather than dropping to an
// initramfs prompt where there is no way to investigate.
func TestFixCryptTabAddsNofail(t *testing.T) {
	entries := ParseCryptTab(`# crypt
sda3_crypt UUID=container none luks
other UUID=two none luks,nofail
`)
	out := FixCryptTab(entries, nil)
	rendered := RenderCryptTab(out)

	if strings.Count(rendered, "nofail") != 2 {
		t.Errorf("every entry needs nofail exactly once:\n%s", rendered)
	}
	if !strings.Contains(rendered, "# crypt") {
		t.Error("the comment was lost")
	}
}

// An encrypted device the restore mounted through, that crypttab does not
// describe, must be added -- or the restored system cannot unlock it.
func TestFixCryptTabAddsMissingDevice(t *testing.T) {
	out := FixCryptTab(ParseCryptTab(""), []EncryptedDevice{
		{MappedName: "sda3_crypt", ParentUUID: "container-uuid"},
	})
	rendered := RenderCryptTab(out)

	if !strings.Contains(rendered, "UUID=container-uuid") {
		t.Errorf("the encrypted device was not added:\n%s", rendered)
	}
	if !strings.Contains(rendered, "luks,nofail") {
		t.Errorf("the added entry needs luks,nofail:\n%s", rendered)
	}

	// And an already-known device is not duplicated.
	out = FixCryptTab(ParseCryptTab("x UUID=container-uuid none luks\n"),
		[]EncryptedDevice{{MappedName: "x", ParentUUID: "container-uuid"}})
	if strings.Count(RenderCryptTab(out), "container-uuid") != 1 {
		t.Errorf("an existing device was duplicated:\n%s", RenderCryptTab(out))
	}
}

func TestParseRealCryptTab(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "testdata", "fstab", "laptop.crypttab"))
	if err != nil {
		t.Fatal(err)
	}
	// This machine has no encrypted volumes, so the file is a comment only --
	// which must round-trip rather than becoming an empty file.
	entries := ParseCryptTab(string(raw))
	out := RenderCryptTab(FixCryptTab(entries, nil))
	if !strings.Contains(out, "#") {
		t.Errorf("a comment-only crypttab lost its content: %q", out)
	}
}
