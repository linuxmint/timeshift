package rsyncx

import (
	"strings"
)

// Options describe one rsync invocation.
type Options struct {
	Source string
	Dest   string

	// DeleteExtra passes --delete: remove anything in the destination that is
	// not in the source.
	DeleteExtra bool

	// DeleteExcluded also removes destination files that the exclude rules
	// match. Only meaningful alongside ExcludeFrom.
	DeleteExcluded bool

	// DryRun changes nothing and is how the progress denominator is measured.
	DryRun bool

	// Verbose lists every file. Progress is a LINE count, so this is not a
	// cosmetic choice: without it there is almost nothing to count.
	Verbose bool

	// LinkFrom is --link-dest: files identical to this tree are hard-linked
	// rather than copied, which is what makes an incremental snapshot cheap.
	//
	// rsync resolves it on the RECEIVING side, so for a remote destination this
	// is a plain repository path with NO host: prefix. Verified against a live
	// sshd; getting it wrong silently copies everything.
	LinkFrom string

	// LogFile and ExcludeFrom are opened by rsync on the CLIENT side. For a
	// remote destination they must therefore be local paths -- pointing either
	// inside a remote snapshot makes rsync warn, ignore it, and still exit 0.
	LogFile     string
	ExcludeFrom string

	// RSH is the -e command for a remote transfer.
	RSH string

	// RsyncPath is --rsync-path, used to pass --fake-super to the remote side
	// when the account there is not root.
	RsyncPath string

	// Remote marks a transfer over the network, which adds the resume and
	// timeout options.
	Remote bool
}

/* The flag set.
 *
 * -a  archive: recurse, preserve everything it can
 * -ii itemise, twice: the second -i reports unchanged files too, which is what
 *     makes the line count track the FILE count rather than only the changes
 * -X  extended attributes. Load-bearing: without it snap-confine loses its
 *     security.capability and every snap silently stops working after a restore
 * -H  hard links, preserved within one transfer
 *
 * Changing any of these changes how many lines a transfer emits, and the
 * progress denominator is a line count measured by a separate dry run. The
 * restore script's rsync carries the same flags for the same reason.
 */
func baseFlags() []string { return []string{"-aiiXH", "--recursive"} }

// Args builds the argv.
func (o Options) Args() []string {
	args := baseFlags()

	if o.Verbose {
		args = append(args, "--verbose")
	} else {
		args = append(args, "--quiet")
	}

	if o.DeleteExtra {
		args = append(args, "--delete")
	}
	args = append(args, "--delete-after", "--force")

	if o.RSH != "" {
		/* --numeric-ids whenever a transfer crosses hosts. Without it rsync
		 * maps uid and gid BY NAME, so a restored system gets whatever those
		 * names resolve to on the backup host -- which is not the same machine
		 * and need not have the same accounts. */
		args = append(args, "-e", o.RSH, "--numeric-ids")
	}
	if o.RsyncPath != "" {
		args = append(args, "--rsync-path="+o.RsyncPath)
	}

	if o.Remote {
		if !o.DryRun {
			// Resume a partial file rather than starting it again, and keep the
			// partial out of the snapshot tree itself.
			args = append(args, "--partial-dir=.timeshift-partial")
		}
		// A dead link otherwise hangs the transfer indefinitely.
		args = append(args, "--timeout=120")
	}

	args = append(args, "--stats", "--sparse")

	if o.DeleteExcluded {
		args = append(args, "--delete-excluded")
	}
	if o.DryRun {
		args = append(args, "--dry-run")
	}
	if o.LinkFrom != "" {
		args = append(args, "--link-dest="+withSlash(o.LinkFrom))
	}
	if o.LogFile != "" {
		args = append(args, "--log-file="+o.LogFile)
	}
	if o.ExcludeFrom != "" {
		args = append(args, "--exclude-from="+o.ExcludeFrom)
	}

	// Trailing slashes: "copy the CONTENTS of source into dest", not "copy the
	// source directory into dest". Without them every snapshot would nest one
	// directory deeper than the last.
	args = append(args, withSlash(o.Source), withSlash(o.Dest))
	return args
}

// Command is the full argv including the program name.
func (o Options) Command() []string {
	return append([]string{"rsync"}, o.Args()...)
}

func withSlash(p string) string {
	if p == "" || strings.HasSuffix(p, "/") {
		return p
	}
	return p + "/"
}

/* rsync exit codes this tree treats specially.
 *
 * 0 and 24 are success: 24 means files vanished during the transfer, which is
 * normal when copying a running system -- temp files and sockets come and go.
 *
 * 23 is a partial transfer, reported as warnings rather than failure: some
 * files could not be read, which again is routine on a live filesystem.
 *
 * 10, 12, 30, 35 and 255 are the transport failing. For a remote transfer they
 * are retried rather than treated as an error, because a home broadband link
 * dropping for thirty seconds should not lose an hour of copying.
 */
const (
	ExitOK            = 0
	ExitPartial       = 23
	ExitVanishedFiles = 24
)

var transportExitCodes = map[int]bool{10: true, 12: true, 30: true, 35: true, 255: true}

// Succeeded reports whether an exit code means the transfer completed.
func Succeeded(code int) bool { return code == ExitOK || code == ExitVanishedFiles }

// Warned reports a partial transfer: finished, but not everything arrived.
func Warned(code int) bool { return code == ExitPartial }

// TransportFailure reports a code worth retrying on a remote transfer.
func TransportFailure(code int) bool { return transportExitCodes[code] }

// ExitMeaning renders an rsync exit code for a person, matching
// Main.rsync_exit_meaning().
func ExitMeaning(code int) string {
	switch code {
	case 1:
		return "syntax or usage error"
	case 2:
		return "protocol incompatibility"
	case 3:
		return "errors selecting input/output files or directories"
	case 5:
		return "error starting client-server protocol"
	case 11:
		return "error in file I/O"
	case 23:
		return "some files could not be transferred"
	case 24:
		return "some files vanished before they could be transferred"
	case 10, 12, 30, 35, 255:
		return "connection lost"
	default:
		return "rsync exited with code " + itoa(code)
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	if neg {
		return "-" + string(b)
	}
	return string(b)
}
