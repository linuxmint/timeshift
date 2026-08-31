package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/block"
	"github.com/makeafide/timeshift/src-go/internal/ipc"
	"github.com/makeafide/timeshift/src-go/internal/jobs"
	"github.com/makeafide/timeshift/src-go/internal/schedule"
)

/* The scheduled check.
 *
 * This is Main.check_create_snapshot() and SnapshotRepo.auto_remove(), with
 * cron's process start removed from the front of it.
 *
 * The shape is worth reading once. A check does up to three things, and only
 * the middle one is expensive:
 *
 *   1. decide which levels are due                (a directory listing)
 *   2. tag an existing snapshot, or make one      (free, or a full backup)
 *   3. apply retention                            (a listing, then deletions)
 *
 * Step 2 is where the original took five copies of the system on a fresh
 * install with five levels enabled, and where tag rotation stops it: every
 * level that a recent-enough snapshot can carry is satisfied by adding a tag,
 * so at most one snapshot is ever created per check no matter how many levels
 * came due together.
 *
 * Step 3 runs on EVERY check, including one where nothing was due. That is
 * deliberate and matches the original: retention is what keeps the repository
 * from filling, and tying it to snapshot creation would mean a machine that
 * stopped taking snapshots also stopped reclaiming space.
 */

// scheduledCheck runs one check and returns a one-line summary for the status.
func (d *daemon) scheduledCheck(ctx context.Context, trigger string) (string, error) {
	repo, _, _, err := d.openRepo(ctx)
	if err != nil {
		return "", fmt.Errorf("the snapshot location is not available: %w", err)
	}

	cfg := d.config()
	list, err := repo.List(ctx)
	if err != nil {
		repo.Close()
		return "", fmt.Errorf("could not read the snapshot list: %w", err)
	}

	sysUUID := d.systemUUID(ctx)
	now := time.Now()
	boot := bootTime(now)

	due, skipped := schedule.DueLevels(cfg, list, sysUUID, now, boot)
	for _, s := range skipped {
		d.log.Debug("level not due", "level", s.Level, "reason", s.Reason)
	}

	var (
		summary  []string
		newTags  []string
		retagged int
	)

	for _, x := range due {
		d.log.Info("level is due", "level", x.Level, "reason", x.Reason)

		if target := schedule.RotationTarget(x.Level, list, now, boot); target != nil {
			if err := repo.AddTag(ctx, target.Name, string(x.Level)); err != nil {
				repo.Close()
				return "", fmt.Errorf("could not tag %s as %s: %w", target.Name, x.Level, err)
			}
			d.log.Info("tagged an existing snapshot", "snapshot", target.Name, "level", x.Level)
			retagged++
			continue
		}
		newTags = append(newTags, string(x.Level))
	}

	// The repository handle is not held across the backup: the job opens its
	// own, and a create can run for an hour.
	repo.Close()

	if retagged > 0 {
		summary = append(summary, plural(retagged, "level")+" tagged onto an existing snapshot")
	}

	if len(newTags) > 0 {
		job, err := d.queue.Submit(jobs.KindCreate, func(ctx context.Context, r jobs.Reporter) (jobs.Outcome, error) {
			return d.runCreate(ctx, r, newTags, "", false)
		})
		if err != nil {
			return "", fmt.Errorf("could not queue the scheduled snapshot: %w", err)
		}
		d.log.Info("scheduled snapshot queued", "job", job.ID, "tags", strings.Join(newTags, ","))

		/* Wait for it. A check that returned here would report success before
		 * the snapshot existed, and the next tick would find the same levels
		 * due and queue a second one. Waiting also means the ticker cannot fire
		 * during a backup, which is the behaviour wanted anyway. */
		if err := waitForJob(ctx, job); err != nil {
			return "", err
		}
		if state := job.State(); state != jobs.StateFinished {
			return "", fmt.Errorf("the scheduled snapshot did not complete (%s)", state)
		}
		summary = append(summary, "created a snapshot tagged "+strings.Join(newTags, ", "))
	}

	pruned, err := d.applyRetention(ctx)
	if err != nil {
		// Retention failing does not undo a snapshot that was just taken, so
		// this is reported rather than turned into a failed check.
		d.log.Error("retention failed", "err", err)
		summary = append(summary, "retention failed: "+err.Error())
	} else if pruned > 0 {
		summary = append(summary, plural(pruned, "snapshot")+" removed by retention")
	}

	if len(summary) == 0 {
		return "nothing was due", nil
	}
	return strings.Join(summary, "; "), nil
}

/* Retention.
 *
 * The plan is computed first and logged, then applied. That ordering is not
 * cosmetic: this is the only routine in the daemon that deletes backups on its
 * own initiative, and being able to read afterwards exactly what it decided and
 * why is the difference between a bug that can be diagnosed and one that can
 * only be regretted.
 */
func (d *daemon) applyRetention(ctx context.Context) (int, error) {
	repo, _, _, err := d.openRepo(ctx)
	if err != nil {
		return 0, err
	}
	defer repo.Close()

	list, err := repo.List(ctx)
	if err != nil {
		return 0, err
	}

	plan := schedule.PlanRetention(d.config(), list, time.Now())
	if len(plan.Actions) == 0 {
		return 0, nil
	}

	for _, a := range plan.Actions {
		if a.Delete {
			d.log.Info("retention: removing snapshot", "snapshot", a.Snapshot, "reason", a.Reason)
		} else {
			d.log.Info("retention: un-tagging snapshot",
				"snapshot", a.Snapshot, "level", a.UntagLevel, "reason", a.Reason)
		}
	}

	for name, tags := range plan.Untags(list) {
		if err := repo.SetTags(ctx, name, tags); err != nil {
			return 0, fmt.Errorf("could not re-tag %s: %w", name, err)
		}
	}

	deletions := plan.Deletions()
	if len(deletions) == 0 {
		return 0, nil
	}

	job, err := d.queue.Submit(jobs.KindDelete, func(ctx context.Context, r jobs.Reporter) (jobs.Outcome, error) {
		return d.runDelete(ctx, r, deletions)
	})
	if err != nil {
		return 0, err
	}
	if err := waitForJob(ctx, job); err != nil {
		return 0, err
	}
	if state := job.State(); state != jobs.StateFinished {
		return 0, fmt.Errorf("the deletion did not complete (%s)", state)
	}
	return len(deletions), nil
}

// waitForJob blocks until the job reaches a terminal state or the context ends.
func waitForJob(ctx context.Context, job *jobs.Job) error {
	select {
	case <-job.Done():
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

/* System boot time.
 *
 * /proc/uptime rather than a stored timestamp, because that is what makes the
 * boot level fire exactly once per boot however long the machine stays up: the
 * question is "was the newest boot snapshot taken before this boot started",
 * and uptime answers it without anything having to be remembered across a
 * reboot.
 */
func bootTime(now time.Time) time.Time {
	data, err := os.ReadFile("/proc/uptime")
	if err != nil {
		// Without uptime the boot level cannot be judged. Returning "now"
		// makes every existing snapshot look older than the boot, so a boot
		// snapshot is taken. An extra snapshot is the safe direction.
		return now
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return now
	}
	secs, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return now
	}
	return now.Add(-time.Duration(secs * float64(time.Second)))
}

// systemUUID is the root filesystem's UUID, which identifies the machine a
// snapshot came from. Empty when it cannot be determined, which means "do not
// filter by machine" rather than "no snapshot matches".
func (d *daemon) systemUUID(ctx context.Context) string {
	devices, err := (&block.Scanner{Runner: d.runner}).Scan(ctx)
	if err != nil {
		d.log.Warn("could not scan block devices", "err", err)
		return ""
	}
	if root := block.MountedAt(devices, "/"); root != nil {
		return root.UUID
	}
	return ""
}

func plural(n int, unit string) string {
	s := strconv.Itoa(n) + " " + unit
	if n != 1 {
		s += "s"
	}
	return s
}

// scheduleCheck is the IPC method that forces a check now.
func (d *daemon) scheduleCheck(_ context.Context, _ *ipc.Conn, _ json.RawMessage) (any, error) {
	if d.ticker == nil {
		return nil, fmt.Errorf("the scheduler is not running")
	}
	d.ticker.RequestCheck("request")
	return map[string]any{"requested": true}, nil
}

// scheduleStatus reports what the scheduler has been doing.
//
// This exists because losing cron lost a scheduler that ran whether or not our
// own code was healthy. A dead timeshiftd now means no snapshots at all, and
// the only thing that makes that visible is a client being able to say "the
// last check was on Tuesday".
func (d *daemon) scheduleStatus(_ context.Context, _ *ipc.Conn, _ json.RawMessage) (any, error) {
	if d.ticker == nil {
		return schedule.Status{}, nil
	}
	return d.ticker.Status(), nil
}
