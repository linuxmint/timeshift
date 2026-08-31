#!/bin/sh
# Verify a built apt-snapshot-guard .deb is complete and correct.
# Usage: ./check-deb.sh path/to/apt-snapshot-guard_*.deb
#
# Guards against the failure modes that matter for this package: a missing hook
# helper, a helper shipped non-executable (the hook would silently never run),
# the /etc files not registered as conffiles (overwritten on upgrade), or a
# maintainer script sneaking in (this package has none by design).
set -eu

DEB=${1:?usage: check-deb.sh path/to/apt-snapshot-guard_*.deb}
fail=0
ok()  { printf '  ok      %s\n' "$1"; }
bad() { printf '  FAIL    %s\n' "$1"; fail=1; }

LIST=$(dpkg-deb -c "$DEB")
INFO=$(dpkg-deb -I "$DEB")
CTRL=$(dpkg-deb --ctrl-tarfile "$DEB" | tar -tf - | sed 's|^\./||' | grep -v '^$')

# Required files.
for f in ./etc/apt/apt.conf.d/05snapshot-guard \
	./etc/apt-snapshot-guard/config \
	./etc/logrotate.d/apt-snapshot-guard \
	./usr/lib/apt-snapshot-guard/pre-invoke \
	./usr/lib/apt-snapshot-guard/gui-prompt \
	./usr/share/doc/apt-snapshot-guard/copyright \
	./usr/share/doc/apt-snapshot-guard/changelog.gz; do
	printf '%s\n' "$LIST" | grep -q " $f\$" && ok "$f" || bad "MISSING $f"
done

# The two helpers must be executable, or the hook never fires.
for f in ./usr/lib/apt-snapshot-guard/pre-invoke ./usr/lib/apt-snapshot-guard/gui-prompt; do
	line=$(printf '%s\n' "$LIST" | grep " $f\$" || true)
	case "$line" in
		-rwxr-xr-x*) ok "executable: $f" ;;
		'')          bad "cannot check perms (missing): $f" ;;
		*)           bad "NOT executable: $f ($(printf '%s' "$line" | awk '{print $1}'))" ;;
	esac
done

# Both /etc files must be registered as conffiles.
if printf '%s\n' "$CTRL" | grep -qx conffiles; then
	CONFF=$(dpkg-deb -I "$DEB" conffiles 2>/dev/null)
	for c in /etc/apt/apt.conf.d/05snapshot-guard /etc/apt-snapshot-guard/config; do
		printf '%s\n' "$CONFF" | grep -qx "$c" && ok "conffile: $c" || bad "not a conffile: $c"
	done
else
	bad "no conffiles member -- /etc files would be overwritten silently on upgrade"
fi

# Shell syntax of everything we ship (the helpers are bash, the config is sh).
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
if dpkg-deb -x "$DEB" "$TMPD" 2>/dev/null; then
	for s in usr/lib/apt-snapshot-guard/pre-invoke usr/lib/apt-snapshot-guard/gui-prompt; do
		[ -r "$TMPD/$s" ] || continue
		bash -n "$TMPD/$s" 2>/dev/null && ok "bash -n: $s" || bad "SYNTAX ERROR: $s"
	done
	sh -n "$TMPD/etc/apt-snapshot-guard/config" 2>/dev/null \
		&& ok "sh -n: etc/apt-snapshot-guard/config" \
		|| bad "SYNTAX ERROR: etc/apt-snapshot-guard/config"
fi

# Control metadata.
printf '%s\n' "$INFO" | grep -q '^ Package: apt-snapshot-guard$' && ok "Package: apt-snapshot-guard" || bad "wrong Package name"
printf '%s\n' "$INFO" | grep -q 'Depends:.*timeshift'            && ok "Depends: timeshift"            || bad "missing Depends on timeshift"
printf '%s\n' "$INFO" | grep -q 'Recommends:.*zenity'            && ok "Recommends: zenity"            || bad "missing Recommends: zenity"

# No maintainer scripts (none are needed; one could interfere with apt hooks).
if printf '%s\n' "$CTRL" | grep -Eq '^(preinst|postinst|prerm|postrm)$'; then
	bad "MAINTAINER SCRIPT PRESENT -- none expected for this package:"
	printf '%s\n' "$CTRL" | grep -E '^(preinst|postinst|prerm|postrm)$' | sed 's/^/          /'
else
	ok "no maintainer scripts"
fi

echo
if [ "$fail" -eq 0 ]; then
	echo "verification passed: $DEB"
else
	echo "VERIFICATION FAILED: $DEB" >&2
	exit 1
fi
