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

	/* --help and --version answer before anything else.
	 *
	 * They are the two things that must work when the rest of the command line
	 * is wrong, and help2man depends on both. */
	for _, a := range args {
		switch a {
		case "--help", "-h":
			fmt.Print(help())
			return 0
		case "--version":
			fmt.Printf("timeshift %s\n", version)
			return 0
		}
	}

	o, err := parseArgs(args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}

	mode := o.mode
	configPath := o.configPath
	socket := o.socket
	scripted := o.scripted
	comments := o.comments
	jobID := o.jobID
	verbosity := o.verbosity
	tags := o.tags
	names := o.names
	restoreOpts := o.restore
	sshPassword := o.sshPassword
	recoveryTarget := o.recoveryTarget
	recoverySize := o.recoverySize

	override := ipc.LocationOverride{
		Device:    o.override.Device,
		URL:       o.override.URL,
		KeyFile:   o.override.KeyFile,
		Port:      o.override.Port,
		BtrfsMode: o.override.BtrfsMode,
	}

	if mode == "" {
		fmt.Print(help())
		return 0
	}

	/* Verbosity is the client's business, not the core's.
	 *
	 * AppConsole set App.debug_mode and the core then printed from inside
	 * itself -- which is why --scripted still had progress written over its
	 * output. Here it only decides what THIS process prints. */
	/* --verbose was a documented no-op.
	 *
	 * The flag set verbosity=1 and nothing ever read anything but >= 2
	 * (--debug) and < 0 (--quiet), so the help promised something that did not
	 * happen. It now reports what this process is about to do, which is the
	 * level of detail the name suggests, without --debug's socket and override
	 * dump.
	 */
	if verbosity == 1 {
		fmt.Fprintf(os.Stderr, "timeshift: %s\n", modeDescription(mode))
	}
	if verbosity >= 2 {
		fmt.Fprintf(os.Stderr, "timeshift: mode=%s socket=%s override=%s\n",
			mode, socket, jsonOr(override))
	}
	if verbosity < 0 {
		scripted = true // --quiet implies no progress rendering
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

	case "cancel":
		return runCancel(socket, jobID)

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

	case "delete-all":
		return runDeleteAll(socket, overridePtr(override), scripted, restoreOpts.Yes)

	case "setup-ssh-key":
		return runSetupSSHKey(socket, &override, sshPassword, scripted, restoreOpts.Yes)

	case "recovery-status":
		return runRecoveryStatus(socket, os.Stdout)

	case "recovery-enable":
		return runRecoveryVerb(socket, ipc.MethodRecoveryEnable, "enable")

	case "recovery-disable":
		return runRecoveryVerb(socket, ipc.MethodRecoveryDisable, "disable")

	case "recovery-install":
		return runRecoveryInstall(socket, recoveryTarget, recoverySize, scripted)

	case "list-snapshots":
		/* Ask the daemon first, and open the repository ourselves only when
		 * there is no daemon to ask. Doing it in-process means mounting a
		 * filesystem the daemon has probably already mounted. */
		ov := overridePtr(override)
		found, served, err := listSnapshotsViaDaemon(socket, os.Stdout, ov)
		if !served {
			/* No daemon. A device given by PATH cannot be honoured here --
			 * resolving it to a UUID needs a scan this path does not have yet
			 * -- so say so rather than listing the configured location and
			 * letting it look like the flag worked. */
			if ov != nil && ov.Device != "" && ov.DeviceUUID == "" {
				fmt.Fprintln(os.Stderr,
					"timeshift: --snapshot-device by path needs the daemon; start timeshiftd, or give the UUID")
				return 1
			}
			found, err = listSnapshotsCmd(ctx, configPath, runner, ov)
		}
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

// help is --help, generated from the flag table so the two cannot disagree.
func help() string { return helpText(version) }

// listSnapshotsCmd wires the config to the engine and prints the listing.
func listSnapshotsCmd(ctx context.Context, configPath string, runner sysexec.Simple, ov *ipc.LocationOverride) (bool, error) {
	cfg, _, err := config.Load(configPath)
	if err != nil {
		return false, err
	}

	/* The same override the daemon would have applied, applied here instead.
	 * `--list` prefers the daemon and falls back to opening the repository
	 * itself, so the two paths have to agree about what --snapshot-device
	 * means, or the command changes meaning when the daemon is not running. */
	cfg = applyOverrideLocally(cfg, ov)

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

	repository.SetFirstSnapshotSize(cfg.SnapshotSize)

	return listSnapshots(ctx, os.Stdout, repository, deviceName, deviceUUID)
}

// modeDescription is the one-line "what is about to happen" that --verbose
// prints. Kept next to the dispatch so a new mode is obvious when it is missing.
func modeDescription(mode string) string {
	switch mode {
	case "create":
		return "taking a snapshot"
	case "delete":
		return "deleting a snapshot"
	case "delete-all":
		return "deleting every snapshot"
	case "restore":
		return "restoring a snapshot"
	case "estimate":
		return "measuring the system size"
	case "check":
		return "running a scheduled check"
	case "cancel":
		return "cancelling the running job"
	case "watch":
		return "watching the running job"
	case "list-snapshots":
		return "listing snapshots"
	case "list-devices":
		return "listing devices"
	default:
		return mode
	}
}
