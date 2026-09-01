package restore

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

/* Mounting the target.
 *
 * A restore to another device mounts SEVERAL filesystems at nested points --
 * root, then /home, then /boot, then /boot/efi -- under one directory the
 * restore owns, rather than using wherever the user happened to have them
 * mounted. Two reasons, and both have bitten this code:
 *
 *   - The mount points have to nest. /boot/efi must land INSIDE the target's
 *     root mount, or the bootloader step writes into the running system's ESP.
 *   - Ownership has to be unambiguous at the end. The restore unmounts exactly
 *     what it mounted, under a directory nothing else uses, so it can say
 *     truthfully whether the target is unmounted -- which is what gates the
 *     fsck. "fsck -y" on a still-mounted filesystem answers yes to "you WILL
 *     cause SEVERE damage".
 *
 * Order matters and is not the caller's business: parents are mounted before
 * children, so the list is sorted by depth here rather than trusted.
 */

// Runner is the subset of the command runner this package needs.
type Runner interface {
	Run(ctx context.Context, argv []string, dir string) (code int, stdout, stderr string, err error)
}

// Mounter mounts and unmounts the target filesystems.
type Mounter struct {
	Runner Runner

	// Root is the directory the restore mounts under, normally
	// /run/timeshift/<pid>/restore.
	Root string

	// mounted records what this Mounter actually mounted, deepest last, so
	// Unmount can reverse it.
	mounted []string
}

// MountTargets mounts every assigned entry under Root and returns the target
// path with a trailing slash.
//
// On any failure everything already mounted is released before returning: a
// half-mounted target is the state in which a restore writes /home into the
// root filesystem.
func (m *Mounter) MountTargets(ctx context.Context, entries []MountEntry) (string, error) {

	if m.Root == "" {
		return "", fmt.Errorf("restore: no mount root")
	}

	ordered := append([]MountEntry(nil), entries...)
	sort.SliceStable(ordered, func(i, j int) bool {
		return mountDepth(ordered[i].MountPoint) < mountDepth(ordered[j].MountPoint)
	})

	if err := os.MkdirAll(m.Root, 0755); err != nil {
		return "", fmt.Errorf("restore: mkdir %s: %w", m.Root, err)
	}

	for _, e := range ordered {
		if !e.Assigned() {
			continue
		}

		target := filepath.Join(m.Root, e.MountPoint)
		if err := os.MkdirAll(target, 0755); err != nil {
			m.unmountAll(ctx)
			return "", fmt.Errorf("restore: mkdir %s: %w", target, err)
		}

		argv := []string{"mount"}
		if opts := strings.TrimSpace(e.Options); opts != "" {
			argv = append(argv, "-o", opts)
		}
		argv = append(argv, "UUID="+e.DeviceUUID, target)

		code, _, stderr, err := m.Runner.Run(ctx, argv, "")
		if err != nil {
			m.unmountAll(ctx)
			return "", fmt.Errorf("restore: mount %s: %w", e.MountPoint, err)
		}
		if code != 0 {
			m.unmountAll(ctx)
			return "", fmt.Errorf("restore: could not mount UUID=%s at %s: %s",
				e.DeviceUUID, e.MountPoint, strings.TrimSpace(stderr))
		}
		m.mounted = append(m.mounted, target)
	}

	return withTrailingSlash(m.Root), nil
}

/* Unmount releases what this Mounter mounted, deepest first.
 *
 * The return value is the whole point and used to be discarded: it gates the
 * fsck. A target that would not unmount is still in use, and running "fsck -y"
 * on it does severe damage.
 */
func (m *Mounter) Unmount(ctx context.Context) (bool, error) {
	return m.unmountAll(ctx)
}

func (m *Mounter) unmountAll(ctx context.Context) (bool, error) {
	var firstErr error
	allClear := true

	// Deepest first: /boot/efi cannot be released after its parent.
	for i := len(m.mounted) - 1; i >= 0; i-- {
		target := m.mounted[i]

		code, _, stderr, err := m.Runner.Run(ctx, []string{"umount", target}, "")
		if err == nil && code == 0 {
			os.Remove(target)
			continue
		}

		allClear = false
		msg := strings.TrimSpace(stderr)
		if err != nil {
			msg = err.Error()
		}
		if firstErr == nil {
			firstErr = fmt.Errorf("restore: could not unmount %s: %s", target, msg)
		}
	}

	if allClear {
		m.mounted = nil
		os.Remove(m.Root)
	}
	return allClear, firstErr
}

// Mounted reports what is currently mounted, for a caller that needs to check
// the result before deleting anything.
func (m *Mounter) Mounted() []string { return append([]string(nil), m.mounted...) }

// mountDepth counts path components, so parents sort before children.
func mountDepth(p string) int {
	p = strings.Trim(p, "/")
	if p == "" {
		return 0
	}
	return strings.Count(p, "/") + 1
}

func withTrailingSlash(p string) string {
	if strings.HasSuffix(p, "/") {
		return p
	}
	return p + "/"
}
