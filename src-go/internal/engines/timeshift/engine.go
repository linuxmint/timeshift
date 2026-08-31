// Package timeshift is the storage engine every existing Timeshift
// installation is already using: rsync with hardlinked incrementals, or btrfs
// subvolume snapshots, on a local filesystem or on another host over SSH.
//
// It owns the on-disk layout -- timeshift/snapshots, info.json, exclude.list --
// and nothing outside this package should know that shape. A future engine
// brings its own.
package timeshift

import (
	"context"
	"fmt"
	"path"

	"github.com/makeafide/timeshift/src-go/internal/engines"
)

// ID is the engine's stable key, written to timeshift.json.
const ID = "timeshift"

func init() { engines.Register(Engine{}) }

// Engine implements engines.Engine.
type Engine struct{}

func (Engine) ID() string          { return ID }
func (Engine) DisplayName() string { return "Timeshift (rsync / btrfs)" }

// Caps describes what this engine can do.
//
// UnsharedSize is true because rsync's hardlinked layout lets a `find -links 1`
// walk price each snapshot exclusively, which is the CLI's "Unique" column.
// WholeVolumeRestore is false here even though btrfs mode restores by swapping
// subvolumes: it is reported per-repository once the mode is known, not for the
// engine as a whole.
func (Engine) Caps() engines.Caps {
	return engines.Caps{
		Incremental:  true,
		Remote:       true,
		Browse:       true,
		UnsharedSize: true,
	}
}

// Open connects to a repository.
//
// Failing to reach it is not a failure to open: the CLI and the GUI both need a
// repository handle in order to *report* that it is unreachable. Status() is
// where that shows up.
func (Engine) Open(ctx context.Context, loc engines.Location, deps engines.Deps) (engines.Repository, error) {
	if deps.Runner == nil {
		return nil, fmt.Errorf("timeshift: no command runner supplied")
	}

	repo := &Repo{Deps: deps, BtrfsMode: loc.BtrfsMode}

	switch loc.Type {
	case "ssh":
		s := loc.SSH
		if s.Host == "" {
			return nil, engines.ErrNotAvailable
		}
		if !IsSafeHostComponent(s.Host) || (s.User != "" && !IsSafeHostComponent(s.User)) {
			return nil, fmt.Errorf("%w: unsafe host or user", ErrBadURL)
		}
		key := s.KeyFile
		if key == "" {
			key = DefaultKeyFile()
		}
		repo.MountPath = s.Path
		repo.Backend = &SSHBackend{
			Runner:      runnerAdapter{deps.Runner},
			User:        s.User,
			Host:        s.Host,
			Port:        s.Port,
			Path:        s.Path,
			KeyFile:     key,
			FakeSuper:   s.FakeSuper,
			ControlPath: controlPath(deps.MountRoot, s),
		}
		// btrfs snapshots are subvolume operations on a local filesystem; they
		// cannot happen over rsync to another host. Forced here as well as in
		// the config loader, so an engine opened directly cannot get it wrong.
		repo.BtrfsMode = false

	case "local", "":
		runner := runnerAdapter{deps.Runner}

		/* Mount the repository device ourselves when one is configured. An
		 * external disk plugged in for the occasion is not mounted, and a
		 * repository that only works if somebody else happened to mount it
		 * first is not a working repository. */
		if loc.DeviceUUID != "" && deps.MountRoot != "" {
			target, own, err := MountRepoDevice(ctx, runner, deps.MountRoot, loc.DeviceUUID)
			if err != nil {
				return nil, fmt.Errorf("%w: %s", engines.ErrNotAvailable, err)
			}
			repo.MountPath = target
			if own {
				repo.ownedMount = target
			}
		} else if loc.MountPath != "" {
			repo.MountPath = loc.MountPath
		} else {
			return nil, engines.ErrNotAvailable
		}

		repo.Runner = runner
		repo.Backend = &LocalBackend{
			Runner: runner,
			Name:   repo.MountPath,
		}

	default:
		return nil, fmt.Errorf("timeshift: unknown location type %q", loc.Type)
	}

	return repo, nil
}

/* The multiplexing socket.
 *
 * sockaddr_un caps a unix socket path at 108 bytes including the terminator,
 * and ssh fails outright rather than truncating -- so this stays short and
 * lives under the daemon's run directory rather than embedding the full
 * user@host:/path. */
func controlPath(mountRoot string, s engines.SSHLocation) string {
	if mountRoot == "" {
		return ""
	}
	name := fmt.Sprintf("ssh-%s", shortHash(s.User+"@"+s.Host+":"+s.Path))
	return path.Join(mountRoot, name)
}

// shortHash is an FNV-1a digest rendered short enough to keep the control path
// inside the 108-byte limit.
func shortHash(s string) string {
	const offset64 = 14695981039346656037
	const prime64 = 1099511628211
	h := uint64(offset64)
	for i := 0; i < len(s); i++ {
		h ^= uint64(s[i])
		h *= prime64
	}
	return fmt.Sprintf("%016x", h)
}

// runnerAdapter bridges engines.Runner to the backend's narrower Runner.
type runnerAdapter struct{ r engines.Runner }

func (a runnerAdapter) Run(ctx context.Context, argv []string, stdin string) (int, string, string, error) {
	return a.r.Run(ctx, argv, stdin)
}
