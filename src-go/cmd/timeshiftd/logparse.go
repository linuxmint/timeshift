package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"

	"github.com/makeafide/timeshift/src-go/internal/ipc"
	"github.com/makeafide/timeshift/src-go/internal/jobs"
	"github.com/makeafide/timeshift/src-go/internal/logging"
	"github.com/makeafide/timeshift/src-go/internal/rsyncx"
)

/* log.parse and log.entries.
 *
 * Parsing is a JOB, not a method that returns the answer, for two reasons.
 *
 * The first is size. A real snapshot's rsync log is 22 MB and a couple of
 * hundred thousand entries on an ordinary desktop; that is not a response, it
 * is a download. So the job parses once, keeps the result, and log.entries
 * serves pages out of it with the filtering done here rather than in every
 * client.
 *
 * The second is what the Vala code does today. RsyncLogBox parses by REPLACING
 * App.task with a fresh RsyncTask (RsyncLogBox.vala:250), which is why the
 * restore wizard has to disable Back and Next while a log is open -- the
 * progress fields the wizard polls are now describing a parse rather than a
 * restore. Making it its own job is what removes that.
 */

// parsedLog is one log file's parsed contents, held for paging.
type parsedLog struct {
	Path    string
	Changes []rsyncx.Change
	Counts  rsyncx.LogCounts
	Lines   int64
}

/* logCache holds recently parsed logs, keyed by the FILE they came from.
 *
 * Keyed by path rather than by job id, because the id is not available inside
 * the job's own run function -- Submit returns it, and the worker may already
 * be running by then. Path is the better key anyway: two clients asking for the
 * same log get one parse, and a client that reconnects can page through a
 * result it did not start.
 *
 * Capped and evicted oldest-first. Each entry can be tens of megabytes, and a
 * daemon that runs for months must not accumulate them. Two clients paging
 * through different logs at once is the case the cap has to survive, so it is
 * not one slot.
 */
type logCache struct {
	mu     sync.Mutex
	byPath map[string]*parsedLog
	order  []string
}

const logCacheSize = 4

func newLogCache() *logCache { return &logCache{byPath: map[string]*parsedLog{}} }

func (c *logCache) put(p *parsedLog) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if _, seen := c.byPath[p.Path]; !seen {
		c.order = append(c.order, p.Path)
	}
	c.byPath[p.Path] = p

	for len(c.order) > logCacheSize {
		oldest := c.order[0]
		c.order = c.order[1:]
		delete(c.byPath, oldest)
	}
}

func (c *logCache) get(path string) (*parsedLog, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	p, ok := c.byPath[path]
	return p, ok
}

// logParse submits a parse job and returns its id, like any other job.
func (d *daemon) logParse(ctx context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {
	in, err := decode[ipc.LogParseParams](params)
	if err != nil {
		return nil, err
	}

	target, err := d.resolveLogPath(ctx, in)
	if err != nil {
		return nil, err
	}

	job, err := d.queue.Submit(jobs.KindParseLog, func(ctx context.Context, r jobs.Reporter) (jobs.Outcome, error) {
		return d.runLogParse(ctx, r, target)
	})
	if err != nil {
		return nil, ipc.Errf(ipc.CodeBusy, "%v", err)
	}
	return ipc.LogParseResult{Job: job.ID, Path: target}, nil
}

func (d *daemon) runLogParse(ctx context.Context, r jobs.Reporter, target string) (jobs.Outcome, error) {
	r.SetPhases([]jobs.Phase{{Key: "parse_log", Title: "Reading the log"}})
	r.Phase("parse_log")

	f, err := os.Open(target)
	if err != nil {
		return jobs.OutcomeFailed, err
	}
	defer f.Close()

	/* The denominator is the file's size in lines, which is not known until it
	 * has been read. Rather than read it twice, progress is reported against
	 * bytes consumed -- the one number available up front. */
	total := int64(0)
	if st, err := f.Stat(); err == nil {
		total = st.Size()
	}

	counted := &countingReader{r: bufio.NewReaderSize(f, 1<<20)}

	var changes []rsyncx.Change
	counts, lines, err := rsyncx.ParseLog(counted,
		func(c rsyncx.Change) { changes = append(changes, c) },
		func(n int64) {
			if r.Cancelled() {
				return
			}
			r.Progress(jobs.Progress{
				Count: counted.n, Total: total,
				StatusLine: fmt.Sprintf("%d lines", n),
			})
		})
	if err != nil {
		return jobs.OutcomeFailed, err
	}
	if r.Cancelled() {
		return jobs.OutcomeFailed, context.Canceled
	}

	d.logCache.put(&parsedLog{
		Path: target, Changes: changes, Counts: counts, Lines: lines,
	})

	r.Note(fmt.Sprintf("%d changes in %d lines", len(changes), lines))
	return jobs.OutcomeOK, nil
}

// logEntries serves a page of a parsed log.
func (d *daemon) logEntries(_ context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {
	in, err := decode[ipc.LogEntriesParams](params)
	if err != nil {
		return nil, err
	}

	p, ok := d.logCache.get(in.Path)
	if !ok {
		return nil, ipc.Errf(ipc.CodeNotFound,
			"%s has not been parsed, or the result was evicted; call log.parse first", in.Path)
	}

	// Filtering here rather than in every client, because the whole point of
	// paging is not to send what is not wanted.
	wanted := map[rsyncx.ChangeKind]bool{}
	for _, k := range in.Kinds {
		wanted[rsyncx.ChangeKind(k)] = true
	}

	matched := p.Changes
	if len(wanted) > 0 {
		matched = matched[:0:0]
		for _, c := range p.Changes {
			if wanted[c.Kind] {
				matched = append(matched, c)
			}
		}
	}

	limit := in.Limit
	if limit <= 0 || limit > ipc.LogEntriesMaxLimit {
		limit = ipc.LogEntriesMaxLimit
	}
	start := in.Offset
	if start < 0 {
		start = 0
	}
	if start > len(matched) {
		start = len(matched)
	}
	end := start + limit
	if end > len(matched) {
		end = len(matched)
	}

	page := make([]ipc.LogEntry, 0, end-start)
	for _, c := range matched[start:end] {
		page = append(page, ipc.LogEntry{Path: c.Path, Kind: string(c.Kind), IsDir: c.IsDir})
	}

	counts := map[string]int{}
	for k, n := range p.Counts {
		counts[string(k)] = n
	}

	return ipc.LogEntriesResult{
		Path:    p.Path,
		Total:   len(matched),
		Lines:   p.Lines,
		Counts:  counts,
		Offset:  start,
		Entries: page,
		More:    end < len(matched),
	}, nil
}

/* resolveLogPath decides which file may be read, and refuses everything else.
 *
 * Without this, log.parse is an arbitrary-file-read primitive: the daemon runs
 * as root, and a caller could name /etc/shadow and get it back a line at a
 * time. Only two places hold Timeshift logs, so only two are allowed --
 * /var/log/timeshift, and a log inside a snapshot of the configured repository.
 *
 * Symlinks are resolved before the prefix test, because the question is where
 * the target is rather than where the name is.
 */
func (d *daemon) resolveLogPath(ctx context.Context, in ipc.LogParseParams) (string, error) {
	if in.Snapshot != "" {
		/* Validate the name BEFORE opening anything. It needs no repository,
		 * and refusing "../../../etc/shadow" should not depend on whether a
		 * remote host happens to be reachable. */
		name := in.Name
		if name == "" {
			name = "rsync-log"
		}
		if name != path.Base(name) || name == "." || name == ".." {
			return "", ipc.Errf(ipc.CodeBadRequest, "%q is not a log name", name)
		}

		repo, _, _, err := d.openRepoFor(ctx, nil)
		if err != nil {
			return "", ipc.Errf(ipc.CodeUnavailable, "%v", err)
		}
		defer repo.Close()

		snap, err := findSnapshot(ctx, repo, in.Snapshot)
		if err != nil {
			return "", err
		}
		/* A remote snapshot's log is not a local file, so it cannot be opened
		 * here. Saying so beats failing later with "no such file". */
		if !isLocalPath(snap.Path) {
			return "", ipc.Errf(ipc.CodeBadRequest,
				"the log of a remote snapshot cannot be parsed directly; browse the snapshot first")
		}
		return path.Join(snap.Path, name), nil
	}

	if in.Path == "" {
		return "", ipc.Errf(ipc.CodeBadRequest, "log.parse needs a path or a snapshot")
	}

	clean := path.Clean(in.Path)
	if resolved, err := filepath.EvalSymlinks(clean); err == nil {
		clean = resolved
	}
	if !strings.HasPrefix(clean, logging.Dir+string(os.PathSeparator)) {
		return "", ipc.Errf(ipc.CodeBadRequest,
			"%s is not a Timeshift log; only files under %s can be parsed by path",
			in.Path, logging.Dir)
	}
	return clean, nil
}

// isLocalPath reports whether a snapshot path names something on this machine.
func isLocalPath(p string) bool {
	if p == "" || !strings.HasPrefix(p, "/") {
		return false
	}
	_, err := os.Stat(p)
	return err == nil
}

// countingReader tallies bytes so progress has a denominator the file can
// supply up front. A line count cannot: it is not known until the read is done.
type countingReader struct {
	r interface{ Read([]byte) (int, error) }
	n int64
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += int64(n)
	return n, err
}
