package timeshift

import (
	"strings"
)

/* The exclude list.
 *
 * These are rsync filter rules and ORDER DECIDES THE OUTCOME: rsync takes the
 * first rule that matches a path and stops. Reordering this list changes what
 * gets backed up, silently. The sequence below is the one
 * create_exclude_list_for_backup() produces:
 *
 *   user patterns -> defaults -> extra defaults -> encrypted homes ->
 *   per-user home rules -> the common home rules -> /timeshift/*
 *
 * The per-user rules come BEFORE the common ones for the same reason: an
 * include for one user's home has to be seen before the blanket "/home/x/**"
 * exclusion that would otherwise swallow it.
 */

// DefaultExcludes are the paths never worth snapshotting.
//
// Some entries look arbitrary and are not:
//
//   - /etc/timeshift/* holds the live config AND the SSH private key for a
//     remote repository. Backing it up would put the key inside the very repo it
//     unlocks, readable by anyone with access to the share, and a restore would
//     revert or delete the key and silently break scheduled backups.
//   - /var/cache/timeshift-recovery/* and /var/lib/timeshift-recovery/* are the
//     recovery environment's build cache and placed payload: multiple gigabytes
//     that `timeshift-recovery build` reproduces exactly. Over a remote
//     repository the transfer can exceed apt-snapshot-guard's timeout, and
//     because that guard is fail-closed a timed-out snapshot blocks apt
//     entirely. Restoring them would also be wrong -- the payload must match the
//     Timeshift installed now, not the one current when the snapshot was taken.
//   - The three /snap rules are an include-include-exclude triple. "/snap/*"
//     alone was a kilobyte too broad: besides the read-only squashfs mounts it
//     swept up the only real files snapd keeps there, /snap/bin/* (every snap
//     command is a symlink to /usr/bin/snap) and /snap/<name>/current. Without
//     them a restored system has the payloads and the mounts but no working
//     commands.
var DefaultExcludes = []string{
	"/dev/*",
	"/proc/*",
	"/sys/*",
	"/media/*",
	"/mnt/*",
	"/tmp/*",
	"/run/*",
	"/var/run/*",
	"/var/lock/*",
	"/var/lib/dhcpcd/*",
	"/var/lib/docker/*",
	"/var/lib/schroot/*",
	"/var/cache/timeshift-recovery/*",
	"/var/lib/timeshift-recovery/*",
	"/lost+found",
	"/timeshift/*",
	"/timeshift-btrfs/*",
	"/data/*",
	"/DATA/*",
	"/cdrom/*",
	"/sdcard/*",
	"/system/*",
	"/etc/timeshift.json", // the legacy config path
	"/etc/timeshift/*",
	"/var/log/timeshift/*",
	"/var/log/timeshift-btrfs/*",
	"/swapfile",
	"/swap.img", // Ubuntu's default since 17.04
	"+ /snap/bin/***",
	"+ /snap/*/current",
	"- /snap/*/*",
}

// CacheExcludes are the per-user caches appended after the defaults.
var CacheExcludes = []string{
	"/root/.thumbnails",
	"/root/.cache",
	"/root/.dbus",
	"/root/.gvfs",
	"/root/.local/share/[Tt]rash",
	"/home/*/.thumbnails",
	"/home/*/.cache",
	"/home/*/.dbus",
	"/home/*/.gvfs",
	"/home/*/.local/share/[Tt]rash",
}

// HomeExcludes are the blanket home rules, applied last.
//
// "/home/*/**" rather than "/home/**": the latter would ignore any include
// filter under /home, so a user who asked to keep their home would lose it.
var HomeExcludes = []string{
	"/root/**",
	"/home/*/**",
}

// TimeshiftExclude keeps a repository on the root filesystem from copying
// itself into its own snapshot.
//
// Also present in DefaultExcludes, so adding it again at the end of the list is
// a no-op -- deliberately, and matching the guarded final add() in
// create_exclude_list_for_backup(). It is there so the rule survives somebody
// editing the defaults.
const TimeshiftExclude = "/timeshift/*"

// User describes one account for the purpose of home-directory rules.
type User struct {
	Name     string
	HomePath string
	IsSystem bool

	// HasEncryptedHome means an eCryptfs home, which cannot usefully be
	// rsynced: the plaintext is only visible while the user is logged in, and
	// what is on disk is the encrypted tree.
	HasEncryptedHome bool

	// EncryptedPrivateDirs are ~/Private-style mounts, same problem.
	EncryptedPrivateDirs []string
}

// ExcludeInput is everything the list is built from.
type ExcludeInput struct {
	// UserPatterns are the operator's own rules, from timeshift.json. First,
	// so they win.
	UserPatterns []string

	// Users are the accounts on the system.
	Users []User

	// SwapFiles are the active swap files from /proc/swaps. Copying a swap
	// file wastes exactly its size.
	SwapFiles []string

	// ForeignMountPoints are fstab mount points that are not system
	// directories -- a data disk, a network share. Their contents are not part
	// of the system being snapshotted.
	ForeignMountPoints []string
}

// systemPrefixes are the mount points that ARE part of the system and so are
// not excluded, even when fstab mounts them separately.
var systemPrefixes = []string{
	"/bin", "/boot", "/cdrom", "/dev", "/etc", "/home", "/lib", "/lib64",
	"/media", "/mnt", "/opt", "/proc", "/root", "/run", "/sbin", "/snap",
	"/srv", "/sys", "/system", "/tmp", "/usr", "/var",
}

// IsForeignMountPoint reports whether an fstab mount point should be excluded
// from a snapshot.
func IsForeignMountPoint(mountPoint string) bool {
	if !strings.HasPrefix(mountPoint, "/") || mountPoint == "/" {
		return false
	}
	for _, p := range systemPrefixes {
		if strings.HasPrefix(mountPoint, p) {
			return false
		}
	}
	return true
}

// BuildBackupExcludes assembles the filter list for a backup.
func BuildBackupExcludes(in ExcludeInput) []string {
	var out []string
	seen := map[string]bool{}
	add := func(p string) {
		if p == "" || seen[p] {
			return
		}
		seen[p] = true
		out = append(out, p)
	}

	// The operator's rules first: they must be able to override a default.
	for _, p := range in.UserPatterns {
		add(p)
	}

	for _, p := range DefaultExcludes {
		add(p)
	}
	for _, p := range in.SwapFiles {
		add(p)
	}
	for _, p := range CacheExcludes {
		add(p)
	}
	for _, mp := range in.ForeignMountPoints {
		add(mp + "/*")
	}

	/* An encrypted home is excluded outright and cannot be opted back in:
	 * what is on disk is ciphertext, and copying it produces a snapshot that
	 * restores to an unreadable home. */
	for _, u := range in.Users {
		if u.IsSystem {
			continue
		}
		if u.HasEncryptedHome {
			add(u.HomePath + "/**")
		}
		for _, d := range u.EncryptedPrivateDirs {
			add(d + "/**")
		}
	}

	/* Per-user home rules, before the blanket ones so an include is seen
	 * first. A user is included only if the operator asked for it, by having
	 * "+ /home/u/**" or "+ /home/u/.**" among their own patterns. */
	userPatterns := map[string]bool{}
	for _, p := range in.UserPatterns {
		userPatterns[p] = true
	}
	for _, u := range in.Users {
		if u.IsSystem {
			continue
		}
		excPattern := u.HomePath + "/**"
		incPattern := "+ " + u.HomePath + "/**"
		incHidden := "+ " + u.HomePath + "/.**"
		if u.HasEncryptedHome {
			excPattern = "/home/.ecryptfs/" + u.Name + "/***"
			incPattern = "+ /home/.ecryptfs/" + u.Name + "/***"
		}
		if !userPatterns[incPattern] && !userPatterns[incHidden] {
			add(excPattern)
		}
	}

	for _, p := range HomeExcludes {
		add(p)
	}

	add(TimeshiftExclude)
	return out
}

// BuildRestoreExcludes assembles the filter list for a restore.
//
// Two differences from the backup list, both deliberate. Include filters are
// dropped: on a restore a "+" rule would pull in a path the snapshot does not
// contain, and rsync --delete would then remove it from the target. And the
// snapshot's own recorded exclude list is merged in, because what was excluded
// when the snapshot was taken is not in it and must not be deleted from the
// target now.
func BuildRestoreExcludes(backupList, snapshotList []string) []string {
	var out []string
	seen := map[string]bool{}
	add := func(p string) {
		if p == "" || seen[p] || strings.HasPrefix(p, "+ ") {
			return
		}
		seen[p] = true
		out = append(out, p)
	}
	for _, p := range backupList {
		add(p)
	}
	for _, p := range snapshotList {
		add(p)
	}
	return out
}

// ExcludeFileContents renders the list for rsync --exclude-from: one rule per
// line, trailing newline.
func ExcludeFileContents(list []string) string {
	if len(list) == 0 {
		return ""
	}
	return strings.Join(list, "\n") + "\n"
}
