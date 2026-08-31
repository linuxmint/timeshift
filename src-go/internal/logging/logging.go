// Package logging sets up the daemon's session log.
//
// It reproduces two things from TeeJee.Logging that are contracts rather than
// taste: the log file lives at /var/log/timeshift/<timestamp>_<mode>.log and is
// chmod 0600 (session logs record command lines and device details and are kept
// for hundreds of runs), and old sessions are pruned so the directory does not
// grow without bound.
//
// What it does not reproduce is the global `dos_log` stream. A logger is
// created and passed; nothing here is package state.
package logging

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Dir is where session logs are written.
const Dir = "/var/log/timeshift"

// TimestampLayout is the filename timestamp, matching timestamp_for_path().
const TimestampLayout = "2006-01-02_15-04-05"

/* Pruning thresholds from Main.clean_logs(): once the directory holds more than
 * Keep sessions, remove the Prune oldest. Deleting in batches rather than one
 * per run keeps the directory scan off the hot path. */
const (
	Keep  = 500
	Prune = 100
)

// Options configures Open.
type Options struct {
	// Dir overrides the log directory. Empty uses Dir.
	Dir string
	// Mode is the filename suffix: "gui" for the GUI, otherwise the app mode
	// ("backup", "ondemand", "restore", "delete", ...). Empty becomes "daemon".
	Mode string
	// Debug enables slog.LevelDebug on both sinks.
	Debug bool
	// Console additionally writes to this writer. Nil means os.Stdout; use
	// io.Discard for a daemon that should only write to its file.
	Console io.Writer
	// Now overrides the clock, for tests.
	Now func() time.Time
}

// Session is an open session log.
type Session struct {
	Logger *slog.Logger
	Path   string

	file *os.File
}

// Open creates the session log file and returns a logger writing to it and to
// the console.
//
// A log directory that cannot be created is not fatal: the daemon still runs
// and logs to the console alone. Refusing to start because /var/log is full
// would take backups down for a reason that has nothing to do with backups.
func Open(o Options) (*Session, error) {
	dir := o.Dir
	if dir == "" {
		dir = Dir
	}
	mode := o.Mode
	if mode == "" {
		mode = "daemon"
	}
	now := o.Now
	if now == nil {
		now = time.Now
	}
	console := o.Console
	if console == nil {
		console = os.Stdout
	}

	level := slog.LevelInfo
	if o.Debug {
		level = slog.LevelDebug
	}

	s := &Session{}
	writers := []io.Writer{console}

	if err := os.MkdirAll(dir, 0755); err == nil {
		name := fmt.Sprintf("%s_%s.log", now().Format(TimestampLayout), mode)
		path := filepath.Join(dir, name)
		// 0600 from the start rather than create-then-chmod: the window in
		// between is small but it is a window.
		f, ferr := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
		if ferr == nil {
			s.file = f
			s.Path = path
			writers = append(writers, f)
		}
	}

	h := slog.NewTextHandler(io.MultiWriter(writers...), &slog.HandlerOptions{
		Level: level,
		ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
			// Seconds are enough for a log read by humans after the fact, and
			// it keeps lines narrow enough to scan.
			if a.Key == slog.TimeKey {
				a.Value = slog.StringValue(a.Value.Time().Format("15:04:05"))
			}
			return a
		},
	})

	s.Logger = slog.New(h)
	return s, nil
}

// Close closes the log file.
func (s *Session) Close() error {
	if s.file == nil {
		return nil
	}
	return s.file.Close()
}

// CleanOld removes the oldest session logs once the directory holds more than
// Keep of them. Called at daemon startup, where a slow directory scan does not
// matter -- not per operation.
func CleanOld(dir string) (removed int, err error) {
	if dir == "" {
		dir = Dir
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, fmt.Errorf("logging: read %s: %w", dir, err)
	}

	var names []string
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".log") {
			continue
		}
		names = append(names, e.Name())
	}
	if len(names) <= Keep {
		return 0, nil
	}

	// The filename starts with a sortable timestamp, so lexical order is
	// chronological order and no stat calls are needed.
	sort.Strings(names)

	for i := 0; i < Prune && i < len(names); i++ {
		if err := os.Remove(filepath.Join(dir, names[i])); err == nil {
			removed++
		}
	}
	return removed, nil
}

// Ring is a bounded FIFO of log lines.
//
// Every job keeps one so a client attaching midway can be shown what it has
// missed -- the replay half of jobs.subscribe. It is also what the GUI's
// LogPane reads, which is why the cap is in lines rather than bytes.
type Ring struct {
	mu    sync.Mutex
	buf   []string
	next  int
	full  bool
	total int64
}

// NewRing returns a ring holding at most size lines.
func NewRing(size int) *Ring {
	if size <= 0 {
		size = 1
	}
	return &Ring{buf: make([]string, size)}
}

// Add appends a line, discarding the oldest when full.
func (r *Ring) Add(line string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.buf[r.next] = line
	r.next = (r.next + 1) % len(r.buf)
	if r.next == 0 {
		r.full = true
	}
	r.total++
}

// Lines returns the buffered lines, oldest first.
func (r *Ring) Lines() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.full {
		out := make([]string, r.next)
		copy(out, r.buf[:r.next])
		return out
	}
	out := make([]string, 0, len(r.buf))
	out = append(out, r.buf[r.next:]...)
	out = append(out, r.buf[:r.next]...)
	return out
}

// Total is how many lines have ever been added, including discarded ones. The
// UI uses it to say "showing the last N of M".
func (r *Ring) Total() int64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.total
}
