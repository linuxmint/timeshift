package schedule

import (
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/config"
	"github.com/makeafide/timeshift/src-go/internal/engines"
)

func names(s []string) string {
	out := append([]string(nil), s...)
	sort.Strings(out)
	return strings.Join(out, ",")
}

func TestRetentionUntagsBeforeItDeletes(t *testing.T) {
	cfg := config.Defaults()
	cfg.CountHourly = 2

	// Three hourly snapshots, all well beyond the two-hour window. The newest
	// two survive; the oldest loses its tag and, having no other, is deleted.
	list := []engines.Snapshot{
		snap("a", base.Add(-10*time.Hour), "hourly"),
		snap("b", base.Add(-9*time.Hour), "hourly"),
		snap("c", base.Add(-8*time.Hour), "hourly"),
	}

	plan := PlanRetention(cfg, list, base)

	if got := names(plan.Deletions()); got != "a" {
		t.Fatalf("deleted %q, want just the oldest", got)
	}
}

// The reason retention removes tags instead of snapshots.
func TestRetentionKeepsASnapshotStillHeldByAnotherLevel(t *testing.T) {
	cfg := config.Defaults()
	cfg.CountHourly = 1
	cfg.CountDaily = 5

	list := []engines.Snapshot{
		// Beyond the hourly limit and window, but it is also a daily, and the
		// daily limit is nowhere near reached.
		snap("shared", base.Add(-6*time.Hour), "hourly", "daily"),
		snap("newest", base.Add(-time.Minute), "hourly"),
	}

	plan := PlanRetention(cfg, list, base)

	if got := names(plan.Deletions()); got != "" {
		t.Fatalf("deleted %q; a snapshot still tagged daily must survive the hourly limit", got)
	}
	tags := plan.Untags(list)["shared"]
	if names(tags) != "daily" {
		t.Fatalf("shared kept tags %v, want just daily", tags)
	}
}

func TestRetentionSparesCommentedSnapshots(t *testing.T) {
	cfg := config.Defaults()
	cfg.CountHourly = 1

	commented := snap("commented", base.Add(-10*time.Hour), "hourly")
	commented.Description = "before upgrading the kernel"

	list := []engines.Snapshot{
		commented,
		snap("plain", base.Add(-9*time.Hour), "hourly"),
		snap("newest", base.Add(-time.Minute), "hourly"),
	}

	plan := PlanRetention(cfg, list, base)

	if got := names(plan.Deletions()); got != "plain" {
		t.Fatalf("deleted %q, want only the uncommented one", got)
	}
}

// Both conditions are required, and this is the one that surprises people: a
// level far beyond its count keeps everything inside its window anyway.
func TestRetentionNeedsBothCountAndAge(t *testing.T) {
	cfg := config.Defaults()
	cfg.CountDaily = 1

	// Four dailies, all taken today, so all inside the one-day window.
	list := []engines.Snapshot{
		snap("a", base.Add(-4*time.Hour), "daily"),
		snap("b", base.Add(-3*time.Hour), "daily"),
		snap("c", base.Add(-2*time.Hour), "daily"),
		snap("d", base.Add(-1*time.Hour), "daily"),
	}

	plan := PlanRetention(cfg, list, base)

	if got := names(plan.Deletions()); got != "" {
		t.Fatalf("deleted %q; nothing is outside the daily window yet", got)
	}
}

// Boot is count-only, which is what lets it release snapshots that the
// interval levels would still be holding.
func TestBootRetentionIsCountOnly(t *testing.T) {
	cfg := config.Defaults()
	cfg.CountBoot = 2

	list := []engines.Snapshot{
		snap("a", base.Add(-3*time.Minute), "boot"),
		snap("b", base.Add(-2*time.Minute), "boot"),
		snap("c", base.Add(-1*time.Minute), "boot"),
	}

	plan := PlanRetention(cfg, list, base)

	if got := names(plan.Deletions()); got != "a" {
		t.Fatalf("deleted %q, want the oldest boot snapshot even though it is minutes old", got)
	}
}

func TestRetentionNeverTouchesOnDemand(t *testing.T) {
	cfg := config.Defaults()
	cfg.CountHourly = 0
	cfg.CountDaily = 0

	list := []engines.Snapshot{
		snap("kept", base.AddDate(-2, 0, 0), "ondemand"),
		snap("rotated", base.AddDate(-2, 0, 0), "hourly"),
	}

	plan := PlanRetention(cfg, list, base)

	if got := names(plan.Deletions()); got != "rotated" {
		t.Fatalf("deleted %q; an ondemand snapshot is never subject to retention", got)
	}
}

func TestRetentionDeletesMarkedSnapshots(t *testing.T) {
	cfg := config.Defaults()

	marked := snap("marked", base, "ondemand")
	marked.MarkedForDeletion = true

	plan := PlanRetention(cfg, []engines.Snapshot{marked}, base)

	if got := names(plan.Deletions()); got != "marked" {
		t.Fatalf("deleted %q, want the marked snapshot", got)
	}
}

// An incomplete snapshot is left alone here. Deciding it is really incomplete
// needs a look at the control file on the repository, which this pure function
// cannot do, and guessing wrong deletes a backup.
func TestRetentionLeavesInvalidSnapshotsToThePruneStep(t *testing.T) {
	cfg := config.Defaults()

	broken := snap("broken", base.AddDate(-5, 0, 0))
	broken.Valid = false

	plan := PlanRetention(cfg, []engines.Snapshot{broken}, base)

	if got := names(plan.Deletions()); got != "" {
		t.Fatalf("deleted %q; an invalid snapshot needs evidence, not inference", got)
	}
}

// The deviation from the original, stated as a test so it cannot drift back.
func TestInvalidSnapshotsDoNotInflateTheCount(t *testing.T) {
	cfg := config.Defaults()
	cfg.CountHourly = 2

	broken := snap("broken", base.Add(-11*time.Hour), "hourly")
	broken.Valid = false

	list := []engines.Snapshot{
		broken,
		snap("a", base.Add(-10*time.Hour), "hourly"),
		snap("b", base.Add(-9*time.Hour), "hourly"),
	}

	plan := PlanRetention(cfg, list, base)

	// Counting the broken one would make three, push "a" past the limit and
	// delete a good backup to stay under a limit a broken directory filled.
	if got := names(plan.Deletions()); got != "" {
		t.Fatalf("deleted %q; a broken snapshot must not cost a good one its tag", got)
	}
}

func TestRetentionOnAnEmptyRepositoryDoesNothing(t *testing.T) {
	plan := PlanRetention(config.Defaults(), nil, base)
	if len(plan.Actions) != 0 {
		t.Fatalf("planned %d actions on an empty repository", len(plan.Actions))
	}
}
