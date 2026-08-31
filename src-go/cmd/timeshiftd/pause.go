package main

import (
	"os"
	"strconv"
	"strings"
	"time"
)

/* The pause setting.
 *
 * One config key, "pause_snapshots", holding one of two different things: a
 * unix timestamp to pause until, or the boot id to pause for. Which one it is
 * is decided by whether it parses as a number -- a boot id is a UUID, so it
 * never does.
 *
 * The boot form is the interesting half. Storing the CURRENT boot id and
 * comparing it against /proc/sys/kernel/random/boot_id means "paused until
 * reboot" needs nothing to clean it up: after a reboot the stored id no longer
 * matches, and the pause has expired on its own. A stored "paused: true" would
 * have needed something to remember to clear it, and that something would
 * eventually not run.
 *
 * The original honoured a pause only in scripted mode, so a GUI-initiated
 * snapshot ignored it. That is kept, and it is right: a pause is a statement
 * about automatic snapshots, not a refusal to work. Here it is enforced in the
 * ticker and nowhere else, which is the same rule expressed once instead of at
 * every call site.
 */

// pauseState reports whether automatic snapshots are suspended, and until when.
func (d *daemon) pauseState() (bool, string) {
	value := strings.TrimSpace(d.config().PauseSnapshots)
	if value == "" {
		return false, ""
	}

	if until, err := strconv.ParseInt(value, 10, 64); err == nil {
		if until <= 0 {
			return false, ""
		}
		deadline := time.Unix(until, 0)
		if time.Now().Before(deadline) {
			return true, "until " + deadline.Format("2006-01-02 15:04")
		}
		return false, ""
	}

	if value == currentBootID() {
		return true, "until the next reboot"
	}
	return false, ""
}

// currentBootID is the kernel's identifier for this boot, empty if unreadable.
func currentBootID() string {
	data, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}
