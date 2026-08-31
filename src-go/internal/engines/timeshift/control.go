package timeshift

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"
)

/* The control file every snapshot directory carries.
 *
 * Same rules as timeshift.json: every value is a JSON *string*, including
 * booleans, counts and sizes, and the file is written by json-glib's pretty
 * printer. A snapshot written here has to be readable by the Vala GUI on the
 * same machine, so the format is a contract and not an implementation detail.
 *
 * `subvolumes` is the odd one: an object whose values are positional
 * five-element string arrays, [name, id, total_bytes, unshared_bytes,
 * device_uuid]. Only "@" and "@home" are accepted. */

// ControlFile is the parsed info.json.
type ControlFile struct {
	Created       time.Time
	SysUUID       string
	SysDistro     string
	AppVersion    string
	FileCount     int64
	Tags          []string
	Description   string
	Live          bool
	Type          string // "rsync" or "btrfs"
	SizeBytes     int64  // -1 when not computed
	UnsharedBytes int64  // -1 when not computed
	Subvolumes    map[string]Subvolume
	present       map[string]bool
}

// Subvolume is one btrfs subvolume recorded in a control file.
type Subvolume struct {
	Name          string
	ID            int64
	TotalBytes    int64
	UnsharedBytes int64
	DeviceUUID    string
}

// TagOrder is the order retention levels are considered in, and the order tags
// are printed in.
var TagOrder = []string{"ondemand", "boot", "hourly", "daily", "weekly", "monthly"}

// tagLetters maps a level to the single letter the CLI's Tags column shows.
var tagLetters = map[string]string{
	"ondemand": "O", "boot": "B", "hourly": "H",
	"daily": "D", "weekly": "W", "monthly": "M",
}

// TagListShort renders tags as the CLI's Tags column: single letters, space
// separated, in the order the tags are stored.
func TagListShort(tags []string) string {
	out := make([]string, 0, len(tags))
	for _, t := range tags {
		if letter, ok := tagLetters[t]; ok {
			out = append(out, letter)
		} else {
			out = append(out, t)
		}
	}
	return strings.Join(out, " ")
}

// ParseTagList splits the space-separated `tags` value, dropping duplicates and
// preserving order -- matching the taglist setter.
func ParseTagList(s string) []string {
	var out []string
	seen := map[string]bool{}
	for _, t := range strings.Split(s, " ") {
		t = strings.TrimSpace(t)
		if t == "" || seen[t] {
			continue
		}
		seen[t] = true
		out = append(out, t)
	}
	return out
}

// ParseControlFile parses an info.json.
//
// A parse failure is an error, and the caller marks the snapshot invalid rather
// than dropping it from the listing. A repository that looks emptier than it is
// is how data gets deleted: auto_remove() prunes what it cannot see.
func ParseControlFile(raw []byte) (*ControlFile, error) {
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil, fmt.Errorf("timeshift: parse info.json: %w", err)
	}

	c := &ControlFile{
		Type:          "rsync", // the default on read, for files predating the key
		SizeBytes:     -1,
		UnsharedBytes: -1,
		Subvolumes:    map[string]Subvolume{},
		present:       make(map[string]bool, len(obj)),
	}
	for k := range obj {
		c.present[k] = true
	}

	str := func(key string) string {
		v, ok := obj[key]
		if !ok {
			return ""
		}
		var s string
		if json.Unmarshal(v, &s) != nil {
			return ""
		}
		return s
	}

	if v := str("created"); v != "" {
		if secs, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64); err == nil {
			// Written as UTC unix seconds; displayed in local time.
			c.Created = time.Unix(secs, 0)
		}
	}
	c.SysUUID = str("sys-uuid")
	c.SysDistro = str("sys-distro")
	c.AppVersion = str("app-version")
	c.Description = str("comments")
	c.Tags = ParseTagList(str("tags"))
	c.Live = str("live") == "true"
	if t := str("type"); t != "" {
		c.Type = t
	}
	if v := str("file_count"); v != "" {
		c.FileCount, _ = strconv.ParseInt(strings.TrimSpace(v), 10, 64)
	}
	// -1 is "not computed yet", which is different from 0.
	if v := str("size_bytes"); v != "" {
		if n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64); err == nil {
			c.SizeBytes = n
		}
	}
	if v := str("size_unshared_bytes"); v != "" {
		if n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64); err == nil {
			c.UnsharedBytes = n
		}
	}

	if v, ok := obj["subvolumes"]; ok {
		var table map[string][]string
		if json.Unmarshal(v, &table) == nil {
			for name, fields := range table {
				// Only @ and @home are accepted, matching read_control_file.
				if name != "@" && name != "@home" {
					continue
				}
				if len(fields) < 5 {
					continue
				}
				sv := Subvolume{Name: fields[0], DeviceUUID: fields[4]}
				sv.ID, _ = strconv.ParseInt(fields[1], 10, 64)
				sv.TotalBytes, _ = strconv.ParseInt(fields[2], 10, 64)
				sv.UnsharedBytes, _ = strconv.ParseInt(fields[3], 10, 64)
				c.Subvolumes[name] = sv
			}
		}
	}

	return c, nil
}

// IsBtrfs reports whether this snapshot was taken with btrfs subvolumes.
func (c *ControlFile) IsBtrfs() bool { return c.Type == "btrfs" }

// TotalSize is the snapshot's apparent size.
//
// btrfs sums its subvolumes; rsync returns the cached figure, which is -1 until
// something has walked the tree to compute it.
func (c *ControlFile) TotalSize() int64 {
	if !c.IsBtrfs() {
		return c.SizeBytes
	}
	var total int64
	for _, sv := range c.Subvolumes {
		total += sv.TotalBytes
	}
	return total
}

// UnsharedSize is the part of the snapshot not shared with a neighbour.
func (c *ControlFile) UnsharedSize() int64 {
	if !c.IsBtrfs() {
		return c.UnsharedBytes
	}
	var total int64
	for _, sv := range c.Subvolumes {
		total += sv.UnsharedBytes
	}
	return total
}

// Marshal renders the control file in json-glib's format, in the key order
// write_control_file() uses.
func (c *ControlFile) Marshal() []byte {
	var b strings.Builder
	b.WriteString("{\n")

	first := true
	kv := func(key, val string) {
		if !first {
			b.WriteString(",\n")
		}
		first = false
		fmt.Fprintf(&b, "  %s : %s", quote(key), quote(val))
	}

	kv("created", strconv.FormatInt(c.Created.UTC().Unix(), 10))
	kv("sys-uuid", c.SysUUID)
	kv("sys-distro", c.SysDistro)
	kv("app-version", c.AppVersion)
	kv("file_count", strconv.FormatInt(c.FileCount, 10))
	kv("tags", strings.Join(c.Tags, " "))
	kv("comments", c.Description)
	kv("live", boolStr(c.Live))
	kv("type", c.Type)

	if c.IsBtrfs() {
		if len(c.Subvolumes) > 0 {
			if !first {
				b.WriteString(",\n")
			}
			first = false
			fmt.Fprintf(&b, "  %s : {\n", quote("subvolumes"))
			names := make([]string, 0, len(c.Subvolumes))
			for n := range c.Subvolumes {
				names = append(names, n)
			}
			sort.Strings(names)
			for i, n := range names {
				sv := c.Subvolumes[n]
				fmt.Fprintf(&b, "    %s : [ %s, %s, %s, %s, %s ]",
					quote(n), quote(sv.Name),
					quote(strconv.FormatInt(sv.ID, 10)),
					quote(strconv.FormatInt(sv.TotalBytes, 10)),
					quote(strconv.FormatInt(sv.UnsharedBytes, 10)),
					quote(sv.DeviceUUID))
				if i < len(names)-1 {
					b.WriteByte(',')
				}
				b.WriteByte('\n')
			}
			b.WriteString("  }")
		}
	} else {
		kv("size_bytes", strconv.FormatInt(c.SizeBytes, 10))
		kv("size_unshared_bytes", strconv.FormatInt(c.UnsharedBytes, 10))
	}

	b.WriteString("\n}")
	return []byte(b.String())
}

func boolStr(v bool) string {
	if v {
		return "true"
	}
	return "false"
}

// quote renders a JSON string without encoding/json's HTML escaping, which
// json-glib does not do.
func quote(s string) string {
	var b strings.Builder
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(s); err != nil {
		return strconv.Quote(s)
	}
	return strings.TrimRight(b.String(), "\n")
}
