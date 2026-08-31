// Command timeshift is the Timeshift command-line client.
//
// It is replacing the Vala AppConsole flag by flag. The commands implemented so
// far run in-process; once timeshiftd's socket lands they move behind it, which
// is what will let a snapshot started by apt-snapshot-guard be watched from the
// GUI at the same time. Output is compared byte for byte against the Vala
// binary, so this is a drop-in replacement rather than a rewrite that happens
// to do the same job.
//
// This binary is not installed yet: the Vala `timeshift` still owns
// /usr/bin/timeshift.
//
// NOTE for whoever wires this into the man pages: docs/man/meson.build runs
// help2man against the installed binary, so --help must keep its shape (a
// version line, then Usage:, then Options:) or the package build breaks.
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/makeafide/timeshift/src-go/internal/block"
	"github.com/makeafide/timeshift/src-go/internal/config"
	"github.com/makeafide/timeshift/src-go/internal/engines"
	tsengine "github.com/makeafide/timeshift/src-go/internal/engines/timeshift"
	"github.com/makeafide/timeshift/src-go/internal/sysexec"
)

// version is stamped by the build; see src-go/go-build.sh.
var version = "dev"

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	mode := ""
	configPath := config.SystemPath

	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--help", "-h":
			fmt.Print(help())
			return 0
		case "--version":
			fmt.Printf("timeshift %s\n", version)
			return 0
		case "--list-devices":
			mode = "list-devices"
		case "--list", "--list-snapshots":
			mode = "list-snapshots"
		case "--config":
			/* Bounds-checked, unlike AppConsole.parse_arguments(), where every
			 * value-taking flag does args[++k] with no check at all -- so a
			 * trailing `--comments` reads past the end of the array. */
			if i+1 >= len(args) {
				fmt.Fprintln(os.Stderr, "timeshift: --config needs a path")
				return 1
			}
			i++
			configPath = args[i]
		default:
			fmt.Fprintf(os.Stderr, "timeshift: unrecognised option %q\n", args[i])
			return 1
		}
	}

	if mode == "" {
		fmt.Print(help())
		return 0
	}

	// Both binaries refuse to run as anyone but root, and say so the same way.
	if err := requireRoot(os.Geteuid()); err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		return 1
	}

	ctx := context.Background()
	runner := sysexec.NewSimple(sysexec.New(nil))

	switch mode {
	case "list-snapshots":
		found, err := listSnapshotsCmd(ctx, configPath, runner)
		if err != nil {
			fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
			return 1
		}
		// An empty repository exits 1. Scripts rely on it.
		if !found {
			return 1
		}
		return 0

	case "list-devices":
		/* AppConsole prints this through log_msg(), which appends its own
		 * newline -- so the leading "\n" and trailing ":\n" produce a blank
		 * line, the heading, and another blank line. The log_msg("") after the
		 * table is a third. */
		fmt.Print("\nDevices with Linux file systems:\n\n")
		if err := listDevices(ctx, os.Stdout, &block.Scanner{Runner: runner}); err != nil {
			fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
			return 1
		}
		fmt.Println()
		_ = configPath
		return 0
	}

	return 1
}

func help() string {
	return fmt.Sprintf(`
Timeshift %s

Syntax: timeshift [options]

Options:

  --list            List snapshots
  --list-devices    List available devices
  --config PATH     Path to timeshift.json (default %s)
  --help, -h        Show all options
  --version         Print version number
`, version, config.SystemPath)
}

// listSnapshotsCmd wires the config to the engine and prints the listing.
func listSnapshotsCmd(ctx context.Context, configPath string, runner sysexec.Simple) (bool, error) {
	cfg, _, err := config.Load(configPath)
	if err != nil {
		return false, err
	}

	var devices []*block.Device
	if !cfg.Remote() {
		scanner := &block.Scanner{Runner: runner}
		if devices, err = scanner.Scan(ctx); err != nil {
			return false, err
		}
	}

	loc, deviceName, deviceUUID, err := locationFromConfig(cfg, devices)
	if err != nil {
		return false, err
	}

	engine, err := engines.Lookup(cfg.Engine)
	if err != nil {
		return false, err
	}

	/* Per-process, matching Main.mount_point_app. Two Timeshifts must not
	 * fight over one mount point, and a stale one is identifiable by the pid
	 * in its name. */
	mountRoot := fmt.Sprintf("/run/timeshift/%d", os.Getpid())

	repository, err := engine.Open(ctx, loc, engines.Deps{
		Runner:    runner,
		TempDir:   os.TempDir(),
		MountRoot: mountRoot,
	})
	if err != nil {
		return false, err
	}
	defer repository.Close()

	repo, ok := repository.(*tsengine.Repo)
	if !ok {
		return false, fmt.Errorf("timeshift: engine %q does not provide a console listing", engine.ID())
	}
	repo.FirstSnapshotSize = cfg.SnapshotSize

	return listSnapshots(ctx, os.Stdout, repo, deviceName, deviceUUID)
}
