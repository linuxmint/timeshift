package timeshift

import (
	"strings"
	"testing"
)

func indexOfPattern(list []string, want string) int {
	for i, p := range list {
		if p == want {
			return i
		}
	}
	return -1
}

// These are rsync filter rules: the FIRST match wins and the rest are never
// considered. Order is behaviour, not tidiness.
func TestExcludeOrder(t *testing.T) {
	list := BuildBackupExcludes(ExcludeInput{
		UserPatterns: []string{"/my/own/rule/**"},
		Users:        []User{{Name: "u", HomePath: "/home/u"}},
	})

	user := indexOfPattern(list, "/my/own/rule/**")
	def := indexOfPattern(list, "/dev/*")
	cache := indexOfPattern(list, "/home/*/.cache")
	perUser := indexOfPattern(list, "/home/u/**")
	blanket := indexOfPattern(list, "/home/*/**")
	last := indexOfPattern(list, TimeshiftExclude)

	if user < 0 || def < 0 || cache < 0 || perUser < 0 || blanket < 0 || last < 0 {
		t.Fatalf("a required rule is missing from %v", list)
	}
	if !(user < def && def < cache && cache < perUser && perUser < blanket) {
		t.Errorf("wrong order: user=%d default=%d cache=%d per-user=%d blanket=%d",
			user, def, cache, perUser, blanket)
	}
	/* Not last: "/timeshift/*" is already among the defaults, so the trailing
	 * add() dedupes away. Same in create_exclude_list_for_backup(), whose final
	 * add is guarded by a contains() check. It is belt and braces for the day
	 * somebody edits the defaults, and it only has to be present. */
	if last < 0 {
		t.Errorf("%q is missing", TimeshiftExclude)
	}
}

// The operator's own rules come first so they can override a default.
func TestUserPatternsWinOverDefaults(t *testing.T) {
	list := BuildBackupExcludes(ExcludeInput{
		UserPatterns: []string{"+ /var/lib/docker/keep-this/***"},
	})
	inc := indexOfPattern(list, "+ /var/lib/docker/keep-this/***")
	exc := indexOfPattern(list, "/var/lib/docker/*")
	if inc < 0 || exc < 0 || inc > exc {
		t.Errorf("an operator include must precede the default exclude: inc=%d exc=%d", inc, exc)
	}
}

// The snap triple: keep the symlinks, skip the squashfs contents. Without the
// two includes a restored system has the payloads and the mounts but no
// working snap commands.
func TestSnapRulesAreOrdered(t *testing.T) {
	list := BuildBackupExcludes(ExcludeInput{})
	bin := indexOfPattern(list, "+ /snap/bin/***")
	cur := indexOfPattern(list, "+ /snap/*/current")
	rest := indexOfPattern(list, "- /snap/*/*")
	if bin < 0 || cur < 0 || rest < 0 {
		t.Fatal("the snap rules are missing")
	}
	if !(bin < rest && cur < rest) {
		t.Errorf("the snap includes must precede the exclude: %d %d %d", bin, cur, rest)
	}
}

// Backing up /etc/timeshift would put the SSH private key inside the very
// repository it unlocks.
func TestSecuritySensitiveDefaults(t *testing.T) {
	list := BuildBackupExcludes(ExcludeInput{})
	for _, want := range []string{
		"/etc/timeshift/*",
		"/etc/timeshift.json",
		"/var/cache/timeshift-recovery/*",
		"/var/lib/timeshift-recovery/*",
	} {
		if indexOfPattern(list, want) < 0 {
			t.Errorf("%q is missing from the defaults", want)
		}
	}
}

func TestSwapFilesExcluded(t *testing.T) {
	list := BuildBackupExcludes(ExcludeInput{SwapFiles: []string{"/swap/extra.img"}})
	if indexOfPattern(list, "/swap/extra.img") < 0 {
		t.Error("an active swap file was not excluded")
	}
	// The two well-known ones are defaults regardless.
	if indexOfPattern(list, "/swapfile") < 0 || indexOfPattern(list, "/swap.img") < 0 {
		t.Error("the default swap paths are missing")
	}
}

// An encrypted home holds ciphertext on disk; copying it produces a snapshot
// that restores to an unreadable home. It is excluded and cannot be opted in.
func TestEncryptedHomeAlwaysExcluded(t *testing.T) {
	list := BuildBackupExcludes(ExcludeInput{
		// Even with an explicit include from the operator.
		UserPatterns: []string{"+ /home/enc/**"},
		Users: []User{{
			Name: "enc", HomePath: "/home/enc",
			HasEncryptedHome:     true,
			EncryptedPrivateDirs: []string{"/home/enc/Private"},
		}},
	})
	if indexOfPattern(list, "/home/enc/**") < 0 {
		t.Error("an encrypted home must be excluded outright")
	}
	if indexOfPattern(list, "/home/enc/Private/**") < 0 {
		t.Error("an encrypted Private dir must be excluded")
	}
}

// A user is included only when the operator asked for it.
func TestPerUserHomeRules(t *testing.T) {
	users := []User{
		{Name: "keeper", HomePath: "/home/keeper"},
		{Name: "other", HomePath: "/home/other"},
		{Name: "daemon", HomePath: "/var/lib/daemon", IsSystem: true},
	}

	// Nobody opted in: every non-system home is excluded.
	list := BuildBackupExcludes(ExcludeInput{Users: users})
	if indexOfPattern(list, "/home/keeper/**") < 0 || indexOfPattern(list, "/home/other/**") < 0 {
		t.Error("homes with no include rule must be excluded")
	}
	if indexOfPattern(list, "/var/lib/daemon/**") >= 0 {
		t.Error("a system account's home must not get a rule of its own")
	}

	// keeper opted in: no blanket exclusion is added for that home.
	list = BuildBackupExcludes(ExcludeInput{
		UserPatterns: []string{"+ /home/keeper/**"},
		Users:        users,
	})
	if indexOfPattern(list, "/home/keeper/**") >= 0 {
		t.Error("a home with an include rule must not also be excluded")
	}
	if indexOfPattern(list, "/home/other/**") < 0 {
		t.Error("the other home should still be excluded")
	}

	// Hidden-files-only counts as opting in too.
	list = BuildBackupExcludes(ExcludeInput{
		UserPatterns: []string{"+ /home/keeper/.**"},
		Users:        users,
	})
	if indexOfPattern(list, "/home/keeper/**") >= 0 {
		t.Error("an include-hidden rule must also suppress the blanket exclusion")
	}
}

// "/home/*/**" not "/home/**": the latter would ignore include filters under
// /home, so a user who asked to keep their home would lose it anyway.
func TestBlanketHomeRuleShape(t *testing.T) {
	list := BuildBackupExcludes(ExcludeInput{})
	if indexOfPattern(list, "/home/*/**") < 0 {
		t.Error("the blanket home rule is missing or the wrong shape")
	}
	if indexOfPattern(list, "/home/**") >= 0 {
		t.Error("/home/** would defeat every include filter under /home")
	}
}

func TestForeignMountPoints(t *testing.T) {
	cases := map[string]bool{
		"/data":        true,
		"/srv/backups": false, // under /srv, a system prefix
		"/mnt/disk":    false,
		"/":            false,
		"/home/u":      false,
		"/scratch":     true,
		"relative":     false,
		"":             false,
	}
	for mp, want := range cases {
		if got := IsForeignMountPoint(mp); got != want {
			t.Errorf("IsForeignMountPoint(%q) = %v, want %v", mp, got, want)
		}
	}

	list := BuildBackupExcludes(ExcludeInput{ForeignMountPoints: []string{"/data2"}})
	if indexOfPattern(list, "/data2/*") < 0 {
		t.Error("a foreign mount point was not excluded")
	}
}

func TestNoDuplicates(t *testing.T) {
	list := BuildBackupExcludes(ExcludeInput{
		// Deliberately colliding with a default.
		UserPatterns: []string{"/dev/*", "/dev/*", "/tmp/*"},
		SwapFiles:    []string{"/swapfile"},
	})
	seen := map[string]int{}
	for _, p := range list {
		seen[p]++
	}
	for p, n := range seen {
		if n > 1 {
			t.Errorf("%q appears %d times", p, n)
		}
	}
}

// A "+" rule on a restore would pull in a path the snapshot does not contain,
// and --delete would then remove it from the target.
func TestRestoreListDropsIncludes(t *testing.T) {
	backup := []string{"+ /home/u/**", "/dev/*", "/tmp/*"}
	snapshot := []string{"/var/cache/*", "/dev/*"}

	list := BuildRestoreExcludes(backup, snapshot)

	for _, p := range list {
		if strings.HasPrefix(p, "+ ") {
			t.Errorf("an include rule survived into the restore list: %q", p)
		}
	}
	// The snapshot's own list is merged: what was excluded when it was taken is
	// not in it, and must not be deleted from the target now.
	if indexOfPattern(list, "/var/cache/*") < 0 {
		t.Error("the snapshot's recorded excludes were not merged in")
	}
	if indexOfPattern(list, "/dev/*") < 0 {
		t.Error("a shared rule was lost")
	}
	seen := map[string]int{}
	for _, p := range list {
		seen[p]++
	}
	if seen["/dev/*"] != 1 {
		t.Errorf("/dev/* appears %d times after merging", seen["/dev/*"])
	}
}

func TestExcludeFileContents(t *testing.T) {
	got := ExcludeFileContents([]string{"/a", "/b"})
	if got != "/a\n/b\n" {
		t.Errorf("contents = %q", got)
	}
	if ExcludeFileContents(nil) != "" {
		t.Error("an empty list must produce an empty file")
	}
}
