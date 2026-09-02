package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/makeafide/timeshift/src-go/internal/ipc"
	"github.com/makeafide/timeshift/src-go/internal/rsyncx"
)

/* log.parse reads a file as root, on request, over a socket. Without a guard it
 * is an arbitrary-file-read primitive: name /etc/shadow and get it back a line
 * at a time. Only Timeshift's own log directory may be named by path. */
func TestLogParseRefusesFilesOutsideTheLogDirectory(t *testing.T) {
	d := &daemon{}

	refused := []string{
		"/etc/shadow",
		"/etc/timeshift/ssh/id_ed25519",
		"/home/someone/.ssh/id_rsa",
		"/var/log/syslog",
		"/var/log/timeshift-other/x.log", // prefix that is not a path boundary
		"/var/log/timeshiftevil",
		"/var/log/timeshift/../../../etc/shadow",
		"relative/path",
		"",
	}
	for _, p := range refused {
		if got, _, err := d.resolveLogPath(context.Background(), ipc.LogParseParams{Path: p}); err == nil {
			t.Errorf("resolveLogPath(%q) accepted, resolved to %q", p, got)
		}
	}

	accepted := map[string]string{
		"/var/log/timeshift/rsync-log-restore": "/var/log/timeshift/rsync-log-restore",
		"/var/log/timeshift//a//b.log":         "/var/log/timeshift/a/b.log",
		"/var/log/timeshift/2026-01-01_x.log":  "/var/log/timeshift/2026-01-01_x.log",
	}
	for in, want := range accepted {
		got, _, err := d.resolveLogPath(context.Background(), ipc.LogParseParams{Path: in})
		if err != nil {
			t.Errorf("resolveLogPath(%q) was refused: %v", in, err)
			continue
		}
		if got != want {
			t.Errorf("resolveLogPath(%q) = %q, want %q", in, got, want)
		}
	}
}

// A log name inside a snapshot must not be able to climb out of it.
func TestSnapshotLogNameCannotEscape(t *testing.T) {
	d := &daemon{}
	for _, name := range []string{"../../../etc/shadow", "..", "a/b", "/etc/shadow"} {
		_, _, err := d.resolveLogPath(context.Background(),
			ipc.LogParseParams{Snapshot: "2026-01-01_00-00-00", Name: name})
		if err == nil {
			t.Errorf("log name %q was accepted", name)
		}
	}
}

// seedLog writes a small but real-shaped rsync log.
func seedLog(t *testing.T, dir string) string {
	t.Helper()
	p := filepath.Join(dir, "rsync-log")
	var b strings.Builder
	for i := 0; i < 40; i++ {
		b.WriteString("2026/08/31 12:00:00 [1] >f+++++++++ created-" + strconv.Itoa(i) + "\n")
	}
	for i := 0; i < 15; i++ {
		b.WriteString("2026/08/31 12:00:00 [1] *deleting   gone-" + strconv.Itoa(i) + "\n")
	}
	b.WriteString("2026/08/31 12:00:00 [1] rsync chatter that is not a change\n")
	if err := os.WriteFile(p, []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

/* Paging, filtering and the counts, which is what the cache exists for: a real
 * snapshot log holds a couple of hundred thousand entries, so serving it in one
 * response is a download rather than an answer. */
func TestLogEntriesPagesAndFilters(t *testing.T) {
	dir := t.TempDir()
	p := seedLog(t, dir)

	d := &daemon{logCache: newLogCache()}

	f, err := os.Open(p)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	var changes []rsyncx.Change
	counts, lines, err := rsyncx.ParseLog(f, func(c rsyncx.Change) { changes = append(changes, c) }, nil)
	if err != nil {
		t.Fatal(err)
	}
	d.logCache.put(&parsedLog{Path: p, Changes: changes, Counts: counts, Lines: lines})

	call := func(in ipc.LogEntriesParams) ipc.LogEntriesResult {
		t.Helper()
		raw, _ := json.Marshal(in)
		out, err := d.logEntries(context.Background(), nil, raw)
		if err != nil {
			t.Fatalf("logEntries(%+v): %v", in, err)
		}
		return out.(ipc.LogEntriesResult)
	}

	all := call(ipc.LogEntriesParams{Path: p})
	if all.Total != 55 {
		t.Errorf("Total = %d, want 55", all.Total)
	}
	if all.Lines != 56 {
		t.Errorf("Lines = %d, want 56 (the chatter line counts as read)", all.Lines)
	}
	if all.Counts["created"] != 40 || all.Counts["deleted"] != 15 {
		t.Errorf("Counts = %v", all.Counts)
	}

	// Paging.
	first := call(ipc.LogEntriesParams{Path: p, Limit: 10})
	if len(first.Entries) != 10 || !first.More {
		t.Fatalf("first page: %d entries, More=%v", len(first.Entries), first.More)
	}
	last := call(ipc.LogEntriesParams{Path: p, Offset: 50, Limit: 10})
	if len(last.Entries) != 5 || last.More {
		t.Fatalf("last page: %d entries, More=%v", len(last.Entries), last.More)
	}
	if first.Entries[0].Path == last.Entries[0].Path {
		t.Error("paging returned the same entry twice")
	}

	// An offset past the end is empty, not an error and not a panic.
	past := call(ipc.LogEntriesParams{Path: p, Offset: 10000})
	if len(past.Entries) != 0 || past.More {
		t.Errorf("offset past the end: %d entries, More=%v", len(past.Entries), past.More)
	}

	// Filtering happens here, so the client is not sent what it did not want.
	deleted := call(ipc.LogEntriesParams{Path: p, Kinds: []string{"deleted"}})
	if deleted.Total != 15 {
		t.Errorf("filtered Total = %d, want 15", deleted.Total)
	}
	for _, e := range deleted.Entries {
		if e.Kind != "deleted" {
			t.Fatalf("filter leaked a %q entry", e.Kind)
		}
	}

	// The unfiltered counts still describe the whole log, so a summary stays
	// truthful while a filter is applied.
	if deleted.Counts["created"] != 40 {
		t.Errorf("filtering changed the summary counts: %v", deleted.Counts)
	}
}

// An unparsed path is a clear refusal, not an empty page that reads as "this
// log had no changes".
func TestLogEntriesForAnUnparsedPathIsAnError(t *testing.T) {
	d := &daemon{logCache: newLogCache()}
	raw, _ := json.Marshal(ipc.LogEntriesParams{Path: "/var/log/timeshift/never-parsed"})
	if _, err := d.logEntries(context.Background(), nil, raw); err == nil {
		t.Fatal("an unparsed path returned a result")
	}
}

/* The cache is capped. Each entry can be tens of megabytes, and a daemon that
 * runs for months must not accumulate them. */
func TestLogCacheEvictsOldestFirst(t *testing.T) {
	c := newLogCache()
	for i := 0; i < logCacheSize+3; i++ {
		c.put(&parsedLog{Path: "/var/log/timeshift/log-" + strconv.Itoa(i)})
	}

	if _, ok := c.get("/var/log/timeshift/log-0"); ok {
		t.Error("the oldest entry survived eviction")
	}
	newest := "/var/log/timeshift/log-" + strconv.Itoa(logCacheSize+2)
	if _, ok := c.get(newest); !ok {
		t.Error("the newest entry was evicted")
	}

	c.mu.Lock()
	n := len(c.byPath)
	c.mu.Unlock()
	if n != logCacheSize {
		t.Errorf("cache holds %d entries, want %d", n, logCacheSize)
	}
}

// Re-parsing the same file replaces its entry rather than growing the cache.
func TestLogCacheReplacesRatherThanDuplicates(t *testing.T) {
	c := newLogCache()
	c.put(&parsedLog{Path: "/var/log/timeshift/a", Lines: 1})
	c.put(&parsedLog{Path: "/var/log/timeshift/a", Lines: 2})

	c.mu.Lock()
	n, order := len(c.byPath), len(c.order)
	c.mu.Unlock()
	if n != 1 || order != 1 {
		t.Fatalf("cache holds %d entries / %d in order, want 1 / 1", n, order)
	}
	if p, _ := c.get("/var/log/timeshift/a"); p.Lines != 2 {
		t.Error("the re-parse did not replace the earlier result")
	}
}
