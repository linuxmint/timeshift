package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/fsutil"
	"github.com/makeafide/timeshift/src-go/internal/ipc"
	"github.com/makeafide/timeshift/src-go/internal/jobs"
)

/* Driving a job from the command line.
 *
 * The CLI submits work and then WATCHES it. It does not do the work, and it
 * does not own it: killing the CLI leaves the snapshot running, and a second
 * client can attach to the same job at any point. That is the whole difference
 * from AppConsole, where the operation lived inside the process that started it
 * and AppLock made a second one impossible.
 */

// watchJob follows a job to completion, rendering progress, and returns its
// outcome.
func watchJob(c *ipc.Client, jobID string, w io.Writer, scripted bool) (jobs.Outcome, error) {
	snap, err := c.Subscribe(ipc.SubscribeParams{Job: jobID})
	if err != nil {
		return jobs.OutcomeFailed, err
	}

	// Everything that already happened before we attached.
	if snap.State.Terminal() {
		render(w, snap.Progress, scripted)
		finish(w, snap.Outcome, snap.Messages, scripted)
		return snap.Outcome, nil
	}
	if snap.Progress.Count > 0 {
		fmt.Fprintf(w, "attached to %s, already in progress\n", jobID)
	}

	var lastPhase string
	for {
		select {
		case e, ok := <-c.Events():
			if !ok {
				return jobs.OutcomeFailed, fmt.Errorf("timeshift: lost contact with the daemon")
			}
			switch e.Type {
			case jobs.EventPhase:
				if e.Phase != "" && e.Phase != lastPhase {
					lastPhase = e.Phase
					if !scripted {
						clearLine(w)
					}
					fmt.Fprintf(w, "%s\n", phaseTitle(snap.Phases, e.Phases, e.Phase))
				}
			case jobs.EventProgress:
				if e.Progress != nil {
					render(w, *e.Progress, scripted)
				}
			case jobs.EventFinished:
				if !scripted {
					clearLine(w)
				}
				finish(w, e.Outcome, e.Messages, scripted)
				if e.Error != "" {
					return e.Outcome, fmt.Errorf("timeshift: %s", e.Error)
				}
				return e.Outcome, nil
			}
		case <-c.Done():
			return jobs.OutcomeFailed, fmt.Errorf("timeshift: the daemon went away")
		}
	}
}

/* Progress rendering.
 *
 * AppConsole printed this from INSIDE the core -- Main.create_snapshot_with_rsync
 * wrote a \r progress line to stdout even under --scripted, which is why
 * apt-snapshot-guard redirects everything to its log. Here the core reports
 * numbers and the client decides how to show them, so --scripted can simply
 * not draw a progress bar.
 */
func render(w io.Writer, p jobs.Progress, scripted bool) {
	if scripted {
		return
	}
	line := ""
	switch {
	case p.Total > 0:
		line = fmt.Sprintf("%6.2f%% complete", p.Percent*100)
		if p.ETASeconds >= 0 {
			line += fmt.Sprintf(" (%s remaining)", duration(p.ETASeconds))
		}
	case p.Count > 0:
		line = fmt.Sprintf("%s entries", group(p.Count))
	default:
		return
	}
	if p.StatusLine != "" {
		line += "  " + truncate(p.StatusLine, 48)
	}
	fmt.Fprintf(w, "\r%-100s", line)
}

func clearLine(w io.Writer) { fmt.Fprintf(w, "\r%-100s\r", "") }

func finish(w io.Writer, outcome jobs.Outcome, messages []string, scripted bool) {
	for _, m := range messages {
		fmt.Fprintln(w, m)
	}
	switch outcome {
	case jobs.OutcomeOK:
		fmt.Fprintln(w, "Done.")
	case jobs.OutcomeWarnings:
		fmt.Fprintln(w, "Done, with warnings.")
	default:
		fmt.Fprintln(w, "Failed.")
	}
}

// phaseTitle finds a phase's human title, preferring the freshest list.
func phaseTitle(initial, updated []jobs.Phase, key string) string {
	for _, list := range [][]jobs.Phase{updated, initial} {
		for _, p := range list {
			if p.Key == key {
				return p.Title
			}
		}
	}
	return key
}

func duration(seconds int64) string {
	if seconds < 0 {
		return "?"
	}
	d := time.Duration(seconds) * time.Second
	h := int(d.Hours())
	m := int(d.Minutes()) % 60
	s := int(d.Seconds()) % 60
	if h > 0 {
		return fmt.Sprintf("%d:%02d:%02d", h, m, s)
	}
	return fmt.Sprintf("%d:%02d", m, s)
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	// Keep the tail: the interesting part of a long path is its end.
	return "..." + s[len(s)-n+3:]
}

func group(n int64) string { return fsutil.GroupDigits(n) }

/* connect dials the daemon, starting it if it is not there, and reports the one
 * failure worth acting on.
 *
 * Every command that routes through here mutates something and has no
 * in-process path, so an absent daemon is total failure -- and --create is run
 * by a fail-closed apt hook that blocks dpkg. autostartDaemon is what keeps
 * that hook's promise that it never depends on the daemon being up.
 */
func connect(socket string) (*ipc.Client, error) {
	c, err := ipc.Dial(socket)
	if errors.Is(err, ipc.ErrNoDaemon) {
		/* Try to bring it up, then dial once more. A failure to start is not
		 * reported on its own: the message that helps names the daemon, not
		 * whichever of systemctl or exec was tried last. */
		if autostartDaemon(socket) == nil {
			c, err = ipc.Dial(socket)
		}
	}
	if err != nil {
		if errors.Is(err, ipc.ErrNotPermitted) {
			return nil, fmt.Errorf(
				"not permitted to talk to timeshiftd (socket %s).\n"+
					"Run as root, or join the 'timeshift' group for read-only access:\n"+
					"  sudo usermod -aG timeshift $USER   (then log out and back in)", socket)
		}
		if errors.Is(err, ipc.ErrNoDaemon) {
			return nil, fmt.Errorf(
				"timeshiftd is not running and could not be started (socket %s).\n"+
					"Start it with: sudo systemctl start timeshiftd", socket)
		}
		return nil, err
	}

	/* Ask what it is before trusting it with anything.
	 *
	 * A mismatched daemon is refused rather than talked to: JSON ignores
	 * fields it does not know, so an older one does not reject a request it
	 * cannot honour -- it carries it out against the wrong thing. */
	info, err := c.Handshake()
	if err != nil {
		c.Close()
		return nil, err
	}
	if info.ProtocolVersion != ipc.ProtocolVersion {
		c.Close()
		return nil, fmt.Errorf(
			"timeshiftd speaks protocol %d, this client speaks %d.\n"+
				"Restart the service after upgrading: sudo systemctl restart timeshiftd",
			info.ProtocolVersion, ipc.ProtocolVersion)
	}
	return c, nil
}

// runCreate submits a snapshot and follows it.
func runCreate(socket string, p ipc.CreateParams, scripted bool) int {
	c, err := connect(socket)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	defer c.Close()

	var ref ipc.JobRef
	if err := c.Call(ipc.MethodSnapshotCreate, p, &ref); err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	if ref.Existing {
		fmt.Printf("A snapshot is already in progress (%s); watching that one.\n", ref.Job)
	}

	outcome, err := watchJob(c, ref.Job, os.Stdout, scripted)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	if outcome == jobs.OutcomeFailed {
		return 1
	}
	return 0
}

// runWatch attaches to a job, or to the one running now.
//
// This is the command that demonstrates what the daemon is for: run it while a
// snapshot started by apt-snapshot-guard is in flight and it picks the work up
// mid-stream.
func runWatch(socket, jobID string, scripted bool) int {
	c, err := connect(socket)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	defer c.Close()

	if jobID == "" {
		var info ipc.SystemInfo
		if err := c.Call(ipc.MethodSystemInfo, nil, &info); err != nil {
			fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
			return 1
		}
		if info.ActiveJob == "" {
			fmt.Println("Nothing is running.")
			return 0
		}
		jobID = info.ActiveJob
		fmt.Printf("Watching %s.\n", jobID)
	}

	outcome, err := watchJob(c, jobID, os.Stdout, scripted)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	if outcome == jobs.OutcomeFailed {
		return 1
	}
	return 0
}

// runDelete removes snapshots by name.
func runDelete(socket string, names []string, scripted bool) int {
	c, err := connect(socket)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	defer c.Close()

	var ref ipc.JobRef
	if err := c.Call(ipc.MethodSnapshotDelete, ipc.DeleteParams{Names: names}, &ref); err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	outcome, err := watchJob(c, ref.Job, os.Stdout, scripted)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	if outcome == jobs.OutcomeFailed {
		return 1
	}
	return 0
}

// runEstimate measures the system, which is also the progress denominator for
// the first backup.
func runEstimate(socket string, scripted bool) int {
	c, err := connect(socket)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	defer c.Close()

	var ref ipc.JobRef
	if err := c.Call(ipc.MethodEstimateRun, nil, &ref); err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	outcome, err := watchJob(c, ref.Job, os.Stdout, scripted)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	if outcome == jobs.OutcomeFailed {
		return 1
	}
	return 0
}

/* runCancel stops a running job.
 *
 * It exists because killing this client does NOT stop the work: a job belongs
 * to the daemon and deliberately outlives every client watching it, which is
 * what lets apt-snapshot-guard hand a snapshot off and lets a GUI window close
 * without abandoning it. The consequence is that a caller which gives up --
 * apt-snapshot-guard hitting its timeout, say -- leaves a snapshot still
 * running and still holding the repository write lock, with no way to say so.
 * This is that way.
 */
func runCancel(socket, jobID string) int {
	c, err := connect(socket)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	defer c.Close()

	/* No --job means "whatever is running now", which is what a caller
	 * cleaning up after itself almost always means. */
	if jobID == "" {
		var info ipc.SystemInfo
		if err := c.Call(ipc.MethodSystemInfo, nil, &info); err != nil {
			fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
			return 1
		}
		if info.ActiveJob == "" {
			fmt.Println("No job is running.")
			return 0
		}
		jobID = info.ActiveJob
	}

	if err := c.Call(ipc.MethodJobsCancel, ipc.JobRefParams{Job: jobID}, nil); err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	fmt.Printf("Cancelled %s.\n", jobID)
	return 0
}
