package restore

import (
	"strings"

	"github.com/makeafide/timeshift/src-go/internal/block"
)

/* Deciding, by default, which device goes where.
 *
 * The snapshot carries the fstab of the machine it was taken on. That fstab is
 * the statement of what the restored system EXPECTS: a root, maybe a separate
 * /home, maybe a /boot and an ESP. This turns it into a selection over the
 * devices that actually exist here.
 *
 * A mount point whose device cannot be found is kept in the list with no device
 * rather than dropped. Dropping it would hide the decision: the restored system
 * would come up with /home on the root filesystem and nothing would ever have
 * said so.
 */

// BuildMountList turns a snapshot's fstab into a default selection.
//
// excludes are the backup exclude patterns: a directory the snapshot did not
// copy must not get a device, because nothing would be restored onto it.
func BuildMountList(fstabText, crypttabText string, devices []*block.Device, excludes []string) []MountEntry {

	crypttab := ParseCryptTab(crypttabText)

	var out []MountEntry
	for _, e := range ParseFsTab(fstabText) {
		if e.IsComment || e.IsBlank {
			continue
		}
		if !e.IsForSystemDirectory() {
			continue
		}
		if isExcludedMountPoint(e.MountPoint, excludes) {
			continue
		}

		entry := MountEntry{
			MountPoint: e.MountPoint,
			Options:    e.Options,
			IsESP:      e.MountPoint == "/boot/efi",
		}

		if dev := findDevice(e, crypttab, devices); dev != nil {
			entry.DeviceUUID = dev.UUID
			entry.DevicePath = dev.Path
			entry.DiskPath = dev.DiskPath()
		}

		out = append(out, entry)
	}

	return out
}

/* findDevice resolves an fstab entry against the devices present here.
 *
 * By UUID first, because a device name is not stable across machines or even
 * across boots. A /dev/mapper/ name is looked up through crypttab instead: the
 * mapped name may differ on this system, so the entry is matched to the LUKS
 * CONTAINER's uuid, which does not change.
 */
func findDevice(e FsTabEntry, crypttab []CryptTabEntry, devices []*block.Device) *block.Device {

	if uuid := uuidFromDeviceRef(e.Device); uuid != "" {
		if d := byUUID(devices, uuid); d != nil {
			return d
		}
	}

	if strings.HasPrefix(e.Device, "/dev/mapper/") {
		mapped := strings.TrimPrefix(e.Device, "/dev/mapper/")
		for _, c := range crypttab {
			if c.IsComment || c.IsBlank || c.MappedName != mapped {
				continue
			}
			parentUUID := uuidFromDeviceRef(c.Device)
			if parentUUID == "" {
				break
			}
			container := byUUID(devices, parentUUID)
			if container == nil {
				break
			}
			/* An unlocked container has the usable filesystem as its child. A
			 * locked one is returned as itself, so the caller can see that a
			 * device was identified but needs a passphrase, rather than seeing
			 * nothing at all. */
			if len(container.Children) > 0 {
				return container.Children[0]
			}
			return container
		}
	}

	// A plain device path, last, and only as written.
	if strings.HasPrefix(e.Device, "/dev/") {
		for _, d := range devices {
			if d.Path == e.Device {
				return d
			}
		}
	}

	return nil
}

// uuidFromDeviceRef reads a UUID out of "UUID=x" or "/dev/disk/by-uuid/x".
func uuidFromDeviceRef(ref string) string {
	if v, ok := strings.CutPrefix(ref, "UUID="); ok {
		return strings.Trim(v, `"`)
	}
	if v, ok := strings.CutPrefix(ref, "/dev/disk/by-uuid/"); ok {
		return v
	}
	return ""
}

func byUUID(devices []*block.Device, uuid string) *block.Device {
	for _, d := range devices {
		if d.UUID == uuid {
			return d
		}
	}
	return nil
}

/* isExcludedMountPoint reports whether the backup skipped this directory.
 *
 * Mounting a device at a directory the snapshot never copied gives an empty
 * filesystem where the user expects their data, which is worse than leaving it
 * unmounted and saying so.
 */
func isExcludedMountPoint(mountPoint string, excludes []string) bool {
	for _, suffix := range []string{"/*", "/**", "/***"} {
		pattern := mountPoint + suffix
		for _, ex := range excludes {
			if strings.TrimSpace(ex) == pattern {
				return true
			}
		}
	}
	return false
}

// SnapshotNeedsESP reports whether the snapshot's fstab expects an EFI System
// Partition. A system that booted via UEFI will not boot without one.
func SnapshotNeedsESP(fstabText string) bool {
	for _, e := range ParseFsTab(fstabText) {
		if !e.IsComment && !e.IsBlank && e.MountPoint == "/boot/efi" {
			return true
		}
	}
	return false
}

// FSTypes maps each selected device's UUID to its filesystem type, which fstab
// needs and the mount plan does not carry.
func FSTypes(entries []MountEntry, devices []*block.Device) map[string]string {
	out := map[string]string{}
	for _, e := range entries {
		if !e.Assigned() {
			continue
		}
		if d := byUUID(devices, e.DeviceUUID); d != nil && d.FSType != "" {
			out[e.DeviceUUID] = d.FSType
		}
	}
	return out
}

// EncryptedDevicesFor lists the LUKS containers behind the selected devices, so
// crypttab can name the container rather than the unlocked device inside it.
func EncryptedDevicesFor(entries []MountEntry, devices []*block.Device) []EncryptedDevice {
	var out []EncryptedDevice
	for _, e := range entries {
		if !e.Assigned() {
			continue
		}
		d := byUUID(devices, e.DeviceUUID)
		if d == nil || d.Parent == nil || !d.Parent.IsEncryptedPartition() {
			continue
		}
		out = append(out, EncryptedDevice{
			MappedName: d.Name,
			ParentUUID: d.Parent.UUID,
		})
	}
	return out
}
