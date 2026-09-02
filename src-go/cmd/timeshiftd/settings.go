package main

import (
	"context"
	"encoding/json"

	"github.com/makeafide/timeshift/src-go/internal/config"
	"github.com/makeafide/timeshift/src-go/internal/ipc"
	"github.com/makeafide/timeshift/src-go/internal/jobs"
)

/* Writing state, as opposed to reading it.
 *
 * These are the methods that make the daemon the single writer of
 * timeshift.json and of a snapshot's control file. That matters beyond
 * tidiness: while the Vala GUI also writes the config there are two writers,
 * each dropping keys the other added, which is why the scheduler's
 * startup_delay_interval_mins is read but never written. One writer is what
 * ends that.
 *
 * Each one announces what it changed, so a second client attached at the same
 * time redraws instead of showing state that is no longer true.
 */

// configSet applies a partial configuration update and persists it.
func (d *daemon) configSet(_ context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {

	var in ipc.ConfigSetParams
	if err := json.Unmarshal(params, &in); err != nil {
		return nil, ipc.Errf(ipc.CodeBadRequest, "%v", err)
	}

	/* The whole update under one lock, read-modify-write.
	 *
	 * Two clients saving different settings at the same moment would otherwise
	 * each start from the config as they found it and the second would undo
	 * the first. Several clients at once is the normal case here, not an edge
	 * one. */
	d.mu.Lock()
	updated, err := config.Apply(d.cfg, in.Values)
	if err != nil {
		d.mu.Unlock()
		return nil, ipc.Errf(ipc.CodeBadRequest, "%v", err)
	}

	if err := config.Save(d.configPath, updated); err != nil {
		d.mu.Unlock()
		return nil, ipc.Errf(ipc.CodeInternal, "%v", err)
	}
	d.cfg = updated
	d.mu.Unlock()

	changed := make([]string, 0, len(in.Values))
	for k := range in.Values {
		changed = append(changed, k)
	}
	d.log.Info("configuration updated", "keys", changed)

	d.queue.Hub().Publish(jobs.EventConfigChanged)

	/* A schedule change should take effect now rather than at the next tick.
	 * Turning hourly snapshots on and seeing nothing happen for ten minutes
	 * reads as "it did not work". */
	if d.ticker != nil && touchesSchedule(in.Values) {
		d.ticker.RequestCheck("config")
	}

	return updated, nil
}

func touchesSchedule(values map[string]json.RawMessage) bool {
	for k := range values {
		switch k {
		case "schedule_boot", "schedule_hourly", "schedule_daily",
			"schedule_weekly", "schedule_monthly",
			"count_boot", "count_hourly", "count_daily",
			"count_weekly", "count_monthly", "pause_snapshots":
			return true
		}
	}
	return false
}

// snapshotsUpdate edits a snapshot's tags, comment or deletion marker.
func (d *daemon) snapshotsUpdate(ctx context.Context, _ *ipc.Conn, params json.RawMessage) (any, error) {

	var in ipc.SnapshotsUpdateParams
	if err := json.Unmarshal(params, &in); err != nil {
		return nil, ipc.Errf(ipc.CodeBadRequest, "%v", err)
	}
	if in.Name == "" {
		return nil, ipc.Errf(ipc.CodeBadRequest, "no snapshot named")
	}

	repo, _, _, err := d.openRepoFor(ctx, nil)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	defer repo.Close()

	if in.Comments != nil {
		if err := repo.SetDescription(ctx, in.Name, *in.Comments); err != nil {
			return nil, ipc.Errf(ipc.CodeInternal, "%v", err)
		}
	}
	if in.Tags != nil {
		if err := repo.SetTags(ctx, in.Name, *in.Tags); err != nil {
			return nil, ipc.Errf(ipc.CodeInternal, "%v", err)
		}
	}
	if in.MarkedForDeletion != nil {
		if err := repo.SetMarkedForDeletion(ctx, in.Name, *in.MarkedForDeletion); err != nil {
			return nil, ipc.Errf(ipc.CodeInternal, "%v", err)
		}
	}

	d.queue.Hub().Publish(jobs.EventSnapshotsChanged)

	list, err := repo.List(ctx)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	for _, s := range list {
		if s.Name == in.Name {
			return s, nil
		}
	}
	return nil, ipc.Errf(ipc.CodeNotFound, "no snapshot named %q", in.Name)
}

/* repoReload drops whatever the daemon has cached about the repository.
 *
 * There is not much: a repository handle is opened and closed per operation
 * rather than held, precisely so a disk that was unplugged or an SSH link that
 * dropped cannot leave a stale handle behind. What this does is re-read the
 * config from disk, which is the one thing that can change underneath the
 * daemon while the Vala GUI is still a second writer of that file.
 */
func (d *daemon) repoReload(_ context.Context, _ *ipc.Conn, _ json.RawMessage) (any, error) {

	cfg, _, err := config.Load(d.configPath)
	if err != nil {
		return nil, ipc.Errf(ipc.CodeInternal, "%v", err)
	}

	d.mu.Lock()
	d.cfg = cfg
	d.mu.Unlock()

	d.log.Info("configuration re-read from disk", "path", d.configPath)
	d.queue.Hub().Publish(jobs.EventConfigChanged)

	return cfg, nil
}
