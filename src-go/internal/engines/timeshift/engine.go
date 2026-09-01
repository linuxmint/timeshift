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
	"errors"
	"fmt"
	"os"
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
//
// Browse is true again, restored in the same change that added
// snapshots.browse. It was declared true for a while with no method behind it,
// which is worse than absent: an absent capability makes a client hide a
// button, a lying one makes it show a button that returns unknown_method.
func (Engine) Caps() engines.Caps {
	return engines.Caps{
		Incremental:  true,
		Remote:       true,
		Browse:       true,
		UnsharedSize: true,
	}
}

// ErrBtrfsRemote reports the one combination this engine cannot do.
var ErrBtrfsRemote = errors.New(
	"timeshift: btrfs mode needs a local filesystem; a remote repository can only store rsync snapshots")

// ValidateLocation reports whether a location is one this engine can use.
//
// btrfs mode and a remote repository are mutually exclusive, and saying so is
// better than the Vala behaviour of silently turning btrfs off during config
// load: a user who chose btrfs and then chose a remote location got rsync
// snapshots without ever being told. A client calls this to explain the
// conflict at the point the choice is made.
func (Engine) ValidateLocation(loc engines.Location) error {
	if loc.BtrfsMode && loc.Type == "ssh" {
		return ErrBtrfsRemote
	}
	return nil
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

	/* The run directory has to exist before anything is put in it.
	 *
	 * A local repository gets one on the way to mounting its device. A REMOTE
	 * one never touched it, and ssh's ControlPath lives there -- so
	 * `timeshift --list` against an SSH repository failed with
	 *
	 *   unix_listener: cannot bind to path /run/timeshift/<pid>/ssh-...:
	 *   No such file or directory
	 *
	 * and then reported "Remote location not available" with no snapshots,
	 * which is indistinguishable from an empty repository. The daemon uses the
	 * same per-pid path, so it could not reach a remote repository either.
	 *
	 * 0755, not 0700. It is tempting to lock it down because the ssh control
	 * socket lives in here, but a browse mount lives in here too and the
	 * desktop user has to traverse the directory to reach it -- 0700 makes the
	 * mount unreadable by the only person who wanted it. The socket is
	 * protected by its own mode: ssh creates a ControlPath 0600, so only root
	 * can connect to it whatever the directory says. */
	if deps.MountRoot != "" {
		if err := os.MkdirAll(deps.MountRoot, 0o755); err != nil {
			return nil, fmt.Errorf("timeshift: could not create %s: %w", deps.MountRoot, err)
		}
	}

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
		/* Forced here as well as in the config loader, so an engine opened
		 * directly cannot get it wrong. ValidateLocation is what a client
		 * calls to be TOLD about the conflict; this is the backstop that makes
		 * the wrong combination harmless rather than merely reported. */
		repo.BtrfsMode = false

	case "local", "":
		runner := runnerAdapter{deps.Runner}

		/* Mount the repository device ourselves when one is configured. An
		 * external disk plugged in for the occasion is not mounted, and a
		 * repository that only works if somebody else happened to mount it
		 * first is not a working repository. */
		if loc.DeviceUUID != "" && deps.MountRoot != "" {
			/* btrfs mode mounts the filesystem's TOP LEVEL, so that "@" and
			 * the snapshot directory are siblings on one filesystem -- which is
			 * what `btrfs subvolume snapshot` requires. Mounting plainly gives
			 * the default subvolume, which on Ubuntu is "@" itself. */
			opts := ""
			if repo.BtrfsMode {
				opts = BtrfsTopLevelOpts
			}
			target, own, err := MountRepoDeviceOpts(ctx, runner, deps.MountRoot, loc.DeviceUUID, opts)
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
