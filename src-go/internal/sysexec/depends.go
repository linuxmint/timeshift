package sysexec

import (
	"fmt"
	"os/exec"
	"strings"
)

/* RequiredTools are the external commands the core cannot work without.
 *
 * The same list the Vala core checks at startup (Main.vala:463-490), and for
 * the same reason: every one of these is shelled out to somewhere in a backup
 * or a restore, and discovering that one is absent halfway through an
 * operation produces an error from inside rsync or a script rather than a
 * sentence naming the missing package.
 *
 * "crontab" was on the Vala list and is deliberately not here. The schedule
 * belongs to the daemon now, and the only thing left that reaches for cron is
 * the sweep that removes what older versions wrote -- which treats an absent
 * crontab as an empty one.
 */
var RequiredTools = []string{
	"rsync",
	"/sbin/blkid",
	"df",
	"mount",
	"umount",
	"fuser",
	"cp",
	"rm",
	"touch",
	"ln",
	"sync",
	"run-parts",
}

// MissingTools returns the entries of tools that cannot be found.
//
// An absolute path is tested as a path; a bare name is looked up on PATH, the
// way the shell would resolve it.
func MissingTools(tools []string) []string {
	var missing []string
	for _, t := range tools {
		if _, err := exec.LookPath(t); err != nil {
			missing = append(missing, t)
		}
	}
	return missing
}

/* CheckDependencies reports which required tools are absent.
 *
 * The error names all of them rather than stopping at the first, because
 * someone fixing this wants one apt install, not one per restart.
 */
func CheckDependencies() error {
	missing := MissingTools(RequiredTools)
	if len(missing) == 0 {
		return nil
	}
	return fmt.Errorf(
		"these commands are not available on this system: %s\n"+
			"install the packages that provide them and try again",
		strings.Join(missing, ", "))
}
