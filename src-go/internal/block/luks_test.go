package block

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// recordingRunner captures argv and stdin so a test can assert the passphrase
// never reaches the command line.
type recordingRunner struct {
	calls  [][]string
	stdins []string
	code   int
	stderr string
}

func (r *recordingRunner) Run(_ context.Context, argv []string, stdin string) (int, string, string, error) {
	r.calls = append(r.calls, argv)
	r.stdins = append(r.stdins, stdin)
	return r.code, "", r.stderr, nil
}

func luksPart(kname string) *Device {
	return &Device{KName: kname, Path: "/dev/" + kname, Type: "part", FSType: "crypto_luks"}
}

/* The passphrase goes on STDIN and must never appear in argv.
 *
 * In argv it sits in /proc/<pid>/cmdline for the life of the process, readable
 * by anything on the machine. The Vala version got there by a longer route --
 * piping `echo -n -e '<pass>'` through a generated shell script -- which also
 * put the passphrase through single-quote escaping, one missed call away from a
 * shell injection.
 */
func TestThePassphraseNeverReachesArgv(t *testing.T) {
	r := &recordingRunner{}
	u := &Unlocker{Runner: r}

	const secret = "correct horse battery staple"
	if _, _, err := u.Unlock(context.Background(), nil, luksPart("sda3"), "", secret); err != nil {
		t.Fatalf("Unlock: %v", err)
	}

	if len(r.calls) != 1 {
		t.Fatalf("expected one command, got %v", r.calls)
	}
	for _, arg := range r.calls[0] {
		if strings.Contains(arg, secret) {
			t.Fatalf("the passphrase appeared in argv: %v", r.calls[0])
		}
	}
	if r.stdins[0] != secret {
		t.Errorf("stdin = %q, want the passphrase", r.stdins[0])
	}
	if !contains(r.calls[0], "--key-file") || !contains(r.calls[0], "-") {
		t.Errorf("cryptsetup was not told to read the key from stdin: %v", r.calls[0])
	}
}

// The default mapper name is the one Device.vala has always used, so a
// container unlocked by either build appears at the same /dev/mapper path.
func TestDefaultMapperNameMatchesTheValaBuild(t *testing.T) {
	r := &recordingRunner{}
	u := &Unlocker{Runner: r}

	name, _, err := u.Unlock(context.Background(), nil, luksPart("sda3"), "", "x")
	if err != nil {
		t.Fatal(err)
	}
	if name != "sda3_crypt" {
		t.Errorf("mapper name = %q, want sda3_crypt", name)
	}
	if r.calls[0][len(r.calls[0])-1] != "sda3_crypt" {
		t.Errorf("cryptsetup was given %q", r.calls[0][len(r.calls[0])-1])
	}
}

/* The mapper name becomes a path under /dev/mapper, so a name with a slash or
 * ".." chooses where the node lands. cryptsetup would very likely refuse too,
 * but "very likely" is not the standard for a root command acting on a value
 * that arrived over a socket. */
func TestMapperNamesThatWouldEscapeAreRefused(t *testing.T) {
	u := &Unlocker{Runner: &recordingRunner{}}
	for _, name := range []string{
		"../../etc/passwd", "a/b", "..", ".", "name with space",
		"name;rm -rf /", "$(id)", "back\\slash",
	} {
		if _, _, err := u.Unlock(context.Background(), nil, luksPart("sda3"), name, "x"); err == nil {
			t.Errorf("mapper name %q was accepted", name)
		}
	}
	// An empty name is not an escape attempt: it means "use the default",
	// which the previous test pins as sda3_crypt.
	for _, name := range []string{"", "sda3_crypt", "luks-1234", "root.crypt", "a+b"} {
		if _, _, err := u.Unlock(context.Background(), nil, luksPart("sda3"), name, "x"); err != nil {
			t.Errorf("mapper name %q was refused: %v", name, err)
		}
	}
}

func TestUnlockingSomethingUnencryptedIsRefused(t *testing.T) {
	u := &Unlocker{Runner: &recordingRunner{}}
	plain := &Device{KName: "sda1", Path: "/dev/sda1", Type: "part", FSType: "ext4"}

	if _, _, err := u.Unlock(context.Background(), nil, plain, "", "x"); !errors.Is(err, ErrNotEncrypted) {
		t.Errorf("err = %v, want ErrNotEncrypted", err)
	}
	if _, _, err := u.Unlock(context.Background(), nil, nil, "", "x"); !errors.Is(err, ErrNotEncrypted) {
		t.Errorf("nil device: err = %v, want ErrNotEncrypted", err)
	}
}

/* An already-unlocked container is success. Refusing because someone else got
 * there first would make two clients unlocking the same disk a failure for the
 * second, when what both wanted -- a usable device -- exists. */
func TestAnAlreadyUnlockedContainerIsSuccess(t *testing.T) {
	r := &recordingRunner{}
	u := &Unlocker{Runner: r}

	target := luksPart("sda3")
	mapper := &Device{KName: "dm-0", Name: "sda3_crypt", Path: "/dev/mapper/sda3_crypt",
		Type: "crypt", PKName: "sda3"}

	name, already, err := u.Unlock(context.Background(), []*Device{target, mapper}, target, "", "")
	if err != nil {
		t.Fatalf("Unlock: %v", err)
	}
	if !already {
		t.Error("AlreadyOpen was not reported")
	}
	if name != "sda3_crypt" {
		t.Errorf("mapper name = %q", name)
	}
	if len(r.calls) != 0 {
		t.Errorf("cryptsetup was run for an already-open container: %v", r.calls)
	}
}

/* No passphrase is a refusal, not a prompt. A daemon has no terminal, and
 * cryptsetup with no key file would wait on one that never answers -- a hang,
 * which is the failure nobody can diagnose. */
func TestUnlockWithNoPassphraseRefusesRatherThanWaits(t *testing.T) {
	r := &recordingRunner{}
	u := &Unlocker{Runner: r}

	if _, _, err := u.Unlock(context.Background(), nil, luksPart("sda3"), "", ""); !errors.Is(err, ErrNoPassphrase) {
		t.Errorf("err = %v, want ErrNoPassphrase", err)
	}
	if len(r.calls) != 0 {
		t.Errorf("cryptsetup was run with no passphrase: %v", r.calls)
	}
}

// Exit 2 is cryptsetup's "no key available with this passphrase" -- the one
// failure that is the user's to fix rather than ours.
func TestWrongPassphraseIsNamed(t *testing.T) {
	u := &Unlocker{Runner: &recordingRunner{code: 2, stderr: "No key available with this passphrase."}}
	if _, _, err := u.Unlock(context.Background(), nil, luksPart("sda3"), "", "nope"); !errors.Is(err, ErrWrongPassphrase) {
		t.Errorf("err = %v, want ErrWrongPassphrase", err)
	}

	other := &Unlocker{Runner: &recordingRunner{code: 5, stderr: "Device /dev/sda3 is busy."}}
	_, _, err := other.Unlock(context.Background(), nil, luksPart("sda3"), "", "x")
	if errors.Is(err, ErrWrongPassphrase) {
		t.Error("a busy device was reported as a wrong passphrase")
	}
	if err == nil || !strings.Contains(err.Error(), "busy") {
		t.Errorf("err = %v, want the real reason", err)
	}
}

func contains(ss []string, want string) bool {
	for _, s := range ss {
		if s == want {
			return true
		}
	}
	return false
}

/* The real thing, on a loopback file.
 *
 * A faked cryptsetup only proves the fake agrees with the fake. This makes an
 * actual LUKS container, unlocks it with the real tool through the real code
 * path, and checks the mapper device appears -- which is the only way to know
 * the argv and the stdin plumbing are right. Needs root; skips cleanly without.
 */
func TestUnlockARealLUKSContainer(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("needs root to attach a loop device and run cryptsetup")
	}
	for _, tool := range []string{"cryptsetup", "losetup"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s not available", tool)
		}
	}

	dir := t.TempDir()
	img := filepath.Join(dir, "luks.img")
	if err := run(t, "truncate", "-s", "32M", img); err != nil {
		t.Fatal(err)
	}

	loop, err := output(t, "losetup", "--find", "--show", img)
	if err != nil {
		t.Skipf("could not attach a loop device: %v", err)
	}
	loop = strings.TrimSpace(loop)
	defer exec.Command("losetup", "-d", loop).Run()

	const pass = "test-passphrase-not-a-secret"

	// The smallest, fastest KDF settings: this is a throwaway container and the
	// default argon2 tuning would make the test take tens of seconds.
	format := exec.Command("cryptsetup", "luksFormat", "--batch-mode",
		"--pbkdf", "pbkdf2", "--pbkdf-force-iterations", "1000", loop)
	format.Stdin = strings.NewReader(pass)
	if out, err := format.CombinedOutput(); err != nil {
		t.Skipf("luksFormat failed: %v: %s", err, out)
	}

	mapper := "ts-luks-test"
	defer exec.Command("cryptsetup", "luksClose", mapper).Run()

	u := &Unlocker{Runner: realRun{}}
	target := &Device{
		KName: strings.TrimPrefix(loop, "/dev/"), Path: loop,
		Type: "loop", FSType: "crypto_LUKS",
	}

	// The wrong passphrase must be reported as such, not as a generic failure.
	if _, _, err := u.Unlock(context.Background(), nil, target, mapper, "definitely-wrong"); !errors.Is(err, ErrWrongPassphrase) {
		t.Errorf("wrong passphrase gave %v, want ErrWrongPassphrase", err)
	}

	name, already, err := u.Unlock(context.Background(), nil, target, mapper, pass)
	if err != nil {
		t.Fatalf("Unlock: %v", err)
	}
	if already {
		t.Error("a freshly formatted container reported AlreadyOpen")
	}
	if name != mapper {
		t.Errorf("mapper name = %q, want %q", name, mapper)
	}
	if _, err := os.Stat("/dev/mapper/" + mapper); err != nil {
		t.Fatalf("the mapper device was not created: %v", err)
	}

	if err := u.Lock(context.Background(), mapper); err != nil {
		t.Fatalf("Lock: %v", err)
	}
	if _, err := os.Stat("/dev/mapper/" + mapper); !os.IsNotExist(err) {
		t.Errorf("the mapper device survived Lock: %v", err)
	}
}

// realRun runs commands for real, with stdin, as the daemon's runner does.
type realRun struct{}

func (realRun) Run(ctx context.Context, argv []string, stdin string) (int, string, string, error) {
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var out, errb strings.Builder
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	if ee, ok := err.(*exec.ExitError); ok {
		return ee.ExitCode(), out.String(), errb.String(), nil
	}
	if err != nil {
		return -1, out.String(), errb.String(), err
	}
	return 0, out.String(), errb.String(), nil
}

func run(t *testing.T, argv ...string) error {
	t.Helper()
	return exec.Command(argv[0], argv[1:]...).Run()
}

func output(t *testing.T, argv ...string) (string, error) {
	t.Helper()
	b, err := exec.Command(argv[0], argv[1:]...).Output()
	return string(b), err
}
