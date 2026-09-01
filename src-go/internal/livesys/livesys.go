/* Package livesys answers one question: is this machine booted from live media?
 *
 * It matters because the answer changes what Timeshift is allowed to do. A
 * live session's root filesystem is a squashfs plus a ramdisk -- it is not the
 * system anybody wants a backup of, and it disappears at the next power cycle.
 * Snapshotting it is never useful, and it is actively harmful: the snapshot
 * lands in the user's real repository, and the retention pass that follows
 * counts it towards a level's limit and can untag -- and so delete -- a real
 * snapshot to make room for it.
 *
 * The Vala core has always known this. `scheduled` at Main.vala:1281 reads
 *
 *     return !live_system() && (schedule_boot || schedule_hourly || ...)
 *
 * so the live check gates the whole scheduler, ahead of any config. Nothing in
 * the Go core knew it, which was survivable only for as long as the daemon ran
 * exclusively on installed systems. It does not: the recovery environment
 * boots `boot=casper`, enables timeshiftd.service, and carries a copy of the
 * user's real timeshift.json -- repository location, schedule and all.
 *
 * Restoring is deliberately still allowed. Restoring is the entire reason the
 * recovery environment exists, and it writes to the target rather than to the
 * repository. What is refused is anything that WRITES A SNAPSHOT.
 */
package livesys

import (
	"os"
	"strings"
)

// ProcCmdline is where the kernel publishes the boot command line.
const ProcCmdline = "/proc/cmdline"

/* Markers that mean "booted from live media".
 *
 * These are the two the Vala core tests for (Main.vala:1335) and they cover
 * what this project actually produces and runs on: casper is Ubuntu's live
 * boot -- and is what our own recovery environment uses, through both of its
 * payload mechanisms -- while boot=live is live-boot, the Debian equivalent.
 *
 * Deliberately a prefix-free substring test on the whole command line rather
 * than a parse into key=value pairs. `boot=casper` appears as its own word in
 * every form we emit, and a looser test that catches an unfamiliar variant is
 * the safer error here: a false positive costs a refused scheduled snapshot on
 * a machine that could have taken one, a false negative costs a junk snapshot
 * in a real repository plus whatever retention then deletes to make room.
 */
var markers = []string{"boot=casper", "boot=live"}

// Detector reports whether the machine is running from live media.
//
// The path is a field so a test can point it at a file it wrote, rather than
// this being a package-level function nothing can drive.
type Detector struct {
	// Path is the file to read. Empty means ProcCmdline.
	Path string
}

// Live reports whether this is a live session.
//
// An unreadable command line is reported as NOT live. That is the fail-open
// direction and it is the right one: /proc/cmdline is readable on every Linux
// this runs on, so a read error means something far stranger than a live boot
// is going on, and refusing every scheduled snapshot on a healthy machine
// because a file could not be read would be a worse failure than the one being
// guarded against.
func (d Detector) Live() bool {
	path := d.Path
	if path == "" {
		path = ProcCmdline
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	return IsLive(string(raw))
}

// IsLive reports whether a kernel command line describes a live boot.
func IsLive(cmdline string) bool {
	for _, m := range markers {
		if strings.Contains(cmdline, m) {
			return true
		}
	}
	return false
}

// Reason is the message to give a person when work is refused because this is
// a live session. It names the medium rather than the flag, because the person
// reading it did not choose the flag.
const Reason = "this is a live session (booted from removable media), " +
	"so there is no installed system to snapshot"
