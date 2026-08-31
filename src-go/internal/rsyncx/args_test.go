package rsyncx

import (
	"strings"
	"testing"
)

func joined(o Options) string { return strings.Join(o.Args(), " ") }

// The flag set decides how many lines a transfer emits, and the progress
// denominator is a line count from a separate dry run. These are not cosmetic.
func TestBaseFlags(t *testing.T) {
	got := joined(Options{Source: "/", Dest: "/dst"})

	for _, want := range []string{"-aiiXH", "--recursive", "--delete-after", "--force", "--stats", "--sparse"} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in: %s", want, got)
		}
	}
	// -X is what keeps snap-confine's security.capability; without it every
	// snap silently stops working after a restore.
	if !strings.Contains(got, "-aiiXH") {
		t.Error("the combined flag must keep X for xattrs and H for hard links")
	}
}

// Trailing slashes mean "copy the contents", not "copy the directory". Without
// them each snapshot would nest one level deeper than the last.
func TestTrailingSlashes(t *testing.T) {
	args := Options{Source: "/", Dest: "/repo/snap/localhost"}.Args()
	src, dst := args[len(args)-2], args[len(args)-1]
	if src != "/" {
		t.Errorf("source = %q", src)
	}
	if dst != "/repo/snap/localhost/" {
		t.Errorf("dest = %q, want a trailing slash", dst)
	}

	// Already-slashed paths are not doubled.
	args = Options{Source: "/src/", Dest: "/dst/"}.Args()
	if args[len(args)-2] != "/src/" || args[len(args)-1] != "/dst/" {
		t.Errorf("existing slashes were doubled: %v", args[len(args)-2:])
	}
}

// rsync resolves --link-dest on the RECEIVING side, so it is a plain
// repository path with no host: prefix even for a remote transfer.
func TestLinkDestHasNoHostPrefix(t *testing.T) {
	got := joined(Options{
		Source:   "/",
		Dest:     "backup@host:/srv/snap/new/localhost",
		LinkFrom: "/srv/snap/previous/localhost",
		RSH:      "ssh -o BatchMode=yes",
		Remote:   true,
	})
	if !strings.Contains(got, "--link-dest=/srv/snap/previous/localhost/") {
		t.Errorf("link-dest wrong: %s", got)
	}
	if strings.Contains(got, "--link-dest=backup@host:") {
		t.Error("link-dest must not carry a host prefix; rsync resolves it on the receiving side")
	}
}

// Crossing hosts without --numeric-ids maps uid and gid BY NAME, so a restored
// system gets whatever those names resolve to on the backup host.
func TestNumericIDsOnlyForRemote(t *testing.T) {
	remote := joined(Options{Source: "/", Dest: "h:/d", RSH: "ssh", Remote: true})
	if !strings.Contains(remote, "--numeric-ids") {
		t.Errorf("a transfer with -e must pass --numeric-ids: %s", remote)
	}

	local := joined(Options{Source: "/", Dest: "/d"})
	if strings.Contains(local, "--numeric-ids") {
		t.Errorf("a local transfer should not need --numeric-ids: %s", local)
	}
}

func TestRemoteResumeAndTimeout(t *testing.T) {
	got := joined(Options{Source: "/", Dest: "h:/d", RSH: "ssh", Remote: true})
	if !strings.Contains(got, "--partial-dir=.timeshift-partial") {
		t.Errorf("a remote transfer should be resumable: %s", got)
	}
	if !strings.Contains(got, "--timeout=120") {
		t.Errorf("a remote transfer needs a timeout or a dead link hangs it: %s", got)
	}

	// A dry run writes nothing, so there is nothing to resume.
	dry := joined(Options{Source: "/", Dest: "h:/d", RSH: "ssh", Remote: true, DryRun: true})
	if strings.Contains(dry, "--partial-dir") {
		t.Errorf("a dry run must not ask for a partial dir: %s", dry)
	}
	if !strings.Contains(dry, "--timeout=120") {
		t.Errorf("a dry run still needs the timeout: %s", dry)
	}
	if !strings.Contains(dry, "--dry-run") {
		t.Errorf("missing --dry-run: %s", dry)
	}
}

// Progress is a line count; --quiet would leave almost nothing to count.
func TestVerbosity(t *testing.T) {
	if !strings.Contains(joined(Options{Source: "/", Dest: "/d", Verbose: true}), "--verbose") {
		t.Error("verbose not passed")
	}
	if !strings.Contains(joined(Options{Source: "/", Dest: "/d"}), "--quiet") {
		t.Error("quiet is the default")
	}
}

func TestDeleteFlags(t *testing.T) {
	plain := joined(Options{Source: "/", Dest: "/d"})
	if strings.Contains(plain, " --delete ") {
		t.Errorf("--delete must be opt-in: %s", plain)
	}

	del := joined(Options{Source: "/", Dest: "/d", DeleteExtra: true, DeleteExcluded: true})
	if !strings.Contains(del, "--delete") || !strings.Contains(del, "--delete-excluded") {
		t.Errorf("delete flags missing: %s", del)
	}
}

// Both are opened by rsync on the CLIENT side. Pointing either inside a remote
// snapshot makes rsync warn, ignore it, and still exit 0.
func TestClientSideFiles(t *testing.T) {
	got := joined(Options{
		Source:      "/",
		Dest:        "h:/d",
		RSH:         "ssh",
		Remote:      true,
		LogFile:     "/tmp/ts/rsync-log",
		ExcludeFrom: "/tmp/ts/exclude.list",
	})
	if !strings.Contains(got, "--log-file=/tmp/ts/rsync-log") {
		t.Errorf("log file wrong: %s", got)
	}
	if !strings.Contains(got, "--exclude-from=/tmp/ts/exclude.list") {
		t.Errorf("exclude file wrong: %s", got)
	}
}

func TestRsyncPathForFakeSuper(t *testing.T) {
	got := joined(Options{
		Source: "/", Dest: "h:/d", RSH: "ssh", Remote: true,
		RsyncPath: "rsync --fake-super",
	})
	if !strings.Contains(got, "--rsync-path=rsync --fake-super") {
		t.Errorf("rsync-path missing: %s", got)
	}
}

func TestCommandIncludesProgramName(t *testing.T) {
	cmd := Options{Source: "/", Dest: "/d"}.Command()
	if cmd[0] != "rsync" {
		t.Errorf("Command[0] = %q", cmd[0])
	}
	if len(cmd) != len(Options{Source: "/", Dest: "/d"}.Args())+1 {
		t.Error("Command should be Args with the program name prepended")
	}
}

// 24 is success and 23 is a warning. Treating either as failure would make
// almost every snapshot of a running system look broken.
func TestExitCodeClassification(t *testing.T) {
	if !Succeeded(0) || !Succeeded(24) {
		t.Error("0 and 24 are both success")
	}
	if Succeeded(23) || Succeeded(1) {
		t.Error("23 and 1 are not success")
	}
	if !Warned(23) || Warned(24) {
		t.Error("only 23 is the warning code")
	}
	for _, c := range []int{10, 12, 30, 35, 255} {
		if !TransportFailure(c) {
			t.Errorf("%d should be a transport failure worth retrying", c)
		}
	}
	for _, c := range []int{0, 1, 23, 24} {
		if TransportFailure(c) {
			t.Errorf("%d is not a transport failure", c)
		}
	}
}

func TestExitMeaning(t *testing.T) {
	cases := map[int]string{
		23:  "some files could not be transferred",
		24:  "vanished",
		255: "connection lost",
		11:  "file I/O",
		99:  "99",
	}
	for code, want := range cases {
		if got := ExitMeaning(code); !strings.Contains(got, want) {
			t.Errorf("ExitMeaning(%d) = %q, want it to mention %q", code, got, want)
		}
	}
}
