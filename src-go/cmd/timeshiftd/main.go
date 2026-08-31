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
	"flag"
	"fmt"
	"os"

	"github.com/makeafide/timeshift/src-go/internal/config"
	"github.com/makeafide/timeshift/src-go/internal/logging"
)

// version is stamped by the build; see src-go/go-build.sh.
var version = "dev"

func main() {
	var (
		showVersion = flag.Bool("version", false, "print the version and exit")
		debug       = flag.Bool("debug", false, "log at debug level")
		configPath  = flag.String("config", config.SystemPath, "path to timeshift.json")
		checkConfig = flag.Bool("check-config", false,
			"parse the configuration, report it, and exit without starting the daemon")
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

	log.Info("timeshiftd starting",
		"version", version,
		"config", *configPath,
		"first_run", !found,
		"engine", cfg.Engine,
		"location", cfg.BackupLocationType,
		"scheduled", cfg.Scheduled())

	// The socket server, the job queue and the schedule ticker are the next
	// phases. Exiting cleanly here is deliberate: shipping a daemon that idles
	// while doing nothing would be worse than shipping one that says so.
	log.Error("the daemon loop is not implemented yet; run with --check-config")
	os.Exit(2)
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
  --debug           log at debug level
  --version         print the version and exit
`, version, config.SystemPath)
}
