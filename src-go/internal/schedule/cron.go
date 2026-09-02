package schedule

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

/* CommandRunner is the subset of sysexec this package needs.
 *
 * Declared here rather than imported so the sweep can be tested without a
 * process: the crontab of the machine running the tests is not a fixture. */
type CommandRunner interface {
	Run(ctx context.Context, argv []string, stdin string) (int, string, string, error)
}

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

/* RemoveLegacyCrontabEntries strips the scheduler lines older versions put in
 * root's own crontab.
 *
 * The drop-in files above are only half of what cron_job_update() swept.
 * Versions before the drop-ins existed wrote "timeshift --backup" and
 * "timeshift-btrfs --backup" straight into root's user crontab, and a machine
 * upgraded far enough forward still carries them. Leaving them means both
 * schedulers fire, and the cron one starts a SECOND timeshift process --
 * exactly the collision this port exists to remove.
 *
 * Three rules, and they are the same ones that govern the files:
 *
 *   - Only OUR lines go. A line is ours when it invokes timeshift AND asks for
 *     a backup; anything else in root's crontab is somebody's own work and
 *     deleting it would be silent damage that is very hard to trace back here.
 *   - The remainder is written back whole. Never `crontab -r` when lines
 *     survive: that would remove everything else root had scheduled.
 *   - No crontab, or no cron at all, is success with nothing to do. A machine
 *     without cron installed is the normal case now, not an error.
 */
func RemoveLegacyCrontabEntries(run CommandRunner) (removed int, err error) {
	code, out, _, err := run.Run(context.Background(), []string{"crontab", "-l"}, "")
	if err != nil {
		// crontab is not installed. Nothing wrote these, nothing to sweep.
		return 0, nil
	}
	if code != 0 {
		// "no crontab for root" also exits non-zero, and is the common case.
		return 0, nil
	}

	var keep []string
	for _, line := range strings.Split(out, "\n") {
		if isLegacyBackupLine(line) {
			removed++
			continue
		}
		keep = append(keep, line)
	}
	if removed == 0 {
		return 0, nil
	}

	body := strings.Join(keep, "\n")
	if strings.TrimSpace(body) == "" {
		/* Nothing of anyone else's is left, so the crontab goes entirely.
		 * Writing an empty one through `crontab -` is rejected by some
		 * implementations. */
		if code, _, stderr, err := run.Run(context.Background(), []string{"crontab", "-r"}, ""); err != nil || code != 0 {
			return removed, fmt.Errorf("crontab -r: %s", strings.TrimSpace(stderr))
		}
		return removed, nil
	}

	if !strings.HasSuffix(body, "\n") {
		body += "\n"
	}
	if code, _, stderr, err := run.Run(context.Background(), []string{"crontab", "-"}, body); err != nil || code != 0 {
		return removed, fmt.Errorf("crontab -: %s", strings.TrimSpace(stderr))
	}
	return removed, nil
}

// isLegacyBackupLine reports a crontab line this tool wrote.
//
// Both halves are required. "timeshift" alone would match a comment or
// somebody's own wrapper; "--backup" alone would match another program's flag.
func isLegacyBackupLine(line string) bool {
	trimmed := strings.TrimSpace(line)
	if trimmed == "" || strings.HasPrefix(trimmed, "#") {
		return false
	}
	return strings.Contains(trimmed, "timeshift") && strings.Contains(trimmed, "--backup")
}
