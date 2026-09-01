package timeshift

import (
	"context"
	"fmt"
	"os"
	"path"
	"strconv"
	"strings"
)

/* Setting up key-based login to a remote repository.
 *
 * Timeshift keeps its own key in /etc/timeshift/ssh rather than using the
 * invoking user's: the daemon runs as root, unattended, and a key in someone's
 * home directory is not reachable from a cron-equivalent context, may be
 * passphrase-protected, and would give Timeshift whatever else that key opens.
 *
 * The flow is deliberately four steps, not one:
 *
 *   1. scan the host key, so a fingerprint can be shown BEFORE any password is
 *      sent -- otherwise the first connection is trust-on-first-use with a
 *      password attached;
 *   2. generate the key if there is none;
 *   3. install it with ssh-copy-id;
 *   4. VERIFY it authenticates.
 *
 * Step 4 is not belt-and-braces. ssh-copy-id exits 0 even when the password was
 * wrong and nothing was installed, so its status alone cannot be trusted to
 * mean success.
 */

// EnsureKeyDir creates /etc/timeshift/ssh with the permissions ssh insists on.
func EnsureKeyDir() error {
	if err := os.MkdirAll(KeyDir, 0o700); err != nil {
		return fmt.Errorf("timeshift: %w", err)
	}
	// ssh refuses to use a key whose directory is group- or world-writable.
	return os.Chmod(KeyDir, 0o700)
}

/* KeyMarker identifies keys this machine installed.
 *
 * Hostnames are not unique -- "raspberrypi", "ubuntu" and "localhost" are the
 * default on very many machines -- so keying on one would let two hosts sharing
 * a name delete each other's entries from a shared repository's
 * authorized_keys. The machine-id is stable and unique; the hostname is kept
 * only as a human-readable hint.
 */
func KeyMarker() string {
	host, err := os.Hostname()
	if err != nil || host == "" {
		host = "unknown"
	}
	raw, err := os.ReadFile("/etc/machine-id")
	id := ""
	if err == nil {
		id = strings.TrimSpace(string(raw))
	}
	if id == "" {
		// No machine-id: fall back to the hostname and accept the ambiguity
		// rather than refusing to work.
		return "timeshift@" + host
	}
	return "timeshift-" + id + "@" + host
}

// EnsureKey generates the key if it is missing, and reports whether it made one.
func EnsureKey(ctx context.Context, runner Runner, keyFile string) (created bool, err error) {
	if keyFile == "" {
		keyFile = DefaultKeyFile()
	}
	if err := EnsureKeyDir(); err != nil {
		return false, err
	}
	if _, err := os.Stat(keyFile); err == nil {
		return false, nil
	}

	// ed25519 with no passphrase: an unattended daemon has nobody to ask for
	// one, and a passphrase it stored beside the key would protect nothing.
	code, _, stderr, err := runner.Run(ctx, []string{
		"ssh-keygen", "-t", "ed25519", "-N", "", "-f", keyFile, "-C", KeyMarker(),
	}, "")
	if err != nil {
		return false, err
	}
	if code != 0 {
		return false, fmt.Errorf("timeshift: could not generate an SSH key: %s", firstLine(stderr))
	}

	_ = os.Chmod(keyFile, 0o600)
	_ = os.Chmod(keyFile+".pub", 0o644)
	return true, nil
}

// HostKey is a scanned host key and its fingerprint, for a person to confirm.
type HostKey struct {
	// Line is the raw known_hosts entry.
	Line string

	// Fingerprint is ssh-keygen -lf's rendering, which is what a person
	// compares against the host's own.
	Fingerprint string
}

/* ScanHostKey fetches the remote's host key WITHOUT connecting as a user.
 *
 * This exists so the fingerprint can be shown before any password is typed. The
 * alternative is StrictHostKeyChecking=accept-new on the first real connection,
 * which is trust-on-first-use with a password already in flight.
 */
func ScanHostKey(ctx context.Context, runner Runner, host string, port int) (HostKey, error) {
	if !IsSafeHostComponent(host) {
		return HostKey{}, fmt.Errorf("%w: unsafe host", ErrBadURL)
	}
	if port == 0 {
		port = 22
	}

	code, stdout, stderr, err := runner.Run(ctx,
		[]string{"ssh-keyscan", "-T", "5", "-p", strconv.Itoa(port), host}, "")
	if err != nil {
		return HostKey{}, err
	}
	if code != 0 || strings.TrimSpace(stdout) == "" {
		return HostKey{}, fmt.Errorf("timeshift: no response from %s: %s", host, firstLine(stderr))
	}

	line := ""
	for _, l := range strings.Split(stdout, "\n") {
		l = strings.TrimSpace(l)
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		if line == "" {
			line = l
		}
		// Prefer ed25519 when the host offers several.
		if strings.Contains(l, "ssh-ed25519") {
			line = l
			break
		}
	}
	if line == "" {
		return HostKey{}, fmt.Errorf("timeshift: %s offered no host key", host)
	}

	hk := HostKey{Line: line}

	tmp, err := os.CreateTemp("", "ts-hostkey-")
	if err == nil {
		defer os.Remove(tmp.Name())
		if _, err := tmp.WriteString(line + "\n"); err == nil {
			tmp.Close()
			if _, out, _, err := runner.Run(ctx, []string{"ssh-keygen", "-lf", tmp.Name()}, ""); err == nil {
				hk.Fingerprint = strings.TrimSpace(out)
			}
		} else {
			tmp.Close()
		}
	}
	return hk, nil
}

/* TrustHostKey records a scanned key in Timeshift's own known_hosts.
 *
 * Its own, not the user's: this file is what every later connection is checked
 * against with StrictHostKeyChecking=yes, and mixing it with a person's
 * ~/.ssh/known_hosts would mean a host they trusted for other reasons is
 * silently trusted for this.
 *
 * knownHosts is explicit, defaulting to KnownHostsFile(), so a test can point
 * it somewhere harmless. A package-level variable would be the other way to do
 * that, and this tree does not have mutable package state for exactly the
 * reason it would be tempting here.
 */
func TrustHostKey(hk HostKey, knownHosts string) error {
	if strings.TrimSpace(hk.Line) == "" {
		return fmt.Errorf("timeshift: no host key to trust")
	}
	if knownHosts == "" {
		knownHosts = KnownHostsFile()
		if err := EnsureKeyDir(); err != nil {
			return err
		}
	}

	existing, _ := os.ReadFile(knownHosts)
	for _, l := range strings.Split(string(existing), "\n") {
		if strings.TrimSpace(l) == strings.TrimSpace(hk.Line) {
			return nil // already trusted
		}
	}

	f, err := os.OpenFile(knownHosts, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()

	// Guard the newline: an existing file that does not end in one would
	// otherwise have this key appended to its last entry.
	if len(existing) > 0 && !strings.HasSuffix(string(existing), "\n") {
		if _, err := f.WriteString("\n"); err != nil {
			return err
		}
	}
	_, err = f.WriteString(strings.TrimSpace(hk.Line) + "\n")
	return err
}

/* InstallPublicKey appends the key to the remote's authorized_keys.
 *
 * ssh-copy-id rather than a hand-rolled append, because it already handles
 * umask, creating ~/.ssh, the newline guard before appending, SELinux
 * restorecon, and skipping a key that is already there.
 *
 * The password reaches ssh through SSH_ASKPASS, in the CHILD's environment
 * only. It is never an argument -- /proc/<pid>/cmdline is readable by anything
 * on the machine -- and never written to a file. The helper script carries no
 * secret itself; it only echoes what the environment holds.
 *
 * Two ssh options are deliberately ABSENT and must stay absent: BatchMode,
 * which would disable the very password prompt this depends on, and
 * PubkeyAuthentication=no, because ssh-copy-id probes with publickey first to
 * find keys that are already installed.
 */
func InstallPublicKey(ctx context.Context, runner EnvRunner, b *SSHBackend, password string) error {
	pub := b.KeyFile + ".pub"
	if b.KeyFile == "" {
		pub = DefaultKeyFile() + ".pub"
	}
	if _, err := os.Stat(pub); err != nil {
		return fmt.Errorf("timeshift: public key not found: %s", pub)
	}

	port := b.Port
	if port == 0 {
		port = 22
	}

	argv := []string{
		"ssh-copy-id",
		"-i", pub,
		"-p", strconv.Itoa(port),
		"-o", "UserKnownHostsFile=" + KnownHostsFile(),
		"-o", "StrictHostKeyChecking=yes",
		"-o", "ConnectTimeout=10",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=3",
		b.HostSpec(),
	}

	if password == "" {
		/* No password: let ssh prompt on whatever terminal the caller has.
		 * The console path works this way and the password never enters this
		 * process at all, which is strictly better than handling it. */
		code, _, stderr, err := runner.RunEnv(ctx, argv, "", nil)
		if err != nil {
			return err
		}
		if code != 0 {
			return fmt.Errorf("timeshift: could not install the key on %s: %s", b.Host, firstLine(stderr))
		}
		return nil
	}

	helper, cleanup, err := writeAskpassHelper()
	if err != nil {
		return err
	}
	defer cleanup()

	env := append(os.Environ(),
		"TIMESHIFT_ASKPASS="+password,
		"SSH_ASKPASS="+helper,
		"SSH_ASKPASS_REQUIRE=force",
		// ssh only consults SSH_ASKPASS with no controlling terminal on older
		// versions; REQUIRE=force covers the modern ones, and an empty DISPLAY
		// keeps the old heuristic from looking for an X helper.
		"DISPLAY=",
	)

	code, _, stderr, err := runner.RunEnv(ctx, argv, "", env)
	if err != nil {
		return err
	}
	if code != 0 {
		return fmt.Errorf("timeshift: could not install the key on %s: %s", b.Host, firstLine(stderr))
	}
	return nil
}

/* VerifyKeyAuth confirms the installed key actually authenticates.
 *
 * Required, not optional: ssh-copy-id exits 0 even when the password was wrong
 * and nothing was installed. A failure here covers both that and "installed but
 * the remote refuses key auth", which ssh-copy-id cannot tell apart for us.
 */
func VerifyKeyAuth(ctx context.Context, runner Runner, b *SSHBackend) error {
	key := b.KeyFile
	if key == "" {
		key = DefaultKeyFile()
	}
	port := b.Port
	if port == 0 {
		port = 22
	}

	argv := []string{
		"ssh", "-n",
		"-F", "/dev/null",
		"-o", "BatchMode=yes",
		"-o", "PasswordAuthentication=no",
		"-o", "PubkeyAuthentication=yes",
		"-o", "ConnectTimeout=10",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=3",
		"-o", "UserKnownHostsFile=" + KnownHostsFile(),
		"-o", "StrictHostKeyChecking=yes",
		"-o", "IdentitiesOnly=yes",
		"-i", key,
		"-p", strconv.Itoa(port),
		b.HostSpec(),
		"echo TIMESHIFT_KEY_OK",
	}

	code, stdout, stderr, err := runner.Run(ctx, argv, "")
	if err != nil {
		return err
	}
	if code == 0 && strings.Contains(stdout, "TIMESHIFT_KEY_OK") {
		return nil
	}

	msg := "key-based login is not working; the password may have been incorrect, " +
		"or the remote may not permit key authentication"
	if s := firstLine(stderr); s != "" {
		msg += ": " + s
	}
	return fmt.Errorf("timeshift: %s", msg)
}

// EnvRunner runs a command with a replaced environment, which is how the
// password reaches ssh without touching argv or a file.
type EnvRunner interface {
	RunEnv(ctx context.Context, argv []string, stdin string, env []string) (int, string, string, error)
}

// writeAskpassHelper writes the tiny script ssh calls to obtain the password.
//
// Under /run rather than /tmp: it must not survive a reboot, and on a restore
// of the running system /tmp is on the filesystem being overwritten.
func writeAskpassHelper() (string, func(), error) {
	dir, err := os.MkdirTemp("/run", "ts-askpass-")
	if err != nil {
		// /run may be unavailable in a container; fall back rather than fail.
		dir, err = os.MkdirTemp("", "ts-askpass-")
		if err != nil {
			return "", func() {}, err
		}
	}
	cleanup := func() { os.RemoveAll(dir) }

	helper := path.Join(dir, "ssh-askpass")
	script := "#!/bin/sh\nprintf '%s\\n' \"$TIMESHIFT_ASKPASS\"\n"
	if err := os.WriteFile(helper, []byte(script), 0o700); err != nil {
		cleanup()
		return "", func() {}, err
	}
	return helper, cleanup, nil
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}
