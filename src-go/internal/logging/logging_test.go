package logging

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestOpenNamesAndPermissions(t *testing.T) {
	dir := t.TempDir()
	when := time.Date(2026, 8, 31, 16, 15, 21, 0, time.UTC)

	s, err := Open(Options{
		Dir:     dir,
		Mode:    "ondemand",
		Console: &bytes.Buffer{},
		Now:     func() time.Time { return when },
	})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	want := filepath.Join(dir, "2026-08-31_16-15-21_ondemand.log")
	if s.Path != want {
		t.Errorf("path = %q, want %q", s.Path, want)
	}

	fi, err := os.Stat(s.Path)
	if err != nil {
		t.Fatal(err)
	}
	// Session logs carry command lines and device details and are kept for
	// hundreds of runs; there is no reason for them to be world-readable.
	if fi.Mode().Perm() != 0600 {
		t.Errorf("mode = %v, want 0600", fi.Mode().Perm())
	}
}

func TestLogsToBothSinks(t *testing.T) {
	dir := t.TempDir()
	var console bytes.Buffer

	s, err := Open(Options{Dir: dir, Mode: "backup", Console: &console})
	if err != nil {
		t.Fatal(err)
	}
	s.Logger.Info("creating snapshot", "tag", "O")
	s.Close()

	if !strings.Contains(console.String(), "creating snapshot") {
		t.Error("console sink did not receive the record")
	}
	body, err := os.ReadFile(s.Path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "creating snapshot") {
		t.Error("file sink did not receive the record")
	}
	if !strings.Contains(string(body), "tag=O") {
		t.Error("structured attribute lost")
	}
}

// An unwritable log directory must not stop the daemon: a full /var/log is no
// reason for backups to stop happening.
func TestUnwritableDirStillLogs(t *testing.T) {
	var console bytes.Buffer
	s, err := Open(Options{
		Dir:     "/proc/definitely/not/writable",
		Mode:    "backup",
		Console: &console,
	})
	if err != nil {
		t.Fatalf("Open must not fail when the log dir is unusable: %v", err)
	}
	defer s.Close()

	if s.Path != "" {
		t.Errorf("Path should be empty when no file could be opened, got %q", s.Path)
	}
	s.Logger.Info("still running")
	if !strings.Contains(console.String(), "still running") {
		t.Error("console logging must keep working without a file")
	}
}

func TestDebugLevelGate(t *testing.T) {
	for _, debug := range []bool{false, true} {
		var console bytes.Buffer
		s, _ := Open(Options{Dir: t.TempDir(), Console: &console, Debug: debug})
		s.Logger.Debug("chatty")
		s.Close()

		got := strings.Contains(console.String(), "chatty")
		if got != debug {
			t.Errorf("debug=%v: record emitted=%v, want %v", debug, got, debug)
		}
	}
}

func TestCleanOld(t *testing.T) {
	dir := t.TempDir()

	// Names sort chronologically, which is what CleanOld relies on instead of
	// stat-ing every file.
	total := Keep + 40
	for i := 0; i < total; i++ {
		name := fmt.Sprintf("2026-01-%02d_%02d-00-00_backup.log", 1+i/24, i%24)
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	// Non-log files must be left alone.
	os.WriteFile(filepath.Join(dir, "notes.txt"), []byte("keep me"), 0644)

	removed, err := CleanOld(dir)
	if err != nil {
		t.Fatal(err)
	}
	if removed != Prune {
		t.Errorf("removed %d, want %d", removed, Prune)
	}
	if !FileStillThere(filepath.Join(dir, "notes.txt")) {
		t.Error("CleanOld deleted a non-log file")
	}

	entries, _ := os.ReadDir(dir)
	if len(entries) != total-Prune+1 {
		t.Errorf("directory holds %d entries, want %d", len(entries), total-Prune+1)
	}
}

func TestCleanOldUnderThreshold(t *testing.T) {
	dir := t.TempDir()
	for i := 0; i < 10; i++ {
		os.WriteFile(filepath.Join(dir, fmt.Sprintf("2026-01-01_00-00-%02d_x.log", i)), []byte("x"), 0600)
	}
	removed, err := CleanOld(dir)
	if err != nil {
		t.Fatal(err)
	}
	if removed != 0 {
		t.Errorf("removed %d below the threshold, want 0", removed)
	}
}

func TestCleanOldMissingDir(t *testing.T) {
	removed, err := CleanOld(filepath.Join(t.TempDir(), "absent"))
	if err != nil {
		t.Errorf("a missing log dir must not be an error: %v", err)
	}
	if removed != 0 {
		t.Errorf("removed %d, want 0", removed)
	}
}

func TestRing(t *testing.T) {
	r := NewRing(3)

	if got := r.Lines(); len(got) != 0 {
		t.Errorf("new ring has %d lines, want 0", len(got))
	}

	r.Add("a")
	r.Add("b")
	if got := strings.Join(r.Lines(), ","); got != "a,b" {
		t.Errorf("partial ring = %q, want a,b", got)
	}

	r.Add("c")
	if got := strings.Join(r.Lines(), ","); got != "a,b,c" {
		t.Errorf("full ring = %q, want a,b,c", got)
	}

	// Wrapping discards the oldest, which is the whole point: a client
	// attaching to a long backup gets the tail, not an OOM.
	r.Add("d")
	if got := strings.Join(r.Lines(), ","); got != "b,c,d" {
		t.Errorf("wrapped ring = %q, want b,c,d", got)
	}

	r.Add("e")
	r.Add("f")
	if got := strings.Join(r.Lines(), ","); got != "d,e,f" {
		t.Errorf("twice-wrapped ring = %q, want d,e,f", got)
	}

	if r.Total() != 6 {
		t.Errorf("Total = %d, want 6 (including discarded)", r.Total())
	}
}

func TestRingConcurrent(t *testing.T) {
	r := NewRing(64)
	done := make(chan struct{})
	// Handlers run on the reader goroutines while the job loop reads; the race
	// detector on this test is the point.
	for i := 0; i < 4; i++ {
		go func(n int) {
			for j := 0; j < 500; j++ {
				r.Add(fmt.Sprintf("w%d-%d", n, j))
			}
			done <- struct{}{}
		}(i)
	}
	for i := 0; i < 100; i++ {
		_ = r.Lines()
		_ = r.Total()
	}
	for i := 0; i < 4; i++ {
		<-done
	}
	if r.Total() != 2000 {
		t.Errorf("Total = %d, want 2000", r.Total())
	}
}

func FileStillThere(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}
