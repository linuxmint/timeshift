package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/makeafide/timeshift/src-go/internal/engines"
	"github.com/makeafide/timeshift/src-go/internal/ipc"
)

/* The commands the Vala CLI has that this one did not.
 *
 * Each is a thin client over a daemon method. That is the point of the port:
 * the CLI submits and watches, and nothing here knows how a snapshot is taken,
 * how a key is installed, or what a recovery environment is.
 */

// runDeleteAll removes every snapshot in the repository.
func runDeleteAll(socket string, ov *ipc.LocationOverride, scripted, yes bool) int {
	c, err := connect(socket)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	defer c.Close()

	var snapshots []engines.Snapshot
	if err := c.Call(ipc.MethodSnapshotsList, ipc.SnapshotsListParams{Location: ov}, &snapshots); err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	if len(snapshots) == 0 {
		fmt.Println("No snapshots found")
		return 0
	}

	names := make([]string, 0, len(snapshots))
	for _, s := range snapshots {
		names = append(names, s.Name)
	}

	/* Confirm by count, and name the location. "Delete all snapshots?" invites
	 * a yes; "Delete 12 snapshots from /dev/sdb1?" is a question about
	 * something specific, which is the one people actually read. */
	if !yes && !scripted {
		fmt.Printf("\nThis will delete %d snapshot(s), permanently.\n", len(names))
		for _, n := range names {
			fmt.Println("  " + n)
		}
		fmt.Print("\nType 'yes' to continue: ")
		answer, err := bufio.NewReader(os.Stdin).ReadString('\n')
		if err != nil || strings.TrimSpace(answer) != "yes" {
			fmt.Fprintln(os.Stderr, "\ntimeshift: cancelled")
			return 1
		}
	}

	return runDelete(socket, names, scripted)
}

/* runSetupSSHKey provisions key-based login, showing the host fingerprint
 * BEFORE any password is sent.
 *
 * The order is the security argument. Accepting the host key after typing a
 * password means the password has already gone to whoever answered.
 */
func runSetupSSHKey(socket string, ov *ipc.LocationOverride, password string, scripted, yes bool) int {
	c, err := connect(socket)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	defer c.Close()

	/* Without --snapshot-url, use the configured location.
	 *
	 * This used to call repo.status into a variable it then discarded, which
	 * could never have worked: ipc.RepoStatus carries no URL. So `url` stayed
	 * empty, hostOf("") returned "", and the whole fingerprint block below was
	 * skipped -- defeating, for the ordinary no-arguments case, the exact
	 * ordering this function's comment argues for. config.get returns the
	 * on-disk shape, where the URL actually lives.
	 */
	url := ov.URL
	if url == "" {
		var cfg struct {
			URL string `json:"backup_ssh_url"`
		}
		if err := c.Call(ipc.MethodConfigGet, nil, &cfg); err != nil {
			fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
			return 1
		}
		url = cfg.URL
		if url == "" {
			fmt.Fprintln(os.Stderr,
				"timeshift: no remote location is configured; pass --snapshot-url user@host:/path")
			return 1
		}
	}

	setup := ipc.SSHSetupKeyParams{URL: url, KeyFile: ov.KeyFile, Port: ov.Port, Password: password}

	/* Scan and confirm the host key BEFORE anything is sent.
	 *
	 * Asked every time, including for a host already in known_hosts. The
	 * comment here used to say it was skipped when the host was already
	 * trusted, which the code never did -- the scan result carries no such
	 * flag. Asking anyway is the better behaviour and worth keeping: this
	 * command is rare and idempotent, one keystroke is cheap, and a host key
	 * that has CHANGED since it was trusted is exactly the case worth
	 * catching. */
	if host := hostOf(url); host != "" {
		var scan ipc.SSHScanHostResult
		err := c.Call(ipc.MethodRepoSSHScanHost, ipc.SSHScanHostParams{Host: host, Port: ov.Port}, &scan)
		if err != nil {
			fmt.Fprintf(os.Stderr, "timeshift: could not read the host key: %v\n", err)
			return 1
		}
		fmt.Printf("\nHost key for %s:\n  %s\n", host, scan.Fingerprint)

		if !yes && !scripted {
			fmt.Print("\nDoes this match the host's own fingerprint? Type 'yes' to trust it: ")
			answer, err := bufio.NewReader(os.Stdin).ReadString('\n')
			if err != nil || strings.TrimSpace(answer) != "yes" {
				fmt.Fprintln(os.Stderr, "\ntimeshift: not trusted; nothing was sent")
				return 1
			}
		}
		setup.HostKeyLine = scan.Line
	}

	var res ipc.SSHSetupKeyResult
	if err := c.Call(ipc.MethodRepoSSHSetupKey, setup, &res); err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}

	switch {
	case res.AlreadyWorking:
		fmt.Println("Key-based login already works; nothing was changed.")
	case res.Verified:
		fmt.Printf("Key installed and verified (%s).\n", res.KeyFile)
	default:
		// Unreachable: the daemon refuses rather than returning unverified.
		fmt.Println("Key installed, but it could not be verified.")
		return 1
	}
	return 0
}

// hostOf extracts the host from user@host:/path, for the fingerprint prompt.
func hostOf(url string) string {
	if url == "" {
		return ""
	}
	rest := strings.TrimPrefix(url, "ssh://")
	if at := strings.LastIndex(rest, "@"); at >= 0 {
		rest = rest[at+1:]
	}
	if i := strings.IndexAny(rest, ":/"); i >= 0 {
		rest = rest[:i]
	}
	return rest
}

// runRecoveryStatus prints what the press-R environment looks like.
func runRecoveryStatus(socket string, w io.Writer) int {
	c, err := connect(socket)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	defer c.Close()

	var st ipc.RecoveryStatus
	if err := c.Call(ipc.MethodRecoveryStatus, nil, &st); err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	if !st.Available {
		fmt.Fprintln(w, "The timeshift-recovery package is not installed.")
		return 1
	}

	fmt.Fprintf(w, "%-11s %s\n", "installed:", yesNo(st.Installed))
	if st.Installed {
		fmt.Fprintf(w, "%-11s %s\n", "target:", st.Target)
		fmt.Fprintf(w, "%-11s %s\n", "env:", st.EnvVersion)
		fmt.Fprintf(w, "%-11s %s\n", "host:", st.HostVersion)
		fmt.Fprintf(w, "%-11s %s\n", "current:", yesNo(!st.Stale))
		fmt.Fprintf(w, "%-11s %s\n", "boot entry:", enabledDisabled(!st.Disabled))
	}
	if st.Stale {
		// The whole point of the environment is that it matches the system it
		// will be used to repair.
		return 1
	}
	return 0
}

func runRecoveryVerb(socket, method, verb string) int {
	c, err := connect(socket)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	defer c.Close()

	var res ipc.RecoveryVerbResult
	if err := c.Call(method, nil, &res); err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	fmt.Printf("Recovery environment %sd.\n", verb)
	return 0
}

// runRecoveryInstall builds the environment, which takes minutes, so it is a
// job and the CLI watches it like any other.
func runRecoveryInstall(socket, target, size string, scripted bool) int {
	c, err := connect(socket)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	defer c.Close()

	var ref ipc.JobRef
	if err := c.Call(ipc.MethodRecoveryInstall,
		ipc.RecoveryInstallParams{Target: target, Size: size}, &ref); err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}

	outcome, err := watchJob(c, ref.Job, os.Stdout, scripted)
	if err != nil {
		fmt.Fprintf(os.Stderr, "timeshift: %v\n", err)
		return 1
	}
	if outcome == "failed" {
		return 1
	}
	return 0
}

func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

func enabledDisabled(b bool) string {
	if b {
		return "enabled"
	}
	return "disabled"
}

// jsonOr renders a value compactly for a debug line.
func jsonOr(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return "?"
	}
	return string(b)
}

// overridePtr returns nil for an override that asks for nothing, so the wire
// carries no "location" key at all rather than an empty object.
func overridePtr(o ipc.LocationOverride) *ipc.LocationOverride {
	if o.Empty() {
		return nil
	}
	return &o
}
