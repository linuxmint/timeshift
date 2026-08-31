// Package schedule decides when a scheduled snapshot is due, and which older
// snapshots retention should let go of.
//
// This was cron plus Main.check_create_snapshot() plus SnapshotRepo.auto_remove().
// Two things change in the move.
//
// The timer moves INTO the daemon. cron ran "timeshift --check --scripted"
// hourly, and every run paid for a whole process start, a config parse, a
// device scan and a repository mount just to discover that nothing was due.
// More importantly a cron-driven run had nowhere to report to: a client could
// not attach to it, which is the defect this port exists to remove.
//
// The decisions themselves stay pure functions over a snapshot list and a
// clock. They are the part that is easy to get subtly wrong and impossible to
// observe once it is wrong -- a retention rule that is slightly too eager
// deletes backups quietly, and the first sign of it is the day one is needed.
// So they take "now" as an argument and are tested against a table rather than
// against the wall clock.
package schedule

import (
	"strconv"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/config"
	"github.com/makeafide/timeshift/src-go/internal/engines"
)

// Level is one retention level.
type Level string

// The levels, in the order a check applies them. Order matters: boot runs
// first so that when several levels are due at once, the snapshot created for
// boot is the one the others tag rather than copying the system again.
const (
	Boot    Level = "boot"
	Hourly  Level = "hourly"
	Daily   Level = "daily"
	Weekly  Level = "weekly"
	Monthly Level = "monthly"

	// OnDemand is not scheduled and is never subject to retention. It is here
	// because the tag shares the same namespace.
	OnDemand Level = "ondemand"
)

// Levels are the scheduled levels in application order.
var Levels = []Level{Boot, Hourly, Daily, Weekly, Monthly}

// Enabled reports whether the configuration asks for this level.
func (l Level) Enabled(c config.Config) bool {
	switch l {
	case Boot:
		return c.ScheduleBoot
	case Hourly:
		return c.ScheduleHourly
	case Daily:
		return c.ScheduleDaily
	case Weekly:
		return c.ScheduleWeekly
	case Monthly:
		return c.ScheduleMonthly
	}
	return false
}

// Keep is how many snapshots of this level the configuration retains.
func (l Level) Keep(c config.Config) int {
	switch l {
	case Boot:
		return c.CountBoot
	case Hourly:
		return c.CountHourly
	case Daily:
		return c.CountDaily
	case Weekly:
		return c.CountWeekly
	case Monthly:
		return c.CountMonthly
	}
	return 0
}

// Due is one level that needs a snapshot, with the reason, which is logged and
// shown to a client. The reason is the whole value of a --check run that does
// nothing: without it the operator cannot tell "not due yet" from "broken".
type Due struct {
	Level  Level
	Reason string
}

/* Whether a level is due.
 *
 * Every interval test carries a one-minute grace: "older than an hour" means
 * older than fifty-nine minutes. cron fired on the hour and a run that began at
 * 10:00:02 would otherwise find the 09:00:01 snapshot fifty-nine minutes and
 * fifty-nine seconds old, decide it was not due yet, and skip the hour
 * entirely. The daemon's ticker has the same problem for the same reason, so
 * the grace stays.
 *
 * Boot is not an interval at all: it asks whether the newest boot snapshot
 * predates the current boot. That is what makes it fire once per boot however
 * long the machine stays up.
 */
func levelDue(l Level, last *engines.Snapshot, now, bootTime time.Time) (bool, string) {
	if last == nil {
		return true, "no " + string(l) + " snapshot found"
	}

	if l == Boot {
		if last.Created.Before(bootTime) {
			return true, "the last boot snapshot is older than the current boot"
		}
		return false, "the last boot snapshot was taken " + humanAge(now.Sub(last.Created)) + " ago, this boot"
	}

	var cutoff time.Time
	switch l {
	case Hourly:
		cutoff = now.Add(-time.Hour).Add(time.Minute)
	case Daily:
		cutoff = now.AddDate(0, 0, -1).Add(time.Minute)
	case Weekly:
		cutoff = now.AddDate(0, 0, -7).Add(time.Minute)
	case Monthly:
		cutoff = now.AddDate(0, -1, 0).Add(time.Minute)
	default:
		return false, "unknown level"
	}

	if last.Created.Before(cutoff) {
		return true, "the last " + string(l) + " snapshot is older than the interval"
	}
	return false, "the last " + string(l) + " snapshot was taken " + humanAge(now.Sub(last.Created)) + " ago"
}

// DueLevels returns the enabled levels that need a snapshot, in application
// order, and the reasons for every enabled level including the ones that are
// not due.
//
// Only snapshots from this system count. A repository shared between machines
// holds snapshots of each, and another machine's hourly snapshot is no reason
// for this one to skip its own.
func DueLevels(cfg config.Config, snaps []engines.Snapshot, sysUUID string, now, bootTime time.Time) (due []Due, skipped []Due) {
	for _, l := range Levels {
		if !l.Enabled(cfg) {
			continue
		}
		last := latestWithTag(snaps, string(l), sysUUID)
		ok, reason := levelDue(l, last, now, bootTime)
		if ok {
			due = append(due, Due{Level: l, Reason: reason})
		} else {
			skipped = append(skipped, Due{Level: l, Reason: reason})
		}
	}
	return due, skipped
}

/* Tag rotation: taking a level without copying the system again.
 *
 * If a snapshot recent enough already exists, the level's tag is added to it
 * instead of a new snapshot being made. This is why enabling all five levels on
 * a fresh install produces ONE snapshot tagged BHDWM rather than five identical
 * copies, and why an ondemand snapshot taken at 10:05 means the 11:00 hourly
 * costs nothing.
 *
 * "Recent enough" is under an hour for the interval levels, and "since this
 * boot" for boot. The interval levels all use the same one-hour window
 * regardless of their own interval, which is deliberate: a daily snapshot may
 * reuse an hour-old copy, but not a twenty-hour-old one, because the point of
 * the daily is to be roughly current.
 *
 * Where several snapshots qualify this picks the NEWEST. The original walked
 * its list oldest-first and took the first match, so with two snapshots inside
 * the window the tag landed on the older one -- which is the opposite of what
 * the level is for. It also made the outcome depend on the caller's sort order,
 * which is not something a decision like this should rest on.
 */
func RotationTarget(l Level, snaps []engines.Snapshot, now, bootTime time.Time) *engines.Snapshot {
	if l == OnDemand {
		// An ondemand snapshot is an explicit request for a copy of the system
		// as it is now. Answering it with an existing snapshot would be
		// answering a different question.
		return nil
	}

	cutoff := now.Add(-time.Hour).Add(59 * time.Second)
	if l == Boot {
		cutoff = bootTime
	}

	var best *engines.Snapshot
	for i := range snaps {
		s := &snaps[i]
		if !s.Valid || s.MarkedForDeletion {
			continue
		}
		if !s.Created.After(cutoff) {
			continue
		}
		if best == nil || s.Created.After(best.Created) {
			best = s
		}
	}
	return best
}

// latestWithTag returns the newest valid snapshot of this system carrying the
// tag, or nil.
func latestWithTag(snaps []engines.Snapshot, tag, sysUUID string) *engines.Snapshot {
	var best *engines.Snapshot
	for i := range snaps {
		s := &snaps[i]
		if !s.Valid || !hasTag(s.Tags, tag) {
			continue
		}
		if sysUUID != "" && s.SysUUID != sysUUID {
			continue
		}
		if best == nil || s.Created.After(best.Created) {
			best = s
		}
	}
	return best
}

func hasTag(tags []string, want string) bool {
	for _, t := range tags {
		if t == want {
			return true
		}
	}
	return false
}

// humanAge renders a duration the way the logs read best: the largest unit that
// gives a number above one.
func humanAge(d time.Duration) string {
	switch {
	case d < time.Minute:
		return plural(int(d.Seconds()), "second")
	case d < time.Hour:
		return plural(int(d.Minutes()), "minute")
	case d < 48*time.Hour:
		return plural(int(d.Hours()), "hour")
	default:
		return plural(int(d.Hours()/24), "day")
	}
}

func plural(n int, unit string) string {
	s := strconv.Itoa(n) + " " + unit
	if n != 1 {
		s += "s"
	}
	return s
}
