package fsutil

import (
	"compress/gzip"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFormatSizeMatchesTeeJee(t *testing.T) {
	d := DefaultSizeOpts()

	cases := []struct {
		size uint64
		opts SizeOpts
		want string
	}{
		// The boundary is strictly greater-than in format_file_size(), so a
		// round 1000 stays in bytes. This looks like an off-by-one and is the
		// behaviour every existing snapshot listing already has.
		{1000, d, "1000 B"},
		{1001, d, "1.0 KB"},
		{1000 * 1000, d, "1000.0 KB"},
		{1000*1000 + 1, d, "1.0 MB"},

		// Values in the shape `timeshift --list` prints on this machine.
		{10_800_000_000, d, "10.8 GB"},
		{157_200_000, d, "157.2 MB"},
		{29_900_000_000_000, d, "29.9 TB"},
		{8_400_000_000, d, "8.4 GB"},

		{0, d, "0 B"},
		{512, d, "512 B"},

		// Binary units carry the i infix.
		{1024 * 1024 * 5, SizeOpts{Binary: true, ShowUnits: true, Decimals: 1}, "5.0 MiB"},
		{1024 * 1024 * 1024 * 3, SizeOpts{Binary: true, ShowUnits: true, Decimals: 1}, "3.0 GiB"},

		// A pinned unit overrides the automatic choice.
		{5_000_000_000, SizeOpts{Unit: "m", ShowUnits: true, Decimals: 1}, "5000.0 MB"},
		{5_000_000_000, SizeOpts{Unit: "k", ShowUnits: true, Decimals: 0}, "5000000 KB"},

		// No units, no decimals.
		{2_500_000, SizeOpts{Decimals: 2}, "2.50"},

		// Grouping is opt-in.
		{123_456_789, SizeOpts{Unit: "k", Decimals: 0, Group: true}, "123,457"},
		{9_999, SizeOpts{Group: true, ShowUnits: true}, "10 KB"},
	}

	for _, c := range cases {
		if got := FormatSize(c.size, c.opts); got != c.want {
			t.Errorf("FormatSize(%d, %+v) = %q, want %q", c.size, c.opts, got, c.want)
		}
	}
}

func TestGroup(t *testing.T) {
	cases := map[string]string{
		"1":          "1",
		"999":        "999",
		"1000":       "1,000",
		"1234567":    "1,234,567",
		"1234.5":     "1,234.5",
		"-1234567.8": "-1,234,567.8",
		"":           "",
	}
	for in, want := range cases {
		if got := group(in); got != want {
			t.Errorf("group(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestLineCount(t *testing.T) {
	dir := t.TempDir()

	cases := []struct {
		body string
		want int64
	}{
		{"", 0},
		{"one\n", 1},
		{"one\ntwo\nthree\n", 3},
		{"no trailing newline", 0},
		{"one\ntwo", 1},
	}
	for i, c := range cases {
		p := filepath.Join(dir, "f")
		if err := os.WriteFile(p, []byte(c.body), 0644); err != nil {
			t.Fatal(err)
		}
		got, err := LineCount(p)
		if err != nil {
			t.Fatalf("case %d: %v", i, err)
		}
		if got != c.want {
			t.Errorf("case %d: LineCount(%q) = %d, want %d", i, c.body, got, c.want)
		}
	}
}

// The rsync log this counts is megabytes of paths; make sure the buffered read
// is not fooled by a file larger than one buffer.
func TestLineCountAcrossBufferBoundary(t *testing.T) {
	p := filepath.Join(t.TempDir(), "big")
	var b strings.Builder
	const lines = 40000
	for i := 0; i < lines; i++ {
		b.WriteString(strings.Repeat("x", 60))
		b.WriteByte('\n')
	}
	if err := os.WriteFile(p, []byte(b.String()), 0644); err != nil {
		t.Fatal(err)
	}
	got, err := LineCount(p)
	if err != nil {
		t.Fatal(err)
	}
	if got != lines {
		t.Errorf("LineCount = %d, want %d", got, lines)
	}
}

func TestShellQuote(t *testing.T) {
	cases := map[string]string{
		"/plain/path":       `'/plain/path'`,
		"with space":        `'with space'`,
		"it's":              `'it'\''s'`,
		"$(rm -rf /)":       `'$(rm -rf /)'`,
		"a'b'c":             `'a'\''b'\''c'`,
		"back\\slash":       `'back\slash'`,
		"newline\nembedded": "'newline\nembedded'",
	}
	for in, want := range cases {
		if got := ShellQuote(in); got != want {
			t.Errorf("ShellQuote(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestWriteAtomic(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "sub", "file.txt")

	if err := WriteAtomic(p, []byte("hello"), 0600); err != nil {
		t.Fatal(err)
	}
	if got := ReadString(p); got != "hello" {
		t.Errorf("content = %q", got)
	}
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0600 {
		t.Errorf("mode = %v, want 0600", fi.Mode().Perm())
	}

	// Overwriting leaves no debris.
	if err := WriteAtomic(p, []byte("second"), 0600); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(filepath.Dir(p))
	if len(entries) != 1 {
		t.Errorf("directory holds %d entries after rewrite, want 1", len(entries))
	}
}

func TestGzip(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "rsync-log")
	body := strings.Repeat("2026/08/31 12:00:00 [1234] >f+++++++++ some/path\n", 500)
	if err := os.WriteFile(p, []byte(body), 0640); err != nil {
		t.Fatal(err)
	}

	if err := Gzip(p); err != nil {
		t.Fatal(err)
	}
	if FileExists(p) {
		t.Error("the original must be removed once compressed")
	}

	f, err := os.Open(p + ".gz")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	back, err := io.ReadAll(zr)
	if err != nil {
		t.Fatal(err)
	}
	if string(back) != body {
		t.Error("round trip through gzip changed the content")
	}
}

func TestExistenceHelpers(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "f")
	os.WriteFile(file, []byte("x"), 0644)
	link := filepath.Join(dir, "l")
	os.Symlink(file, link)

	if !FileExists(file) {
		t.Error("FileExists on a regular file")
	}
	// TeeJee's file_exists() answers false for a directory, deliberately.
	if FileExists(dir) {
		t.Error("FileExists must be false for a directory")
	}
	if !DirExists(dir) {
		t.Error("DirExists on a directory")
	}
	if DirExists(file) {
		t.Error("DirExists must be false for a file")
	}
	if !IsSymlink(link) {
		t.Error("IsSymlink on a symlink")
	}
	if IsSymlink(file) {
		t.Error("IsSymlink must not follow to the target")
	}
	if ReadString(filepath.Join(dir, "absent")) != "" {
		t.Error("ReadString of a missing file must be empty")
	}
}
