package restore

import (
	"testing"

	"github.com/makeafide/timeshift/src-go/internal/block"
)

func devs() []*block.Device {
	root := &block.Device{Name: "sda2", Path: "/dev/sda2", UUID: "root-uuid", FSType: "ext4", Type: "part"}
	home := &block.Device{Name: "sda3", Path: "/dev/sda3", UUID: "home-uuid", FSType: "ext4", Type: "part"}
	esp := &block.Device{Name: "sda1", Path: "/dev/sda1", UUID: "ESP-UUID", FSType: "vfat", Type: "part"}
	return []*block.Device{root, home, esp}
}

const snapshotFsTab = `# <file system> <mount point> <type> <options> <dump> <pass>
UUID=root-uuid / ext4 defaults 0 1
UUID=home-uuid /home ext4 defaults 0 2
UUID=ESP-UUID /boot/efi vfat umask=0077 0 1
UUID=data-uuid /mnt/data ext4 defaults 0 2
`

func entryFor(t *testing.T, list []MountEntry, mp string) MountEntry {
	t.Helper()
	for _, e := range list {
		if e.MountPoint == mp {
			return e
		}
	}
	t.Fatalf("no entry for %q in %+v", mp, list)
	return MountEntry{}
}

func TestBuildMountListMatchesByUUID(t *testing.T) {
	list := BuildMountList(snapshotFsTab, "", devs(), nil)

	if got := entryFor(t, list, "/").DeviceUUID; got != "root-uuid" {
		t.Errorf("root device = %q", got)
	}
	if got := entryFor(t, list, "/home").DevicePath; got != "/dev/sda3" {
		t.Errorf("home device = %q", got)
	}
	if !entryFor(t, list, "/boot/efi").IsESP {
		t.Error("/boot/efi was not marked as an ESP")
	}

	// /mnt/data is not a system directory: rewriting a user's data-disk entry
	// has nothing to do with the restore.
	for _, e := range list {
		if e.MountPoint == "/mnt/data" {
			t.Error("a non-system mount point was included")
		}
	}
}

/* A mount point whose device is absent must stay in the list with no device.
 *
 * Dropping it hides the decision: the restored system comes up with /home on
 * the root filesystem and nothing ever said so.
 */
func TestMissingDeviceIsListedNotDropped(t *testing.T) {
	only := []*block.Device{{Name: "sda2", Path: "/dev/sda2", UUID: "root-uuid", FSType: "ext4"}}

	list := BuildMountList(snapshotFsTab, "", only, nil)

	home := entryFor(t, list, "/home")
	if home.Assigned() {
		t.Fatalf("/home was assigned a device that does not exist: %+v", home)
	}
}

// A directory the backup excluded must not get a device: mounting one there
// gives an empty filesystem where the user expects their data.
func TestExcludedMountPointsAreSkipped(t *testing.T) {
	list := BuildMountList(snapshotFsTab, "", devs(), []string{"/home/**"})

	for _, e := range list {
		if e.MountPoint == "/home" {
			t.Fatal("/home was offered a device even though the backup excluded it")
		}
	}
}

/* An encrypted root is named in fstab by its mapped name, which may differ on
 * this machine. It has to be resolved through crypttab to the LUKS container's
 * uuid, which does not change.
 */
func TestEncryptedRootIsResolvedThroughCrypttab(t *testing.T) {
	container := &block.Device{Name: "sda2", Path: "/dev/sda2", UUID: "luks-uuid", FSType: "crypto_luks", Type: "part"}
	unlocked := &block.Device{Name: "root", Path: "/dev/mapper/root", UUID: "inner-uuid", FSType: "ext4", Type: "crypt", Parent: container}
	container.Children = []*block.Device{unlocked}

	fstab := "/dev/mapper/cryptroot / ext4 defaults 0 1\n"
	crypttab := "cryptroot UUID=luks-uuid none luks\n"

	list := BuildMountList(fstab, crypttab, []*block.Device{container, unlocked}, nil)

	root := entryFor(t, list, "/")
	if root.DeviceUUID != "inner-uuid" {
		t.Fatalf("root resolved to %q, want the unlocked filesystem inside the container", root.DeviceUUID)
	}

	// crypttab must name the CONTAINER, not the device inside it.
	enc := EncryptedDevicesFor(list, []*block.Device{container, unlocked})
	if len(enc) != 1 || enc[0].ParentUUID != "luks-uuid" {
		t.Fatalf("encrypted devices = %+v, want the container uuid", enc)
	}
}

// A container that is still locked is reported as identified-but-locked rather
// than as absent, so the caller can ask for a passphrase instead of silently
// leaving the mount point empty.
func TestLockedContainerIsStillIdentified(t *testing.T) {
	container := &block.Device{Name: "sda2", Path: "/dev/sda2", UUID: "luks-uuid", FSType: "crypto_luks", Type: "part"}

	list := BuildMountList("/dev/mapper/cryptroot / ext4 defaults 0 1\n",
		"cryptroot UUID=luks-uuid none luks\n", []*block.Device{container}, nil)

	root := entryFor(t, list, "/")
	if root.DeviceUUID != "luks-uuid" {
		t.Fatalf("a locked container was not identified: %+v", root)
	}
}

func TestSnapshotNeedsESP(t *testing.T) {
	if !SnapshotNeedsESP(snapshotFsTab) {
		t.Error("an fstab with /boot/efi should need an ESP")
	}
	if SnapshotNeedsESP("UUID=x / ext4 defaults 0 1\n") {
		t.Error("an fstab with no /boot/efi should not need one")
	}
}

func TestFSTypesAreCollected(t *testing.T) {
	list := BuildMountList(snapshotFsTab, "", devs(), nil)
	types := FSTypes(list, devs())

	if types["root-uuid"] != "ext4" {
		t.Errorf("root fstype = %q", types["root-uuid"])
	}
	if types["ESP-UUID"] != "vfat" {
		t.Errorf("ESP fstype = %q", types["ESP-UUID"])
	}
}
