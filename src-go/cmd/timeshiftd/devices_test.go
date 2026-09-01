package main

import (
	"encoding/json"
	"testing"

	"github.com/makeafide/timeshift/src-go/internal/block"
)

/* The filter that made devices.list useless for a GUI.
 *
 * It used to drop every device HasLinuxFilesystem() rejected. A disk carries no
 * filesystem, so every disk was dropped -- and a device tree with no disks in it
 * has nothing for the partitions to hang from. The flag is reported now, and
 * applying it is the client's business.
 */
func TestDeviceInfoReportsTheLinuxFilesystemFlagRatherThanApplyingIt(t *testing.T) {
	disk := &block.Device{Name: "nvme0n1", KName: "nvme0n1", Type: "disk", SizeBytes: 512 << 30}
	if disk.HasLinuxFilesystem() {
		t.Fatal("a bare disk should not count as having a Linux filesystem")
	}

	got := deviceInfo(disk)
	if got.HasLinuxFilesystem {
		t.Error("the flag should be false for a bare disk")
	}
	if got.Type != "disk" || got.Name != "nvme0n1" {
		t.Errorf("the disk must still be described: %+v", got)
	}
}

// pkname is what lets a client rebuild the tree from a flat list.
func TestDeviceInfoCarriesTheParentLink(t *testing.T) {
	part := &block.Device{
		Name: "nvme0n1p2", KName: "nvme0n1p2", PKName: "nvme0n1",
		Type: "part", FSType: "ext4", UUID: "db96-5381",
	}
	got := deviceInfo(part)
	if got.PKName != "nvme0n1" {
		t.Errorf("pkname = %q, want the parent disk", got.PKName)
	}
	if !got.HasLinuxFilesystem {
		t.Error("an ext4 partition has a Linux filesystem")
	}
}

/* Vendor and Model are trimmed; Label and PartLabel are not.
 *
 * lsblk pads the first two out of the SCSI inquiry strings and they go straight
 * into a UI label. A filesystem label may legitimately carry surrounding
 * spaces, and trimming one would stop it matching the device it names.
 */
func TestDeviceInfoTrimsTheInquiryStringsAndNothingElse(t *testing.T) {
	got := deviceInfo(&block.Device{
		Vendor: "ATA     ", Model: "  Samsung SSD 990  ",
		Label: " my backup ", PartLabel: " esp ",
	})
	if got.Vendor != "ATA" {
		t.Errorf("vendor = %q, want it trimmed", got.Vendor)
	}
	if got.Model != "Samsung SSD 990" {
		t.Errorf("model = %q, want it trimmed", got.Model)
	}
	if got.Label != " my backup " {
		t.Errorf("label = %q, want it left alone", got.Label)
	}
	if got.PartLabel != " esp " {
		t.Errorf("partlabel = %q, want it left alone", got.PartLabel)
	}
}

/* mount_points must be an empty array, never null.
 *
 * A client reading the wire iterates it; JSON null is not an array, and a Vala
 * caller asking a null node for its array gets nothing useful back. Building
 * the slice with make() rather than declaring it is what makes the difference,
 * so it is worth a test rather than a comment.
 */
func TestDeviceInfoEncodesEmptyMountsAsAnArray(t *testing.T) {
	raw, err := json.Marshal(deviceInfo(&block.Device{Name: "sdb"}))
	if err != nil {
		t.Fatal(err)
	}
	var back map[string]json.RawMessage
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	if string(back["mount_points"]) != "[]" {
		t.Errorf("mount_points = %s, want []", back["mount_points"])
	}
}
