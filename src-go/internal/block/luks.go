package block

import (
	"context"
	"errors"
	"fmt"
	"strings"
)

/* Unlocking a LUKS container.
 *
 * The passphrase goes to cryptsetup on STDIN, never in argv. As an argument it
 * would sit in /proc/<pid>/cmdline for the life of the process, readable by
 * anything on the machine -- and the Vala version reached the same conclusion
 * by a longer route, piping `echo -n -e '<pass>'` through a generated shell
 * script, which additionally put the passphrase through single-quote escaping
 * one missed call away from a shell injection.
 *
 * Nothing here logs the passphrase, or an error string that might contain it.
 */

// ErrNotEncrypted reports a device that is not a LUKS container.
var ErrNotEncrypted = errors.New("block: this device is not encrypted")

// ErrWrongPassphrase reports cryptsetup's "no key available" exit.
var ErrWrongPassphrase = errors.New("block: wrong passphrase")

// ErrNoPassphrase reports an unlock attempted with nothing to try.
var ErrNoPassphrase = errors.New("block: no passphrase supplied")

// Unlocker opens LUKS containers.
type Unlocker struct {
	Runner Runner
}

/* Unlock opens a LUKS container and returns the device-mapper name holding it.
 *
 * A NAME rather than a *Device, because the mapper device does not exist in the
 * listing that was passed in -- it is created by this call. The caller rescans
 * and looks it up, which is also what makes the already-open path and the
 * just-unlocked path return the same shape of answer.
 *
 * An already-unlocked container is success, not an error: the caller wants a
 * usable device, and refusing because someone else got there first would make
 * two clients unlocking the same disk a failure for the second.
 */
func (u *Unlocker) Unlock(ctx context.Context, devices []*Device, target *Device, mappedName, passphrase string) (mapper string, alreadyOpen bool, err error) {
	if target == nil || !isLUKS(target) {
		return "", false, ErrNotEncrypted
	}

	// Already open? Its mapper device is a child in the current listing.
	if open := unlockedChild(devices, target); open != nil {
		/* lsblk's NAME for a mapper device is the mapper name -- "sda3_crypt"
		 * -- while KNAME is the kernel's "dm-1". The mapper name is what
		 * /dev/mapper holds and what a caller can act on. */
		name := open.Name
		if name == "" {
			name = open.KName
		}
		return name, true, nil
	}

	if passphrase == "" {
		/* Refuse rather than prompt. A daemon has no terminal, and cryptsetup
		 * with no key file would sit waiting on one that will never answer --
		 * which is a hang, not a failure, and a hang is what nobody can
		 * diagnose. A client that can ask a person sends the answer. */
		return "", false, ErrNoPassphrase
	}

	name := mappedName
	if name == "" {
		// The name Device.vala has always used, so a container unlocked by
		// either build appears under the same mapper path.
		name = target.KName + "_crypt"
	}
	if err := validMapperName(name); err != nil {
		return "", false, err
	}

	code, _, stderr, err := u.Runner.Run(ctx,
		[]string{"cryptsetup", "luksOpen", "--key-file", "-", target.Path, name},
		passphrase)
	if err != nil {
		return "", false, err
	}
	if code != 0 {
		/* cryptsetup exits 2 for "no key available with this passphrase",
		 * which is the one failure worth naming: it is the user's to fix, and
		 * every other code is ours. */
		if code == 2 {
			return "", false, ErrWrongPassphrase
		}
		msg := strings.TrimSpace(firstLineOf(stderr))
		if msg == "" {
			msg = fmt.Sprintf("cryptsetup exited %d", code)
		}
		return "", false, fmt.Errorf("block: could not unlock %s: %s", target.Path, msg)
	}

	return name, false, nil
}

// Lock closes an unlocked container.
func (u *Unlocker) Lock(ctx context.Context, mappedName string) error {
	if err := validMapperName(mappedName); err != nil {
		return err
	}
	code, _, stderr, err := u.Runner.Run(ctx, []string{"cryptsetup", "luksClose", mappedName}, "")
	if err != nil {
		return err
	}
	if code != 0 {
		return fmt.Errorf("block: could not lock %s: %s", mappedName, strings.TrimSpace(firstLineOf(stderr)))
	}
	return nil
}

// isLUKS reports a raw container, locked or not.
func isLUKS(d *Device) bool {
	return strings.Contains(d.FSType, "luks") || strings.Contains(d.FSType, "crypt")
}

// unlockedChild finds the mapper device sitting on a container, if it is open.
func unlockedChild(devices []*Device, target *Device) *Device {
	for _, d := range devices {
		if d.PKName != "" && d.PKName == target.KName {
			return d
		}
	}
	return nil
}

/* validMapperName refuses anything that is not a plain device-mapper name.
 *
 * It becomes a path under /dev/mapper/, so a name containing a slash or ".."
 * chooses where the node lands. cryptsetup would very likely refuse too, but
 * "very likely" is not the standard for something that runs as root on a value
 * that arrived over a socket.
 */
func validMapperName(name string) error {
	if name == "" || name == "." || name == ".." {
		return fmt.Errorf("block: %q is not a mapper name", name)
	}
	for _, r := range name {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		case r == '-' || r == '_' || r == '.' || r == '+':
		default:
			return fmt.Errorf("block: %q is not a mapper name", name)
		}
	}
	return nil
}

func firstLineOf(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}
