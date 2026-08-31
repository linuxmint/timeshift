package textui

import (
	"strings"
	"testing"
)

// The exact header of `timeshift --list`, captured from the Vala binary. If
// this drifts, the drop-in replacement is not one.
func TestSnapshotHeaderMatchesVala(t *testing.T) {
	g := Grid{
		HasHeader:  true,
		RightAlign: []bool{false, false, false, false, true, true, false},
		Rows: [][]string{
			{"Num", "", "Name", "Tags", "Size", "Unique", "Description"},
			{"0", ">", "2026-08-30_21-45-59", "O D", "10.8 GB", "8.4 GB", "before apt"},
			{"1", ">", "2026-08-30_21-59-39", "O", "10.8 GB", "157.2 MB", ""},
		},
	}
	var b strings.Builder
	g.Render(&b)
	lines := strings.Split(b.String(), "\n")

	// "Num" is 3 wide (widest of Num, 0, 1), the marker column is 1 wide, and
	// each is followed by two spaces: 3+2+1+2 = 8 characters before "Name".
	if !strings.HasPrefix(lines[0], "Num     Name") {
		t.Errorf("header = %q", lines[0])
	}
	if lines[1] != strings.Repeat("-", 78) {
		t.Errorf("separator is %d dashes, want 78", len(lines[1]))
	}
	if !strings.HasPrefix(lines[2], "0    >  2026-08-30_21-45-59") {
		t.Errorf("first row = %q", lines[2])
	}

	/* Right alignment, checked against a line the Vala binary actually printed:
	 *
	 *   0    >  2026-08-30_21-45-59  O D   10.8 GB    8.4 GB  Auto-snapshot...
	 *
	 * Size is 7 wide ("10.8 GB"), so it fills its column exactly; Unique is 8
	 * wide because "157.2 MB" is in it, so "8.4 GB" is pushed two to the right
	 * -- giving four spaces between the two figures, not three. */
	if !strings.Contains(lines[2], "O D   10.8 GB    8.4 GB  ") {
		t.Errorf("right alignment wrong: %q", lines[2])
	}
	if !strings.Contains(lines[3], "10.8 GB  157.2 MB") {
		t.Errorf("second row = %q", lines[3])
	}
}

// Every cell is followed by two spaces, including the last on the line. The
// Vala output has trailing whitespace on every row and a byte-for-byte diff
// would fail on all of them if this were tidied up.
func TestTrailingWhitespaceIsPreserved(t *testing.T) {
	g := Grid{
		RightAlign: []bool{false, false},
		Rows:       [][]string{{"a", "b"}},
	}
	var b strings.Builder
	g.Render(&b)
	if b.String() != "a  b  \n" {
		t.Errorf("render = %q, want %q", b.String(), "a  b  \n")
	}
}

func TestEmptyDescriptionStillPads(t *testing.T) {
	g := Grid{
		RightAlign: []bool{false, false},
		Rows: [][]string{
			{"name", "a long description"},
			{"x", ""},
		},
	}
	var b strings.Builder
	g.Render(&b)
	lines := strings.Split(b.String(), "\n")
	if len(lines[1]) != len(lines[0]) {
		t.Errorf("rows are not the same width: %d vs %d", len(lines[1]), len(lines[0]))
	}
}

func TestNoHeaderSeparator(t *testing.T) {
	g := Grid{RightAlign: []bool{false}, Rows: [][]string{{"only"}}}
	var b strings.Builder
	g.Render(&b)
	if strings.Contains(b.String(), "---") {
		t.Error("separator printed without HasHeader")
	}
}

// A cell wider than its column must not be truncated -- a long snapshot
// description simply makes the row longer.
func TestOversizedCellNotTruncated(t *testing.T) {
	long := strings.Repeat("x", 200)
	g := Grid{RightAlign: []bool{false}, Rows: [][]string{{long}}}
	var b strings.Builder
	g.Render(&b)
	if !strings.Contains(b.String(), long) {
		t.Error("a long cell was truncated")
	}
}

func TestEmptyGrid(t *testing.T) {
	var b strings.Builder
	Grid{}.Render(&b)
	if b.String() != "" {
		t.Errorf("empty grid rendered %q", b.String())
	}
}

func TestPad(t *testing.T) {
	cases := []struct {
		s     string
		w     int
		right bool
		want  string
	}{
		{"ab", 5, false, "ab   "},
		{"ab", 5, true, "   ab"},
		{"abcdef", 3, false, "abcdef"},
		{"", 3, false, "   "},
		{"", 3, true, "   "},
	}
	for _, c := range cases {
		if got := pad(c.s, c.w, c.right); got != c.want {
			t.Errorf("pad(%q,%d,%v) = %q, want %q", c.s, c.w, c.right, got, c.want)
		}
	}
}
