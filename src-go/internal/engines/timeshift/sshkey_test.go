package timeshift

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// envRecorder captures argv, stdin and the child environment.
type envRecorder struct {
	calls  [][]string
	envs   [][]string
	stdout string
	code   int
	stderr string
}

func (r *envRecorder) Run(_ context.Context, argv []string, stdin string) (int, string, string, error) {
	r.calls = append(r.calls, argv)
	r.envs = append(r.envs, nil)
	return r.code, r.stdout, r.stderr, nil
}

func (r *envRecorder) RunEnv(_ context.Context, argv []string, stdin string, env []string) (int, string, string, error) {
	r.calls = append(r.calls, argv)
	r.envs = append(r.envs, env)
	return r.code, r.stdout, r.stderr, nil
}

func testBackend(keyFile string) *SSHBackend {
	return &SSHBackend{User: "backup", Host: "nas.example", Port: 2222,
		Path: "/srv/snap", KeyFile: keyFile}
}

/* The account password must never reach argv.
 *
 * /proc/<pid>/cmdline is readable by anything on the machine, so a password
 * there is a password disclosed. It goes through SSH_ASKPASS in the CHILD's
 * environment -- not the daemon's, which the Vala build used and which leaves
 * it in /proc/self/environ for as long as the daemon runs rather than for the
 * life of one ssh-copy-id.
 */
func TestTheAccountPasswordNeverReachesArgv(t *testing.T) {
	dir := t.TempDir()
	key := filepath.Join(dir, "id_ed25519")
	if err := os.WriteFile(key+".pub", []byte("ssh-ed25519 AAAA test\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	r := &envRecorder{}
	const secret = "hunter2-not-a-real-password"

	if err := InstallPublicKey(context.Background(), r, testBackend(key), secret); err != nil {
		t.Fatalf("InstallPublicKey: %v", err)
	}
	if len(r.calls) != 1 {
		t.Fatalf("expected one command, got %v", r.calls)
	}
	for _, arg := range r.calls[0] {
		if strings.Contains(arg, secret) {
			t.Fatalf("the password appeared in argv: %v", r.calls[0])
		}
	}

	env := strings.Join(r.envs[0], "\n")
	if !strings.Contains(env, "TIMESHIFT_ASKPASS="+secret) {
		t.Error("the password was not passed through the child's environment")
	}
	if !strings.Contains(env, "SSH_ASKPASS_REQUIRE=force") {
		t.Error("SSH_ASKPASS_REQUIRE=force was not set; ssh may ignore the helper")
	}
}

/* Two ssh options must stay ABSENT from ssh-copy-id.
 *
 * BatchMode would disable the very password prompt the flow depends on, and
 * PubkeyAuthentication=no would stop ssh-copy-id probing for keys that are
 * already installed. Both are easy to add later "for consistency" with the
 * other ssh invocations, and both break this one.
 */
func TestSSHCopyIDOmitsTheOptionsThatWouldBreakIt(t *testing.T) {
	dir := t.TempDir()
	key := filepath.Join(dir, "id_ed25519")
	os.WriteFile(key+".pub", []byte("ssh-ed25519 AAAA test\n"), 0o644)

	r := &envRecorder{}
	if err := InstallPublicKey(context.Background(), r, testBackend(key), "pw"); err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(r.calls[0], " ")

	for _, forbidden := range []string{"BatchMode", "PubkeyAuthentication=no"} {
		if strings.Contains(joined, forbidden) {
			t.Errorf("ssh-copy-id was given %q, which breaks it: %v", forbidden, r.calls[0])
		}
	}
	for _, want := range []string{"ssh-copy-id", "StrictHostKeyChecking=yes", "-p 2222"} {
		if !strings.Contains(joined, want) {
			t.Errorf("ssh-copy-id is missing %q: %v", want, r.calls[0])
		}
	}
	// The host key store is ours, not the invoking user's.
	if !strings.Contains(joined, "UserKnownHostsFile="+KnownHostsFile()) {
		t.Errorf("ssh-copy-id was not pointed at Timeshift's known_hosts: %v", r.calls[0])
	}
}

// With no password, ssh must be left to prompt on the caller's terminal --
// the password then never enters this process at all.
func TestInstallWithNoPasswordDoesNotSetAnAskpass(t *testing.T) {
	dir := t.TempDir()
	key := filepath.Join(dir, "id_ed25519")
	os.WriteFile(key+".pub", []byte("ssh-ed25519 AAAA test\n"), 0o644)

	r := &envRecorder{}
	if err := InstallPublicKey(context.Background(), r, testBackend(key), ""); err != nil {
		t.Fatal(err)
	}
	if r.envs[0] != nil {
		t.Errorf("an environment was imposed when none was needed: %v", r.envs[0])
	}
}

func TestInstallRefusesWithNoPublicKey(t *testing.T) {
	r := &envRecorder{}
	err := InstallPublicKey(context.Background(), r, testBackend(filepath.Join(t.TempDir(), "absent")), "pw")
	if err == nil {
		t.Fatal("installing a key that does not exist was allowed")
	}
	if len(r.calls) != 0 {
		t.Error("ssh-copy-id was run with no key to install")
	}
}

/* Verification is required, not belt-and-braces: ssh-copy-id exits 0 even when
 * the password was wrong and nothing was installed, so its status alone cannot
 * be trusted to mean success. */
func TestVerifyKeyAuthNeedsTheMarkerNotJustExitZero(t *testing.T) {
	// Exit 0 but no marker: a shell that connected and printed nothing useful.
	silent := &envRecorder{code: 0, stdout: ""}
	if err := VerifyKeyAuth(context.Background(), silent, testBackend("/k")); err == nil {
		t.Error("exit 0 with no marker was accepted as working key auth")
	}

	ok := &envRecorder{code: 0, stdout: "TIMESHIFT_KEY_OK\n"}
	if err := VerifyKeyAuth(context.Background(), ok, testBackend("/k")); err != nil {
		t.Errorf("a working key was rejected: %v", err)
	}

	joined := strings.Join(ok.calls[0], " ")
	for _, want := range []string{
		"BatchMode=yes",             // must never prompt
		"PasswordAuthentication=no", // otherwise a password would prove nothing
		"IdentitiesOnly=yes",        // an agent key must not stand in for ours
		"StrictHostKeyChecking=yes", // by now the host must be known
		"-F /dev/null",              // root's ssh_config must not rewrite this
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("verification is missing %q: %v", want, ok.calls[0])
		}
	}
}

func TestScanHostKeyPrefersEd25519AndRejectsUnsafeHosts(t *testing.T) {
	r := &envRecorder{code: 0, stdout: "" +
		"nas.example ssh-rsa AAAArsa\n" +
		"# a comment\n" +
		"nas.example ssh-ed25519 AAAAed\n"}

	hk, err := ScanHostKey(context.Background(), r, "nas.example", 2222)
	if err != nil {
		t.Fatalf("ScanHostKey: %v", err)
	}
	if !strings.Contains(hk.Line, "ssh-ed25519") {
		t.Errorf("did not prefer the ed25519 key: %q", hk.Line)
	}

	// The same option-injection guard the URL parser uses: a host beginning
	// with "-" is an ssh option, not a host.
	if _, err := ScanHostKey(context.Background(), r, "-oProxyCommand=id", 22); err == nil {
		t.Error("an option-shaped host was accepted")
	}
}

func TestScanHostKeyReportsNoResponse(t *testing.T) {
	r := &envRecorder{code: 0, stdout: "   \n"}
	if _, err := ScanHostKey(context.Background(), r, "nas.example", 22); err == nil {
		t.Error("an empty keyscan was reported as success")
	}
}

/* TrustHostKey appends to TIMESHIFT's known_hosts, not the user's, and must
 * guard the newline: a file not ending in one would otherwise have the new key
 * appended to its last entry, corrupting both. */
func TestTrustHostKeyAppendsSafely(t *testing.T) {
	kh := filepath.Join(t.TempDir(), "known_hosts")
	if err := os.WriteFile(kh, []byte("existing.example ssh-rsa AAAA"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := TrustHostKey(HostKey{Line: "nas.example ssh-ed25519 AAAAed"}, kh); err != nil {
		t.Fatalf("TrustHostKey: %v", err)
	}
	raw, _ := os.ReadFile(kh)
	lines := strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
	if len(lines) != 2 {
		t.Fatalf("known_hosts has %d lines, want 2:\n%s", len(lines), raw)
	}
	if lines[0] != "existing.example ssh-rsa AAAA" {
		t.Errorf("the existing entry was corrupted: %q", lines[0])
	}

	// Trusting the same key twice must not duplicate it.
	TrustHostKey(HostKey{Line: "nas.example ssh-ed25519 AAAAed"}, kh)
	raw, _ = os.ReadFile(kh)
	if n := strings.Count(string(raw), "ssh-ed25519"); n != 1 {
		t.Errorf("the key was recorded %d times", n)
	}
}

/* The key marker keys on machine-id, not the hostname.
 *
 * Hostnames are not unique -- "raspberrypi", "ubuntu" and "localhost" are the
 * default on very many machines -- so keying on one would let two hosts sharing
 * a name delete each other's entries from a shared repository's
 * authorized_keys.
 */
func TestKeyMarkerIsMachineSpecific(t *testing.T) {
	m := KeyMarker()
	if !strings.HasPrefix(m, "timeshift") || !strings.Contains(m, "@") {
		t.Fatalf("marker = %q", m)
	}
	if raw, err := os.ReadFile("/etc/machine-id"); err == nil && strings.TrimSpace(string(raw)) != "" {
		if !strings.Contains(m, strings.TrimSpace(string(raw))) {
			t.Errorf("marker %q does not carry the machine-id", m)
		}
	}
}
