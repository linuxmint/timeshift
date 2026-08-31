#!/bin/sh
# Build and verify ALL debs of this project and collect them in dist/:
#   - timeshift-ssh        (the Timeshift fork, via ./build-deb.sh)
#   - apt-snapshot-guard   (the apt snapshot guard plugin)
#   - timeshift-recovery   (the recovery environment provisioner)
#
# Usage: ./build-all.sh ["changelog line" ...]
#   Extra arguments become changelog bullets for EVERY package this build.
#   Set NO_BUMP=1 to rebuild the current versions without new changelog entries.

set -eu

cd "$(dirname "$0")"
root=$PWD
guard_dir=os-plugins/apt-timeshift-guard
recovery_dir=os-plugins/timeshift-recovery
DIST="$root/dist"
mkdir -p "$DIST"

echo "======================================================================"
echo "==> [1/3] building timeshift-ssh"
echo "======================================================================"
sh build-deb.sh "$@"

echo
echo "======================================================================"
echo "==> [2/3] building apt-snapshot-guard"
echo "======================================================================"
( cd "$guard_dir" && sh build-deb.sh "$@" )

echo
echo "======================================================================"
echo "==> [3/3] building timeshift-recovery"
echo "======================================================================"
( cd "$recovery_dir" && sh build-deb.sh "$@" )

# --- collect the debs into dist/ (read versions AFTER the builds bumped them) --
arch=$(dpkg --print-architecture)

ts_pkg=$(sed -n "s/^Source:[[:space:]]*//p" debian/control | head -n1)
ts_ver=$(dpkg-parsechangelog -SVersion)
ts_deb="../${ts_pkg}_${ts_ver}_${arch}.deb"

g_pkg=$(sed -n "s/^Source:[[:space:]]*//p" "$guard_dir/debian/control" | head -n1)
g_ver=$(cd "$guard_dir" && dpkg-parsechangelog -SVersion)
g_deb="$guard_dir/../${g_pkg}_${g_ver}_all.deb"

r_pkg=$(sed -n "s/^Source:[[:space:]]*//p" "$recovery_dir/debian/control" | head -n1)
r_ver=$(cd "$recovery_dir" && dpkg-parsechangelog -SVersion)
r_deb="$recovery_dir/../${r_pkg}_${r_ver}_all.deb"

for d in "$ts_deb" "$g_deb" "$r_deb"; do
	[ -f "$d" ] || { echo "error: expected $d was not produced" >&2; exit 1; }
	cp -f "$d" "$DIST/"
done

echo
echo "======================================================================"
echo "==> all packages built and verified; collected in dist/:"
for d in "$ts_deb" "$g_deb" "$r_deb"; do
	echo "    dist/$(basename "$d")"
done
echo "======================================================================"
