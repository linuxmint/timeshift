package restore

import (
	"fmt"
	"strings"

	"github.com/makeafide/timeshift/src-go/internal/fsutil"
)

/* The finish script: everything after the files are in place.
 *
 * This half does not care which engine produced the files, which is why it
 * lives here rather than in an engine. Restoring a btrfs subvolume and
 * restoring an rsync tree both end with the same question -- does this system
 * boot -- and the same answer: chroot in, reinstall the bootloader, rebuild the
 * initramfs, regenerate the menu, run the hooks.
 *
 * Every step is guarded by ts_step, which announces failures instead of
 * swallowing them. In the original these ran unguarded and the script's status
 * was whatever the last command happened to return, so a grub-install that
 * failed on a half-restored target was completely invisible.
 *
 * Which tool to use is decided by asking the RESTORED system what it has, not
 * by reading its distro id. The distro test used to run before rsync, when a
 * freshly formatted target has no /etc/lsb-release to read, so it silently took
 * the generic branch every time.
 */

// FinishScriptOptions describe the system-repair half of a restore.
type FinishScriptOptions struct {
	// TargetPath is where the restored system is mounted, with a trailing
	// slash. Empty means the running system, and no chroot.
	TargetPath string

	// CurrentSystem means the restore overwrote the running system, so the
	// script ends by rebooting.
	CurrentSystem bool

	// StepLogFile collects each step's own output, beside the rsync log on the
	// restored system so it survives the reboot. ts_step used to record only
	// an exit code, so when grub-install failed the one line saying WHY --
	// "cannot find EFI directory" -- was never written anywhere.
	StepLogFile string

	// ReinstallGrub and GrubDevice control the bootloader step.
	ReinstallGrub bool
	GrubDevice    string

	// NeedsESP means the snapshot's fstab has a /boot/efi entry, so the
	// bootloader step must check one is actually mounted first.
	NeedsESP bool

	UpdateInitramfs bool
	UpdateGrubMenu  bool

	// HooksDir is run with run-parts at the end.
	HooksDir string
}

// DefaultHooksDir is where post-restore scripts live.
const DefaultHooksDir = "/etc/timeshift/restore-hooks.d"

// FinishPhases are the steps the finish script announces, in the order it
// announces them.
//
// The list is built from the same options that build the script, so the
// checklist a client draws lists exactly the steps that will run -- not every
// step that could.
func FinishPhases(o FinishScriptOptions) []Phase {
	var phases []Phase

	/* The same condition the script uses, not merely !CurrentSystem. A
	 * checklist that promises a step the script will not run is worse than no
	 * checklist: the reader waits for something that is never coming.
	 *
	 * Two of these steps happen in Go rather than in shell, and the user waits
	 * through them, so they belong in the list even though no marker announces
	 * them. */
	toTarget := !o.CurrentSystem && o.TargetPath != ""
	if toTarget {
		phases = append(phases,
			Phase{Key: "fix_fstab", Title: "Updating fstab and crypttab"},
			Phase{Key: "parse_log", Title: "Parsing log file"},
			Phase{Key: "chroot_bind", Title: "Preparing target system"})
	}
	if o.ReinstallGrub && o.GrubDevice != "" {
		phases = append(phases, Phase{Key: "grub_install", Title: "Re-installing GRUB2 bootloader"})
	}
	if o.UpdateInitramfs {
		phases = append(phases, Phase{Key: "initramfs", Title: "Rebuilding initramfs"})
	}
	if o.UpdateGrubMenu {
		phases = append(phases, Phase{Key: "grub_menu", Title: "Updating GRUB menu"})
	}
	phases = append(phases, Phase{Key: "fs_sync", Title: "Syncing file systems"})
	if toTarget {
		phases = append(phases, Phase{Key: "cleanup", Title: "Cleaning up"})
	}
	phases = append(phases, Phase{Key: "hooks", Title: "Running post-restore scripts"})
	if o.CurrentSystem {
		phases = append(phases, Phase{Key: "reboot", Title: "Restarting"})
	}
	return phases
}

// BuildFinishScript generates the system-repair script.
func BuildFinishScript(o FinishScriptOptions) string {
	var b strings.Builder

	chroot := ""
	if !o.CurrentSystem && o.TargetPath != "" {
		chroot = fmt.Sprintf("chroot %q", strings.TrimSuffix(o.TargetPath, "/"))
	}

	fmt.Fprintf(&b, "TS_STEP_LOG=%s\n", fsutil.ShellQuote(o.StepLogFile))
	b.WriteString("mkdir -p \"$(dirname \"$TS_STEP_LOG\")\" 2>/dev/null\n")

	b.WriteString("ts_step() {\n")
	b.WriteString("  ts_key=$1; shift\n")
	// tee, so the output reaches the progress pane as well as the log.
	b.WriteString("  \"$@\" 2>&1 | tee -a \"$TS_STEP_LOG\"\n")
	b.WriteString("  ts_rc=${PIPESTATUS[0]}\n")
	b.WriteString("  if [ $ts_rc -ne 0 ]; then\n")
	b.WriteString("    echo \"$ts_key failed with exit code $ts_rc\" >> \"$TS_STEP_LOG\"\n")
	fmt.Fprintf(&b, "    echo '%s'\"$ts_key:$ts_rc\"\n", StepFailedMarker)
	b.WriteString("  fi\n")
	b.WriteString("  return $ts_rc\n")
	b.WriteString("}\n")

	// Does the RESTORED system have this command?
	b.WriteString("ts_has() {\n")
	fmt.Fprintf(&b, "  %s sh -c \"command -v $1 >/dev/null 2>&1\"\n", chroot)
	b.WriteString("}\n")

	if !o.CurrentSystem && o.TargetPath != "" {
		b.WriteString(phaseMarker("chroot_bind"))

		/* --rbind, not --bind: /sys/firmware/efi/efivars is a mount of its own
		 * beneath /sys, and without it grub-install inside the chroot reports
		 * "EFI variables are not supported on this system" and quietly skips
		 * the UEFI boot entry -- leaving a disk the firmware will not boot. */
		fmt.Fprintf(&b,
			"for i in dev dev/pts proc run sys; do mount --rbind \"/$i\" \"%s$i\" 2>/dev/null || mount --bind \"/$i\" \"%s$i\"; done \n",
			o.TargetPath, o.TargetPath)

		// Without a shell in the target every chroot below fails one by one
		// with a confusing error each. Say it once, plainly.
		fmt.Fprintf(&b, "if [ ! -e \"%sbin/sh\" ] && [ ! -e \"%susr/bin/sh\" ]; then \n",
			o.TargetPath, o.TargetPath)
		fmt.Fprintf(&b, "  echo '%s'\"chroot_bind:1\"\n", StepFailedMarker)
		b.WriteString("  echo 'The restored system has no shell; the boot loader steps cannot run.' \n")
		b.WriteString("fi \n")
	}

	if o.ReinstallGrub && o.GrubDevice != "" {
		b.WriteString("sync \n")
		b.WriteString("echo '' \n")
		b.WriteString(phaseMarker("grub_install"))
		b.WriteString("echo 'Re-installing GRUB2 bootloader...' \n")

		/* grub-install resolves --efi-directory to <target>/boot/efi and
		 * requires it to be a mount point on a FAT filesystem. When it is
		 * merely a directory -- which is what a restore with no ESP assigned
		 * produces -- it aborts with "cannot find EFI directory" and returns a
		 * bare 1, with no hint which of its many failure modes was hit. */
		espGuard := o.NeedsESP && !o.CurrentSystem
		if espGuard {
			esp := o.TargetPath + "boot/efi"
			fmt.Fprintf(&b, "if ! mountpoint -q %s; then \n", fsutil.ShellQuote(esp))
			fmt.Fprintf(&b, "  echo '%s'\"grub_install:1\"\n", StepFailedMarker)
			b.WriteString("  echo 'No EFI System Partition is mounted at /boot/efi; the boot loader cannot be installed.' \n")
			b.WriteString("else \n")
		}

		b.WriteString("if ts_has grub-install; then \n")
		fmt.Fprintf(&b, "  ts_step grub_install %s grub-install --recheck --force %s \n", chroot, o.GrubDevice)
		b.WriteString("elif ts_has grub2-install; then \n")
		fmt.Fprintf(&b, "  ts_step grub_install %s grub2-install --recheck --force %s \n", chroot, o.GrubDevice)
		b.WriteString("else \n")
		fmt.Fprintf(&b, "  echo '%s'\"grub_install:127\"\n", StepFailedMarker)
		b.WriteString("  echo 'grub-install was not found in the restored system.' \n")
		b.WriteString("fi \n")

		if espGuard {
			b.WriteString("fi \n")
		}
	}

	if o.UpdateInitramfs {
		b.WriteString("echo '' \n")
		b.WriteString(phaseMarker("initramfs"))
		b.WriteString("echo 'Generating initramfs...' \n")

		/* dracut first, and explicitly --no-hostonly.
		 *
		 * On Ubuntu 26.04 update-initramfs is only a shim over dracut with no
		 * way to ask for a non-hostonly image -- and a hostonly rebuild here
		 * would be doubly wrong, because dracut would read the bind-mounted
		 * /proc, /sys and /dev of the RECOVERY environment and bake those
		 * devices in instead of the target's. */
		b.WriteString("if ts_has dracut; then \n")
		fmt.Fprintf(&b, "  ts_step initramfs %s dracut --force --no-hostonly --regenerate-all \n", chroot)
		b.WriteString("elif ts_has update-initramfs; then \n")
		fmt.Fprintf(&b, "  ts_step initramfs %s update-initramfs -u -k all \n", chroot)
		b.WriteString("elif ts_has mkinitcpio; then \n")
		// The glob has to expand inside the target, not out here.
		fmt.Fprintf(&b, "  ts_step initramfs %s sh -c 'mkinitcpio -p /etc/mkinitcpio.d/*.preset' \n", chroot)
		b.WriteString("else \n")
		fmt.Fprintf(&b, "  echo '%s'\"initramfs:127\"\n", StepFailedMarker)
		b.WriteString("  echo 'No initramfs tool was found in the restored system.' \n")
		b.WriteString("fi \n")
	}

	if o.UpdateGrubMenu {
		b.WriteString("echo '' \n")
		b.WriteString(phaseMarker("grub_menu"))
		b.WriteString("echo 'Updating GRUB menu...' \n")

		/* A flat if/elif chain. The original was "if (redhat) ... if (arch) ...
		 * else ...", where the else bound to the arch test -- so a redhat
		 * target ran grub2-mkconfig AND update-grub. */
		b.WriteString("if ts_has update-grub; then \n")
		fmt.Fprintf(&b, "  ts_step grub_menu %s update-grub \n", chroot)
		b.WriteString("elif ts_has grub2-mkconfig; then \n")
		fmt.Fprintf(&b, "  ts_step grub_menu %s grub2-mkconfig -o /boot/grub2/grub.cfg \n", chroot)
		b.WriteString("elif ts_has grub-mkconfig; then \n")
		fmt.Fprintf(&b, "  ts_step grub_menu %s grub-mkconfig -o /boot/grub/grub.cfg \n", chroot)
		b.WriteString("else \n")
		fmt.Fprintf(&b, "  echo '%s'\"grub_menu:127\"\n", StepFailedMarker)
		b.WriteString("  echo 'No GRUB configuration tool was found in the restored system.' \n")
		b.WriteString("fi \n")

		b.WriteString("sync \n")
		b.WriteString("echo '' \n")
	}

	b.WriteString(phaseMarker("fs_sync"))
	b.WriteString("echo 'Syncing file systems...' \n")
	b.WriteString("sync ; sleep 10s; \n")
	b.WriteString("echo '' \n")

	if !o.CurrentSystem && o.TargetPath != "" {
		b.WriteString(phaseMarker("cleanup"))
		b.WriteString("echo 'Cleaning up...' \n")
		// -R to match the --rbind above; a leftover submount would keep the
		// target busy and make the unmount-then-fsck step refuse to run.
		fmt.Fprintf(&b,
			"for i in dev/pts dev proc run sys; do umount -R \"%s$i\" 2>/dev/null || umount -f \"%s$i\"; done \n",
			o.TargetPath, o.TargetPath)
		b.WriteString("sync \n")
	}

	hooks := o.HooksDir
	if hooks == "" {
		hooks = DefaultHooksDir
	}
	b.WriteString(phaseMarker("hooks"))
	fmt.Fprintf(&b, "if [ -d %s ]; then \n", fsutil.ShellQuote(hooks))
	fmt.Fprintf(&b, "  ts_step hooks run-parts --verbose %s \n", hooks)
	b.WriteString("fi \n")

	if o.CurrentSystem {
		b.WriteString("echo '' \n")
		b.WriteString(phaseMarker("reboot"))
		b.WriteString("echo 'Rebooting system...' \n")
		b.WriteString("sleep 5s \n")
		b.WriteString("reboot -f \n")
	}

	return b.String()
}
