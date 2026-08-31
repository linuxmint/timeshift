package rsyncx

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func corpus(t *testing.T, name string) []string {
	t.Helper()
	f, err := os.Open(filepath.Join("..", "..", "testdata", "rsync", name))
	if err != nil {
		t.Fatalf("open corpus: %v", err)
	}
	defer f.Close()
	var lines []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	return lines
}

func feed(t *testing.T, name string) *Parser {
	t.Helper()
	p := &Parser{KeepChanges: true}
	for _, l := range corpus(t, name) {
		p.Line(l)
	}
	return p
}

// A first transfer: everything is created, nothing is modified or deleted.
func TestFirstPass(t *testing.T) {
	p := feed(t, "create-first-pass.itemise")

	if p.Counters.Created == 0 {
		t.Fatal("no created entries parsed from a first transfer")
	}
	if p.Counters.Deleted != 0 {
		t.Errorf("deleted = %d, want 0 on a first pass", p.Counters.Deleted)
	}
	/* Exactly one: the destination root itself. Even on a first transfer
	 * rsync syncs the existing top-level directory's mtime and permissions,
	 * which it itemises as ".d..tp..... ./". Everything below it is created. */
	if p.Counters.Modified != 1 {
		t.Errorf("modified = %d, want 1 (the destination root ./)", p.Counters.Modified)
	}
	if p.TotalSize != 2528528 {
		t.Errorf("total size = %d, want 2528528 (comma-stripped)", p.TotalSize)
	}
	if p.StatusLine == "" {
		t.Error("no status line was captured")
	}
	if len(p.Changes) == 0 {
		t.Error("the changes sidecar is empty")
	}
}

// A repeat of the same transfer: everything unchanged, nothing created.
func TestUnchangedPass(t *testing.T) {
	p := feed(t, "create-unchanged-pass.itemise")

	if p.Counters.Unchanged == 0 {
		t.Fatal("no unchanged entries parsed from a repeat transfer")
	}
	if p.Counters.Created != 0 {
		t.Errorf("created = %d, want 0 when nothing changed", p.Counters.Created)
	}
	// Unchanged lines are not worth recording in the sidecar.
	for _, c := range p.Changes {
		if strings.Contains(c, ".f          ") {
			t.Errorf("an unchanged line reached the changes sidecar: %q", c)
		}
	}
}

// The mixed pass was produced by deleting 40 files, back-dating 25, chmod-ing
// 10 and adding an orphan directory in the destination.
func TestMixedPass(t *testing.T) {
	p := feed(t, "create-mixed-pass.itemise")

	if p.Counters.Created == 0 {
		t.Error("the re-copied files were not counted as created")
	}
	if p.Counters.Deleted != 2 {
		t.Errorf("deleted = %d, want 2 (the orphan file and its directory)", p.Counters.Deleted)
	}
	if p.Counters.Modified == 0 {
		t.Error("the back-dated and chmod-ed files were not counted as modified")
	}
	// 25 files were back-dated and 10 chmod-ed.
	if p.Counters.Timestamp == 0 {
		t.Error("no timestamp changes counted")
	}
	if p.Counters.Permissions == 0 {
		t.Error("no permission changes counted")
	}
}

// Every itemise column, including the ones this machine cannot produce.
func TestAllFlags(t *testing.T) {
	p := feed(t, "synthetic-all-flags.itemise")
	c := p.Counters

	checks := map[string]int64{
		"created":     c.Created,
		"deleted":     c.Deleted,
		"modified":    c.Modified,
		"checksum":    c.Checksum,
		"size":        c.Size,
		"timestamp":   c.Timestamp,
		"permissions": c.Permissions,
		"owner":       c.Owner,
		"group":       c.Group,
		"unchanged":   c.Unchanged,
	}
	for name, n := range checks {
		if n == 0 {
			t.Errorf("%s counter is 0; the corpus covers every column", name)
		}
	}
	if p.TotalSize != 123456 {
		t.Errorf("total size = %d", p.TotalSize)
	}
}

// Progress is a LINE count. This is the contract the whole progress display
// rests on, and the reason the rsync flags cannot be changed casually.
func TestProgressIsLineCount(t *testing.T) {
	p := &Parser{Total: 4}
	for _, l := range []string{
		">f+++++++++ a.txt",
		">f+++++++++ b.txt",
		"this line matches nothing at all",
		">f+++++++++ c.txt",
	} {
		p.Line(l)
	}

	if p.LineCount != 4 {
		t.Errorf("LineCount = %d; every line counts, matched or not", p.LineCount)
	}
	if got := p.Progress(); got != 1.0 {
		t.Errorf("Progress = %v, want 1.0", got)
	}
}

// A dry run can undercount, and showing 140%% is worse than pinning at 100.
func TestProgressClamps(t *testing.T) {
	p := &Parser{Total: 2}
	for i := 0; i < 10; i++ {
		p.Line(">f+++++++++ x")
	}
	if got := p.Progress(); got != 1.0 {
		t.Errorf("Progress = %v, want it clamped to 1.0", got)
	}
}

// No denominator means the UI must pulse rather than show a wrong bar.
func TestProgressWithoutTotal(t *testing.T) {
	p := &Parser{}
	p.Line(">f+++++++++ x")
	if got := p.Progress(); got != 0 {
		t.Errorf("Progress = %v, want 0 with no denominator", got)
	}
}

// Dispatch order matters: Modified's column patterns accept "+" and " ", so it
// would also match created and unchanged lines if it were tried first.
func TestDispatchOrder(t *testing.T) {
	p := &Parser{}
	p.Line(">f+++++++++ created.txt")
	if p.Counters.Created != 1 || p.Counters.Modified != 0 {
		t.Errorf("a created line was counted as modified: %+v", p.Counters)
	}

	p = &Parser{}
	p.Line(".f          unchanged.txt")
	if p.Counters.Unchanged != 1 || p.Counters.Modified != 0 {
		t.Errorf("an unchanged line was counted as modified: %+v", p.Counters)
	}
}

// A symlink line carries " -> target"; the status label wants the path only.
func TestSymlinkStatusLine(t *testing.T) {
	p := &Parser{}
	p.Line("cL+++++++++ usr/bin/link -> /usr/bin/target")
	if p.StatusLine != "usr/bin/link" {
		t.Errorf("StatusLine = %q, want the path without the target", p.StatusLine)
	}
}

func TestTotalSizeStripsCommas(t *testing.T) {
	p := &Parser{}
	p.Line("total size is 2,528,528  speedup is 0.99")
	if p.TotalSize != 2528528 {
		t.Errorf("TotalSize = %d", p.TotalSize)
	}
}

// The log file carries a timestamp prefix the console output does not.
func TestParseLogLine(t *testing.T) {
	cases := []struct {
		line string
		path string
		kind ChangeKind
	}{
		{"2026/08/31 12:00:00 [1234] >f+++++++++ etc/hosts", "etc/hosts", ChangeCreated},
		{"2026/08/31 12:00:00 [1234] *deleting   var/tmp/old", "var/tmp/old", ChangeDeleted},
		{"2026/08/31 12:00:00 [1234] .f          etc/passwd", "etc/passwd", ChangeUnchanged},
		{"2026/08/31 12:00:00 [1234] >f..t...... etc/fstab", "etc/fstab", ChangeTimestamp},
		{"2026/08/31 12:00:00 [1234] .f...p..... etc/shadow", "etc/shadow", ChangePermissions},
		{"2026/08/31 12:00:00 [1234] >fcst...... etc/motd", "etc/motd", ChangeChecksum},
	}
	for _, c := range cases {
		got, ok := ParseLogLine(c.line)
		if !ok {
			t.Errorf("ParseLogLine(%q) did not match", c.line)
			continue
		}
		if got.Path != c.path || got.Kind != c.kind {
			t.Errorf("ParseLogLine(%q) = %+v, want %s/%s", c.line, got, c.path, c.kind)
		}
	}

	// rsync's own chatter in the log is not a file.
	for _, line := range []string{
		"2026/08/31 12:00:00 [1234] building file list",
		"not a log line at all",
		"",
	} {
		if _, ok := ParseLogLine(line); ok {
			t.Errorf("ParseLogLine(%q) matched something that is not a change", line)
		}
	}
}

// The console lines have no timestamp prefix, so the log regexes must not match
// them -- otherwise the offline parse would double-count a console capture.
func TestLogRegexesRejectConsoleLines(t *testing.T) {
	if _, ok := ParseLogLine(">f+++++++++ etc/hosts"); ok {
		t.Error("a console line matched a log regex")
	}
}

func TestSpaceCheckSize(t *testing.T) {
	line := "sent 1,234,567 bytes  received 4,321 bytes  100,000.00 bytes/sec"
	if got := SpaceCheckSize(line); got != 1234567 {
		t.Errorf("SpaceCheckSize = %d, want 1234567", got)
	}
	if got := SpaceCheckSize("total size is 5  speedup is 1.00"); got != -1 {
		t.Errorf("SpaceCheckSize on an unrelated line = %d, want -1", got)
	}
}

// The whole corpus must parse without a line being counted twice.
func TestNoDoubleCounting(t *testing.T) {
	for _, name := range []string{
		"create-first-pass.itemise",
		"create-unchanged-pass.itemise",
		"create-mixed-pass.itemise",
		"synthetic-all-flags.itemise",
	} {
		p := feed(t, name)
		c := p.Counters
		classified := c.Created + c.Deleted + c.Unchanged + c.Modified
		if classified > p.LineCount {
			t.Errorf("%s: classified %d lines out of %d seen -- something matched twice",
				name, classified, p.LineCount)
		}
	}
}
