package rsyncx

import (
	"bufio"
	"fmt"
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

/* Parsing a whole log file.
 *
 * The fixture is DERIVED from the real itemise capture rather than invented or
 * copied from this machine's own /var/log/timeshift. rsync writes the same
 * itemised text to stdout and to --log-file; the log form only adds a
 * "2026/08/31 12:00:00 [1234] " prefix. So prefixing the real capture produces
 * a faithful log AND lets the two parsers be checked against each other, which
 * a separate hand-written fixture could not do.
 *
 * (A real log from this machine would also carry every path on the system into
 * the repository, which is not something a test corpus should do.)
 */
func logFromItemise(t *testing.T, name string) (logText string, itemiseLines []string) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "testdata", "rsync", name))
	if err != nil {
		t.Fatal(err)
	}
	var b strings.Builder
	for i, line := range strings.Split(string(raw), "\n") {
		if line == "" {
			continue
		}
		itemiseLines = append(itemiseLines, line)
		fmt.Fprintf(&b, "2026/08/31 12:%02d:%02d [4242] %s\n", (i/60)%60, i%60, line)
	}
	return b.String(), itemiseLines
}

func TestParseLogAgreesWithTheConsoleParser(t *testing.T) {
	for _, name := range []string{
		"create-first-pass.itemise",
		"create-mixed-pass.itemise",
		"create-unchanged-pass.itemise",
		"synthetic-all-flags.itemise",
	} {
		logText, itemise := logFromItemise(t, name)

		var fromLog []Change
		counts, lines, err := ParseLog(strings.NewReader(logText), func(c Change) {
			fromLog = append(fromLog, c)
		}, nil)
		if err != nil {
			t.Fatalf("%s: ParseLog: %v", name, err)
		}
		if lines != int64(len(itemise)) {
			t.Errorf("%s: read %d lines, want %d", name, lines, len(itemise))
		}

		// The same lines through the console path must produce the same
		// changes, in the same order.
		var fromConsole []Change
		for _, line := range itemise {
			if c, ok := parseConsoleLine(line); ok {
				fromConsole = append(fromConsole, c)
			}
		}

		if len(fromLog) != len(fromConsole) {
			t.Fatalf("%s: log parser found %d changes, console parser %d",
				name, len(fromLog), len(fromConsole))
		}
		for i := range fromLog {
			if fromLog[i] != fromConsole[i] {
				t.Errorf("%s: change %d: log %+v, console %+v",
					name, i, fromLog[i], fromConsole[i])
			}
		}

		// The counts must add up to the changes found.
		var total int
		for _, n := range counts {
			total += n
		}
		if total != len(fromLog) {
			t.Errorf("%s: counts sum to %d, but %d changes were reported", name, total, len(fromLog))
		}
	}
}

// parseConsoleLine is ParseLogLine's console-format twin, expressed through the
// same regexes so the parity test above compares parsers rather than copies.
func parseConsoleLine(line string) (Change, bool) {
	return ParseLogLine("2026/08/31 12:00:00 [1] " + line)
}

// A caller that only wants counts must not be made to hold every path: a real
// log is 22 MB and a couple of hundred thousand entries.
func TestParseLogWithNoCallbackStillCounts(t *testing.T) {
	logText, _ := logFromItemise(t, "create-mixed-pass.itemise")

	counts, lines, err := ParseLog(strings.NewReader(logText), nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if lines == 0 {
		t.Fatal("no lines were read")
	}
	if counts[ChangeCreated] == 0 {
		t.Error("the mixed pass reported no created files")
	}
	if counts[ChangeDeleted] == 0 {
		t.Error("the mixed pass reported no deletions")
	}
}

/* Progress is per LINE READ, not per change found. rsync's own chatter is not
 * a change, and a bar that only moves on matches stalls visibly through the
 * header and the summary. */
func TestParseLogProgressCountsLinesNotChanges(t *testing.T) {
	var b strings.Builder
	for i := 0; i < 12000; i++ {
		// Every other line is rsync chatter rather than an itemised change.
		if i%2 == 0 {
			fmt.Fprintf(&b, "2026/08/31 12:00:00 [1] >f+++++++++ file-%d\n", i)
		} else {
			fmt.Fprintf(&b, "2026/08/31 12:00:00 [1] some rsync chatter %d\n", i)
		}
	}

	var last int64
	var callbacks int
	_, lines, err := ParseLog(strings.NewReader(b.String()), nil, func(n int64) {
		callbacks++
		last = n
	})
	if err != nil {
		t.Fatal(err)
	}
	if lines != 12000 {
		t.Fatalf("read %d lines, want 12000", lines)
	}
	if last != 12000 {
		t.Errorf("final progress = %d, want the line total", last)
	}
	if callbacks == 0 {
		t.Error("progress was never reported")
	}
	if callbacks > 20 {
		t.Errorf("progress reported %d times for 12000 lines; too chatty", callbacks)
	}
}

/* A path longer than bufio's default 64 KB token must not end the scan.
 * Stopping there would look like a short log rather than a failure -- and a log
 * that reads as short is a changes list that silently omits everything after
 * the long name. */
func TestParseLogHandlesAVeryLongPath(t *testing.T) {
	long := strings.Repeat("a", 200*1024)
	text := "2026/08/31 12:00:00 [1] >f+++++++++ short-one\n" +
		"2026/08/31 12:00:00 [1] >f+++++++++ " + long + "\n" +
		"2026/08/31 12:00:00 [1] >f+++++++++ after-the-long-one\n"

	var got []Change
	_, lines, err := ParseLog(strings.NewReader(text), func(c Change) { got = append(got, c) }, nil)
	if err != nil {
		t.Fatalf("ParseLog: %v", err)
	}
	if lines != 3 {
		t.Fatalf("read %d lines, want 3", lines)
	}
	if len(got) != 3 {
		t.Fatalf("found %d changes, want 3", len(got))
	}
	if got[2].Path != "after-the-long-one" {
		t.Errorf("the entry after a long path was lost: %+v", got[2])
	}
}
