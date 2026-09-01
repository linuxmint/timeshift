#!/bin/sh
# Verify a built timeshift-ssh .deb is complete and safe. Usage: ./check-deb.sh path/to/*.deb
#
# The failure mode this guards against is a .deb that builds successfully but is
# silently empty, missing translations, or - the one that matters most - carries
# a maintainer script. This package has none by design: /etc/timeshift/timeshift.json
# and /etc/timeshift/ssh/ (the SSH key) are not owned by the package, and the only
# thing that could reach in and delete them is a postrm someone adds later.
set -eu

DEB=${1:?usage: check-deb.sh path/to/timeshift-ssh_*.deb}
fail=0
ok()  { printf '  ok      %s\n' "$1"; }
bad() { printf '  FAIL    %s\n' "$1"; fail=1; }

LIST=$(dpkg-deb -c "$DEB")
INFO=$(dpkg-deb -I "$DEB")
CTRL=$(dpkg-deb --ctrl-tarfile "$DEB" | tar -tf - | sed 's|^\./||' | grep -v '^$')

# Floor, not a target: the GTK4 port removed 19 bundled images (icons are now
# resolved from the theme), so a complete package is ~97 files.
n=$(printf '%s\n' "$LIST" | grep -c '^-' || true)
[ "$n" -ge 100 ] && ok "file count: $n" || bad "only $n files shipped (looks empty/partial)"

# /usr/bin/timeshift is now the GO CLI; there is no Vala console binary. That
# matters to more than this package: help2man builds timeshift.1 from whatever
# answers `timeshift --help`, apt-snapshot-guard runs it from a fail-closed hook
# that blocks dpkg, and timeshift-recovery's dpkg trigger watches the path.
for f in ./usr/bin/timeshift ./usr/bin/timeshift-gtk ./usr/bin/timeshift-launcher \
	./usr/bin/timeshift-recovery-shell \
	./usr/libexec/timeshift/timeshiftd \
	./usr/share/applications/timeshift-gtk.desktop \
	./usr/share/polkit-1/actions/in.teejeetech.pkexec.timeshift.policy \
	./etc/timeshift/default.json \
	./usr/share/man/man1/timeshift.1.gz ./usr/share/man/man1/timeshift-gtk.1.gz \
	./usr/share/man/man1/timeshift-recovery-shell.1.gz \
	./usr/share/metainfo/com.linuxmint.timeshift.metainfo.xml; do
	printf '%s\n' "$LIST" | grep -q " $f\$" && ok "$f" || bad "MISSING $f"
done

# The CLI must be the Go binary, and must be shipped ONCE.
#
# Both halves have failed silently before. A build that kept installing to
# /usr/libexec as well would ship two CLIs that drift apart, and the one
# apt-snapshot-guard picked would depend on a path check rather than on which
# is current. And a revert of the meson install_dir would put the Vala console
# binary back at /usr/bin/timeshift with everything still "present" -- the file
# list cannot tell them apart, but the size can: Go links its runtime in, so it
# is megabytes where the Vala binary was ~500 KB.
printf '%s\n' "$LIST" | grep -q ' ./usr/libexec/timeshift/timeshift$' \
	&& bad "the CLI is shipped twice (also at /usr/libexec/timeshift/timeshift)" \
	|| ok "the CLI is shipped once"

cli_size=$(printf '%s\n' "$LIST" | awk '$NF == "./usr/bin/timeshift" {print $3}')
if [ -n "${cli_size:-}" ] && [ "$cli_size" -gt 1000000 ]; then
	ok "/usr/bin/timeshift is the Go CLI (${cli_size} bytes)"
else
	bad "/usr/bin/timeshift is ${cli_size:-absent} bytes; expected the Go CLI (>1 MB)"
fi

mo=$(printf '%s\n' "$LIST" | grep -c 'LC_MESSAGES/timeshift\.mo$' || true)
po=$(ls "$(dirname "$0")"/po/*.po 2>/dev/null | wc -l)
[ "$mo" -eq "$po" ] && ok "$mo/$po translations" || bad "$mo/$po translations shipped (gettext missing from Build-Depends?)"

printf '%s\n' "$CTRL" | grep -qx conffiles \
	&& { dpkg-deb -I "$DEB" conffiles 2>/dev/null | grep -qx /etc/timeshift/default.json \
	     && ok "default.json registered as conffile" \
	     || bad "conffiles present but missing /etc/timeshift/default.json"; } \
	|| bad "no conffiles member — default.json would be overwritten silently on upgrade"

# Maintainer scripts exist now -- the systemd unit needs enable/start snippets,
# and postinst creates the socket group and sweeps the obsolete cron drop-ins.
#
# The thing this check was really guarding stays guarded, and more precisely
# than before: NOTHING in a maintainer script may touch /etc/timeshift. That
# directory holds the SSH keys that open the backup repository, and a script
# that removed it on purge would take the only way back to the snapshots with
# it. Naming the directory at all is the failure, whatever the surrounding code
# claims to do with it.
scripts=$(printf '%s\n' "$CTRL" | grep -E '^(preinst|postinst|prerm|postrm)$' || true)
if [ -n "$scripts" ]; then
	touched=""
	for sc in $scripts; do
		if dpkg-deb -I "$DEB" "$sc" 2>/dev/null | grep -q '/etc/timeshift'; then
			touched="$touched $sc"
		fi
	done
	if [ -n "$touched" ]; then
		bad "maintainer script mentions /etc/timeshift (SSH keys live there):$touched"
	else
		ok "maintainer scripts do not touch /etc/timeshift"
	fi
fi

printf '%s\n' "$LIST" | grep -q ' ./usr/lib/systemd/system/timeshiftd.service$' \
	&& ok "timeshiftd.service shipped" \
	|| bad "MISSING timeshiftd.service — nothing would start the daemon"

dpkg-deb -I "$DEB" postinst 2>/dev/null | grep -q 'addgroup --system timeshift' \
	&& ok "postinst creates the timeshift socket group" \
	|| bad "postinst does not create the timeshift group — group members cannot watch a backup"

# The cron sweep. Without it both schedulers fire and two timeshift processes
# take snapshots of the same machine, which is the collision the daemon exists
# to remove.
dpkg-deb -I "$DEB" postinst 2>/dev/null | grep -q '/etc/cron.d/timeshift-hourly' \
	&& ok "postinst retires the obsolete cron drop-ins" \
	|| bad "postinst does not remove /etc/cron.d/timeshift-* — cron would schedule alongside the daemon"

printf '%s\n' "$INFO" | grep -q '^ Package: timeshift-ssh$' && ok "Package: timeshift-ssh" || bad "wrong Package name"
printf '%s\n' "$INFO" | grep -q 'Conflicts:.*timeshift'     && ok "Conflicts: timeshift"    || bad "missing Conflicts: timeshift"
printf '%s\n' "$INFO" | grep -q 'Replaces:.*timeshift'      && ok "Replaces: timeshift"     || bad "missing Replaces: timeshift"
printf '%s\n' "$INFO" | grep -q 'Depends:.*openssh-client'  && ok "Depends: openssh-client" || bad "missing openssh-client"
printf '%s\n' "$INFO" | grep -q 'Recommends:.*sshfs'        && ok "Recommends: sshfs"       || bad "missing Recommends: sshfs"

echo
if [ "$fail" -eq 0 ]; then
	echo "verification passed: $DEB"
else
	echo "VERIFICATION FAILED: $DEB" >&2
	exit 1
fi
