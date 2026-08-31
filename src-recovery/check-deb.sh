#!/bin/sh
# Verify a built timeshift-recovery .deb is complete and correct.
# Usage: ./check-deb.sh path/to/timeshift-recovery_*.deb
#
# Guards against the failure modes that matter for this package: a helper
# shipped non-executable (the CLI would fail mid-provision, or the refresh
# trigger would silently never run), a missing dpkg trigger (the environment
# would quietly rot behind the installed Timeshift), or the config not
# registered as a conffile (a user's target and hotkey silently reset on
# upgrade).
set -eu

DEB=${1:?usage: check-deb.sh path/to/timeshift-recovery_*.deb}
fail=0
ok()  { printf '  ok      %s\n' "$1"; }
bad() { printf '  FAIL    %s\n' "$1"; fail=1; }

LIST=$(dpkg-deb -c "$DEB")
INFO=$(dpkg-deb -I "$DEB")
CTRL=$(dpkg-deb --ctrl-tarfile "$DEB" | tar -tf - | sed 's|^\./||' | grep -v '^$')

# Required files.
for f in ./usr/sbin/timeshift-recovery \
	./usr/lib/timeshift-recovery/common.sh \
	./usr/lib/timeshift-recovery/build-rootfs \
	./usr/lib/timeshift-recovery/place-payload \
	./usr/lib/timeshift-recovery/grub-entry.in \
	./usr/lib/timeshift-recovery/splash.png \
	./usr/lib/timeshift-recovery/logo.png \
	./etc/timeshift-recovery/config \
	./etc/logrotate.d/timeshift-recovery \
	./usr/lib/systemd/system/timeshift-recovery-refresh.service \
	./usr/share/man/man8/timeshift-recovery.8.gz \
	./usr/share/doc/timeshift-recovery/copyright \
	./usr/share/doc/timeshift-recovery/changelog.gz; do
	printf '%s\n' "$LIST" | grep -q " $f\$" && ok "$f" || bad "MISSING $f"
done

# The CLI and its helpers must be executable, or provisioning dies part-way.
for f in ./usr/sbin/timeshift-recovery \
	./usr/lib/timeshift-recovery/build-rootfs \
	./usr/lib/timeshift-recovery/place-payload; do
	line=$(printf '%s\n' "$LIST" | grep " $f\$" || true)
	case "$line" in
		-rwxr-xr-x*) ok "executable: $f" ;;
		'')          bad "cannot check perms (missing): $f" ;;
		*)           bad "NOT executable: $f ($(printf '%s' "$line" | awk '{print $1}'))" ;;
	esac
done

# The GRUB entry template is fed through sed and installed as /etc/grub.d/42_*,
# which grub-mkconfig only runs if it is executable. Prove the shipped template
# still emits valid GRUB script rather than waiting to find out at boot.
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
if dpkg-deb -x "$DEB" "$TMPD" 2>/dev/null; then
	tmpl=$TMPD/usr/lib/timeshift-recovery/grub-entry.in
	if [ -r "$tmpl" ]; then
		sed -e 's|@HOTKEY@|r|g' -e 's|@UUID@|00000000-0000-0000-0000-000000000000|g' \
		    -e 's|@KERNEL@|/boot/vmlinuz|g' -e 's|@INITRD@|/boot/initrd.img|g' \
		    -e 's|@CMDLINE@|boot=casper quiet splash|g' "$tmpl" > "$TMPD/entry"
		if command -v grub-script-check >/dev/null 2>&1; then
			sh "$TMPD/entry" | grub-script-check 2>/dev/null \
				&& ok "grub-entry.in emits valid GRUB script" \
				|| bad "grub-entry.in emits INVALID GRUB script (would break boot)"
		else
			ok "grub-entry.in present (grub-script-check unavailable, not validated)"
		fi
		# The hotkey is the entire access path; a template that lost it would
		# install an entry nobody can reach without opening the menu by hand.
		sh "$TMPD/entry" | grep -q -- '--hotkey=r' \
			&& ok "menuentry carries the hotkey" \
			|| bad "menuentry has no --hotkey (the recovery key would do nothing)"
	else
		bad "grub-entry.in not extractable"
	fi

	# Shell syntax of everything we ship, so a typo cannot reach a user's disk.
	for s in usr/sbin/timeshift-recovery usr/lib/timeshift-recovery/common.sh \
		usr/lib/timeshift-recovery/build-rootfs usr/lib/timeshift-recovery/place-payload; do
		if [ -r "$TMPD/$s" ]; then
			sh -n "$TMPD/$s" 2>/dev/null && ok "sh -n: $s" || bad "SYNTAX ERROR: $s"
		fi
	done
fi

# The dpkg trigger is what keeps the environment current. Without it the
# package still installs and still works, and silently goes stale.
if printf '%s\n' "$CTRL" | grep -qx triggers; then
	TRIG=$(dpkg-deb --ctrl-tarfile "$DEB" | tar -xOf - ./triggers 2>/dev/null || true)
	printf '%s\n' "$TRIG" | grep -q '/usr/bin/timeshift' \
		&& ok "trigger on the timeshift binaries" \
		|| bad "triggers file present but does not watch /usr/bin/timeshift"
else
	bad "no triggers member -- the environment would never refresh itself"
fi

# Every documented config key must actually ship, or a user setting it in
# /etc silently does nothing. This list must grow with load_config().
if [ -r "$TMPD/etc/timeshift-recovery/config" ]; then
	for key in TARGET SIZE HOTKEY HOTKEY_STYLE TIMEOUT SCALE HINT EMBED_SSH_KEY \
		TORAM FIRMWARE EMBED_WIFI_CREDS EMBED_TAILSCALE_STATE EXTRA_PACKAGES; do
		grep -qE "^$key=" "$TMPD/etc/timeshift-recovery/config" \
			&& ok "config key: $key" || bad "config key missing: $key"
	done
	# The config is sourced as /bin/sh; a syntax error would kill every command.
	sh -n "$TMPD/etc/timeshift-recovery/config" 2>/dev/null \
		&& ok "sh -n: etc/timeshift-recovery/config" \
		|| bad "SYNTAX ERROR: etc/timeshift-recovery/config"
fi

# The config must be a conffile or a user's target/hotkey resets on upgrade.
if printf '%s\n' "$CTRL" | grep -qx conffiles; then
	dpkg-deb -I "$DEB" conffiles 2>/dev/null | grep -qx /etc/timeshift-recovery/config \
		&& ok "conffile: /etc/timeshift-recovery/config" \
		|| bad "not a conffile: /etc/timeshift-recovery/config"
else
	bad "no conffiles member -- the config would be overwritten silently on upgrade"
fi

# postrm must clean up the GRUB files the CLI wrote. dpkg does not know about
# them, so without this a removed package leaves a boot entry pointing nowhere.
POSTRM=$(dpkg-deb --ctrl-tarfile "$DEB" | tar -xOf - ./postrm 2>/dev/null || true)
printf '%s\n' "$POSTRM" | grep -q '42_timeshift_recovery' \
	&& ok "postrm removes the GRUB entry" \
	|| bad "postrm does not remove /etc/grub.d/42_timeshift_recovery"

# postinst is what tightens artifact permissions on upgrade and reacts to the
# refresh trigger; its absence would be silent.
printf '%s\n' "$CTRL" | grep -qx postinst \
	&& ok "postinst present" || bad "no postinst member"

# Control metadata.
printf '%s\n' "$INFO" | grep -q '^ Package: timeshift-recovery$' && ok "Package: timeshift-recovery" || bad "wrong Package name"
printf '%s\n' "$INFO" | grep -q 'Depends:.*timeshift'   && ok "Depends: timeshift"      || bad "missing Depends on timeshift"
printf '%s\n' "$INFO" | grep -q 'Depends:.*grub2-common' && ok "Depends: grub2-common"  || bad "missing Depends on grub2-common"
printf '%s\n' "$INFO" | grep -q 'Recommends:.*mmdebstrap' && ok "Recommends: mmdebstrap" || bad "missing Recommends: mmdebstrap"
# The native-resolution splash render (the sharp path) needs ImageMagick.
printf '%s\n' "$INFO" | grep -q 'Suggests:.*imagemagick' && ok "Suggests: imagemagick" || bad "missing Suggests: imagemagick"

echo
if [ "$fail" -eq 0 ]; then
	echo "verification passed: $DEB"
else
	echo "VERIFICATION FAILED: $DEB" >&2
	exit 1
fi
