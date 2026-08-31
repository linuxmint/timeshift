package timeshift

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func golden(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", "snapshot", name))
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	return b
}

func TestParseRsyncControlFile(t *testing.T) {
	c, err := ParseControlFile(golden(t, "rsync-info.json"))
	if err != nil {
		t.Fatal(err)
	}

	if got := c.Created.UTC(); got != time.Unix(1756400000, 0).UTC() {
		t.Errorf("created = %v", got)
	}
	if c.SysUUID != "db965381-9f0c-453e-a508-0ac5b4cbb48d" {
		t.Errorf("sys-uuid = %q", c.SysUUID)
	}
	if c.Type != "rsync" || c.IsBtrfs() {
		t.Errorf("type = %q", c.Type)
	}
	if c.FileCount != 222576 {
		t.Errorf("file_count = %d", c.FileCount)
	}
	if c.SizeBytes != 14402423333 || c.UnsharedBytes != 418235911 {
		t.Errorf("sizes = %d / %d", c.SizeBytes, c.UnsharedBytes)
	}
	if c.Live {
		t.Error("live should be false")
	}
	want := []string{"O", "D"}
	if len(c.Tags) != 2 || c.Tags[0] != want[0] || c.Tags[1] != want[1] {
		t.Errorf("tags = %v", c.Tags)
	}
	if c.Description == "" {
		t.Error("comments were dropped")
	}
}

func TestParseBtrfsControlFile(t *testing.T) {
	c, err := ParseControlFile(golden(t, "btrfs-info.json"))
	if err != nil {
		t.Fatal(err)
	}

	if !c.IsBtrfs() {
		t.Fatal("type should be btrfs")
	}
	if !c.Live {
		t.Error("live should be true")
	}
	if len(c.Subvolumes) != 2 {
		t.Fatalf("parsed %d subvolumes, want 2", len(c.Subvolumes))
	}

	home, ok := c.Subvolumes["@home"]
	if !ok {
		t.Fatal("@home missing")
	}
	// The positional five-element array: name, id, total, unshared, uuid.
	if home.Name != "@home" || home.ID != 258 {
		t.Errorf("@home = %+v", home)
	}
	if home.TotalBytes != 21474836480 || home.UnsharedBytes != 5368709120 {
		t.Errorf("@home sizes = %d / %d", home.TotalBytes, home.UnsharedBytes)
	}

	// btrfs sizes are the sum of the subvolumes, not a stored figure.
	if got := c.TotalSize(); got != 9663676416+21474836480 {
		t.Errorf("TotalSize = %d", got)
	}
	if got := c.UnsharedSize(); got != 1073741824+5368709120 {
		t.Errorf("UnsharedSize = %d", got)
	}
}

// Only @ and @home are accepted; anything else in the table is ignored rather
// than treated as a subvolume Timeshift knows how to restore.
func TestSubvolumeWhitelist(t *testing.T) {
	raw := []byte(`{"type":"btrfs","subvolumes":{
		"@":["@","257","1","1","u"],
		"@srv":["@srv","259","1","1","u"],
		"whatever":["whatever","260","1","1","u"]}}`)
	c, err := ParseControlFile(raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Subvolumes) != 1 {
		t.Errorf("accepted %d subvolumes, want only @", len(c.Subvolumes))
	}
	if _, ok := c.Subvolumes["@"]; !ok {
		t.Error("@ was rejected")
	}
}

// -1 means "not computed yet", which is different from a snapshot measured at
// zero bytes. Conflating them would make the CLI print 0 B for every snapshot
// whose size has not been walked.
func TestUncomputedSizeIsMinusOne(t *testing.T) {
	c, err := ParseControlFile([]byte(`{"type":"rsync"}`))
	if err != nil {
		t.Fatal(err)
	}
	if c.SizeBytes != -1 || c.UnsharedBytes != -1 {
		t.Errorf("sizes = %d / %d, want -1 for absent keys", c.SizeBytes, c.UnsharedBytes)
	}
}

// A control file predating the `type` key is an rsync snapshot.
func TestTypeDefaultsToRsync(t *testing.T) {
	c, err := ParseControlFile([]byte(`{"created":"1"}`))
	if err != nil {
		t.Fatal(err)
	}
	if c.Type != "rsync" {
		t.Errorf("type = %q, want rsync", c.Type)
	}
}

func TestUnparseableIsAnError(t *testing.T) {
	if _, err := ParseControlFile([]byte("this is not json")); err == nil {
		t.Error("a corrupt control file must be an error, so the caller can mark the snapshot invalid rather than hide it")
	}
}

func TestTagListShort(t *testing.T) {
	cases := []struct {
		tags []string
		want string
	}{
		{[]string{"ondemand", "daily"}, "O D"},
		{[]string{"boot"}, "B"},
		{[]string{"hourly", "weekly", "monthly"}, "H W M"},
		{nil, ""},
		{[]string{"unknown"}, "unknown"},
	}
	for _, c := range cases {
		if got := TagListShort(c.tags); got != c.want {
			t.Errorf("TagListShort(%v) = %q, want %q", c.tags, got, c.want)
		}
	}
}

func TestParseTagList(t *testing.T) {
	cases := map[string][]string{
		"ondemand daily":    {"ondemand", "daily"},
		"  boot   hourly  ": {"boot", "hourly"},
		"daily daily":       {"daily"},
		"":                  nil,
		"O D":               {"O", "D"},
	}
	for in, want := range cases {
		got := ParseTagList(in)
		if len(got) != len(want) {
			t.Errorf("ParseTagList(%q) = %v, want %v", in, got, want)
			continue
		}
		for i := range got {
			if got[i] != want[i] {
				t.Errorf("ParseTagList(%q) = %v, want %v", in, got, want)
				break
			}
		}
	}
}

// The GUI reads these files. Marshal must produce json-glib's shape, not
// encoding/json's.
func TestMarshalShape(t *testing.T) {
	c, err := ParseControlFile(golden(t, "rsync-info.json"))
	if err != nil {
		t.Fatal(err)
	}
	out := string(c.Marshal())

	if !contains(out, `"created" : "1756400000"`) {
		t.Errorf("key/value spacing wrong:\n%s", out)
	}
	if contains(out, `":`) {
		t.Error(`separator is "key": -- json-glib writes "key" : `)
	}
	if hasSuffix(out, "\n") {
		t.Error("json-glib writes no trailing newline")
	}
	if !contains(out, `"size_bytes" : "14402423333"`) {
		t.Error("rsync sizes must be written for an rsync snapshot")
	}
	if contains(out, "subvolumes") {
		t.Error("an rsync snapshot must not carry a subvolumes table")
	}
}

func TestMarshalRoundTrip(t *testing.T) {
	for _, name := range []string{"rsync-info.json", "btrfs-info.json"} {
		orig, err := ParseControlFile(golden(t, name))
		if err != nil {
			t.Fatal(err)
		}
		back, err := ParseControlFile(orig.Marshal())
		if err != nil {
			t.Fatalf("%s: reparse: %v", name, err)
		}
		if back.SysUUID != orig.SysUUID || back.Type != orig.Type ||
			back.FileCount != orig.FileCount || back.Live != orig.Live ||
			back.Description != orig.Description {
			t.Errorf("%s: round trip lost a field", name)
		}
		if back.TotalSize() != orig.TotalSize() {
			t.Errorf("%s: TotalSize %d -> %d", name, orig.TotalSize(), back.TotalSize())
		}
		if len(back.Subvolumes) != len(orig.Subvolumes) {
			t.Errorf("%s: %d subvolumes -> %d", name, len(orig.Subvolumes), len(back.Subvolumes))
		}
		if back.Created.Unix() != orig.Created.Unix() {
			t.Errorf("%s: created %v -> %v", name, orig.Created, back.Created)
		}
	}
}

func contains(s, sub string) bool  { return len(s) >= len(sub) && indexOf(s, sub) >= 0 }
func hasSuffix(s, suf string) bool { return len(s) >= len(suf) && s[len(s)-len(suf):] == suf }

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
