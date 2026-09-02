// Command timeshiftd is the Timeshift core daemon.
//
// It owns the configuration, the discovered system state and the job queue, and
// serves them over a unix socket so any number of clients -- the GTK GUI, the
// CLI, apt-snapshot-guard -- can attach to a running operation instead of being
// refused by a single-instance lock.
//
// The socket and the job engine land in later phases. What works today is
// configuration handling, which is enough to prove the packaging and the
// on-disk compatibility.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/config"
	"github.com/makeafide/timeshift/src-go/internal/ipc"
	"github.com/makeafide/timeshift/src-go/internal/livesys"
	"github.com/makeafide/timeshift/src-go/internal/logging"
	"github.com/makeafide/timeshift/src-go/internal/replock"
	"github.com/makeafide/timeshift/src-go/internal/rundir"
	"github.com/makeafide/timeshift/src-go/internal/schedule"
	"github.com/makeafide/timeshift/src-go/internal/sysexec"

	// Registers the engine every existing installation is using. Which engines
	// exist is decided by this import list and nothing else.
	_ "github.com/makeafide/timeshift/src-go/internal/engines/timeshift"
)

// version is stamped by the build; see src-go/go-build.sh.
var version = "dev"

func main() {
	var (
		showVersion = flag.Bool("version", false, "print the version and exit")
		debug       = flag.Bool("debug", false, "log at debug level")
		configPath  = flag.String("config", config.SystemPath, "path to timeshift.json")
		socketPath  = flag.String("socket", ipc.SocketPath, "unix socket to listen on")
		lockPath    = flag.String("lock", replock.DefaultPath,
			"repository write lock, shared with the Vala core")
		checkConfig = flag.Bool("check-config", false,
			"parse the configuration, report it, and exit without starting the daemon")
		noSchedule = flag.Bool("no-schedule", false,
			"serve requests but do not run the scheduler")
		interval = flag.Duration("schedule-interval", schedule.DefaultInterval,
			"how often to check whether a scheduled snapshot is due")
		/* -1, not 0, for "not given". Zero is a delay someone may legitimately
		 * ask for -- it is what you want when starting the daemon by hand to
		 * see what it decides -- and a sentinel of 0 makes that unrequestable. */
		startupDelay = flag.Duration("startup-delay", -1,
			"hold the first scheduled check back after starting (default: from the configuration)")
	)
	flag.Usage = usage
	flag.Parse()

	if *showVersion {
		fmt.Printf("timeshiftd %s\n", version)
		return
	}

	session, err := logging.Open(logging.Options{Mode: "daemon", Debug: *debug})
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshiftd: %v\n", err)
		os.Exit(1)
	}
	defer session.Close()
	log := session.Logger

	if removed, err := logging.CleanOld(""); err != nil {
		log.Warn("could not prune old session logs", "err", err)
	} else if removed > 0 {
		log.Debug("pruned old session logs", "removed", removed)
	}

	cfg, found, err := config.Load(*configPath)
	if err != nil {
		log.Error("could not read configuration", "path", *configPath, "err", err)
		os.Exit(1)
	}

	if *checkConfig {
		reportConfig(*configPath, found, cfg)
		return
	}

	/* Root only. Every operation reads and writes the whole filesystem, mounts
	 * devices and runs rsync as root; refusing early is clearer than failing
	 * later with a permission error from somewhere deep in a transfer. */
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "timeshiftd needs superuser (root) privileges to run")
		os.Exit(1)
	}

	log.Info("timeshiftd starting",
		"version", version,
		"config", *configPath,
		"first_run", !found,
		"engine", cfg.Engine,
		"location", cfg.BackupLocationType,
		"scheduled", cfg.Scheduled())

	d := newDaemon(log, *configPath, cfg)
	defer d.queue.Close()

	/* Serialise repository writes against the OTHER Timeshift.
	 *
	 * The queue's single worker already orders this daemon's own jobs. It
	 * cannot see the Vala core, which still performs its own creates, deletes
	 * and restores while both are installed -- so without this a scheduled
	 * backup and a GUI-driven one run into the same repository at once. The
	 * Vala side takes the same flock in src/Utility/RepoLock.vala. */
	d.queue.SetWriteLock(writeLock{path: *lockPath, log: log})

	/* Retire cron before doing anything else.
	 *
	 * Leaving the drop-ins in place means both schedulers fire, and the cron
	 * one starts a second timeshift process -- exactly the collision this port
	 * exists to remove. postinst does this too; doing it here as well covers
	 * the case that matters during the transition, where the Vala GUI is still
	 * installed and rewrites the drop-in whenever its settings window closes.
	 *
	 * A failure here is reported and not fatal: refusing to start the daemon
	 * because of a stale cron file would leave the machine with no scheduler at
	 * all, which is worse than having two. */
	/* Say up front which required tools are missing.
	 *
	 * A WARNING rather than a refusal to start, which is where this differs
	 * from the Vala core's check (Main.vala:463). A CLI that exits has nothing
	 * to lose by refusing; a daemon that refuses to start takes the scheduler
	 * with it, so a machine missing `fuser` would silently stop taking
	 * snapshots altogether rather than losing the one operation that needs it.
	 * The individual jobs still fail with their own errors -- this exists so
	 * the reason is in the log before anything goes wrong, not to gate work. */
	if err := sysexec.CheckDependencies(); err != nil {
		log.Warn("some required commands are missing", "err", err)
	}

	if removed, err := schedule.RemoveLegacyCron("/"); err != nil {
		log.Warn("could not remove the legacy cron entries", "err", err)
	} else if len(removed) > 0 {
		log.Info("removed the legacy cron entries; the daemon owns the schedule now",
			"files", removed)
	}

	/* And the entries older versions put in root's own crontab, which the
	 * drop-in sweep above does not reach. cron_job_update() in the GUI swept
	 * both; this is the half that had no Go equivalent. */
	if n, err := schedule.RemoveLegacyCrontabEntries(d.runner); err != nil {
		log.Warn("could not remove the legacy crontab entries", "err", err)
	} else if n > 0 {
		log.Info("removed legacy timeshift lines from root's crontab", "lines", n)
	}

	/* Clear up after runs that were killed, BEFORE listening.
	 *
	 * A daemon that died mid-restore left its target mounted under
	 * /run/timeshift/<pid>/restore. systemd restarts us with a new pid, so
	 * nobody believes they own the old mounts and they stay for the life of
	 * the boot, keeping the filesystem busy. This is also where a killed ssh
	 * ControlMaster's socket goes.
	 *
	 * Only numeric-pid subdirectories are touched. daemon.sock and repo.lock
	 * live in the very directory being swept. */
	reaper := &rundir.Reaper{Runner: d.runner}
	if rep := reaper.Reap(context.Background()); !rep.Empty() {
		log.Info("cleared up after runs that did not exit cleanly",
			"unmounted", rep.Unmounted, "removed", rep.Removed,
			"kept", rep.Kept, "problems", rep.Problems)
	}

	/* The group is created by debian/postinst. A missing one is not an error:
	 * it means root-only access, which is a valid configuration and the one in
	 * place before the package has ever been installed. */
	groupGID := ipc.LookupGroupGID(ipc.Group)
	if groupGID < 0 {
		log.Info("no timeshift group; the socket will be root-only", "group", ipc.Group)
	}

	server := &ipc.Server{
		Path:     *socketPath,
		GroupGID: groupGID,
		Methods:  d.methods(),
		Queue:    d.queue,
		Log:      log,
	}
	if err := server.Listen(); err != nil {
		log.Error("could not listen", "err", err)
		os.Exit(1)
	}

	go func() {
		if err := server.Serve(); err != nil {
			log.Error("serve failed", "err", err)
		}
	}()

	ctx, stopScheduler := context.WithCancel(context.Background())
	defer stopScheduler()

	/* Keep sweeping. The startup pass covers our own crash; this one covers
	 * every other Timeshift that gets killed while we stay up, which for a
	 * daemon measured in months is the case that actually accumulates. Slow on
	 * purpose -- there is nothing to race, since only directories whose
	 * process is already gone are ever touched. */
	go func() {
		t := time.NewTicker(15 * time.Minute)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				if rep := reaper.Reap(ctx); !rep.Empty() {
					log.Info("cleared up after runs that did not exit cleanly",
						"unmounted", rep.Unmounted, "removed", rep.Removed,
						"kept", rep.Kept, "problems", rep.Problems)
				}
			}
		}
	}()

	/* No scheduler on live media.
	 *
	 * This is the direct mirror of the Vala core's `scheduled` property
	 * (Main.vala:1281), which reads `!live_system() && (...)` so the live check
	 * gates the whole schedule ahead of any config. The recovery environment
	 * boots boot=casper, enables this unit, and carries a copy of the user's
	 * real timeshift.json -- repository location and schedule included -- so
	 * without this the rescue environment would snapshot its own ramdisk into
	 * the repository the user is trying to restore FROM, and the retention
	 * pass that follows would count it towards a level's limit.
	 *
	 * schedule.status still reports Enabled from the config plus Live, so a
	 * client can say why nothing is scheduled rather than showing the alarming
	 * "enabled but not running" that a dead scheduler produces. */
	switch {
	case d.live:
		log.Info("scheduler not started: this is a live session", "reason", livesys.Reason)
	case !*noSchedule:
		delay := *startupDelay
		if delay < 0 {
			delay = time.Duration(cfg.StartupDelayIntervalMins) * time.Minute
		}
		d.ticker = &schedule.Ticker{
			Interval:     *interval,
			StartupDelay: delay,
			Enabled: func() bool {
				c := d.config()
				return c.Scheduled()
			},
			Paused: d.pauseState,
			Check:  d.scheduledCheck,
			Log:    log,
		}
		go d.ticker.Run(ctx)
		log.Info("scheduler started", "interval", *interval, "startup_delay", delay)
	default:
		log.Info("scheduler disabled by --no-schedule")
	}

	sdNotify("READY=1\nSTATUS=Waiting for work")

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	sig := <-stop

	/* Shut the door before finishing the work: no new client can connect, but
	 * a snapshot already running is left to complete. Killing a transfer half
	 * way through leaves a partial snapshot directory, which is the worst thing
	 * to leave behind. */
	log.Info("shutting down", "signal", sig.String())
	sdNotify("STOPPING=1\nSTATUS=Finishing the running job")
	stopScheduler()
	server.Close()

	if active := d.queue.Active(); active != nil {
		log.Info("waiting for the running job to finish", "job", active.ID, "kind", active.Kind)
		for !active.State().Terminal() {
			time.Sleep(200 * time.Millisecond)
		}
	}
}

func reportConfig(path string, found bool, c config.Config) {
	if !found {
		fmt.Printf("config:   %s (absent -- these are the first-run defaults)\n", path)
	} else {
		fmt.Printf("config:   %s\n", path)
	}
	fmt.Printf("engine:   %s\n", c.Engine)
	fmt.Printf("location: %s\n", c.BackupLocationType)
	if c.Remote() {
		fmt.Printf("remote:   %s\n", c.BackupSSHURL)
		if c.BackupSSHKey != "" {
			fmt.Printf("ssh key:  %s\n", c.BackupSSHKey)
		}
		if c.BackupSSHPort != 0 {
			fmt.Printf("ssh port: %d\n", c.BackupSSHPort)
		}
	} else if c.BackupDeviceUUID != "" {
		fmt.Printf("device:   UUID=%s\n", c.BackupDeviceUUID)
	}
	fmt.Printf("mode:     %s\n", modeName(c.BtrfsMode))
	fmt.Printf("schedule: %s\n", scheduleSummary(c))
	fmt.Printf("retain:   monthly %d, weekly %d, daily %d, hourly %d, boot %d\n",
		c.CountMonthly, c.CountWeekly, c.CountDaily, c.CountHourly, c.CountBoot)
	fmt.Printf("excludes: %d user pattern(s), %d app(s)\n", len(c.Exclude), len(c.ExcludeApps))
	if c.PauseSnapshots != "" {
		fmt.Printf("paused:   %s\n", c.PauseSnapshots)
	}
}

func modeName(btrfs bool) string {
	if btrfs {
		return "btrfs"
	}
	return "rsync"
}

func scheduleSummary(c config.Config) string {
	if !c.Scheduled() {
		return "disabled"
	}
	levels := []struct {
		on   bool
		name string
	}{
		{c.ScheduleMonthly, "monthly"},
		{c.ScheduleWeekly, "weekly"},
		{c.ScheduleDaily, "daily"},
		{c.ScheduleHourly, "hourly"},
		{c.ScheduleBoot, "boot"},
	}
	out := ""
	for _, l := range levels {
		if !l.on {
			continue
		}
		if out != "" {
			out += ", "
		}
		out += l.name
	}
	return out
}

func usage() {
	fmt.Fprintf(os.Stderr, `timeshiftd %s -- the Timeshift core daemon

Usage: timeshiftd [options]

Options:
  --check-config    parse the configuration, report it, and exit
  --config PATH     path to timeshift.json (default %s)
  --socket PATH     unix socket to listen on (default %s)
  --no-schedule     serve requests but do not run the scheduler
  --schedule-interval D
                    how often to check whether a snapshot is due (default %s)
  --startup-delay D hold the first check back after starting
  --debug           log at debug level
  --version         print the version and exit
`, version, config.SystemPath, ipc.SocketPath, schedule.DefaultInterval)
}
