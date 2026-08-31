package restore

import (
	"fmt"
	"sort"
	"strings"
)

/* Rewriting the restored system's fstab and crypttab.
 *
 * A snapshot carries the fstab of the machine it was taken on. Restored onto
 * different partitions, every UUID in it is wrong, and the system boots to an
 * initramfs prompt. This rewrites the entries to match where the files actually
 * landed.
 *
 * It also REMOVES fstab entries for system directories that the restore did not
 * mount anywhere. Leaving them would make the restored system wait at boot for
 * a device that is not there.
 */

// FsTabEntry is one line of /etc/fstab.
//
// Comments and blank lines are entries too, carrying their text verbatim, so
// rewriting the file preserves everything the user put in it.
type FsTabEntry struct {
	IsComment bool
	IsBlank   bool
	Raw       string

	Device     string
	MountPoint string
	Type       string
	Options    string
	Dump       string
	Pass       string
}

// ParseFsTab reads an fstab, keeping comments and blank lines in place.
func ParseFsTab(text string) []FsTabEntry {
	var out []FsTabEntry
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimSpace(line)
		switch {
		case trimmed == "":
			out = append(out, FsTabEntry{IsBlank: true, Raw: line})
			continue
		case strings.HasPrefix(trimmed, "#"):
			out = append(out, FsTabEntry{IsComment: true, Raw: line})
			continue
		}
		f := strings.Fields(trimmed)
		e := FsTabEntry{Raw: line, Options: "defaults", Dump: "0", Pass: "0"}
		for i, v := range f {
			switch i {
			case 0:
				e.Device = v
			case 1:
				e.MountPoint = v
			case 2:
				e.Type = v
			case 3:
				e.Options = v
			case 4:
				e.Dump = v
			case 5:
				e.Pass = v
			}
		}
		out = append(out, e)
	}
	return out
}

// SubvolumeName extracts subvol= from the options.
func (e FsTabEntry) SubvolumeName() string {
	for _, opt := range strings.Split(e.Options, ",") {
		if v, ok := strings.CutPrefix(opt, "subvol="); ok {
			return strings.TrimPrefix(v, "/")
		}
	}
	return ""
}

// RemoveOption drops one option from the comma list.
func (e *FsTabEntry) RemoveOption(name string) {
	var kept []string
	for _, opt := range strings.Split(e.Options, ",") {
		if opt != name && !strings.HasPrefix(opt, name+"=") {
			kept = append(kept, opt)
		}
	}
	if len(kept) == 0 {
		kept = []string{"defaults"}
	}
	e.Options = strings.Join(kept, ",")
}

/* Which mount points count as part of the system.
 *
 * Only these are pruned when the restore did not mount them: removing a user's
 * data-disk entry would be rewriting a decision that has nothing to do with the
 * restore.
 */
func (e FsTabEntry) IsForSystemDirectory() bool {
	mp := e.MountPoint
	if mp == "" || !strings.HasPrefix(mp, "/") {
		return false
	}
	for _, prefix := range []string{"/mnt", "/mount", "/sdcard", "/cdrom", "/media"} {
		if strings.HasPrefix(mp, prefix) {
			return false
		}
	}
	if e.Device == "none" {
		return false
	}
	// A device reference we do not understand is not ours to rewrite.
	if !strings.HasPrefix(e.Device, "/dev") && !strings.HasPrefix(e.Device, "UUID=") {
		return false
	}
	return true
}

// FixFsTab rewrites the entries to match where the restore actually put things.
//
// deviceInfo maps a device UUID to its filesystem type, which the entry needs
// and the mount plan does not carry.
func FixFsTab(entries []FsTabEntry, mounts []MountEntry, fsTypeByUUID map[string]string) []FsTabEntry {
	out := append([]FsTabEntry(nil), entries...)

	// Point every mounted directory at the device it was actually mounted on.
	for _, m := range mounts {
		if !m.Assigned() {
			continue
		}
		idx := -1
		for i := range out {
			if !out[i].IsComment && !out[i].IsBlank && out[i].MountPoint == m.MountPoint {
				idx = i
				break
			}
		}
		if idx < 0 {
			out = append(out, FsTabEntry{
				MountPoint: m.MountPoint,
				Options:    "defaults",
				Dump:       "0",
				Pass:       "0",
			})
			idx = len(out) - 1
		}

		out[idx].Device = "UUID=" + m.DeviceUUID
		if fs := fsTypeByUUID[m.DeviceUUID]; fs != "" {
			out[idx].Type = fs
			/* A subvol= option on a non-btrfs filesystem makes mount fail
			 * outright. It is left over from a snapshot taken on btrfs and
			 * restored onto ext4. */
			if fs != "btrfs" {
				if sub := out[idx].SubvolumeName(); sub != "" {
					out[idx].RemoveOption("subvol")
				}
			}
		}
		out[idx].Raw = "" // regenerate, the fields have changed
	}

	/* Remove system entries the restore did not mount. Leaving them makes the
	 * restored system wait at boot for a device that is not there. */
	mounted := map[string]bool{}
	for _, m := range mounts {
		mounted[m.MountPoint] = true
	}
	var kept []FsTabEntry
	for _, e := range out {
		if !e.IsComment && !e.IsBlank && e.IsForSystemDirectory() && !mounted[e.MountPoint] {
			continue
		}
		kept = append(kept, e)
	}
	return kept
}

// RenderFsTab writes the entries back out.
//
// Entries are sorted by mount point so a parent is mounted before its children;
// comments and blank lines are kept where they are relative to the entries they
// precede.
func RenderFsTab(entries []FsTabEntry, keepComments bool) string {
	var comments, rows []FsTabEntry
	for _, e := range entries {
		if e.IsComment || e.IsBlank {
			comments = append(comments, e)
			continue
		}
		rows = append(rows, e)
	}

	sort.SliceStable(rows, func(i, j int) bool { return rows[i].MountPoint < rows[j].MountPoint })

	var b strings.Builder
	if keepComments {
		for _, c := range comments {
			b.WriteString(c.Raw)
			b.WriteString("\n")
		}
	} else {
		b.WriteString("# <file system> <mount point> <type> <options> <dump> <pass>\n")
	}
	for _, e := range rows {
		fmt.Fprintf(&b, "%s\t%s\t%s\t%s\t%s\t%s\n",
			e.Device, e.MountPoint, e.Type, e.Options, e.Dump, e.Pass)
	}
	return b.String()
}

// CryptTabEntry is one line of /etc/crypttab.
type CryptTabEntry struct {
	IsComment bool
	IsBlank   bool
	Raw       string

	MappedName string
	Device     string
	KeyFile    string
	Options    string
}

// ParseCryptTab reads a crypttab.
func ParseCryptTab(text string) []CryptTabEntry {
	var out []CryptTabEntry
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimSpace(line)
		switch {
		case trimmed == "":
			out = append(out, CryptTabEntry{IsBlank: true, Raw: line})
			continue
		case strings.HasPrefix(trimmed, "#"):
			out = append(out, CryptTabEntry{IsComment: true, Raw: line})
			continue
		}
		f := strings.Fields(trimmed)
		e := CryptTabEntry{Raw: line, KeyFile: "none", Options: "luks,nofail"}
		for i, v := range f {
			switch i {
			case 0:
				e.MappedName = v
			case 1:
				e.Device = v
			case 2:
				e.KeyFile = v
			case 3:
				e.Options = v
			}
		}
		out = append(out, e)
	}
	return out
}

// HasOption reports whether the entry carries an option.
func (e CryptTabEntry) HasOption(name string) bool {
	for _, opt := range strings.Split(e.Options, ",") {
		if opt == name || strings.HasPrefix(opt, name+"=") {
			return true
		}
	}
	return false
}

// FixCryptTab adds nofail to every entry, and an entry for any encrypted device
// the restore mounted that the file does not already describe.
//
// nofail on everything is the point: a restored system that cannot find one
// encrypted volume should still boot far enough to be fixed, rather than
// dropping to an initramfs prompt where there is no way to investigate.
func FixCryptTab(entries []CryptTabEntry, encrypted []EncryptedDevice) []CryptTabEntry {
	out := append([]CryptTabEntry(nil), entries...)

	for i := range out {
		if out[i].IsComment || out[i].IsBlank {
			continue
		}
		if !out[i].HasOption("nofail") {
			out[i].Options = strings.TrimSuffix(out[i].Options, ",") + ",nofail"
			out[i].Raw = ""
		}
	}

	known := map[string]bool{}
	for _, e := range out {
		if !e.IsComment && !e.IsBlank {
			known[strings.TrimPrefix(e.Device, "UUID=")] = true
		}
	}
	for _, d := range encrypted {
		if d.ParentUUID == "" || known[d.ParentUUID] {
			continue
		}
		out = append(out, CryptTabEntry{
			MappedName: "luks-" + d.ParentUUID,
			Device:     "UUID=" + d.ParentUUID,
			KeyFile:    "none",
			Options:    "luks,nofail",
		})
	}
	return out
}

// EncryptedDevice names a LUKS container the restore mounted through.
type EncryptedDevice struct {
	// MappedName is the /dev/mapper name.
	MappedName string
	// ParentUUID is the UUID of the LUKS container itself, which is what
	// crypttab must name -- not the unlocked device inside it.
	ParentUUID string
}

// RenderCryptTab writes the entries back out, keeping comments.
func RenderCryptTab(entries []CryptTabEntry) string {
	var b strings.Builder
	for _, e := range entries {
		if e.IsComment || e.IsBlank {
			b.WriteString(e.Raw)
			b.WriteString("\n")
			continue
		}
		fmt.Fprintf(&b, "%s\t%s\t%s\t%s\n", e.MappedName, e.Device, e.KeyFile, e.Options)
	}
	return b.String()
}
