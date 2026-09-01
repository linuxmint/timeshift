// Package rsyncx builds rsync command lines and parses its itemised output.
//
// The single most important thing here: **progress is a line count, not a byte
// count**. Every line rsync prints advances the counter, and the denominator
// comes from a separate dry run. Change the rsync flags and the number of lines
// a transfer emits changes with them, which silently skews every progress bar
// in the application. That is why Args() and the restore script's rsync have to
// stay in step.
package rsyncx

import (
	"bufio"
	"io"
	"regexp"
	"strconv"
	"strings"
)

/* rsync's --itemize-changes format, from rsync(1):
 *
 *   column 1: < > transferred, c created locally, h hard link,
 *             . not updated, * the rest of the area is a message
 *   column 2: f file, d directory, L symlink, D device, S special
 *   columns 3-11: c checksum, s size, t mtime, p permissions, o owner,
 *             g group, u reserved, a ACL, x xattr
 *
 * The regexes below are ported from RsyncTask.init_regular_expressions(). The
 * `Log*` twins additionally match the timestamp prefix rsync writes into a
 * --log-file, which is what the offline changes-parser reads.
 */
var (
	reCreated   = regexp.MustCompile(`^([<>ch.*])([.fdLDS])[+]{9} (.*)$`)
	reDeleted   = regexp.MustCompile(`^\*deleting[ \t]+(.*)$`)
	reUnchanged = regexp.MustCompile(`^([.h])([.fdLDS])[ ]{9} (.*)$`)
	reModified  = regexp.MustCompile(
		`^([<>ch.])([.fdLDS])(c|\+|\.| )(s|\+|\.| )(t|\+|\.| )(p|\+|\.| )(o|\+|\.| )(g|\+|\.| )(u|\+|\.| )(a|\+|\.| )(x|\+|\.) (.*)$`)
	reTotalSize = regexp.MustCompile(`total size is ([0-9,]+)[ \t]+speedup is [0-9.]+`)

	logPrefix = `^[0-9/]+ [0-9:.]+ \[[0-9]+\] `

	reLogCreated   = regexp.MustCompile(logPrefix + `([<>ch.*])([.fdLDS])[+]{9} (.*)$`)
	reLogDeleted   = regexp.MustCompile(logPrefix + `\*deleting[ \t]+(.*)$`)
	reLogUnchanged = regexp.MustCompile(logPrefix + `([.h])([.fdLDS])[ ]{9} (.*)$`)
	reLogModified  = regexp.MustCompile(logPrefix +
		`([<>ch.])([.fdLDS])(c|\+|\.| )(s|\+|\.| )(t|\+|\.| )(p|\+|\.| )(o|\+|\.| )(g|\+|\.| )(u|\+|\.| )(a|\+|\.| )(x|\+|\.) (.*)$`)
)

// Counters are the per-change tallies the progress view shows.
type Counters struct {
	Created     int64
	Deleted     int64
	Modified    int64
	Checksum    int64
	Size        int64
	Timestamp   int64
	Permissions int64
	Owner       int64
	Group       int64
	Unchanged   int64
}

// Parser accumulates state across the lines of one rsync run.
//
// Not safe for concurrent use: feed it from one goroutine. The reader goroutine
// in sysexec is that one goroutine.
type Parser struct {
	// Total is the denominator, measured by a previous dry run. Zero means
	// progress cannot be computed and the UI should pulse instead.
	Total int64

	// LineCount is how many lines have been seen. This IS the progress
	// numerator.
	LineCount int64

	// TotalSize is the "total size is N" figure from rsync's summary.
	TotalSize int64

	// StatusLine is the most recent path, for the "currently doing" label.
	StatusLine string

	Counters Counters

	// Changes collects the created, deleted and modified lines, which become
	// the `-changes` sidecar next to the rsync log.
	Changes []string

	// KeepChanges controls whether Changes is accumulated. A restore of a full
	// system produces millions of lines; the sidecar is only wanted for a
	// backup.
	KeepChanges bool
}

// Progress is the completed fraction, 0..1. Zero when there is no denominator.
func (p *Parser) Progress() float64 {
	if p.Total <= 0 {
		return 0
	}
	f := float64(p.LineCount) / float64(p.Total)
	if f > 1 {
		// A dry run can undercount; showing 140% is worse than pinning at 100.
		return 1
	}
	return f
}

// Line consumes one line of rsync output.
//
// The dispatch order is load-bearing and matches RsyncTask: created, deleted,
// unchanged, modified, total-size. `Modified` would otherwise also match many
// created and unchanged lines, because its column patterns accept "+" and " ".
func (p *Parser) Line(line string) {
	if line == "" {
		return
	}

	p.LineCount++

	if m := reCreated.FindStringSubmatch(line); m != nil {
		p.Counters.Created++
		p.StatusLine = firstPath(m[3])
		p.record(line)
		return
	}
	if m := reDeleted.FindStringSubmatch(line); m != nil {
		p.Counters.Deleted++
		p.StatusLine = firstPath(m[1])
		p.record(line)
		return
	}
	if m := reUnchanged.FindStringSubmatch(line); m != nil {
		p.Counters.Unchanged++
		p.StatusLine = firstPath(m[3])
		return
	}
	if m := reModified.FindStringSubmatch(line); m != nil {
		p.Counters.Modified++
		p.StatusLine = firstPath(m[12])
		p.record(line)
		p.countAttribute(m)
		return
	}
	if m := reTotalSize.FindStringSubmatch(line); m != nil {
		p.TotalSize, _ = strconv.ParseInt(strings.ReplaceAll(m[1], ",", ""), 10, 64)
		return
	}
}

/* Which attribute changed.
 *
 * These are `else if`, not independent counts: a line with both a size and a
 * timestamp change increments only the size counter. Faithful to RsyncTask,
 * where the counters are a rough breakdown for the UI rather than a tally that
 * has to add up. */
func (p *Parser) countAttribute(m []string) {
	switch {
	case m[3] == "c":
		p.Counters.Checksum++
	case m[4] == "s":
		p.Counters.Size++
	case m[5] == "t":
		p.Counters.Timestamp++
	case m[6] == "p":
		p.Counters.Permissions++
	case m[7] == "o":
		p.Counters.Owner++
	case m[8] == "g":
		p.Counters.Group++
	default:
		p.Counters.Unchanged++
	}
}

func (p *Parser) record(line string) {
	if p.KeepChanges {
		p.Changes = append(p.Changes, line)
	}
}

// firstPath strips a symlink's " -> target" suffix, leaving the path itself.
func firstPath(s string) string {
	if i := strings.Index(s, " -> "); i >= 0 {
		s = s[:i]
	}
	return strings.TrimSpace(s)
}

// ChangeKind is what happened to one path in a snapshot.
type ChangeKind string

const (
	ChangeCreated     ChangeKind = "created"
	ChangeDeleted     ChangeKind = "deleted"
	ChangeChecksum    ChangeKind = "checksum"
	ChangeSize        ChangeKind = "size"
	ChangeTimestamp   ChangeKind = "timestamp"
	ChangePermissions ChangeKind = "permissions"
	ChangeOwner       ChangeKind = "owner"
	ChangeGroup       ChangeKind = "group"
	ChangeUnchanged   ChangeKind = "unchanged"
)

// Change is one entry of the changes list a snapshot's log yields.
type Change struct {
	Path string
	Kind ChangeKind
}

// ParseLogLine reads one line of an rsync --log-file, which carries a
// "2026/08/31 12:00:00 [1234] " prefix the console output does not.
//
// Returns ok=false for a line that is not an itemised change: the log also
// holds rsync's own chatter, which is not a file.
func ParseLogLine(line string) (Change, bool) {
	if m := reLogCreated.FindStringSubmatch(line); m != nil {
		return Change{Path: firstPath(m[3]), Kind: ChangeCreated}, true
	}
	if m := reLogDeleted.FindStringSubmatch(line); m != nil {
		return Change{Path: firstPath(m[1]), Kind: ChangeDeleted}, true
	}
	if m := reLogUnchanged.FindStringSubmatch(line); m != nil {
		return Change{Path: firstPath(m[3]), Kind: ChangeUnchanged}, true
	}
	if m := reLogModified.FindStringSubmatch(line); m != nil {
		kind := ChangeUnchanged
		switch {
		case m[3] == "c":
			kind = ChangeChecksum
		case m[4] == "s":
			kind = ChangeSize
		case m[5] == "t":
			kind = ChangeTimestamp
		case m[6] == "p":
			kind = ChangePermissions
		case m[7] == "o":
			kind = ChangeOwner
		case m[8] == "g":
			kind = ChangeGroup
		}
		return Change{Path: firstPath(m[12]), Kind: kind}, true
	}
	return Change{}, false
}

// SpaceCheckSize reads the "sent N bytes  received M bytes" summary that the
// dry run uses to size a transfer, matching RsyncSpaceCheckTask's one regex.
var reSentBytes = regexp.MustCompile(`sent ([0-9,]+)[ \t]+bytes[ \t]+received`)

// SpaceCheckSize extracts the sent-bytes figure, or -1 when the line is not it.
func SpaceCheckSize(line string) int64 {
	m := reSentBytes.FindStringSubmatch(line)
	if m == nil {
		return -1
	}
	n, err := strconv.ParseInt(strings.ReplaceAll(m[1], ",", ""), 10, 64)
	if err != nil {
		return -1
	}
	return n
}

/* Parsing a whole log file.
 *
 * A snapshot's rsync log is large -- 22 MB and a couple of hundred thousand
 * lines for an ordinary desktop -- so this streams and hands each change to a
 * callback rather than returning a slice. Whoever wants them all can accumulate
 * them; whoever only wants the counts does not have to hold the paths.
 *
 * Progress is reported per LINE READ, not per change found. Most lines in a
 * log are changes, but rsync's own chatter is not, and a progress bar that only
 * moves on matches stalls visibly through the header and the summary.
 */

// LogCounts is how many of each kind a log contained.
type LogCounts map[ChangeKind]int

// ParseLog reads an rsync --log-file and reports every itemised change.
//
// onChange may be nil, which is how a caller asks for counts alone. onProgress,
// when set, is called every few thousand lines with the number read so far --
// often enough to move a bar, rarely enough not to dominate the parse.
func ParseLog(r io.Reader, onChange func(Change), onProgress func(lines int64)) (LogCounts, int64, error) {
	counts := LogCounts{}
	var lines int64

	sc := bufio.NewScanner(r)

	/* A path may be long, and the default 64 KB token limit makes Scan stop
	 * with an error partway through a perfectly good log -- which would look
	 * like a short log rather than a failure. */
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)

	for sc.Scan() {
		lines++
		if onProgress != nil && lines%5000 == 0 {
			onProgress(lines)
		}

		c, ok := ParseLogLine(sc.Text())
		if !ok {
			continue
		}
		counts[c.Kind]++
		if onChange != nil {
			onChange(c)
		}
	}
	if err := sc.Err(); err != nil {
		return counts, lines, err
	}
	if onProgress != nil {
		onProgress(lines)
	}
	return counts, lines, nil
}
