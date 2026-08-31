package schedule

import (
	"sort"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/config"
	"github.com/makeafide/timeshift/src-go/internal/engines"
)

/* Retention.
 *
 * Nothing here deletes. Retention removes TAGS, and a snapshot that ends up
 * with no tags at all is what the prune step then deletes. That indirection is
 * worth keeping: one snapshot commonly carries several levels, so "the daily
 * limit was exceeded" must not remove a copy that is also this week's weekly.
 *
 * The two rules are not the same shape, and the difference is in the original:
 *
 *   boot     purely count-based. Keep the newest count_boot, untag the rest.
 *   the rest count AND age. A snapshot is untagged only if it is BOTH beyond
 *            the count and older than the window, where the window reuses the
 *            count as its own unit -- count_hourly = 6 means "keep six" and
 *            "keep six hours".
 *
 * Snapshots with a description are spared by the interval levels. Someone
 * typed that comment, or apt-snapshot-guard recorded the apt command that
 * prompted the snapshot, and either way it marks a copy worth more than its
 * position in a rotation.
 *
 * That exemption does NOT apply to boot in the original, and it does not here.
 * It is asymmetric and it looks like an oversight, but changing it would make a
 * commented boot snapshot immortal: boot has no age window to eventually
 * release it, so a handful of commented boot snapshots would accumulate
 * forever with nothing able to reclaim the space.
 */

// Action is one retention decision.
type Action struct {
	// Snapshot is the name of the snapshot acted on.
	Snapshot string

	// UntagLevel is the level being removed, empty for a deletion.
	UntagLevel Level

	// Delete marks a snapshot to be removed entirely.
	Delete bool

	// Reason is why, for the log and for a client that wants to explain
	// itself.
	Reason string
}

// Plan is what a retention pass would do, computed before anything is touched.
//
// Returning a plan rather than acting is what makes this testable at all: the
// alternative is asserting against a repository after the fact, by which point
// a wrong rule has already deleted the evidence.
type Plan struct {
	Actions []Action
}

// Untags returns the resulting tag set per snapshot name, for the snapshots the
// plan changes.
func (p Plan) Untags(snaps []engines.Snapshot) map[string][]string {
	remove := map[string]map[string]bool{}
	for _, a := range p.Actions {
		if a.Delete || a.UntagLevel == "" {
			continue
		}
		if remove[a.Snapshot] == nil {
			remove[a.Snapshot] = map[string]bool{}
		}
		remove[a.Snapshot][string(a.UntagLevel)] = true
	}

	out := map[string][]string{}
	for i := range snaps {
		s := &snaps[i]
		drop := remove[s.Name]
		if drop == nil {
			continue
		}
		var kept []string
		for _, t := range s.Tags {
			if !drop[t] {
				kept = append(kept, t)
			}
		}
		out[s.Name] = kept
	}
	return out
}

// Deletions returns the snapshot names the plan removes.
func (p Plan) Deletions() []string {
	var out []string
	for _, a := range p.Actions {
		if a.Delete {
			out = append(out, a.Snapshot)
		}
	}
	return out
}

// PlanRetention computes the retention pass.
func PlanRetention(cfg config.Config, snaps []engines.Snapshot, now time.Time) Plan {
	var plan Plan

	// Oldest first. Retention always releases the oldest copy of a level.
	ordered := append([]engines.Snapshot(nil), snaps...)
	sort.SliceStable(ordered, func(i, j int) bool { return ordered[i].Created.Before(ordered[j].Created) })

	// Tags removed so far, so a level's decision sees the effect of the
	// previous levels -- a snapshot untagged as hourly may now be untagged.
	removed := map[string]map[string]bool{}
	untag := func(name string, l Level, reason string) {
		if removed[name] == nil {
			removed[name] = map[string]bool{}
		}
		removed[name][string(l)] = true
		plan.Actions = append(plan.Actions, Action{Snapshot: name, UntagLevel: l, Reason: reason})
	}
	stillTagged := func(s *engines.Snapshot, tag string) bool {
		if removed[s.Name][tag] {
			return false
		}
		return hasTag(s.Tags, tag)
	}

	for _, l := range Levels {
		keep := l.Keep(cfg)

		var tagged []*engines.Snapshot
		for i := range ordered {
			s := &ordered[i]
			/* An invalid snapshot is excluded from the count. The original
			 * includes it, which inflates the total and can untag -- and so
			 * delete -- a good snapshot to make room for a broken one. Erring
			 * towards keeping a backup is the only safe direction for a
			 * difference like this. */
			if !s.Valid || !stillTagged(s, string(l)) {
				continue
			}
			tagged = append(tagged, s)
		}

		if len(tagged) <= keep {
			continue
		}

		if l == Boot {
			// Count only. Untag from the oldest until the limit is met.
			for i := 0; i < len(tagged)-keep; i++ {
				untag(tagged[i].Name, l, "beyond the limit of "+plural(keep, "boot snapshot"))
			}
			continue
		}

		cutoff := windowStart(l, keep, now)
		remaining := len(tagged)
		for _, s := range tagged {
			if remaining <= keep {
				break
			}
			if s.Description != "" {
				continue // spared: someone said why this one matters
			}
			if !s.Created.Before(cutoff) {
				continue // inside the window
			}
			untag(s.Name, l, "beyond the limit of "+plural(keep, string(l)+" snapshot")+
				" and older than the "+string(l)+" window")
			remaining--
		}
	}

	/* Deletion. A snapshot with no tags left is gone; so is one a client
	 * marked. An invalid snapshot is NOT deleted here -- that needs positive
	 * evidence that it is really incomplete, which only the repository can
	 * establish by looking for the control file, so it stays with the prune
	 * step that can check. */
	for i := range ordered {
		s := &ordered[i]
		if s.MarkedForDeletion {
			plan.Actions = append(plan.Actions, Action{
				Snapshot: s.Name, Delete: true, Reason: "marked for deletion"})
			continue
		}
		if !s.Valid {
			continue
		}
		live := false
		for _, t := range s.Tags {
			if !removed[s.Name][t] {
				live = true
				break
			}
		}
		if !live {
			plan.Actions = append(plan.Actions, Action{
				Snapshot: s.Name, Delete: true, Reason: "no retention level still holds it"})
		}
	}

	return plan
}

// windowStart is how far back a level's age window reaches. The count doubles
// as the window length in that level's own unit.
func windowStart(l Level, keep int, now time.Time) time.Time {
	switch l {
	case Hourly:
		return now.Add(-time.Duration(keep) * time.Hour)
	case Daily:
		return now.AddDate(0, 0, -keep)
	case Weekly:
		return now.AddDate(0, 0, -7*keep)
	case Monthly:
		return now.AddDate(0, -keep, 0)
	}
	return now.AddDate(-10, 0, 0)
}
