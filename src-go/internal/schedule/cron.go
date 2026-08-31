package schedule

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

/* Retiring cron.
 *
 * The original wrote /etc/cron.d/timeshift-hourly and, when boot snapshots were
 * on, /etc/cron.d/timeshift-boot. Older versions also left entries in root's
 * user crontab and a script in /etc/cron.hourly, which cron_job_update() swept
 * on every run.
 *
 * Those files must go, because leaving them means both schedulers fire. That is
 * not merely redundant: the cron entry starts a SECOND timeshift process, and
 * the whole point of this port is that there is one owner of the work.
 *
 * Only files this tool wrote are removed, identified by name and by content. A
 * /etc/cron.d/timeshift-hourly that does not mention timeshift is somebody
 * else's file with an unlucky name, and deleting it would be the kind of
 * silent damage that is very hard to trace back here.
 */

// LegacyCronFiles are the drop-ins previous versions installed.
var LegacyCronFiles = []string{
	"/etc/cron.d/timeshift-hourly",
	"/etc/cron.d/timeshift-boot",
	"/etc/cron.hourly/timeshift-hourly",
}

// RemoveLegacyCron deletes the cron drop-ins the Vala scheduler installed.
//
// root is prefixed to every path, for tests. It returns what it removed.
func RemoveLegacyCron(root string) (removed []string, err error) {
	for _, p := range LegacyCronFiles {
		full := filepath.Join(root, p)

		data, readErr := os.ReadFile(full)
		if readErr != nil {
			if os.IsNotExist(readErr) {
				continue
			}
			return removed, fmt.Errorf("read %s: %w", full, readErr)
		}

		if !looksLikeOurs(string(data)) {
			// Same name, not our file. Say so rather than deciding for the
			// administrator.
			return removed, fmt.Errorf(
				"%s exists but was not written by timeshift; remove it by hand if it is stale", full)
		}

		if rmErr := os.Remove(full); rmErr != nil {
			return removed, fmt.Errorf("remove %s: %w", full, rmErr)
		}
		removed = append(removed, p)
	}
	return removed, nil
}

// looksLikeOurs reports whether the drop-in invokes timeshift.
func looksLikeOurs(text string) bool {
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		for _, marker := range []string{
			"timeshift --check", "timeshift --create",
			"timeshift --backup", "timeshift-btrfs --backup",
		} {
			if strings.Contains(line, marker) {
				return true
			}
		}
	}
	return false
}
