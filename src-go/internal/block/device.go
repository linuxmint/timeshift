// Package block is the block-device model: what Device.vala built out of
// lsblk, df and /proc/mounts.
//
// The shape is the same because the data source is the same -- there is still
// no libblkid binding, and lsblk remains the only thing that reports the whole
// tree in one call. What is different is that there is no process-global cache.
// Device.vala kept a static `device_list` that several helpers silently
// depended on, so whether resolve_device_name() worked at all came down to
// whether something had happened to call get_block_devices_using_lsblk()
// earlier. Here a Scanner holds the list and is passed.
package block

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// Device is one entry from lsblk, plus whatever df and /proc/mounts add.
type Device struct {
	// Identity.
	Name  string // lsblk NAME: vgubuntu-root
	KName string // lsblk KNAME: dm-1
	Path  string // /dev/<KName>

	Label     string // NOT trimmed: labels may carry leading or trailing spaces
	UUID      string
	PartLabel string // also not trimmed
	PartUUID  string

	// Type is disk, part, crypt, lvm, loop, rom, raid*, dmraid.
	Type string

	// FSType is lower-cased and normalised the way Device.vala does it:
	// crypto_luks becomes luks, lvm2_member becomes lvm2. Anything comparing
	// against the raw lsblk spelling will not match.
	FSType string

	SizeBytes int64

	Model    string
	Vendor   string
	Serial   string
	Revision string

	ReadOnly  bool
	Removable bool

	Major int
	Minor int

	// PKName is lsblk's parent KNAME, which is what the tree is built from.
	PKName string

	// Order is the position in lsblk's output, which is already the order a
	// person expects to see devices in.
	Order int

	// MountPoints are where this device is mounted, from lsblk and then from
	// /proc/mounts.
	MountPoints []MountPoint

	// Space, filled in from df. Zero when df did not cover this device --
	// which is most of them, since df only reports mounted filesystems.
	UsedBytes      int64
	AvailableBytes int64
	UsedPercent    string

	// FSSizeBytes is the filesystem's size as df reports it, which is smaller
	// than SizeBytes whenever the filesystem does not fill its partition. Kept
	// separate rather than overwriting SizeBytes: `--list-devices` reads
	// straight from lsblk and prints the DEVICE size, so folding df's figure in
	// would change what that command has always printed.
	FSSizeBytes int64

	Parent   *Device
	Children []*Device
}

// MountPoint is one place a device is mounted.
type MountPoint struct {
	Path    string
	Options string
}

// SubvolumeName extracts subvol= from the mount options, normalising a leading
// slash away for a single-component name. btrfs mode is built on this.
func (m MountPoint) SubvolumeName() string {
	for _, opt := range strings.Split(m.Options, ",") {
		if !strings.HasPrefix(opt, "subvol=") {
			continue
		}
		name := strings.TrimPrefix(opt, "subvol=")
		trimmed := strings.TrimPrefix(name, "/")
		if !strings.Contains(trimmed, "/") {
			return trimmed
		}
		return name
	}
	return ""
}

/* The filesystems Timeshift is willing to treat as a Linux filesystem. This is
 * the list `--list-devices` filters on, so adding to it changes what the CLI
 * offers. Note the entries are compared against the NORMALISED FSType, which is
 * why both "luks" and "crypto_luks" appear -- the second can no longer occur,
 * and is kept so the set still reads as the original did. */
var linuxFilesystems = map[string]bool{
	"ext2": true, "ext3": true, "ext4": true,
	"f2fs": true, "reiserfs": true, "reiser4": true,
	"xfs": true, "jfs": true,
	"zfs": true, "zfs_member": true,
	"btrfs": true,
	"lvm":   true, "lvm2": true, "lvm2_member": true,
	"luks": true, "crypt": true, "crypto_luks": true,
}

// HasLinuxFilesystem reports whether this device could hold a snapshot
// repository or a system to restore.
func (d *Device) HasLinuxFilesystem() bool { return linuxFilesystems[d.FSType] }

// NameWithParent is the device path, with the parent partition's kernel name
// appended when there is one -- "/dev/dm-1 (sda3)". This is what the CLI
// prints in its Device column.
func (d *Device) NameWithParent() string {
	if d.Parent != nil && d.Parent.Type == "part" {
		return fmt.Sprintf("%s (%s)", d.Path, d.Parent.KName)
	}
	return d.Path
}

// IsEncryptedPartition reports a raw LUKS container.
func (d *Device) IsEncryptedPartition() bool {
	return d.Type == "part" && strings.Contains(d.FSType, "luks")
}

// IsOnEncryptedPartition reports the unlocked mapper device sitting on one.
func (d *Device) IsOnEncryptedPartition() bool { return d.Type == "crypt" }

// IsLVMPartition reports an LVM physical volume.
//
// Device.vala's version tests `fstype.contains("lvm2_member")` AFTER the parse
// has already rewritten that value to "lvm2", so the Vala predicate can never
// be true. Matching the normalised spelling here makes it actually work; the
// only caller is device selection, where the Vala behaviour was to silently
// classify a PV as an ordinary device.
func (d *Device) IsLVMPartition() bool {
	return d.Type == "part" && strings.Contains(d.FSType, "lvm2")
}

// IsMounted reports whether the device is mounted anywhere.
func (d *Device) IsMounted() bool { return len(d.MountPoints) > 0 }

// FreeBytes is the space available on this device.
//
// Device.vala returns 0 whenever used_bytes is 0, which looks like a guard
// against a bogus reading and is kept: df reports nothing for an unmounted
// device, and reporting its "free space" as the whole disk would let a caller
// believe a snapshot would fit somewhere it cannot even be written.
func (d *Device) FreeBytes() int64 {
	if d.UsedBytes == 0 {
		return 0
	}
	return d.AvailableBytes
}

// HasParent reports whether the tree gave this device a parent.
func (d *Device) HasParent() bool { return d.Parent != nil }

// ParseLsblk parses `lsblk --bytes --pairs` output.
//
// The Vala version matched each line against one enormous regex of eighteen
// KEY="(.*)" groups, which silently dropped any line whose value contained a
// quote. This tokenises instead, so a label with a quote in it parses rather
// than vanishing.
func ParseLsblk(out string) []*Device {
	var devices []*Device
	order := 0

	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		fields := parsePairs(line)
		if len(fields) == 0 {
			continue
		}

		d := &Device{
			Name:  strings.TrimSpace(fields["NAME"]),
			KName: strings.TrimSpace(fields["KNAME"]),
			// Labels are deliberately not trimmed.
			Label:     fields["LABEL"],
			UUID:      strings.TrimSpace(fields["UUID"]),
			Type:      strings.ToLower(strings.TrimSpace(fields["TYPE"])),
			FSType:    normaliseFSType(fields["FSTYPE"]),
			Model:     strings.TrimSpace(fields["MODEL"]),
			PartLabel: fields["PARTLABEL"],
			PartUUID:  strings.TrimSpace(fields["PARTUUID"]),
			PKName:    strings.TrimSpace(fields["PKNAME"]),
			Vendor:    strings.TrimSpace(fields["VENDOR"]),
			Serial:    strings.TrimSpace(fields["SERIAL"]),
			Revision:  strings.TrimSpace(fields["REV"]),
			ReadOnly:  strings.TrimSpace(fields["RO"]) == "1",
			Order:     order,
		}
		order++

		// HOTPLUG on a modern lsblk, RM on an ancient one.
		hot := strings.TrimSpace(fields["HOTPLUG"])
		if hot == "" {
			hot = strings.TrimSpace(fields["RM"])
		}
		d.Removable = hot == "1"

		d.SizeBytes, _ = strconv.ParseInt(strings.TrimSpace(fields["SIZE"]), 10, 64)
		d.Path = "/dev/" + d.KName

		if mm := strings.TrimSpace(fields["MAJ:MIN"]); strings.Contains(mm, ":") {
			parts := strings.SplitN(mm, ":", 2)
			d.Major, _ = strconv.Atoi(parts[0])
			d.Minor, _ = strconv.Atoi(parts[1])
		}

		if mp := strings.TrimSpace(fields["MOUNTPOINT"]); mp != "" {
			d.MountPoints = append(d.MountPoints, MountPoint{Path: mp})
		}

		devices = append(devices, d)
	}

	BuildTree(devices)
	return devices
}

// normaliseFSType lower-cases and applies the two rewrites Device.vala does at
// parse time. Every comparison downstream assumes them.
func normaliseFSType(raw string) string {
	fs := strings.ToLower(strings.TrimSpace(raw))
	switch fs {
	case "crypto_luks":
		return "luks"
	case "lvm2_member":
		return "lvm2"
	}
	return fs
}

/* lsblk --pairs emits KEY="value" separated by spaces, escaping a literal
 * double quote inside a value as \x22 and a backslash as \x5c. Splitting on
 * whitespace or matching a fixed regex both mangle any value containing a
 * space, which LABEL and MODEL routinely do ("Samsung SSD 970 EVO Plus"). */
func parsePairs(line string) map[string]string {
	out := map[string]string{}
	i := 0
	for i < len(line) {
		for i < len(line) && line[i] == ' ' {
			i++
		}
		eq := strings.IndexByte(line[i:], '=')
		if eq < 0 {
			break
		}
		key := line[i : i+eq]
		i += eq + 1
		if i >= len(line) || line[i] != '"' {
			break
		}
		i++ // opening quote
		start := i
		for i < len(line) && line[i] != '"' {
			i++
		}
		if i > len(line) {
			break
		}
		out[key] = unescapeLsblk(line[start:i])
		i++ // closing quote
	}
	return out
}

// unescapeLsblk turns lsblk's \xNN escapes back into bytes.
func unescapeLsblk(s string) string {
	if !strings.Contains(s, `\x`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+3 < len(s) && s[i+1] == 'x' {
			if v, err := strconv.ParseUint(s[i+2:i+4], 16, 8); err == nil {
				b.WriteByte(byte(v))
				i += 3
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// BuildTree links devices to their parents using PKNAME, and sorts each
// device's children into lsblk order.
func BuildTree(devices []*Device) {
	byKName := make(map[string]*Device, len(devices))
	for _, d := range devices {
		byKName[d.KName] = d
	}
	for _, d := range devices {
		d.Parent = nil
		d.Children = nil
	}
	for _, d := range devices {
		if d.PKName == "" {
			continue
		}
		parent, ok := byKName[d.PKName]
		if !ok || parent == d {
			continue
		}
		d.Parent = parent
		parent.Children = append(parent.Children, d)
	}
	for _, d := range devices {
		sort.Slice(d.Children, func(i, j int) bool {
			return d.Children[i].Order < d.Children[j].Order
		})
	}
}

// ToplevelParent walks up to the disk holding this device. It is what a GRUB
// install target is derived from.
func (d *Device) ToplevelParent() *Device {
	cur := d
	for cur.Parent != nil {
		cur = cur.Parent
	}
	if cur == d {
		return nil
	}
	return cur
}

// ParseDF parses `df -T -B1` output onto the matching devices.
//
// Mount points from df are deliberately NOT trusted: df reports one mount point
// per filesystem, and a bind-mounted or multiply-mounted device gets whichever
// one df felt like printing. /proc/mounts is the authority for that.
func ParseDF(out string, devices []*Device) {
	byPath := make(map[string]*Device, len(devices))
	for _, d := range devices {
		byPath[d.Path] = d
	}

	lines := strings.Split(out, "\n")
	for i, line := range lines {
		if i == 0 || strings.TrimSpace(line) == "" {
			continue // header
		}
		f := strings.Fields(line)
		// filesystem type 1B-blocks used available use% mounted-on
		if len(f) < 7 {
			continue
		}
		d, ok := byPath[f[0]]
		if !ok {
			continue
		}
		size, _ := strconv.ParseInt(f[2], 10, 64)
		used, _ := strconv.ParseInt(f[3], 10, 64)
		avail, _ := strconv.ParseInt(f[4], 10, 64)

		d.FSSizeBytes = size
		d.UsedBytes = used
		d.AvailableBytes = avail
		d.UsedPercent = f[5]
	}
}

// ParseMounts parses /proc/mounts onto the matching devices.
//
// Read in reverse so that when a path is mounted over, the mount that is
// actually visible wins -- the last line for a path is the effective one.
// Docker's mounts are skipped wholesale, exactly as Device.vala does: they are
// numerous, they are never a backup target, and they made every device listing
// unreadable.
func ParseMounts(out string, devices []*Device) {
	byPath := make(map[string]*Device, len(devices))
	for _, d := range devices {
		byPath[d.Path] = d
		d.MountPoints = nil
	}

	seen := map[string]bool{}
	lines := strings.Split(out, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		f := strings.Fields(lines[i])
		if len(f) < 4 {
			continue
		}
		devPath, mountPoint, options := f[0], unescapeMount(f[1]), f[3]
		if strings.Contains(mountPoint, "/docker") {
			continue
		}
		d, ok := byPath[devPath]
		if !ok {
			continue
		}
		key := devPath + "\x00" + mountPoint
		if seen[key] {
			continue
		}
		seen[key] = true
		d.MountPoints = append(d.MountPoints, MountPoint{Path: mountPoint, Options: options})
	}

	// Reverse iteration built each list backwards; put it back in file order.
	for _, d := range devices {
		for i, j := 0, len(d.MountPoints)-1; i < j; i, j = i+1, j-1 {
			d.MountPoints[i], d.MountPoints[j] = d.MountPoints[j], d.MountPoints[i]
		}
	}
}

// unescapeMount decodes the octal escapes /proc/mounts uses for spaces and tabs.
func unescapeMount(s string) string {
	if !strings.Contains(s, `\0`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+3 < len(s) {
			if v, err := strconv.ParseUint(s[i+1:i+4], 8, 8); err == nil {
				b.WriteByte(byte(v))
				i += 3
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// FindByUUID returns the device with the given UUID.
func FindByUUID(devices []*Device, uuid string) *Device {
	if uuid == "" {
		return nil
	}
	for _, d := range devices {
		if d.UUID == uuid {
			return d
		}
	}
	return nil
}

// FindByPath resolves a device path, a UUID= reference or a /dev/disk/by-*
// alias to a device.
func FindByPath(devices []*Device, ref string) *Device {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		return nil
	}
	if strings.HasPrefix(ref, "UUID=") {
		return FindByUUID(devices, strings.TrimPrefix(ref, "UUID="))
	}
	for _, prefix := range []string{"/dev/disk/by-uuid/", "/dev/disk/by-partuuid/", "/dev/disk/by-label/", "/dev/disk/by-partlabel/"} {
		if !strings.HasPrefix(ref, prefix) {
			continue
		}
		value := strings.TrimPrefix(ref, prefix)
		for _, d := range devices {
			switch prefix {
			case "/dev/disk/by-uuid/":
				if d.UUID == value {
					return d
				}
			case "/dev/disk/by-partuuid/":
				if d.PartUUID == value {
					return d
				}
			case "/dev/disk/by-label/":
				if strings.TrimSpace(d.Label) == value {
					return d
				}
			case "/dev/disk/by-partlabel/":
				if strings.TrimSpace(d.PartLabel) == value {
					return d
				}
			}
		}
		return nil
	}
	for _, d := range devices {
		if d.Path == ref || d.Name == ref || d.KName == ref {
			return d
		}
	}
	return nil
}

// MountedAt returns the device mounted at a path, if any.
func MountedAt(devices []*Device, path string) *Device {
	for _, d := range devices {
		for _, m := range d.MountPoints {
			if m.Path == path {
				return d
			}
		}
	}
	return nil
}

// Scanner reads the block-device tree. It replaces Device.vala's static
// device_list: state lives here and is passed, not reached for.
type Scanner struct {
	Runner Runner
}

// Runner is the subset of sysexec this package needs.
type Runner interface {
	Run(ctx context.Context, argv []string, stdin string) (exitCode int, stdout, stderr string, err error)
}

// LsblkColumns is the column list Device.vala asks lsblk for. The corpus in
// testdata was captured with exactly this list; changing it invalidates it.
const LsblkColumns = "NAME,KNAME,LABEL,UUID,TYPE,FSTYPE,SIZE,MOUNTPOINT,MODEL,RO,HOTPLUG,MAJ:MIN,PARTLABEL,PARTUUID,PKNAME,VENDOR,SERIAL,REV"

// Scan enumerates block devices and fills in mount points and free space.
//
// df and /proc/mounts failing is not fatal: the device list without space
// figures is still enough to show the user what is attached, which is better
// than reporting that the machine has no disks.
func (s *Scanner) Scan(ctx context.Context) ([]*Device, error) {
	code, stdout, stderr, err := s.Runner.Run(ctx,
		[]string{"lsblk", "--bytes", "--pairs", "--output", LsblkColumns}, "")
	if err != nil {
		return nil, fmt.Errorf("block: lsblk: %w", err)
	}
	if code != 0 {
		return nil, fmt.Errorf("block: lsblk exited %d: %s", code, strings.TrimSpace(stderr))
	}

	devices := ParseLsblk(stdout)

	if _, out, _, err := s.Runner.Run(ctx, []string{"df", "-T", "-B1"}, ""); err == nil {
		ParseDF(out, devices)
	}
	if _, out, _, err := s.Runner.Run(ctx, []string{"cat", "/proc/mounts"}, ""); err == nil {
		ParseMounts(out, devices)
	}

	return devices, nil
}
