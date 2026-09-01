package main

import (
	"context"

	"github.com/makeafide/timeshift/src-go/internal/block"
	"github.com/makeafide/timeshift/src-go/internal/config"
	"github.com/makeafide/timeshift/src-go/internal/engines"
	"github.com/makeafide/timeshift/src-go/internal/ipc"
)

/* Per-invocation location overrides.
 *
 * `timeshift --list --snapshot-device /dev/sdb1` looks at that device without
 * changing anything, and --btrfs / --rsync do the same for the mode. Vala
 * implements this by setting the same fields it would have loaded and simply
 * not saving them, which is exactly the right shape: an override is a config
 * that was never written down.
 *
 * It has to travel over the wire rather than being applied client-side, because
 * `--list` prefers the daemon and falls back to opening the repository itself.
 * An override that only worked on the fallback path would make the same command
 * mean two different things depending on whether the daemon happened to be
 * running -- which is the sort of difference nobody notices until it matters.
 */

// applyOverride returns cfg with the override applied, and reports whether any
// field actually changed.
func applyOverride(ctx context.Context, runner block.Runner, cfg config.Config, ov *ipc.LocationOverride) (config.Config, bool, error) {
	if ov == nil {
		return cfg, false, nil
	}
	changed := false

	switch {
	case ov.URL != "":
		cfg.BackupLocationType = "ssh"
		cfg.BackupSSHURL = ov.URL
		/* btrfs and a remote repository cannot coexist. Forcing it off here
		 * rather than reporting a conflict, because this branch is reached by
		 * someone who explicitly named a remote for this one command. */
		cfg.BtrfsMode = false
		changed = true

	case ov.DeviceUUID != "" || ov.Device != "":
		uuid := ov.DeviceUUID
		if uuid == "" {
			devices, err := (&block.Scanner{Runner: runner}).Scan(ctx)
			if err != nil {
				return cfg, false, err
			}
			dev := block.FindByPath(devices, ov.Device)
			if dev == nil {
				return cfg, false, ipc.Errf(ipc.CodeNotFound, "no such device: %s", ov.Device)
			}
			if dev.UUID == "" {
				return cfg, false, ipc.Errf(ipc.CodeBadRequest,
					"%s has no UUID, so it cannot be addressed as a repository", ov.Device)
			}
			uuid = dev.UUID
		}
		cfg.BackupLocationType = "local"
		cfg.BackupDeviceUUID = uuid
		changed = true
	}

	if ov.KeyFile != "" {
		cfg.BackupSSHKey = ov.KeyFile
		changed = true
	}
	if ov.Port != 0 {
		cfg.BackupSSHPort = ov.Port
		changed = true
	}

	/* Mode is a pointer so that "leave it alone" and "force it off" are
	 * different requests. A plain bool cannot express --rsync. */
	if ov.BtrfsMode != nil {
		cfg.BtrfsMode = *ov.BtrfsMode
		changed = true
	}

	return cfg, changed, nil
}

// openRepoOverridden opens the repository a request asked for, or the
// configured one when it asked for nothing.
func (d *daemon) openRepoOverridden(ctx context.Context, ov *ipc.LocationOverride) (engines.Repository, string, string, error) {
	cfg, changed, err := applyOverride(ctx, d.runner, d.config(), ov)
	if err != nil {
		return nil, "", "", err
	}
	if changed {
		d.log.Info("opening an overridden location for one request",
			"type", cfg.BackupLocationType, "device_uuid", cfg.BackupDeviceUUID,
			"url", cfg.BackupSSHURL, "btrfs", cfg.BtrfsMode)
	}

	repo, name, uuid, err := d.openRepoWith(ctx, cfg)
	if err != nil {
		return nil, "", "", ipc.Errf(ipc.CodeUnavailable, "%v", err)
	}
	return repo, name, uuid, nil
}
