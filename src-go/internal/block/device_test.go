package block

import (
	"os"
	"path/filepath"
	"testing"
)

func load(t *testing.T, parts ...string) string {
	t.Helper()
	p := filepath.Join(append([]string{"..", "..", "testdata"}, parts...)...)
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read %s: %v", p, err)
	}
	return string(b)
}

func TestParseRealLsblk(t *testing.T) {
	devices := ParseLsblk(load(t, "lsblk", "laptop-nvme-ext4.pairs"))

	if len(devices) != 21 {
		t.Fatalf("parsed %d devices, want 21", len(devices))
	}

	disk := FindByPath(devices, "/dev/nvme0n1")
	if disk == nil {
		t.Fatal("the NVMe disk is missing")
	}
	if disk.Type != "disk" {
		t.Errorf("type = %q", disk.Type)
	}
	// A model with spaces in it is exactly what a regex split on whitespace
	// mangles.
	if disk.Model != "Samsung SSD 970 EVO Plus 500GB" {
		t.Errorf("model = %q", disk.Model)
	}
	if disk.Serial != "S58SNM0W621781K" {
		t.Errorf("serial = %q", disk.Serial)
	}
	if disk.SizeBytes != 500107862016 {
		t.Errorf("size = %d", disk.SizeBytes)
	}
	if len(disk.Children) != 2 {
		t.Errorf("disk has %d children, want 2", len(disk.Children))
	}

	root := FindByUUID(devices, "db965381-9f0c-453e-a508-0ac5b4cbb48d")
	if root == nil {
		t.Fatal("the root partition is missing")
	}
	if root.Path != "/dev/nvme0n1p2" || root.FSType != "ext4" || root.Type != "part" {
		t.Errorf("root = %+v", root)
	}
	if root.Parent != disk {
		t.Error("root partition is not linked to its disk")
	}
	if len(root.MountPoints) != 1 || root.MountPoints[0].Path != "/" {
		t.Errorf("root mount points = %+v", root.MountPoints)
	}

	esp := FindByPath(devices, "/dev/nvme0n1p1")
	if esp == nil || esp.FSType != "vfat" {
		t.Fatalf("esp = %+v", esp)
	}
	if esp.PartUUID != "3f1a0616-1f23-48f1-a251-3eb4c3eae03a" {
		t.Errorf("partuuid = %q", esp.PartUUID)
	}

	// The snap loop devices are what detect_system_devices() has to skip when
	// picking sys_root, so they must survive the parse rather than be filtered
	// out here.
	loops := 0
	for _, d := range devices {
		if d.Type == "loop" {
			loops++
		}
	}
	if loops != 18 {
		t.Errorf("parsed %d loop devices, want 18", loops)
	}
}

// The whole LUKS-on-LVM chain has to link up, because every encrypted-install
// code path keys off exactly these relationships.
func TestParseLUKSOnLVM(t *testing.T) {
	devices := ParseLsblk(load(t, "lsblk", "synthetic-luks-lvm.pairs"))

	container := FindByPath(devices, "/dev/sda3")
	if container == nil {
		t.Fatal("LUKS container missing")
	}
	// crypto_LUKS is normalised to luks at parse time; anything comparing
	// against the raw lsblk spelling will not match.
	if container.FSType != "luks" {
		t.Errorf("fstype = %q, want luks (normalised)", container.FSType)
	}
	if !container.IsEncryptedPartition() {
		t.Error("IsEncryptedPartition false for the container")
	}

	mapper := FindByPath(devices, "/dev/dm-0")
	if mapper == nil {
		t.Fatal("unlocked mapper device missing")
	}
	if mapper.Name != "sda3_crypt" {
		t.Errorf("name = %q", mapper.Name)
	}
	if !mapper.IsOnEncryptedPartition() {
		t.Error("IsOnEncryptedPartition false for the crypt device")
	}
	if mapper.FSType != "lvm2" {
		t.Errorf("mapper fstype = %q, want lvm2 (normalised)", mapper.FSType)
	}
	if mapper.Parent != container {
		t.Error("mapper is not linked to its LUKS container")
	}

	lvRoot := FindByPath(devices, "/dev/dm-1")
	if lvRoot == nil || lvRoot.Type != "lvm" {
		t.Fatalf("root LV = %+v", lvRoot)
	}
	if lvRoot.Parent != mapper {
		t.Error("root LV is not linked to the mapper device")
	}
	if lvRoot.ToplevelParent() != FindByPath(devices, "/dev/sda") {
		t.Error("walking up from the LV does not reach the disk")
	}

	// The Device column of `--list-devices` for a device-mapper node.
	if got := lvRoot.NameWithParent(); got != "/dev/dm-1" {
		// dm-0 is a crypt, not a part, so no suffix is added.
		t.Errorf("NameWithParent = %q, want /dev/dm-1", got)
	}
	if got := mapper.NameWithParent(); got != "/dev/dm-0 (sda3)" {
		t.Errorf("NameWithParent = %q, want /dev/dm-0 (sda3)", got)
	}
}

func TestHasLinuxFilesystem(t *testing.T) {
	cases := map[string]bool{
		"ext4": true, "btrfs": true, "xfs": true, "zfs_member": true,
		"luks": true, "crypt": true, "lvm2": true,
		"vfat": false, "squashfs": false, "swap": false, "": false, "ntfs": false,
	}
	for fs, want := range cases {
		d := &Device{FSType: fs}
		if got := d.HasLinuxFilesystem(); got != want {
			t.Errorf("HasLinuxFilesystem(%q) = %v, want %v", fs, got, want)
		}
	}
}

// This is the exact set --list-devices shows, so it is worth pinning.
func TestListDevicesFilterOnRealHardware(t *testing.T) {
	devices := ParseLsblk(load(t, "lsblk", "laptop-nvme-ext4.pairs"))
	var shown []string
	for _, d := range devices {
		if d.HasLinuxFilesystem() {
			shown = append(shown, d.Path)
		}
	}
	if len(shown) != 1 || shown[0] != "/dev/nvme0n1p2" {
		t.Errorf("--list-devices would show %v, want just the ext4 root", shown)
	}
}

func TestParseDF(t *testing.T) {
	devices := ParseLsblk(load(t, "lsblk", "laptop-nvme-ext4.pairs"))
	ParseDF(load(t, "df", "laptop.txt"), devices)

	root := FindByPath(devices, "/dev/nvme0n1p2")
	if root.UsedBytes != 54442164224 {
		t.Errorf("used = %d", root.UsedBytes)
	}
	if root.AvailableBytes != 410589323264 {
		t.Errorf("available = %d", root.AvailableBytes)
	}
	if root.UsedPercent != "12%" {
		t.Errorf("used%% = %q", root.UsedPercent)
	}
	// df's filesystem size is recorded separately; SizeBytes stays lsblk's
	// device size, because that is what --list-devices prints.
	if root.FSSizeBytes != 489997189120 {
		t.Errorf("fs size = %d, want df's figure", root.FSSizeBytes)
	}
	if root.SizeBytes != 498978521088 {
		t.Errorf("size = %d, want lsblk's device size untouched by df", root.SizeBytes)
	}
	if root.FreeBytes() != 410589323264 {
		t.Errorf("free = %d", root.FreeBytes())
	}

	// tmpfs lines name no block device and must not match anything.
	for _, d := range devices {
		if d.Type == "loop" && d.UsedBytes != 0 {
			t.Errorf("%s picked up df figures it should not have", d.Path)
		}
	}
}

// An unmounted device has no df row, and reporting its free space as the whole
// disk would let a caller believe a snapshot fits somewhere it cannot be
// written at all.
func TestFreeBytesIsZeroWithoutUsage(t *testing.T) {
	d := &Device{AvailableBytes: 999, UsedBytes: 0}
	if d.FreeBytes() != 0 {
		t.Errorf("FreeBytes = %d, want 0 when df reported no usage", d.FreeBytes())
	}
}

func TestParseMounts(t *testing.T) {
	devices := ParseLsblk(load(t, "lsblk", "laptop-nvme-ext4.pairs"))
	ParseMounts(load(t, "mounts", "laptop.txt"), devices)

	root := FindByPath(devices, "/dev/nvme0n1p2")
	if !root.IsMounted() {
		t.Fatal("root is not mounted")
	}
	found := false
	for _, m := range root.MountPoints {
		if m.Path == "/" {
			found = true
			if m.Options == "" {
				t.Error("mount options were dropped")
			}
		}
	}
	if !found {
		t.Errorf("root mount points = %+v", root.MountPoints)
	}

	if MountedAt(devices, "/boot/efi") == nil {
		t.Error("MountedAt(/boot/efi) found nothing")
	}
	if MountedAt(devices, "/nowhere-at-all") != nil {
		t.Error("MountedAt matched a path that is not mounted")
	}
}

func TestParsePairsHandlesAwkwardValues(t *testing.T) {
	line := `NAME="weird" KNAME="sdz" LABEL="  spaced  " UUID="" TYPE="part" ` +
		`FSTYPE="ext4" SIZE="1024" MOUNTPOINT="/mnt/my stuff" MODEL="Some Vendor Model X" ` +
		`RO="0" HOTPLUG="1" MAJ:MIN="8:400" PARTLABEL="Label With Spaces" PARTUUID="p-uuid" ` +
		`PKNAME="sdz9" VENDOR="ACME    " SERIAL="S/N 123" REV="1.0"`

	devices := ParseLsblk(line)
	if len(devices) != 1 {
		t.Fatalf("parsed %d devices", len(devices))
	}
	d := devices[0]

	// Labels keep their surrounding whitespace: Device.vala does not strip
	// them, and a label really can have them.
	if d.Label != "  spaced  " {
		t.Errorf("label = %q, leading/trailing spaces must survive", d.Label)
	}
	if d.PartLabel != "Label With Spaces" {
		t.Errorf("partlabel = %q", d.PartLabel)
	}
	if d.Model != "Some Vendor Model X" {
		t.Errorf("model = %q", d.Model)
	}
	if len(d.MountPoints) != 1 || d.MountPoints[0].Path != "/mnt/my stuff" {
		t.Errorf("mount point with a space = %+v", d.MountPoints)
	}
	if d.Serial != "S/N 123" {
		t.Errorf("serial = %q", d.Serial)
	}
	if d.Vendor != "ACME" {
		t.Errorf("vendor = %q, should be trimmed", d.Vendor)
	}
	if !d.Removable {
		t.Error("HOTPLUG=1 should mean removable")
	}
	if d.Major != 8 || d.Minor != 400 {
		t.Errorf("maj:min = %d:%d", d.Major, d.Minor)
	}
}

// The Vala regex dropped any line whose value contained a quote. lsblk escapes
// one as \x22, so it can happen.
func TestParsePairsUnescapes(t *testing.T) {
	line := `NAME="odd" KNAME="sdq" LABEL="say \x22hi\x22" TYPE="part" FSTYPE="ext4" SIZE="1"`
	devices := ParseLsblk(line)
	if len(devices) != 1 {
		t.Fatalf("a line with an escaped quote was dropped")
	}
	if devices[0].Label != `say "hi"` {
		t.Errorf("label = %q", devices[0].Label)
	}
}

func TestUnescapeMountPath(t *testing.T) {
	if got := unescapeMount(`/mnt/my\040drive`); got != "/mnt/my drive" {
		t.Errorf("unescapeMount = %q", got)
	}
}

func TestSubvolumeName(t *testing.T) {
	cases := map[string]string{
		"rw,relatime,subvol=/@":     "@",
		"rw,subvol=@home":           "@home",
		"rw,subvol=/nested/path":    "/nested/path",
		"rw,relatime":               "",
		"rw,subvolid=257,subvol=/@": "@",
	}
	for opts, want := range cases {
		m := MountPoint{Options: opts}
		if got := m.SubvolumeName(); got != want {
			t.Errorf("SubvolumeName(%q) = %q, want %q", opts, got, want)
		}
	}
}

func TestFindByPathForms(t *testing.T) {
	devices := ParseLsblk(load(t, "lsblk", "laptop-nvme-ext4.pairs"))
	uuid := "db965381-9f0c-453e-a508-0ac5b4cbb48d"

	for _, ref := range []string{
		"/dev/nvme0n1p2",
		"nvme0n1p2",
		"UUID=" + uuid,
		"/dev/disk/by-uuid/" + uuid,
		"/dev/disk/by-partuuid/722990b4-4870-47e8-bd1e-82ca9d21084e",
	} {
		if d := FindByPath(devices, ref); d == nil || d.UUID != uuid {
			t.Errorf("FindByPath(%q) did not resolve to the root partition", ref)
		}
	}
	if FindByPath(devices, "/dev/nope") != nil {
		t.Error("FindByPath matched a device that does not exist")
	}
	if FindByPath(devices, "") != nil {
		t.Error("FindByPath matched on an empty reference")
	}
}

// Re-running the tree build must not accumulate duplicate children.
func TestBuildTreeIsIdempotent(t *testing.T) {
	devices := ParseLsblk(load(t, "lsblk", "synthetic-luks-lvm.pairs"))
	disk := FindByPath(devices, "/dev/sda")
	first := len(disk.Children)

	BuildTree(devices)
	BuildTree(devices)

	if len(disk.Children) != first {
		t.Errorf("children grew from %d to %d across rebuilds", first, len(disk.Children))
	}
}
