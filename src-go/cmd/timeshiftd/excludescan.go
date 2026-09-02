package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"

	tsengine "github.com/makeafide/timeshift/src-go/internal/engines/timeshift"
	"github.com/makeafide/timeshift/src-go/internal/restore"
)

/* The machine-derived half of the exclude list.
 *
 * BuildBackupExcludes takes four inputs and only one of them -- the operator's
 * own patterns -- comes from the config. The other three describe the machine,
 * and until this file existed nothing produced them: the daemon passed
 * UserPatterns alone, so every backup was taken with SwapFiles,
 * ForeignMountPoints and Users empty.
 *
 * That was invisible because the package tests construct ExcludeInput
 * themselves, so they exercised the fields the product never filled. A test
 * whose only caller is the test proves the function, not the behaviour -- which
 * is why the daemon-level test beside this file asserts that a scanned value
 * reaches the finished list.
 *
 * The two that cost real bytes:
 *
 *   - A swap file is copied in full, every time, and it is dirty on every run.
 *     DefaultExcludes names /swapfile and /swap.img, so the common cases were
 *     covered by luck; a swap file anywhere else was not.
 *   - A foreign mount point is descended into. rsync is not given
 *     --one-file-system, so a data disk mounted outside /media, /mnt or /data
 *     was copied into the snapshot in its entirety.
 */

// excludeScanner reads the system files the exclude list is derived from.
//
// root is "" in production. Tests point it at a temporary tree, which is the
// only way to exercise an ecryptfs home or a foreign mount on a machine that
// has neither.
type excludeScanner struct{ root string }

func (s excludeScanner) path(p string) string {
	if s.root == "" {
		return p
	}
	return filepath.Join(s.root, p)
}

func (s excludeScanner) read(p string) string {
	b, err := os.ReadFile(s.path(p))
	if err != nil {
		return ""
	}
	return string(b)
}

// input assembles everything BuildBackupExcludes needs.
func (s excludeScanner) input(userPatterns []string) tsengine.ExcludeInput {
	return tsengine.ExcludeInput{
		UserPatterns:       userPatterns,
		Users:              s.users(),
		SwapFiles:          s.swapFiles(),
		ForeignMountPoints: s.foreignMountPoints(),
	}
}

/* swapFiles returns the file-backed swap areas in use.
 *
 * Swap PARTITIONS are skipped: only a file can end up inside a snapshot. The
 * type is the second column, and it is the only thing separating the two. */
func (s excludeScanner) swapFiles() []string {
	var out []string
	for i, line := range strings.Split(s.read("/proc/swaps"), "\n") {
		if i == 0 {
			continue // the header
		}
		f := strings.Fields(line)
		if len(f) < 2 || f[1] != "file" {
			continue
		}
		if strings.HasPrefix(f[0], "/") {
			out = append(out, f[0])
		}
	}
	return out
}

/* foreignMountPoints returns the fstab mount points that are not part of the
 * system. IsForeignMountPoint holds the prefix list, so the rule lives with the
 * rules it belongs to rather than here. */
func (s excludeScanner) foreignMountPoints() []string {
	var out []string
	seen := map[string]bool{}
	for _, e := range restore.ParseFsTab(s.read("/etc/fstab")) {
		if e.IsComment || e.IsBlank || seen[e.MountPoint] {
			continue
		}
		if tsengine.IsForeignMountPoint(e.MountPoint) {
			seen[e.MountPoint] = true
			out = append(out, e.MountPoint)
		}
	}
	return out
}

// users returns the accounts, with their eCryptfs state resolved.
func (s excludeScanner) users() []tsengine.User {
	var out []tsengine.User
	for _, line := range strings.Split(s.read("/etc/passwd"), "\n") {
		f := strings.Split(strings.TrimSpace(line), ":")
		if len(f) < 6 || f[0] == "" {
			continue
		}
		uid, err := strconv.Atoi(f[2])
		if err != nil {
			continue
		}
		u := tsengine.User{
			Name:     f[0],
			HomePath: strings.TrimSpace(f[5]),
			/* nobody is 65534 and is not a login account. Everything below
			 * 1000 except root is a service account. */
			IsSystem: (uid != 0 && uid < 1000) || uid == 65534,
		}
		if u.HomePath != "" && !u.IsSystem {
			s.resolveEncryption(&u)
		}
		out = append(out, u)
	}
	return out
}

/* resolveEncryption fills in the eCryptfs flags.
 *
 * Two different files, and they mean different things. The one under
 * /home/.ecryptfs/<name>/ names the mount point of the user's whole home; the
 * one under the home itself names a ~/Private-style mount. Only the first makes
 * the home unusable to copy. */
func (s excludeScanner) resolveEncryption(u *tsengine.User) {
	for _, p := range s.mountPaths("/home/.ecryptfs/" + u.Name + "/.ecryptfs/Private.mnt") {
		if p == u.HomePath {
			u.HasEncryptedHome = true
		}
	}
	for _, p := range s.mountPaths(u.HomePath + "/.ecryptfs/Private.mnt") {
		if p != u.HomePath {
			u.EncryptedPrivateDirs = append(u.EncryptedPrivateDirs, p)
		}
	}
}

func (s excludeScanner) mountPaths(file string) []string {
	var out []string
	for _, line := range strings.Split(s.read(file), "\n") {
		if p := strings.TrimSpace(line); p != "" {
			out = append(out, p)
		}
	}
	return out
}
