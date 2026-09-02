package main

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

/* These tests assert against the FINISHED list, not against the scanner.
 *
 * The defect they cover was a missing producer: BuildBackupExcludes handled
 * SwapFiles, ForeignMountPoints and Users correctly and had tests proving it,
 * while the daemon passed none of them. Every one of those tests kept passing.
 * So the assertion has to span the seam -- scan a fake system, build the list
 * the way the daemon builds it, and look for the rule in the output.
 */

/* fakeSystem writes the files the scanner reads and returns a daemon pointed at
 * them. It returns the DAEMON, not the scanner, deliberately: the first version
 * of these tests called the scanner directly and passed with the fix reverted,
 * because the bug was never in the scanner -- it was in what the daemon handed
 * to BuildBackupExcludes. Driving d.buildExcludes() is the whole point. */
func fakeSystem(t *testing.T, files map[string]string) *daemon {
	t.Helper()
	root := t.TempDir()
	for name, body := range files {
		p := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return &daemon{scan: excludeScanner{root: root}}
}

// listFor runs the daemon's own exclude assembly over the fake system.
func listFor(d *daemon, userPatterns ...string) []string {
	d.mu.Lock()
	d.cfg.Exclude = userPatterns
	d.mu.Unlock()
	return d.buildExcludes()
}

const swapsHeader = "Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n"

/* A swap file at a non-default path is the case DefaultExcludes misses.
 * /swapfile and /swap.img are named there, so the common layouts were covered
 * by luck and this one was not. */
func TestAnActiveSwapFileIsExcludedWhereverItLives(t *testing.T) {
	d := fakeSystem(t, map[string]string{
		"proc/swaps": swapsHeader +
			"/srv/swapdata                           file            8388604 0       -2\n",
	})

	got := listFor(d)
	if !slices.Contains(got, "/srv/swapdata") {
		t.Fatalf("the active swap file is missing from the exclude list: %v", got)
	}
}

/* A swap PARTITION cannot end up inside a snapshot, and excluding a /dev path
 * would be noise. The type column is the only thing that separates them. */
func TestASwapPartitionIsNotExcluded(t *testing.T) {
	d := fakeSystem(t, map[string]string{
		"proc/swaps": swapsHeader +
			"/dev/nvme0n1p3                          partition       8388604 0       -2\n",
	})

	for _, p := range listFor(d) {
		if p == "/dev/nvme0n1p3" {
			t.Fatal("a swap partition was added to the exclude list")
		}
	}
}

/* A data disk mounted outside /media, /mnt and /data was copied in full: rsync
 * is not given --one-file-system, so nothing else stopped the descent. */
func TestAForeignMountPointIsExcluded(t *testing.T) {
	d := fakeSystem(t, map[string]string{
		"etc/fstab": "# comment\n" +
			"UUID=1111 /               ext4 defaults 0 1\n" +
			"UUID=2222 /games          ext4 defaults 0 2\n" +
			"UUID=3333 /var/lib/thing  ext4 defaults 0 2\n",
	})

	got := listFor(d)
	if !slices.Contains(got, "/games/*") {
		t.Errorf("the foreign mount point is missing: %v", got)
	}
	if slices.Contains(got, "/var/lib/thing/*") {
		t.Error("a mount point under /var is part of the system and must be kept")
	}
	if slices.Contains(got, "//*") {
		t.Error("the root mount point must never be excluded")
	}
}

/* An eCryptfs home holds ciphertext on disk. Copying it produces a snapshot
 * that restores to an unreadable home, so the ciphertext tree is what gets
 * excluded, under its own path rather than the user's. */
func TestAnEncryptedHomeIsExcludedByItsCiphertextPath(t *testing.T) {
	d := fakeSystem(t, map[string]string{
		"etc/passwd": "root:x:0:0:root:/root:/bin/bash\n" +
			"daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n" +
			"alice:x:1000:1000:Alice:/home/alice:/bin/bash\n",
		"home/.ecryptfs/alice/.ecryptfs/Private.mnt": "/home/alice\n",
	})

	got := listFor(d)
	if !slices.Contains(got, "/home/.ecryptfs/alice/***") {
		t.Errorf("the ciphertext tree is missing: %v", got)
	}
	if !slices.Contains(got, "/home/alice/**") {
		t.Errorf("the plaintext mount point is missing: %v", got)
	}
}

/* ~/Private is the same problem in miniature: a separate eCryptfs mount inside
 * a home that is otherwise ordinary. */
func TestAnEncryptedPrivateDirIsExcluded(t *testing.T) {
	d := fakeSystem(t, map[string]string{
		"etc/passwd":                     "bob:x:1001:1001:Bob:/home/bob:/bin/bash\n",
		"home/bob/.ecryptfs/Private.mnt": "/home/bob/Private\n",
	})

	if got := listFor(d); !slices.Contains(got, "/home/bob/Private/**") {
		t.Errorf("the private dir is missing: %v", got)
	}
}

/* A system account has no home worth excluding, and adding one for every
 * service account would bury the real rules. */
func TestSystemAccountsAreSkipped(t *testing.T) {
	d := fakeSystem(t, map[string]string{
		"etc/passwd": "root:x:0:0:root:/root:/bin/bash\n" +
			"daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n" +
			"nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n",
	})

	for _, p := range listFor(d) {
		if p == "/usr/sbin/**" || p == "/nonexistent/**" {
			t.Fatalf("a system account produced an exclude rule: %s", p)
		}
	}
}

/* The operator's own patterns come first and must still win: an explicit
 * include for a home has to survive the blanket rule that follows it. */
func TestAnOperatorIncludeStillWinsOverTheScannedRules(t *testing.T) {
	d := fakeSystem(t, map[string]string{
		"etc/passwd": "carol:x:1000:1000:Carol:/home/carol:/bin/bash\n",
	})

	got := listFor(d, "+ /home/carol/**")
	inc := slices.Index(got, "+ /home/carol/**")
	exc := slices.Index(got, "/home/carol/**")
	if inc != 0 {
		t.Fatalf("the operator's pattern must come first, got index %d: %v", inc, got)
	}
	if exc != -1 && exc < inc {
		t.Fatal("the blanket exclusion preceded the include, which reverses the outcome")
	}
}

/* A machine with none of these files must still produce a usable list rather
 * than failing: a container has no /proc/swaps, and /etc/fstab can be absent. */
func TestAnEmptySystemStillProducesTheDefaults(t *testing.T) {
	d := fakeSystem(t, map[string]string{})

	got := listFor(d)
	if len(got) == 0 {
		t.Fatal("the default rules disappeared")
	}
	if !slices.Contains(got, "/proc/*") {
		t.Errorf("the defaults are missing: %v", got)
	}
}
