package main

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/makeafide/timeshift/src-go/internal/config"
	"github.com/makeafide/timeshift/src-go/internal/ipc"
)

// The defaults the table starts from, named once.
var (
	defaultConfigPath = config.SystemPath
	defaultSocket     = ipc.SocketPath
)

/* The command line, as data.
 *
 * This was a 244-line switch, which is a fine shape for ten flags and a poor
 * one for fifty-six. Three things went wrong with it and all three are
 * structural rather than careless:
 *
 *   - Every value-taking flag repeated the same four-line bounds check.
 *     Eighteen copies, all correct, none of them interesting.
 *   - Aliases were spelled two different ways -- some as extra `case` labels,
 *     some as whole duplicate arms with their own error strings -- so
 *     --target and --target-device set the same field from different code.
 *   - The help text was maintained by hand alongside it and had already
 *     drifted: eight accepted aliases were undocumented and --verbose was
 *     documented while doing nothing.
 *
 * A table fixes the first two by construction and the third by generating the
 * help from the same data the parser uses, so the two cannot disagree again.
 */

// options is everything the command line can set.
type options struct {
	mode       string
	configPath string
	socket     string
	scripted   bool
	comments   string
	jobID      string
	verbosity  int

	tags  []string
	names []string

	restore RestoreOptions

	// Per-run location and mode overrides. See ipc.LocationOverride.
	override overrideOptions

	sshPassword    string
	recoveryTarget string
	recoverySize   string

	// modeFlag records which flag set the mode, so a second one can name both.
	modeFlag string
}

// overrideOptions mirrors ipc.LocationOverride without importing it here, so
// the table stays about parsing.
type overrideOptions struct {
	Device    string
	URL       string
	KeyFile   string
	Port      int
	BtrfsMode *bool
}

/* flagSpec is one accepted option.
 *
 * arg being non-empty is what makes a flag take a value, and its text is used
 * both in the error when the value is missing and in the generated help -- so
 * "--target DEVICE" and "--target needs a DEVICE" can never describe different
 * things.
 */
type flagSpec struct {
	names []string // the flag and its aliases; names[0] is canonical
	arg   string   // "" for a switch; otherwise the value's name
	help  string   // "" hides it from --help (aliases and deprecated spellings)
	sect  string   // help section; "" is the main list
	mode  string   // non-empty: this flag selects a mode
	apply func(o *options, v string) error
}

// sections, in the order --help prints them.
const (
	sectLocation = "Location (for this run only; nothing is saved):"
	sectRemote   = "Remote setup:"
	sectRecovery = "Recovery environment:"
	sectGlobal   = "Global:"
)

func boolPtr(b bool) *bool { return &b }

// flagTable is the whole command line. Order is the order --help prints.
var flagTable = []flagSpec{
	// ---- modes ----
	{names: []string{"--create"}, mode: "create", help: "Take a snapshot now"},
	{names: []string{"--check"}, mode: "check", help: "Take a scheduled snapshot if one is due"},
	{names: []string{"--watch"}, mode: "watch", help: "Watch the snapshot already running"},
	{names: []string{"--cancel"}, mode: "cancel", help: "Stop the running job (or --job ID)"},
	{names: []string{"--estimate"}, mode: "estimate", help: "Measure the system size"},
	{names: []string{"--delete"}, mode: "delete", help: "Delete a snapshot (with --snapshot NAME)"},
	{names: []string{"--delete-all"}, mode: "delete-all", help: "Delete every snapshot"},
	{names: []string{"--restore"}, mode: "restore", help: "Restore a snapshot (with --snapshot NAME)"},
	{names: []string{"--list", "--list-snapshots"}, mode: "list-snapshots", help: "List snapshots"},
	{names: []string{"--list-devices"}, mode: "list-devices", help: "List available devices"},
	{names: []string{"--schedule-status"}, mode: "schedule-status", help: "Report when the scheduler last ran"},

	// ---- restore ----
	{names: []string{"--target", "--target-device"}, arg: "DEVICE",
		help:  "Device to restore the root filesystem to",
		apply: func(o *options, v string) error { o.restore.Target = v; return nil }},
	{names: []string{"--mount"}, arg: "MP=DEV",
		help: "Device for another mount point, e.g. /home=/dev/sda3",
		apply: func(o *options, v string) error {
			mp, dev, err := parseMountArg(v)
			if err != nil {
				return err
			}
			if o.restore.Mounts == nil {
				o.restore.Mounts = map[string]string{}
			}
			o.restore.Mounts[mp] = dev
			return nil
		}},
	{names: []string{"--current-system", "--restore-in-place"},
		help:  "Restore over the running system (destructive)",
		apply: func(o *options, _ string) error { o.restore.CurrentSystem = true; return nil }},
	{names: []string{"--dry-run"},
		help:  "Compare only; change nothing",
		apply: func(o *options, _ string) error { o.restore.DryRun = true; return nil }},
	{names: []string{"--skip-grub"},
		help:  "Do not reinstall the bootloader",
		apply: func(o *options, _ string) error { o.restore.SkipGrub = true; return nil }},
	{names: []string{"--grub-device", "--grub"}, arg: "DEV",
		help:  "Install the bootloader here",
		apply: func(o *options, v string) error { o.restore.GrubDevice = v; return nil }},
	{names: []string{"--yes", "-y"},
		help:  "Do not ask for confirmation",
		apply: func(o *options, _ string) error { o.restore.Yes = true; return nil }},

	// ---- what to act on ----
	{names: []string{"--tags"}, arg: "LETTERS",
		help:  "Retention levels for --create: O B H D W M",
		apply: func(o *options, v string) error { o.tags = expandTags(v); return nil }},
	{names: []string{"--comments", "--comment"}, arg: "TEXT",
		help:  "Description for --create",
		apply: func(o *options, v string) error { o.comments = v; return nil }},
	{names: []string{"--snapshot", "--snapshot-name"}, arg: "NAME",
		help:  "Snapshot to act on",
		apply: func(o *options, v string) error { o.names = append(o.names, v); return nil }},
	{names: []string{"--job"}, arg: "ID",
		help:  "Job to watch",
		apply: func(o *options, v string) error { o.jobID = v; return nil }},
	{names: []string{"--scripted"},
		help:  "No progress bar; for unattended use",
		apply: func(o *options, _ string) error { o.scripted = true; return nil }},

	// ---- location overrides ----
	{names: []string{"--snapshot-device", "--backup-device"}, arg: "DEV", sect: sectLocation,
		help:  "Use this device as the repository",
		apply: func(o *options, v string) error { o.override.Device = v; return nil }},
	{names: []string{"--snapshot-url", "--remote"}, arg: "URL", sect: sectLocation,
		help:  "Use this remote repository (user@host:/path)",
		apply: func(o *options, v string) error { o.override.URL = v; return nil }},
	{names: []string{"--ssh-key"}, arg: "FILE", sect: sectLocation,
		help:  "SSH key for the remote repository",
		apply: func(o *options, v string) error { o.override.KeyFile = v; return nil }},
	{names: []string{"--ssh-port"}, arg: "PORT", sect: sectLocation,
		help: "SSH port for the remote repository",
		apply: func(o *options, v string) error {
			port, err := strconv.Atoi(v)
			if err != nil || port < 1 || port > 65535 {
				return fmt.Errorf("--ssh-port needs a number from 1 to 65535, not %q", v)
			}
			o.override.Port = port
			return nil
		}},
	{names: []string{"--btrfs"}, sect: sectLocation,
		help:  "Treat the repository as BTRFS for this run",
		apply: func(o *options, _ string) error { o.override.BtrfsMode = boolPtr(true); return nil }},
	{names: []string{"--rsync"}, sect: sectLocation,
		help:  "Treat the repository as RSYNC for this run",
		apply: func(o *options, _ string) error { o.override.BtrfsMode = boolPtr(false); return nil }},

	// ---- remote setup ----
	{names: []string{"--setup-ssh-key"}, mode: "setup-ssh-key", sect: sectRemote,
		help: "Provision key-based login to the remote repository"},
	{names: []string{"--ssh-password"}, arg: "PASS", sect: sectRemote,
		help:  "Password for --setup-ssh-key (prompted if omitted)",
		apply: func(o *options, v string) error { o.sshPassword = v; return nil }},

	// ---- recovery environment ----
	{names: []string{"--recovery-status"}, mode: "recovery-status", sect: sectRecovery,
		help: "Report the recovery environment"},
	{names: []string{"--recovery-enable"}, mode: "recovery-enable", sect: sectRecovery,
		help: "Add the recovery entry to the boot menu"},
	{names: []string{"--recovery-disable"}, mode: "recovery-disable", sect: sectRecovery,
		help: "Remove the recovery entry"},
	{names: []string{"--recovery-install"}, mode: "recovery-install", sect: sectRecovery,
		help: "Build and install the recovery environment"},
	{names: []string{"--recovery-target"}, arg: "T", sect: sectRecovery,
		help:  "Where to place it (partition or root)",
		apply: func(o *options, v string) error { o.recoveryTarget = v; return nil }},
	{names: []string{"--recovery-size"}, arg: "S", sect: sectRecovery,
		help:  "Size of a dedicated recovery partition",
		apply: func(o *options, v string) error { o.recoverySize = v; return nil }},

	// ---- global ----
	{names: []string{"--socket"}, arg: "PATH", sect: sectGlobal,
		help:  "Daemon socket",
		apply: func(o *options, v string) error { o.socket = v; return nil }},
	{names: []string{"--config"}, arg: "PATH", sect: sectGlobal,
		help:  "Configuration file",
		apply: func(o *options, v string) error { o.configPath = v; return nil }},
	{names: []string{"--verbose"}, sect: sectGlobal,
		help:  "Say what is being done",
		apply: func(o *options, _ string) error { o.verbosity = 1; return nil }},
	{names: []string{"--debug"}, sect: sectGlobal,
		help:  "More detail, including the resolved location",
		apply: func(o *options, _ string) error { o.verbosity = 2; return nil }},
	{names: []string{"--quiet"}, sect: sectGlobal,
		help:  "No progress output",
		apply: func(o *options, _ string) error { o.verbosity = -1; return nil }},
}

/* refusals are flags the Vala CLI accepted that this one deliberately will not,
 * each with a reason. Refusing with an explanation beats reinterpreting: a
 * script that used --clone should be told, not quietly given something else.
 */
var refusals = map[string]string{
	"--clone": "--clone is not implemented.\n" +
		"           It was --restore with mirror_system set, and upstream's own\n" +
		"           help calls it a broken feature and does not document it.\n" +
		"           Use --restore --target DEVICE to restore onto another disk.",
	"--backup": "--backup was renamed. Use --create to take a snapshot now,\n" +
		"           or --check to take one only if the schedule is due.",
	"--backup-now": "--backup-now was renamed. Use --create to take a snapshot now,\n" +
		"           or --check to take one only if the schedule is due.",
}

// lookup finds a flag by any of its names.
func lookup(name string) (flagSpec, bool) {
	for _, f := range flagTable {
		for _, n := range f.names {
			if n == name {
				return f, true
			}
		}
	}
	return flagSpec{}, false
}

/* parseArgs turns a command line into options.
 *
 * Errors carry their own text and are printed by the caller, so every "needs a
 * value" message has one source rather than eighteen.
 */
func parseArgs(args []string) (options, error) {
	o := options{
		configPath: defaultConfigPath,
		socket:     defaultSocket,
	}

	for i := 0; i < len(args); i++ {
		arg := args[i]

		if reason, refused := refusals[arg]; refused {
			return o, fmt.Errorf("%s", reason)
		}

		spec, known := lookup(arg)
		if !known {
			return o, fmt.Errorf("unrecognised option %q\nRun 'timeshift --help' to list the options", arg)
		}

		value := ""
		if spec.arg != "" {
			// One bounds check, not eighteen.
			if i+1 >= len(args) {
				return o, fmt.Errorf("%s needs a %s", spec.names[0], spec.arg)
			}
			i++
			value = args[i]
		}

		/* Two modes on one command line is a mistake worth catching.
		 *
		 * The mode used to be a plain string that each flag overwrote, so
		 * `timeshift --list --delete --snapshot x` silently deleted: the last
		 * mode flag won and nothing said the first had been ignored. */
		if spec.mode != "" {
			if o.mode != "" && o.mode != spec.mode {
				return o, fmt.Errorf("%s and %s cannot both be given; pick one",
					o.modeFlag, spec.names[0])
			}
			o.mode = spec.mode
			o.modeFlag = spec.names[0]
		}

		if spec.apply != nil {
			if err := spec.apply(&o, value); err != nil {
				return o, err
			}
		}
	}
	return o, nil
}

/* helpText renders --help from the same table the parser uses.
 *
 * Generated rather than written, because the hand-written version had already
 * drifted from the parser in both directions. Aliases are deliberately not
 * listed: they exist for compatibility with the Vala CLI's spellings, and
 * printing every one would treble the length of the list for no one's benefit.
 *
 * help2man builds the man page by running this, so the shape matters: a
 * version line, then Usage:, then Options:.
 */
func helpText(version string) string {
	var b strings.Builder

	fmt.Fprintf(&b, "\nTimeshift %s\n", version)
	b.WriteString("\nUsage: timeshift [options]\n")

	// One column width for the whole page, measured rather than guessed: a
	// hardcoded one silently ragged the moment a flag outgrew it.
	width := 0
	label := func(f flagSpec) string {
		left := f.names[0]
		if f.arg != "" {
			left += " " + f.arg
		}
		return left
	}
	for _, f := range flagTable {
		if f.help == "" {
			continue
		}
		if n := len(label(f)); n > width {
			width = n
		}
	}

	writeSection := func(title, sect string) {
		var rows []flagSpec
		for _, f := range flagTable {
			if f.sect == sect && f.help != "" {
				rows = append(rows, f)
			}
		}
		if len(rows) == 0 {
			return
		}
		fmt.Fprintf(&b, "\n%s\n\n", title)
		for _, f := range rows {
			fmt.Fprintf(&b, "  %-*s  %s\n", width, label(f), f.help)
		}
	}

	writeSection("Options:", "")
	writeSection(sectLocation, sectLocation)
	writeSection(sectRemote, sectRemote)
	writeSection(sectRecovery, sectRecovery)
	writeSection(sectGlobal, sectGlobal)

	b.WriteString(`
Examples:

  timeshift --list
  timeshift --create --comments "before upgrading"
  timeshift --create --tags D --scripted
  timeshift --restore --snapshot 2026-09-01_10-00-00 --target /dev/sda2
  timeshift --restore --snapshot 2026-09-01_10-00-00 --current-system
  timeshift --delete --snapshot 2026-09-01_10-00-00
  timeshift --watch

Notes:

  1. Snapshots are taken and restored by the timeshiftd service; this command
     is a client. --list works without it.
  2. A job outlives the client that started it, so closing this program does
     not stop a snapshot. Use --cancel to stop one.
  3. --restore needs a target: --target DEVICE, or --current-system to
     overwrite the machine you are typing on.
`)

	fmt.Fprintf(&b, "\nConfiguration: %s\nSocket:        %s\n", defaultConfigPath, defaultSocket)
	return b.String()
}
