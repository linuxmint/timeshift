package schedule

import (
	"strings"

	"testing"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/config"
	"github.com/makeafide/timeshift/src-go/internal/engines"
)

// base is a fixed clock. Every test works relative to it, so nothing here
// depends on when it runs.
var base = time.Date(2026, 3, 15, 12, 0, 0, 0, time.UTC)

func snap(name string, at time.Time, tags ...string) engines.Snapshot {
	return engines.Snapshot{
		Name:    name,
		Created: at,
		Tags:    tags,
		SysUUID: "sys",
		Valid:   true,
	}
}

func allLevels() config.Config {
	c := config.Defaults()
	c.ScheduleBoot = true
	c.ScheduleHourly = true
	c.ScheduleDaily = true
	c.ScheduleWeekly = true
	c.ScheduleMonthly = true
	return c
}

func levelNames(d []Due) []string {
	var out []string
	for _, x := range d {
		out = append(out, string(x.Level))
	}
	return out
}

func TestDueLevels(t *testing.T) {
	bootTime := base.Add(-2 * time.Hour)

	cases := []struct {
		name string
		cfg  func() config.Config
		snap []engines.Snapshot
		want []string
	}{
		{
			name: "an empty repository owes every enabled level",
			cfg:  allLevels,
			want: []string{"boot", "hourly", "daily", "weekly", "monthly"},
		},
		{
			name: "nothing is due right after a snapshot carrying every tag",
			cfg:  allLevels,
			snap: []engines.Snapshot{
				snap("now", base.Add(-time.Minute), "boot", "hourly", "daily", "weekly", "monthly"),
			},
			want: nil,
		},
		{
			name: "only the enabled levels are considered",
			cfg: func() config.Config {
				c := config.Defaults()
				c.ScheduleHourly = true
				return c
			},
			want: []string{"hourly"},
		},
		{
			name: "an hourly snapshot from before this boot still owes boot",
			cfg:  allLevels,
			snap: []engines.Snapshot{
				snap("old", base.Add(-3*time.Hour), "boot", "hourly", "daily", "weekly", "monthly"),
			},
			want: []string{"boot", "hourly"},
		},
		{
			// Without the grace minute this would not be due until 60
			// minutes, and a check that ran a second or two after the hour
			// would find the previous snapshot 59:58 old, decline, and skip
			// the hour entirely.
			name: "the grace minute makes a 59m30s snapshot due",
			cfg: func() config.Config {
				c := config.Defaults()
				c.ScheduleHourly = true
				return c
			},
			snap: []engines.Snapshot{snap("recent", base.Add(-59*time.Minute-30*time.Second), "hourly")},
			want: []string{"hourly"},
		},
		{
			name: "a snapshot 58 minutes old is not yet due",
			cfg: func() config.Config {
				c := config.Defaults()
				c.ScheduleHourly = true
				return c
			},
			snap: []engines.Snapshot{snap("recent", base.Add(-58*time.Minute), "hourly")},
			want: nil,
		},
		{
			name: "another machine's snapshot does not satisfy this machine's schedule",
			cfg: func() config.Config {
				c := config.Defaults()
				c.ScheduleHourly = true
				return c
			},
			snap: []engines.Snapshot{
				func() engines.Snapshot {
					s := snap("theirs", base.Add(-time.Minute), "hourly")
					s.SysUUID = "other-machine"
					return s
				}(),
			},
			want: []string{"hourly"},
		},
		{
			name: "an invalid snapshot does not satisfy the schedule either",
			cfg: func() config.Config {
				c := config.Defaults()
				c.ScheduleHourly = true
				return c
			},
			snap: []engines.Snapshot{
				func() engines.Snapshot {
					s := snap("broken", base.Add(-time.Minute), "hourly")
					s.Valid = false
					return s
				}(),
			},
			want: []string{"hourly"},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			due, _ := DueLevels(tc.cfg(), tc.snap, "sys", base, bootTime)
			got := levelNames(due)
			if strings.Join(got, ",") != strings.Join(tc.want, ",") {
				t.Fatalf("due = %v, want %v", got, tc.want)
			}
		})
	}
}

// The behaviour that keeps a fresh install from taking five identical copies of
// the system in one pass.
func TestRotationAvoidsDuplicateSnapshots(t *testing.T) {
	bootTime := base.Add(-2 * time.Hour)

	// A snapshot has just been created for the boot level.
	list := []engines.Snapshot{snap("fresh", base, "boot")}

	for _, l := range []Level{Hourly, Daily, Weekly, Monthly} {
		target := RotationTarget(l, list, base, bootTime)
		if target == nil {
			t.Fatalf("%s: wanted to reuse the snapshot just created, got a new copy", l)
		}
		if target.Name != "fresh" {
			t.Fatalf("%s: reused %q, want %q", l, target.Name, "fresh")
		}
	}
}

func TestRotationTarget(t *testing.T) {
	bootTime := base.Add(-2 * time.Hour)

	t.Run("an ondemand request is never answered with an existing snapshot", func(t *testing.T) {
		list := []engines.Snapshot{snap("recent", base.Add(-time.Minute), "hourly")}
		if got := RotationTarget(OnDemand, list, base, bootTime); got != nil {
			t.Fatalf("reused %q for an explicit request", got.Name)
		}
	})

	t.Run("a snapshot older than an hour is not reused", func(t *testing.T) {
		list := []engines.Snapshot{snap("old", base.Add(-90*time.Minute), "hourly")}
		if got := RotationTarget(Daily, list, base, bootTime); got != nil {
			t.Fatalf("reused a 90-minute-old snapshot (%q) for the daily level", got.Name)
		}
	})

	t.Run("boot reuses anything taken since the machine came up", func(t *testing.T) {
		list := []engines.Snapshot{snap("this-boot", base.Add(-90*time.Minute), "ondemand")}
		got := RotationTarget(Boot, list, base, bootTime)
		if got == nil || got.Name != "this-boot" {
			t.Fatalf("boot did not reuse a snapshot from this boot: %v", got)
		}
	})

	t.Run("boot does not reuse a snapshot from before the boot", func(t *testing.T) {
		list := []engines.Snapshot{snap("last-boot", base.Add(-3*time.Hour), "ondemand")}
		if got := RotationTarget(Boot, list, base, bootTime); got != nil {
			t.Fatalf("boot reused %q, taken before this boot", got.Name)
		}
	})

	t.Run("an invalid snapshot is not a rotation target", func(t *testing.T) {
		s := snap("broken", base.Add(-time.Minute), "hourly")
		s.Valid = false
		if got := RotationTarget(Hourly, []engines.Snapshot{s}, base, bootTime); got != nil {
			t.Fatalf("reused an invalid snapshot %q", got.Name)
		}
	})
}

// Where several snapshots qualify, the tag belongs on the most current one --
// and the answer must not depend on how the caller happened to sort the list.
func TestRotationPicksTheNewestEligibleSnapshot(t *testing.T) {
	bootTime := base.Add(-2 * time.Hour)

	oldestFirst := []engines.Snapshot{
		snap("older", base.Add(-40*time.Minute), "ondemand"),
		snap("newer", base.Add(-5*time.Minute), "ondemand"),
	}
	newestFirst := []engines.Snapshot{oldestFirst[1], oldestFirst[0]}

	for _, list := range [][]engines.Snapshot{oldestFirst, newestFirst} {
		got := RotationTarget(Daily, list, base, bootTime)
		if got == nil || got.Name != "newer" {
			t.Fatalf("RotationTarget = %v, want the newest eligible snapshot", got)
		}
	}
}
