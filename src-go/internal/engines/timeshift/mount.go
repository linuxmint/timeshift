package timeshift

import (
	"context"
	"fmt"
	"os"
	"path"
	"strings"
)

/* Mounting the repository device.
 *
 * A local repository is identified by a device UUID, and that device is often
 * not mounted -- an external disk plugged in for the occasion, a partition kept
 * unmounted on purpose. Timeshift mounts it itself, under its own run
 * directory, rather than requiring the user to have mounted it first.
 *
 * This lives in the engine rather than in the CLI because both the CLI and the
 * daemon reach a repository through Open(), and a repository that only works
 * when someone else happened to mount it is not a working repository. */

// MountRepoDevice mounts the device with the given UUID under root and returns
// the mount point.
//
// Idempotent in the way that matters: if the device is already mounted at the
// target the existing mount is kept, so two clients opening the same repository
// do not fight over it. That is a deliberate difference from Device.mount(),
// which unmounts the target first unconditionally -- harmless when only one
// process could ever exist, and not something to carry into a daemon that
// expects several.
func MountRepoDevice(ctx context.Context, runner Runner, root, uuid string) (string, bool, error) {
	return MountRepoDeviceOpts(ctx, runner, root, uuid, "")
}

/* BtrfsTopLevelOpts mounts the whole btrfs filesystem rather than its default
 * subvolume.
 *
 * btrfs mode needs this and cannot work without it. `btrfs subvolume snapshot`
 * requires source and destination to be on the SAME filesystem, and the two
 * here are the live "@" and a directory under "timeshift-btrfs/snapshots/".
 * Mounting the device plainly gives whatever subvolume is set as default --
 * on Ubuntu that IS "@" -- so "@" would not be visible as a sibling and the
 * snapshot directory would live inside the very subvolume being snapshotted.
 *
 * subvolid=5 is the filesystem root, which always exists and is never renamed.
 */
const BtrfsTopLevelOpts = "subvolid=5"

// MountRepoDeviceOpts is MountRepoDevice with explicit mount options. An empty
// opts is the same as MountRepoDevice.
func MountRepoDeviceOpts(ctx context.Context, runner Runner, root, uuid, opts string) (string, bool, error) {
	if uuid == "" {
		return "", false, fmt.Errorf("timeshift: no device uuid to mount")
	}
	target := path.Join(root, "backup")

	if already, err := isMountedAt(target, uuid); err == nil && already {
		return target, false, nil
	}

	if err := os.MkdirAll(target, 0755); err != nil {
		return "", false, fmt.Errorf("timeshift: mkdir %s: %w", target, err)
	}

	argv := []string{"mount"}
	if opts != "" {
		argv = append(argv, "-o", opts)
	}
	argv = append(argv, "UUID="+uuid, target)

	code, _, stderr, err := runner.Run(ctx, argv, "")
	if err != nil {
		return "", false, fmt.Errorf("timeshift: mount %s: %w", uuid, err)
	}
	if code != 0 {
		return "", false, fmt.Errorf("timeshift: mount UUID=%s at %s failed: %s",
			uuid, target, strings.TrimSpace(stderr))
	}
	return target, true, nil
}

// UnmountRepoDevice releases a mount this process made.
func UnmountRepoDevice(ctx context.Context, runner Runner, target string) error {
	if target == "" {
		return nil
	}
	code, _, stderr, err := runner.Run(ctx, []string{"umount", target}, "")
	if err != nil {
		return err
	}
	if code != 0 {
		/* EBUSY here is not a failure worth shouting about: a browse mount or
		 * another client may still be using it, and refusing to force it is the
		 * safe behaviour. */
		return fmt.Errorf("timeshift: umount %s: %s", target, strings.TrimSpace(stderr))
	}
	os.Remove(target)
	return nil
}

// isMountedAt reports whether the device with this UUID is already mounted at
// the given path, by resolving the UUID symlink and consulting /proc/mounts.
func isMountedAt(target, uuid string) (bool, error) {
	devPath, err := os.Readlink("/dev/disk/by-uuid/" + uuid)
	if err != nil {
		return false, err
	}
	// The by-uuid entries are relative symlinks: ../../nvme0n1p2.
	resolved := "/dev/" + path.Base(devPath)

	mounts, err := os.ReadFile("/proc/mounts")
	if err != nil {
		return false, err
	}
	for _, line := range strings.Split(string(mounts), "\n") {
		f := strings.Fields(line)
		if len(f) >= 2 && f[0] == resolved && f[1] == target {
			return true, nil
		}
	}
	return false, nil
}
