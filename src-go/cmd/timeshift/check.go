package main

import (
	"fmt"
	"os"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/ipc"
	"github.com/makeafide/timeshift/src-go/internal/schedule"
)

/* --check.
 *
 * This was the cron entry point, and cron is gone, so the flag now means "run
 * the check you would have run anyway, now". It is kept because scripts and
 * documentation call it, because a legacy /etc/cron.d entry on a machine that
 * has not been upgraded yet still calls it, and because asking for a check by
 * hand is a reasonable thing to want.
 *
 * It is safe for both to happen. The daemon's answer to "is an hourly snapshot
 * due" does not change with how many times it is asked, so a stray cron entry
 * firing alongside the ticker costs a directory listing and nothing else. That
 * is the whole reason the check could be moved without a flag day.
 */

// runCheck asks the daemon to run a scheduled check and reports what happened.
func runCheck(socket string, scripted bool) int {
	client, err := ipc.Dial(socket)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	defer client.Close()

	before, err := scheduleStatus(client)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}

	if !before.Enabled {
		fmt.Println("Scheduled snapshots are disabled - Nothing to do!")
		return 0
	}

	/* Enabled without Running is the failure that losing cron introduced, and
	 * it has to be said out loud.
	 *
	 * cron ran whether or not our own code was healthy. A timeshiftd whose
	 * scheduler never started now means no snapshots at all, and the only
	 * thing that makes it visible is a client saying so. Reporting it as
	 * success -- which is what reading Enabled alone did -- is the one answer
	 * that guarantees nobody investigates.
	 *
	 * A live session is the benign reason for the same two values, so it gets
	 * its own message and exit 0: a rescue environment has nothing to
	 * snapshot, and that is correct rather than broken. */
	if !before.Running {
		if before.Live {
			fmt.Println("This is a live session - Nothing to do!")
			return 0
		}
		fmt.Fprintln(os.Stderr,
			"timeshift: scheduled snapshots are enabled, but no scheduler is running.\n"+
				"           No snapshots are being taken. Check: systemctl status timeshiftd")
		return 1
	}

	if err := client.Call(ipc.MethodScheduleCheck, nil, nil); err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}

	if !scripted {
		fmt.Println("Checking for scheduled snapshots...")
	}

	/* Wait for the check to complete by watching LastRun advance. A check that
	 * takes a snapshot runs for as long as the backup does, so there is no
	 * timeout here -- returning early would print "nothing happened" while the
	 * snapshot was still being written. Ctrl-C leaves the daemon working, which
	 * is the point of the daemon. */
	status := before
	for {
		time.Sleep(500 * time.Millisecond)

		status, err = scheduleStatus(client)
		if err != nil {
			fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
			return 1
		}
		if status.LastRun.After(before.LastRun) {
			break
		}
	}

	if status.LastError != "" {
		fmt.Fprintf(os.Stderr, "timeshift: %s\n", status.LastError)
		return 1
	}
	fmt.Println(status.LastResult)
	return 0
}

// runScheduleStatus prints what the scheduler has been doing.
//
// Worth having as its own command: cron used to be the thing that ran whether
// or not Timeshift was healthy, and with the daemon owning the timer the only
// way to notice it has stopped is to ask.
func runScheduleStatus(socket string) int {
	client, err := ipc.Dial(socket)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	defer client.Close()

	st, err := scheduleStatus(client)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}

	switch {
	/* Live comes first, because on a live session it is the explanation for
	 * every other value below and the alarming "NOT running" line would be
	 * both true and misleading. */
	case st.Live:
		fmt.Println("Scheduled snapshots: not scheduled here (live session)")
	case !st.Enabled:
		fmt.Println("Scheduled snapshots: disabled")
	case !st.Running:
		fmt.Println("Scheduled snapshots: enabled, but the scheduler is NOT running")
	default:
		fmt.Printf("Scheduled snapshots: enabled, checking every %s\n",
			(time.Duration(st.IntervalSeconds) * time.Second).String())
	}

	if st.LastRun.IsZero() {
		fmt.Println("Last check:          never")
	} else {
		fmt.Printf("Last check:          %s (%s ago)\n",
			st.LastRun.Local().Format("2006-01-02 15:04:05"),
			time.Since(st.LastRun).Truncate(time.Second))
	}
	if st.LastResult != "" {
		fmt.Printf("Result:              %s\n", st.LastResult)
	}
	if st.LastError != "" {
		fmt.Printf("Error:               %s\n", st.LastError)
	}
	if !st.NextRun.IsZero() && st.Running {
		fmt.Printf("Next check:          %s\n", st.NextRun.Local().Format("2006-01-02 15:04:05"))
	}
	return 0
}

func scheduleStatus(client *ipc.Client) (schedule.Status, error) {
	var st schedule.Status
	err := client.Call(ipc.MethodScheduleStatus, nil, &st)
	return st, err
}
