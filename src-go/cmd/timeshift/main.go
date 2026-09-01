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
	"strings"

	"github.com/makeafide/timeshift/src-go/internal/block"
	"github.com/makeafide/timeshift/src-go/internal/config"
	"github.com/makeafide/timeshift/src-go/internal/engines"
	tsengine "github.com/makeafide/timeshift/src-go/internal/engines/timeshift"
	"github.com/makeafide/timeshift/src-go/internal/ipc"
	"github.com/makeafide/timeshift/src-go/internal/sysexec"
)

/* The retention levels, and their single-letter aliases.
 *
 * --tags takes the letters: O ondemand, B boot, H hourly, D daily, W weekly,
 * M monthly. apt-snapshot-guard passes "O".
 */
var tagLetters = map[string]string{
	"O": "ondemand", "B": "boot", "H": "hourly",
	"D": "daily", "W": "weekly", "M": "monthly",
}

// expandTags turns "O,D" or "OD" into the level names.
func expandTags(spec string) []string {
	var out []string
	seen := map[string]bool{}
	for _, part := range strings.FieldsFunc(spec, func(r rune) bool {
		return r == ',' || r == ' '
	}) {
		for _, letter := range part {
			name, ok := tagLetters[strings.ToUpper(string(letter))]
			if !ok || seen[name] {
				continue
			}
			seen[name] = true
			out = append(out, name)
		}
	}
	return out
}

// version is stamped by the build; see src-go/go-build.sh.
var version = "dev"

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	mode := ""
	configPath := config.SystemPath
	socket := ipc.SocketPath
	scripted := false
	comments := ""
	jobID := ""
	var tags []string
	var names []string
	var restoreOpts RestoreOptions

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
		case "--create":
			mode = "create"
		case "--watch":
			mode = "watch"
		case "--estimate":
			mode = "estimate"
		case "--delete":
			mode = "delete"
		case "--restore":
			mode = "restore"
		case "--current-system", "--restore-in-place":
			restoreOpts.CurrentSystem = true
		case "--dry-run":
			restoreOpts.DryRun = true
		case "--yes", "-y":
			restoreOpts.Yes = true
		case "--skip-grub":
			restoreOpts.SkipGrub = true
		case "--target":
			if i+1 >= len(args) {
				fmt.Fprintln(os.Stderr, "timeshift: --target needs a device")
				return 1
			}
			i++
			restoreOpts.Target = args[i]
		case "--mount":
			if i+1 >= len(args) {
				fmt.Fprintln(os.Stderr, "timeshift: --mount needs MOUNTPOINT=DEVICE")
				return 1
			}
			i++
			mp, dev, err := parseMountArg(args[i])
			if err != nil {
				fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
				return 1
			}
			if restoreOpts.Mounts == nil {
				restoreOpts.Mounts = map[string]string{}
			}
			restoreOpts.Mounts[mp] = dev
		case "--grub-device":
			if i+1 >= len(args) {
				fmt.Fprintln(os.Stderr, "timeshift: --grub-device needs a device")
				return 1
			}
			i++
			restoreOpts.GrubDevice = args[i]
		case "--check":
			mode = "check"
		case "--schedule-status":
			mode = "schedule-status"
		case "--scripted":
			scripted = true
		case "--comments", "--comment":
			if i+1 >= len(args) {
				fmt.Fprintln(os.Stderr, "timeshift: --comments needs a value")
				return 1
			}
			i++
			comments = args[i]
		case "--tags":
			if i+1 >= len(args) {
				fmt.Fprintln(os.Stderr, "timeshift: --tags needs a value")
				return 1
			}
			i++
			tags = expandTags(args[i])
		case "--snapshot", "--snapshot-name":
			if i+1 >= len(args) {
				fmt.Fprintln(os.Stderr, "timeshift: --snapshot needs a name")
				return 1
			}
			i++
			names = append(names, args[i])
		case "--job":
			if i+1 >= len(args) {
				fmt.Fprintln(os.Stderr, "timeshift: --job needs an id")
				return 1
			}
			i++
			jobID = args[i]
		case "--socket":
			if i+1 >= len(args) {
				fmt.Fprintln(os.Stderr, "timeshift: --socket needs a path")
				return 1
			}
			i++
			socket = args[i]
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

	/* Root, except for the commands that only watch.
	 *
	 * The original refused every invocation from a non-root user, which is why
	 * seeing whether a backup was running meant a pkexec prompt. These two go
	 * to the daemon and ask it questions; the daemon decides for itself who may
	 * ask, from the peer credentials on the socket, and a member of the
	 * timeshift group may. Refusing here as well would make that grant
	 * unreachable. */
	switch mode {
	case "watch", "schedule-status":
	default:
		if err := requireRoot(os.Geteuid()); err != nil {
			fmt.Fprintf(os.Stderr, "%v\n", err)
			return 1
		}
	}

	ctx := context.Background()
	runner := sysexec.NewSimple(sysexec.New(nil))

	switch mode {
	case "create":
		/* AttachExisting: two apt frontends racing to snapshot should watch one
		 * job rather than take two snapshots of the same moment. */
		return runCreate(socket, ipc.CreateParams{
			Tags: tags, Comments: comments, AttachExisting: true,
		}, scripted)

	case "watch":
		return runWatch(socket, jobID, scripted)

	case "estimate":
		return runEstimate(socket, scripted)

	case "restore":
		restoreOpts.Scripted = scripted
		if restoreOpts.Snapshot == "" && len(names) > 0 {
			restoreOpts.Snapshot = names[0]
		}
		return runRestore(socket, restoreOpts)

	case "check":
		return runCheck(socket, scripted)

	case "schedule-status":
		return runScheduleStatus(socket)

	case "delete":
		if len(names) == 0 {
			fmt.Fprintln(os.Stderr, "timeshift: --delete needs --snapshot NAME")
			return 1
		}
		return runDelete(socket, names, scripted)

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

  --create          Take a snapshot now
  --check           Take a scheduled snapshot if one is due
  --watch           Watch the snapshot already running
  --estimate        Measure the system size
  --delete          Delete a snapshot (with --snapshot NAME)
  --restore         Restore a snapshot (with --snapshot NAME)
  --target DEVICE   Device to restore the root filesystem to
  --mount MP=DEV    Device for another mount point, e.g. /home=/dev/sda3
  --current-system  Restore over the running system (destructive)
  --dry-run         Compare only; change nothing
  --skip-grub       Do not reinstall the bootloader
  --grub-device DEV Install the bootloader here
  --yes, -y         Do not ask for confirmation
  --list            List snapshots
  --list-devices    List available devices
  --schedule-status Report when the scheduler last ran
  --tags LETTERS    Retention levels for --create: O B H D W M
  --comments TEXT   Description for --create
  --snapshot NAME   Snapshot to act on
  --job ID          Job to watch
  --scripted        No progress bar; for unattended use
  --socket PATH     Daemon socket (default %s)
  --config PATH     Path to timeshift.json (default %s)
  --help, -h        Show all options
  --version         Print version number
`, version, ipc.SocketPath, config.SystemPath)
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
