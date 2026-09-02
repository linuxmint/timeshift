#!/bin/sh
# Build and verify ALL debs of this project and collect them in dist/:
#   - timeshift-ssh        (the Timeshift fork, via ./build-deb.sh)
#   - apt-snapshot-guard   (the apt snapshot guard plugin)
#   - timeshift-recovery   (the recovery environment provisioner)
#   - timeshift-tray       (the desktop status-tray applet)
#
# Usage: ./build-all.sh ["changelog line" ...]
#   Extra arguments become changelog bullets for EVERY package this build.
#   Per-package overrides (so one package's changelog is not polluted with
#   another's work): TS_MSG, GUARD_MSG, RECOVERY_MSG, TRAY_MSG each replace the
#   shared bullets for that one package.
#   Set NO_BUMP=1 to rebuild the current versions without new changelog entries.

set -eu

cd "$(dirname "$0")"
root=$PWD
guard_dir=os-plugins/apt-snapshot-guard
recovery_dir=src-recovery
tray_dir=os-plugins/timeshift-tray
DIST="$root/dist"
mkdir -p "$DIST"

# The children read it; make sure an inline NO_BUMP=1 reaches them.
export NO_BUMP="${NO_BUMP:-0}"

echo "======================================================================"
echo "==> [1/4] building timeshift-ssh"
echo "======================================================================"
if [ -n "${TS_MSG:-}" ]; then sh build-deb.sh "$TS_MSG"; else sh build-deb.sh "$@"; fi

echo
echo "======================================================================"
echo "==> [2/4] building apt-snapshot-guard"
echo "======================================================================"
( cd "$guard_dir" && if [ -n "${GUARD_MSG:-}" ]; then sh build-deb.sh "$GUARD_MSG"; else sh build-deb.sh "$@"; fi )

echo
echo "======================================================================"
echo "==> [3/4] building timeshift-recovery"
echo "======================================================================"
( cd "$recovery_dir" && if [ -n "${RECOVERY_MSG:-}" ]; then sh build-deb.sh "$RECOVERY_MSG"; else sh build-deb.sh "$@"; fi )

echo
echo "======================================================================"
echo "==> [4/4] building timeshift-tray"
echo "======================================================================"
( cd "$tray_dir" && if [ -n "${TRAY_MSG:-}" ]; then sh build-deb.sh "$TRAY_MSG"; else sh build-deb.sh "$@"; fi )

# --- collect the debs into dist/ (read versions AFTER the builds bumped them) --
host_arch=$(dpkg --print-architecture)

# Architecture: all packages name their deb _all; everything else uses the host.
pkg_arch() { # control-file
	_a=$(sed -n 's/^Architecture:[[:space:]]*//p' "$1" | head -n1)
	[ "$_a" = "all" ] && echo all || echo "$host_arch"
}

ts_pkg=$(sed -n "s/^Source:[[:space:]]*//p" debian/control | head -n1)
ts_ver=$(dpkg-parsechangelog -SVersion)
ts_deb="../${ts_pkg}_${ts_ver}_$(pkg_arch debian/control).deb"

g_pkg=$(sed -n "s/^Source:[[:space:]]*//p" "$guard_dir/debian/control" | head -n1)
g_ver=$(cd "$guard_dir" && dpkg-parsechangelog -SVersion)
g_deb="$guard_dir/../${g_pkg}_${g_ver}_$(pkg_arch "$guard_dir/debian/control").deb"

r_pkg=$(sed -n "s/^Source:[[:space:]]*//p" "$recovery_dir/debian/control" | head -n1)
r_ver=$(cd "$recovery_dir" && dpkg-parsechangelog -SVersion)
r_deb="$recovery_dir/../${r_pkg}_${r_ver}_$(pkg_arch "$recovery_dir/debian/control").deb"

t_pkg=$(sed -n "s/^Source:[[:space:]]*//p" "$tray_dir/debian/control" | head -n1)
t_ver=$(cd "$tray_dir" && dpkg-parsechangelog -SVersion)
t_deb="$tray_dir/../${t_pkg}_${t_ver}_$(pkg_arch "$tray_dir/debian/control").deb"

# MOVED, not copied: dpkg-buildpackage writes into the parent directory, which
# for the root package is $HOME -- leaving debs strewn there forever. The
# .buildinfo/.changes metadata travels with its deb.
for d in "$ts_deb" "$g_deb" "$r_deb" "$t_deb"; do
	[ -f "$d" ] || { echo "error: expected $d was not produced" >&2; exit 1; }
	mv -f "$d" "$DIST/"
	base=${d%.deb}
	for ext in buildinfo changes; do
		m=$(printf '%s' "$base" | sed "s/_all\$/_${host_arch}/")".$ext"
		[ -f "$m" ] && mv -f "$m" "$DIST/" || true
	done
done

echo
echo "======================================================================"
echo "==> all packages built and verified; collected in dist/:"
for d in "$ts_deb" "$g_deb" "$r_deb" "$t_deb"; do
	echo "    dist/$(basename "$d")"
done
echo "======================================================================"
