package restore

import (
	"fmt"
	"strings"

	"github.com/makeafide/timeshift/src-go/internal/fsutil"
)

/* The transfer script.
 *
 * This is the one place in the port that still generates shell, and for a
 * reason that has not gone away: the script runs to completion while the system
 * it is rewriting is being replaced underneath it, and on a current-system
 * restore it ends by rebooting. A Go program driving that would be replacing
 * its own binary mid-run.
 *
 * The rsync flags are NOT interchangeable with the backup's:
 *
 *   -aiir   the second -i itemises unchanged files, and -r is what makes the
 *           line count track the file count -- the progress denominator is a
 *           line count from the dry run of this same script
 *   -X      extended attributes. rsync's archive mode is "-rlptgoD (no
 *           -A,-X,-U,-N,-H)", so without this every security.capability is
 *           silently dropped: /usr/lib/snapd/snap-confine carries ten file
 *           capabilities and a copy without them fails with "snap-confine is
 *           packaged without necessary permissions", breaking EVERY snap. ping
 *           and mtr-packet lose cap_net_raw the same way.
 *   -H      hard links, also omitted by archive mode. Without it 138 paths in
 *           /usr/bin and /usr/lib alone stop sharing inodes.
 *   --delete-before, not --delete-after: space on the target is freed before
 *           the new copy needs it.
 */

// SyncScriptOptions describe the transfer half of a restore.
type SyncScriptOptions struct {
	// Source is the snapshot payload, with a host prefix for a remote
	// repository.
	Source string

	// Target is where files are written: "/" for the running system, otherwise
	// the mount point, with a trailing slash.
	Target string

	// LogFile and ExcludeFile are opened by rsync on the CLIENT side, so both
	// are local paths even when the source is remote.
	LogFile     string
	ExcludeFile string

	// FailedFlag is the sentinel touched when the transfer aborts. It is the
	// only signal the console path has, because its script wrapper always
	// reports success.
	FailedFlag string

	// DryRun compares without writing, and is how the progress denominator for
	// the real run is measured.
	DryRun bool

	// CurrentSystem means the target is the running system, which changes the
	// banner and adds the reboot at the end of the finish script.
	CurrentSystem bool

	// Remote marks a source on another host.
	Remote bool

	// RSH is the -e command, RsyncPath the --rsync-path, for a remote source.
	RSH       string
	RsyncPath string

	// ReachabilityCommand probes whether the remote is back, and DropMaster
	// drops the shared ssh connection before probing. Both are emitted INTO the
	// script: the retry loop runs in the generated shell, long after this
	// function has returned.
	ReachabilityCommand string
	DropMasterCommand   string
}

// SyncPhases are the steps the transfer script announces, in order.
func SyncPhases(dryRun bool) []Phase {
	compare := "Restoring files"
	if dryRun {
		compare = "Comparing files"
	}
	phases := []Phase{
		{Key: "prepare", Title: "Preparing"},
		{Key: "sync_files", Title: compare},
	}
	if !dryRun {
		phases = append(phases, Phase{Key: "flush", Title: "Flushing writes to disk"})
	}
	return phases
}

// BuildSyncScript generates the transfer script.
func BuildSyncScript(o SyncScriptOptions) string {
	var b strings.Builder

	b.WriteString("echo ''\n")
	if o.CurrentSystem {
		b.WriteString("echo 'Please do not interrupt the restore process!'\n")
		b.WriteString("echo 'System will reboot after files are restored'\n")
	}
	b.WriteString("echo ''\n")

	b.WriteString(phaseMarker("prepare"))
	b.WriteString("sleep 3s\n")

	b.WriteString(phaseMarker("sync_files"))

	/* A shell FUNCTION, not a variable. The command embeds single-quoted paths
	 * and an -e '...' option; re-expanding that from a string would need eval
	 * and would mangle any path containing a space. */
	b.WriteString("ts_run_rsync() {\n")
	b.WriteString("rsync -aiirXH --force --delete --delete-before")

	if o.DryRun {
		b.WriteString(" --dry-run")
	} else {
		/* --partial-dir, not bare --partial: --partial leaves a TRUNCATED file
		 * at its real path, which on a system restore is precisely the
		 * corruption this exists to prevent. */
		b.WriteString(" --partial-dir=.timeshift-partial")
	}
	// Catches a connection that has hung rather than dropped; ssh's
	// ServerAlive* only catches a link that is actually dead.
	b.WriteString(" --timeout=120")

	if o.Remote {
		// Numeric ids are required across the SSH boundary, and --fake-super
		// has to be repeated on the source side so stored ownership is
		// expanded again.
		b.WriteString(" --numeric-ids")
		fmt.Fprintf(&b, " -e %s", fsutil.ShellQuote(o.RSH))
		if o.RsyncPath != "" {
			fmt.Fprintf(&b, " --rsync-path=%s", fsutil.ShellQuote(o.RsyncPath))
		}
	}

	fmt.Fprintf(&b, " --log-file=%s", fsutil.ShellQuote(o.LogFile))
	fmt.Fprintf(&b, " --exclude-from=%s", fsutil.ShellQuote(o.ExcludeFile))
	fmt.Fprintf(&b, " %s %s\n}\n", fsutil.ShellQuote(o.Source), fsutil.ShellQuote(o.Target))

	b.WriteString(retryBlock(o))

	if o.DryRun {
		// A dry run stops here: there is nothing to flush and nothing to fix.
		return b.String()
	}

	b.WriteString(phaseMarker("flush"))
	b.WriteString("sync \n")

	return b.String()
}

// retryBlock wraps the transfer in the reconnect loop.
func retryBlock(o SyncScriptOptions) string {
	var b strings.Builder

	b.WriteString("ts_attempt=0\n")
	b.WriteString("while :; do\n")
	b.WriteString("  ts_attempt=$((ts_attempt + 1))\n")
	b.WriteString("  ts_run_rsync\n")
	b.WriteString("  ts_rc=$?\n")
	b.WriteString("  case $ts_rc in\n")
	b.WriteString("    0|24) break ;;\n")

	/* 23 is "some files could not be transferred", the rest succeeded. Almost
	 * always a permission or special-file problem, which retrying cannot fix --
	 * and each retry would re-scan the entire tree. So: warn, and carry on to
	 * the finish steps. */
	b.WriteString("    23)\n")
	fmt.Fprintf(&b, "      echo '%s'\n", WarningsMarker)
	b.WriteString("      break\n")
	b.WriteString("      ;;\n")

	b.WriteString("    10|12|30|35|255)\n")
	fmt.Fprintf(&b, "      echo '%s'\"$ts_attempt:$ts_rc\"\n", ReconnectMarker)
	b.WriteString("      echo \"Connection lost (rsync exit $ts_rc). Waiting for the snapshot location...\"\n")
	b.WriteString("      echo 'The transfer resumes where it stopped; nothing already copied is lost.'\n")

	/* Drop the shared ssh connection before probing. The master that carried
	 * the dead transfer is still resident, and every later ssh -- including the
	 * probe below -- would attach to it over its unix socket, where
	 * ConnectTimeout does not apply. That is an indefinite block, not a retry. */
	if o.DropMasterCommand != "" {
		fmt.Fprintf(&b, "      %s\n", o.DropMasterCommand)
	}

	if o.ReachabilityCommand != "" {
		// Wait for the host to answer rather than burning attempts against a
		// link that is still down. Capped per round so a permanently dead host
		// still cycles and keeps the UI informed.
		b.WriteString("      ts_wait=0\n")
		b.WriteString("      while [ $ts_wait -lt 60 ]; do\n")
		fmt.Fprintf(&b, "        if %s >/dev/null 2>&1; then break; fi\n", o.ReachabilityCommand)
		b.WriteString("        ts_wait=$((ts_wait + 1))\n")
		b.WriteString("        sleep 5\n")
		b.WriteString("      done\n")
	} else {
		b.WriteString("      sleep 5\n")
	}

	b.WriteString("      echo 'Retrying...'\n")
	// Re-announce the phase so the reconnect banner clears.
	b.WriteString("      ")
	b.WriteString(phaseMarker("sync_files"))
	b.WriteString("      ;;\n")

	b.WriteString("    *)\n")
	fmt.Fprintf(&b, "      echo '%s'$ts_rc\n", FailedMarker)
	b.WriteString("      echo 'The target is INCOMPLETE and must not be booted. Re-run the restore.'\n")
	fmt.Fprintf(&b, "      touch %s\n", fsutil.ShellQuote(o.FailedFlag))
	b.WriteString("      exit 1\n")
	b.WriteString("      ;;\n")
	b.WriteString("  esac\n")
	b.WriteString("done\n")

	return b.String()
}

func phaseMarker(key string) string {
	return fmt.Sprintf("echo '%s%s'\n", PhaseMarker, key)
}

/* The source-readability probe.
 *
 * Runs BEFORE the transfer and is fail-closed. Requiring at least two entries
 * is the point: an empty or unreadable snapshot directory would otherwise be
 * copied over the target with --delete, erasing the system it was meant to
 * restore. One entry is not enough because a bare "." always lists.
 */
func SourceProbeScript(source, rsh string, remote bool) string {
	var b strings.Builder
	b.WriteString("ts_entries=$(rsync --list-only")
	if remote {
		fmt.Fprintf(&b, " -e %s", fsutil.ShellQuote(rsh))
	}
	fmt.Fprintf(&b, " %s 2>/dev/null | wc -l)\n", fsutil.ShellQuote(source))
	b.WriteString("if [ \"$ts_entries\" -ge 2 ]; then\n")
	fmt.Fprintf(&b, "  echo '%s'\n", SourceOKMarker)
	b.WriteString("fi\n")
	return b.String()
}
