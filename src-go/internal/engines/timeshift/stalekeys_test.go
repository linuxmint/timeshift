package timeshift

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

/* These tests RUN the script rather than asserting on its text.
 *
 * The whole of RemoveStaleKeys is one awk program deciding which lines of an
 * authorized_keys survive, and a mistake there does not look like a mistake --
 * it looks like a working function that also deleted the key somebody else's
 * machine uses. Comparing the built string against an expected string would
 * only prove it still equals what it equalled when the test was written.
 *
 * localShell is the seam that makes it runnable: it takes the command
 * RemoveStaleKeys hands to ssh and executes it here instead, with HOME pointed
 * at a fixture. Everything the remote side does is therefore real -- mktemp,
 * awk, the empty-result refusal, the rename.
 */
type localShell struct {
	home string
	last string
}

func (r *localShell) Run(ctx context.Context, argv []string, _ string) (int, string, string, error) {
	// The command is the final argument of "ssh <options> host <command>".
	r.last = argv[len(argv)-1]
	cmd := exec.CommandContext(ctx, "sh", "-c", r.last)
	cmd.Env = append(os.Environ(), "HOME="+r.home)
	var out, errb strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errb
	err := cmd.Run()
	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code, err = ee.ExitCode(), nil
	}
	return code, out.String(), errb.String(), err
}

// stalePub writes a public key file and returns the backend that holds it.
func stalePub(t *testing.T, blob string) (*SSHBackend, *localShell) {
	t.Helper()
	dir := t.TempDir()
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, ".ssh"), 0o700); err != nil {
		t.Fatal(err)
	}
	key := filepath.Join(dir, "id_ed25519")
	pub := "ssh-ed25519 " + blob + " " + KeyMarker() + "\n"
	if err := os.WriteFile(key+".pub", []byte(pub), 0o644); err != nil {
		t.Fatal(err)
	}
	sh := &localShell{home: home}
	b := testBackend(key)
	b.Runner = sh
	return b, sh
}

func authKeys(t *testing.T, sh *localShell, lines ...string) {
	t.Helper()
	p := filepath.Join(sh.home, ".ssh", "authorized_keys")
	if err := os.WriteFile(p, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func readKeys(t *testing.T, sh *localShell) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(sh.home, ".ssh", "authorized_keys"))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

/* The point of the routine: an old key of OURS goes, the current one stays.
 * Both carry the same marker, so only the blob separates them. */
func TestAStaleKeyOfOursIsRemovedAndTheCurrentOneKept(t *testing.T) {
	b, sh := stalePub(t, "CURRENT")
	authKeys(t, sh,
		"ssh-ed25519 OLDONE "+KeyMarker(),
		"ssh-ed25519 CURRENT "+KeyMarker(),
	)

	n, err := RemoveStaleKeys(context.Background(), b)
	if err != nil {
		t.Fatalf("removal failed: %v", err)
	}
	if n != 1 {
		t.Errorf("removed = %d, want 1", n)
	}
	got := readKeys(t, sh)
	if strings.Contains(got, "OLDONE") {
		t.Error("the stale key survived")
	}
	if !strings.Contains(got, "CURRENT") {
		t.Fatal("the current key was deleted -- this locks the account out")
	}
}

/* Another machine's key must never be touched. Its marker differs, and a
 * shared repository is exactly where two machines' keys sit side by side. */
func TestAnotherMachinesKeyIsLeftAlone(t *testing.T) {
	b, sh := stalePub(t, "CURRENT")
	authKeys(t, sh,
		"ssh-ed25519 THEIRS timeshift-0000@otherbox",
		"ssh-rsa PERSONAL alice@laptop",
		"ssh-ed25519 CURRENT "+KeyMarker(),
	)

	if _, err := RemoveStaleKeys(context.Background(), b); err != nil {
		t.Fatal(err)
	}
	got := readKeys(t, sh)
	for _, want := range []string{"THEIRS", "PERSONAL", "CURRENT"} {
		if !strings.Contains(got, want) {
			t.Errorf("%s was removed and should not have been:\n%s", want, got)
		}
	}
}

/* The key type is found by prefix, not by field position, so a line carrying
 * options still parses. Get this wrong and the options line is unrecognisable,
 * which means an old key hides behind "no-pty" and is never cleaned up. */
func TestAKeyCarryingOptionsIsStillMatched(t *testing.T) {
	b, sh := stalePub(t, "CURRENT")
	authKeys(t, sh,
		`no-pty,command="/bin/true" ssh-ed25519 OLDONE `+KeyMarker(),
		"ssh-ed25519 CURRENT "+KeyMarker(),
	)

	n, err := RemoveStaleKeys(context.Background(), b)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("removed = %d, want 1 -- the options line was not parsed", n)
	}
	if strings.Contains(readKeys(t, sh), "OLDONE") {
		t.Error("the stale key behind options survived")
	}
}

/* The comment is rebuilt and compared WHOLE. Matching only the last field
 * would delete any key whose comment merely ends in our marker -- somebody
 * else's key, permanently, with no way to know why. */
func TestAKeyWhoseCommentMerelyEndsInOurMarkerIsKept(t *testing.T) {
	b, sh := stalePub(t, "CURRENT")
	authKeys(t, sh,
		"ssh-ed25519 INNOCENT backup for "+KeyMarker(),
		"ssh-ed25519 CURRENT "+KeyMarker(),
	)

	n, err := RemoveStaleKeys(context.Background(), b)
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("removed = %d, want 0", n)
	}
	if !strings.Contains(readKeys(t, sh), "INNOCENT") {
		t.Error("a key with a longer comment was deleted on a suffix match")
	}
}

/* Refusing to write an empty result is the last line of defence: if every line
 * matched, the account would be left with no way in at all. */
func TestAnEmptyResultIsRefused(t *testing.T) {
	b, sh := stalePub(t, "CURRENT")
	authKeys(t, sh, "ssh-ed25519 OLDONE "+KeyMarker())

	if _, err := RemoveStaleKeys(context.Background(), b); err == nil {
		t.Fatal("emptying authorized_keys was allowed")
	}
	if !strings.Contains(readKeys(t, sh), "OLDONE") {
		t.Fatal("the original was modified despite the refusal")
	}
}

/* No authorized_keys at all is success with nothing to do, not an error: the
 * key was just installed, so the file normally exists, but a race or a manual
 * tidy should not turn a completed setup into a failure. */
func TestAMissingAuthorizedKeysIsNotAnError(t *testing.T) {
	b, sh := stalePub(t, "CURRENT")
	_ = sh

	n, err := RemoveStaleKeys(context.Background(), b)
	if err != nil {
		t.Fatalf("a missing file should be harmless: %v", err)
	}
	if n != 0 {
		t.Errorf("removed = %d, want 0", n)
	}
}

/* Without the sentinel there is no proof the script finished. A login banner
 * or a non-POSIX remote shell would otherwise be read as "removed 0" -- a
 * silent no-op reported as success. */
func TestOutputWithoutTheSentinelIsAFailure(t *testing.T) {
	dir := t.TempDir()
	key := filepath.Join(dir, "id_ed25519")
	if err := os.WriteFile(key+".pub", []byte("ssh-ed25519 CURRENT "+KeyMarker()+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	b := testBackend(key)
	b.Runner = &envRecorder{stdout: "Welcome to Ubuntu 24.04 LTS\n"}

	if _, err := RemoveStaleKeys(context.Background(), b); err == nil {
		t.Fatal("a run with no sentinel was reported as success")
	}
}

// A missing public key cannot be reasoned about, so nothing is deleted.
func TestAMissingPublicKeyRemovesNothing(t *testing.T) {
	b := testBackend(filepath.Join(t.TempDir(), "absent"))
	b.Runner = &envRecorder{}

	if _, err := RemoveStaleKeys(context.Background(), b); err == nil {
		t.Fatal("a missing public key should refuse rather than proceed")
	}
}
