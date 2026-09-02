#!/bin/sh
# Verify a built timeshift-tray .deb is complete and correct.
# Usage: ./check-deb.sh path/to/timeshift-tray_*.deb
#
# The failures this guards against are the silent ones: a module that will not
# parse (the applet exits on the first import and nothing says so), a helper
# shipped non-executable (pkexec refuses and the menu item does nothing), a
# polkit action naming a program this package does not install (a password
# prompt that can never succeed), or that action quietly widening from the one
# fixed-argument wrapper it is meant to authorise.
set -eu

DEB=${1:?usage: check-deb.sh path/to/timeshift-tray_*.deb}
fail=0
ok()   { printf '  ok      %s\n' "$1"; }
bad()  { printf '  FAIL    %s\n' "$1"; fail=1; }
# A skipped check verified nothing. That is tolerable on a developer's machine
# and not tolerable in a release build, so STRICT=1 turns every skip into a
# failure -- otherwise a builder missing xmllint prints "verification passed"
# having parsed no XML at all.
skip() {
	if [ "${STRICT:-0}" = "1" ]; then
		bad "$1 (STRICT)"
	else
		printf '  skip    %s\n' "$1"
	fi
}

LIST=$(dpkg-deb -c "$DEB")
INFO=$(dpkg-deb -I "$DEB")
CTRL=$(dpkg-deb --ctrl-tarfile "$DEB" | tar -tf - | sed 's|^\./||' | grep -v '^$')

POLICY=usr/share/polkit-1/actions/io.github.makeafide.timeshift-tray.policy
AUTOSTART=etc/xdg/autostart/timeshift-tray.desktop
LAUNCHER=usr/share/applications/timeshift-tray.desktop

# --- required files -----------------------------------------------------------
required="./usr/lib/timeshift-tray/timeshift-tray
./usr/libexec/timeshift-tray/create-snapshot
./usr/libexec/timeshift-tray/grant-access
./usr/libexec/timeshift-tray/revoke-access
./$POLICY
./$AUTOSTART
./$LAUNCHER
./usr/bin/timeshift-tray
./usr/share/man/man1/timeshift-tray.1.gz
./usr/share/doc/timeshift-tray/copyright
./usr/share/doc/timeshift-tray/changelog.gz"
# The modules the applet cannot start without. Everything else is discovered
# from the package itself below, so a module added to the glob is compiled
# without anyone remembering to list it here.
for m in app controller daemonclient dbusmenu gcompat menutree model sni; do
	required="$required
./usr/lib/timeshift-tray/timeshift_tray/$m.py"
done
for f in $required; do
	# " -> " as well as end-of-line: a symlink's row carries its target, so
	# anchoring on the end alone reports a shipped symlink as missing.
	printf '%s\n' "$LIST" | grep -qE " $f( -> .*)?\$" && ok "$f" || bad "MISSING $f"
done

# --- executable bits ----------------------------------------------------------
# pkexec also requires the wrappers to be root-owned and not writable by group
# or other, which is what dh_fixperms plus this 0755 produces.
for f in ./usr/lib/timeshift-tray/timeshift-tray \
	./usr/libexec/timeshift-tray/create-snapshot \
	./usr/libexec/timeshift-tray/grant-access \
	./usr/libexec/timeshift-tray/revoke-access; do
	line=$(printf '%s\n' "$LIST" | grep " $f\$" || true)
	case "$line" in
		-rwxr-xr-x*root/root*) ok "executable, root-owned: $f" ;;
		'')                    bad "cannot check perms (missing): $f" ;;
		*)                     bad "WRONG MODE OR OWNER: $line" ;;
	esac
done

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
dpkg-deb -x "$DEB" "$TMPD" 2>/dev/null || bad "cannot extract $DEB"

# --- the code parses ----------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
	pyfail=0
	count=0
	# Globbed from the extracted package, not from a list in this file: the
	# install glob ships any new module automatically, and a hand-kept list
	# would silently stop compiling the one nobody remembered to add.
	for f in "$TMPD"/usr/lib/timeshift-tray/timeshift_tray/*.py \
		"$TMPD"/usr/lib/timeshift-tray/timeshift-tray; do
		[ -r "$f" ] || continue
		count=$((count + 1))
		python3 -m py_compile "$f" 2>/dev/null \
			|| { bad "SYNTAX ERROR: $(basename "$f")"; pyfail=1; }
	done
	[ "$count" -ge 10 ] || bad "only $count python files found; the install glob looks wrong"
	[ "$pyfail" -eq 0 ] && ok "py_compile: $count shipped python files"
else
	skip "python3 not installed"
fi

for s in usr/libexec/timeshift-tray/create-snapshot usr/libexec/timeshift-tray/grant-access; do
	[ -r "$TMPD/$s" ] || continue
	sh -n "$TMPD/$s" 2>/dev/null && ok "sh -n: $s" || bad "SYNTAX ERROR: $s"
done

# --- the polkit policy --------------------------------------------------------
if [ -r "$TMPD/$POLICY" ]; then
	if command -v xmllint >/dev/null 2>&1; then
		xmllint --noout "$TMPD/$POLICY" 2>/dev/null \
			&& ok "polkit policy is well-formed XML" \
			|| bad "polkit policy is not well-formed XML"
	else
		skip "xmllint not installed (apt install libxml2-utils)"
	fi

	# Every authorised program must be one this package ships. An action naming
	# a path that is not installed is a prompt the user can pass and still get
	# nothing.
	for path in $(sed -n 's|.*exec\.path">\([^<]*\)<.*|\1|p' "$TMPD/$POLICY"); do
		[ -e "$TMPD/${path#/}" ] \
			&& ok "polkit action runs a shipped file: $path" \
			|| bad "polkit action names $path, which this package does not ship"
	done

	# Assert the WHOLE grant, not one nuance of it.
	#
	# The previous version only counted auth_admin_keep on allow_active, which
	# a policy saying <allow_active>yes</allow_active> passes -- i.e. any local
	# user adding themselves to the timeshift group with no password at all
	# would have shipped green. allow_any and allow_inactive were not looked at
	# even once.
	check_action() { # id, allow_any, allow_inactive, allow_active
		_block=$(sed -n "/<action id=\"[^\"]*\.$1\">/,/<\/action>/p" "$TMPD/$POLICY")
		[ -n "$_block" ] || { bad "policy has no $1 action"; return; }
		for _elem in allow_any:$2 allow_inactive:$3 allow_active:$4; do
			_name=${_elem%%:*}
			_want=${_elem#*:}
			_got=$(printf '%s\n' "$_block" \
				| sed -n "s|.*<$_name>\([^<]*\)</$_name>.*|\1|p" | head -n1)
			if [ "$_got" = "$_want" ]; then
				ok "$1: $_name is $_want"
			else
				bad "$1: $_name is '${_got:-missing}', expected '$_want'"
			fi
		done
	}
	# create-snapshot caches authorisation because the whole point of the
	# applet is a snapshot without ceremony; the wrapper rate-limits itself so
	# the cache cannot be turned into unbounded snapshot creation.
	check_action create-snapshot auth_admin auth_admin auth_admin_keep
	# The two access actions change who can read the machine's disk layout.
	# Done once, so nothing about them is cached.
	check_action grant-access auth_admin auth_admin auth_admin
	check_action revoke-access auth_admin auth_admin auth_admin

	# allow_gui hands the target DISPLAY and XAUTHORITY. None of these is a
	# GUI program.
	if grep -q 'allow_gui' "$TMPD/$POLICY"; then
		bad "policy sets allow_gui; no wrapper here is a GUI program"
	else
		ok "no allow_gui"
	fi
fi

# --- the autostart entry ------------------------------------------------------
if [ -r "$TMPD/$AUTOSTART" ]; then
	if command -v desktop-file-validate >/dev/null 2>&1; then
		desktop-file-validate "$TMPD/$AUTOSTART" >/dev/null 2>&1 \
			&& ok "autostart entry validates" \
			|| bad "autostart entry does not validate"
	else
		skip "desktop-file-validate not installed (apt install desktop-file-utils)"
	fi
fi

# The visible entry is what gets the applet back after someone clicks Quit, so
# it has to be there and it has to point at something real.
for entry in "$AUTOSTART" "$LAUNCHER"; do
	[ -r "$TMPD/$entry" ] || continue
	if command -v desktop-file-validate >/dev/null 2>&1 && [ "$entry" = "$LAUNCHER" ]; then
		desktop-file-validate "$TMPD/$entry" >/dev/null 2>&1 \
			&& ok "launcher entry validates" \
			|| bad "launcher entry does not validate"
	fi
	exec_path=$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$TMPD/$entry" | head -n1)
	[ -n "$exec_path" ] && [ -e "$TMPD/${exec_path#/}" ] \
		&& ok "Exec names a shipped file: $entry -> $exec_path" \
		|| bad "$entry names $exec_path, which this package does not ship"
done

# --- icons --------------------------------------------------------------------
# Every name icons.py can return has to exist, or a state renders as no icon at
# all -- and the state that would go missing is the one nobody tests, the
# failure.
if command -v python3 >/dev/null 2>&1 \
	&& [ -r "$TMPD/usr/lib/timeshift-tray/timeshift_tray/icons.py" ]; then
	missing=0
	# Ask the module for its own list rather than regexing the source. The old
	# pattern was [a-z]* and would silently skip any name containing a digit or
	# an internal hyphen -- the state that goes missing is then the one nobody
	# tests.
	for name in $(cd "$TMPD/usr/lib/timeshift-tray" && python3 -c \
		'from timeshift_tray import icons; print("\n".join(icons.ALL_ICONS))'); do
		[ -e "$TMPD/usr/share/icons/hicolor/scalable/status/$name.svg" ] \
			|| { bad "icons.ALL_ICONS names $name, with no scalable icon installed"; missing=1; }
		[ -e "$TMPD/usr/share/icons/hicolor/16x16/status/$name.png" ] \
			|| { bad "icons.ALL_ICONS names $name, with no 16x16 fallback"; missing=1; }
	done
	[ "$missing" -eq 0 ] && ok "every icon icons.ALL_ICONS names is installed"
	if command -v xmllint >/dev/null 2>&1; then
		svgfail=0
		for f in "$TMPD"/usr/share/icons/hicolor/scalable/status/*.svg; do
			xmllint --noout "$f" 2>/dev/null \
				|| { bad "malformed SVG: $(basename "$f")"; svgfail=1; }
		done
		[ "$svgfail" -eq 0 ] && ok "every shipped SVG parses"
	fi
fi

# --- the /etc payload ---------------------------------------------------------
if printf '%s\n' "$CTRL" | grep -qx conffiles; then
	CONFF=$(dpkg-deb -I "$DEB" conffiles 2>/dev/null)
	printf '%s\n' "$CONFF" | grep -qx "/$AUTOSTART" \
		&& ok "conffile: /$AUTOSTART" \
		|| bad "not a conffile: /$AUTOSTART -- a disabled autostart would come back on upgrade"
else
	bad "no conffiles member -- /$AUTOSTART would be overwritten silently on upgrade"
fi

# --- the project-wide invariant -----------------------------------------------
# /etc/timeshift holds the SSH keys that open the backup repository. Nothing in
# this package has any business naming it.
if grep -rl '/etc/timeshift\b' "$TMPD" >/dev/null 2>&1; then
	bad "a shipped file mentions /etc/timeshift:"
	grep -rl '/etc/timeshift\b' "$TMPD" | sed "s|$TMPD|          |"
else
	ok "nothing shipped mentions /etc/timeshift"
fi

# --- control metadata ---------------------------------------------------------
printf '%s\n' "$INFO" | grep -q '^ Package: timeshift-tray$' && ok "Package: timeshift-tray" || bad "wrong Package name"
printf '%s\n' "$INFO" | grep -q 'Depends:.*python3-gi'       && ok "Depends: python3-gi"       || bad "missing Depends on python3-gi"
printf '%s\n' "$INFO" | grep -q 'Depends:.*timeshift'        && ok "Depends: timeshift"        || bad "missing Depends on timeshift"
printf '%s\n' "$INFO" | grep -q 'Recommends:.*appindicator'  && ok "Recommends: an appindicator host" || bad "missing Recommends on an appindicator extension"
printf '%s\n' "$INFO" | grep -q 'Depends:.*passwd'           && ok "Depends: passwd"           || bad "missing Depends on passwd (gpasswd)"

# --- the man page renders -----------------------------------------------------
# Checked directly rather than left to lintian, because its groff tag is
# suppressed below: a page that will not format must still fail the build.
if command -v groff >/dev/null 2>&1; then
	MAN=$TMPD/usr/share/man/man1/timeshift-tray.1.gz
	if [ -r "$MAN" ]; then
		if zcat "$MAN" | groff -mandoc -ww -z >/dev/null 2>"$TMPD/groff.err" \
			&& [ ! -s "$TMPD/groff.err" ]; then
			ok "the man page formats with no warnings"
		else
			bad "the man page does not format cleanly"
			head -5 "$TMPD/groff.err"
		fi
	fi
else
	skip "groff not installed"
fi

# --- lintian ------------------------------------------------------------------
#
# groff-message is suppressed, deliberately and narrowly. On this build host
# lintian reports it for EVERY man page in this project -- including
# timeshift-recovery's, which has shipped thirty versions of it -- while the
# exact pipeline it names succeeds by hand and groff itself is silent. That is
# lintian's sandbox, not the page, and the check immediately above is what
# would catch a page that is genuinely broken.
if command -v lintian >/dev/null 2>&1; then
	if lintian --fail-on error,warning --suppress-tags groff-message \
		--no-tag-display-limit "$DEB" >/dev/null 2>&1; then
		ok "lintian"
	else
		bad "lintian"
		lintian --fail-on error,warning --suppress-tags groff-message \
			"$DEB" 2>&1 | head -10
	fi
else
	skip "lintian not installed"
fi

# --- no maintainer scripts ----------------------------------------------------
# Nothing needs registering: hicolor is trigger-driven, XDG autostart is
# file-presence, and polkit watches its own directory.
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
