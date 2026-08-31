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
[ "$n" -ge 92 ] && ok "file count: $n" || bad "only $n files shipped (looks empty/partial)"

for f in ./usr/bin/timeshift ./usr/bin/timeshift-gtk ./usr/bin/timeshift-launcher \
	./usr/bin/timeshift-recovery-shell \
	./usr/share/applications/timeshift-gtk.desktop \
	./usr/share/polkit-1/actions/in.teejeetech.pkexec.timeshift.policy \
	./etc/timeshift/default.json \
	./usr/share/man/man1/timeshift.1.gz ./usr/share/man/man1/timeshift-gtk.1.gz \
	./usr/share/man/man1/timeshift-recovery-shell.1.gz \
	./usr/share/metainfo/com.linuxmint.timeshift.metainfo.xml; do
	printf '%s\n' "$LIST" | grep -q " $f\$" && ok "$f" || bad "MISSING $f"
done

mo=$(printf '%s\n' "$LIST" | grep -c 'LC_MESSAGES/timeshift\.mo$' || true)
po=$(ls "$(dirname "$0")"/po/*.po 2>/dev/null | wc -l)
[ "$mo" -eq "$po" ] && ok "$mo/$po translations" || bad "$mo/$po translations shipped (gettext missing from Build-Depends?)"

printf '%s\n' "$CTRL" | grep -qx conffiles \
	&& { dpkg-deb -I "$DEB" conffiles 2>/dev/null | grep -qx /etc/timeshift/default.json \
	     && ok "default.json registered as conffile" \
	     || bad "conffiles present but missing /etc/timeshift/default.json"; } \
	|| bad "no conffiles member — default.json would be overwritten silently on upgrade"

if printf '%s\n' "$CTRL" | grep -Eq '^(preinst|postinst|prerm|postrm)$'; then
	bad "MAINTAINER SCRIPT PRESENT — audit before shipping: could delete /etc/timeshift/ssh/"
	printf '%s\n' "$CTRL" | grep -E '^(preinst|postinst|prerm|postrm)$' | sed 's/^/          /'
else
	ok "no maintainer scripts (SSH key directory cannot be touched on remove/purge)"
fi

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
