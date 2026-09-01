package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"github.com/makeafide/timeshift/src-go/internal/ipc"
	"github.com/makeafide/timeshift/src-go/internal/jobs"
)

/* timeshift --restore.
 *
 * Two round trips, always: plan, then restore. The plan is printed and agreed
 * to before anything is written, because the failure that matters here is not a
 * crash -- it is a restore that worked perfectly onto the wrong disk. A person
 * reading "/  /dev/sdb2  will be erased and replaced" is the only thing that
 * catches that, and it cannot happen if the command just starts working.
 *
 * --yes skips the question. --scripted implies it, and also makes every
 * remaining prompt a hard failure rather than a wait: an unattended run with
 * nobody to answer must stop, not hang.
 */

// RestoreOptions are the command's inputs.
type RestoreOptions struct {
	Snapshot      string
	Target        string            // device for /
	Mounts        map[string]string // mount point -> device
	CurrentSystem bool
	DryRun        bool
	SkipGrub      bool
	GrubDevice    string
	Yes           bool
	Scripted      bool
}

func runRestore(socket string, o RestoreOptions) int {

	c, err := connect(socket)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	defer c.Close()

	if o.Snapshot == "" {
		fmt.Fprintln(os.Stderr, "timeshift: --restore needs --snapshot NAME")
		fmt.Fprintln(os.Stderr, "           run 'timeshift --list' to see the available snapshots")
		return 1
	}

	mounts := map[string]string{}
	for k, v := range o.Mounts {
		mounts[k] = v
	}
	if o.Target != "" {
		mounts["/"] = o.Target
	}

	/* Restoring the running system has to be asked for.
	 *
	 * Defaulting to it would mean that forgetting --target overwrites the
	 * machine you are typing on. There is no undo, so the default is the
	 * cautious one and the dangerous one is spelled out. */
	if !o.CurrentSystem && len(mounts) == 0 {
		fmt.Fprintln(os.Stderr, "timeshift: --restore needs a target")
		fmt.Fprintln(os.Stderr, "           --target /dev/sdXN         restore to another device")
		fmt.Fprintln(os.Stderr, "           --current-system           overwrite the running system")
		return 1
	}

	params := ipc.RestoreParams{
		Snapshot:      o.Snapshot,
		Mounts:        mounts,
		CurrentSystem: o.CurrentSystem,
		DryRun:        o.DryRun,
		SkipGrub:      o.SkipGrub,
		GrubDevice:    o.GrubDevice,
	}

	// 1. Plan. Nothing is touched.
	var plan ipc.RestorePlanResult
	if err := c.Call(ipc.MethodRestorePlan, params, &plan); err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}

	fmt.Println()
	fmt.Print(plan.Summary)

	if plan.Blocked {
		fmt.Fprintln(os.Stderr, "\ntimeshift: this restore cannot proceed:")
		for _, b := range plan.Blockers {
			fmt.Fprintf(os.Stderr, "  %s\n", b)
		}
		return 1
	}

	// 2. Agree to it.
	if !confirmRestore(o, plan) {
		fmt.Println("Cancelled. Nothing was changed.")
		return 0
	}

	// 3. Do it, as a job, so it can be watched from elsewhere and survives
	// this client going away.
	var ref ipc.JobRef
	if err := c.Call(ipc.MethodSnapshotRestore, params, &ref); err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}

	fmt.Println()
	outcome, err := watchJob(c, ref.Job, os.Stdout, o.Scripted)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}

	switch outcome {
	case jobs.OutcomeFailed:
		fmt.Fprintln(os.Stderr, "\nRestore FAILED. The target may be incomplete and must not be booted.")
		return 1
	case jobs.OutcomeWarnings:
		fmt.Println("\nRestore completed with warnings.")
		return 0
	}

	if o.DryRun {
		fmt.Println("\nDry run complete. Nothing was changed.")
	} else if o.CurrentSystem {
		fmt.Println("\nRestore complete. The system will restart.")
	} else {
		fmt.Println("\nRestore complete.")
	}
	return 0
}

/* confirmRestore asks, unless told not to.
 *
 * The prompt requires the word "yes", not a bare Enter. A y/N prompt is
 * answered by accident; this one is not.
 */
func confirmRestore(o RestoreOptions, plan ipc.RestorePlanResult) bool {

	if o.DryRun {
		return true // nothing is written, so there is nothing to agree to
	}
	if o.Yes || o.Scripted {
		return true
	}

	fmt.Println()
	if o.CurrentSystem {
		fmt.Println("This will overwrite THE RUNNING SYSTEM and restart the machine.")
	} else {
		fmt.Printf("This will ERASE and replace the contents of %s.\n", plan.Target)
	}
	fmt.Println("Files on the target that are not in the snapshot will be deleted.")
	fmt.Print("\nType 'yes' to continue: ")

	reader := bufio.NewReader(os.Stdin)
	answer, err := reader.ReadString('\n')
	if err != nil {
		/* No terminal and no --yes. Refuse rather than assume: an unattended
		 * run that cannot be asked must not proceed by default. */
		fmt.Fprintln(os.Stderr, "\ntimeshift: no answer, and --yes was not given")
		return false
	}
	return strings.TrimSpace(answer) == "yes"
}

// parseMountArg reads "--mount /home=/dev/sda3".
func parseMountArg(arg string) (mountPoint, device string, err error) {
	mountPoint, device, found := strings.Cut(arg, "=")
	if !found || strings.TrimSpace(mountPoint) == "" {
		return "", "", fmt.Errorf("--mount expects MOUNTPOINT=DEVICE, got %q", arg)
	}
	if !strings.HasPrefix(mountPoint, "/") {
		return "", "", fmt.Errorf("--mount: %q is not a mount point", mountPoint)
	}
	return mountPoint, device, nil
}
