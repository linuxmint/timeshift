#!/bin/sh
# Build a versioned .deb of this fork.
#
# Each run bumps the packaging revision (25.12.4+ssh1 -> +ssh2 -> ...) by
# prepending a stanza to debian/changelog, then runs an unsigned binary-only
# dpkg-buildpackage. The upstream part of the version is read from meson.build,
# so after rebasing onto a newer upstream the counter restarts at +ssh1.
#
# Usage: ./build-deb.sh ["changelog line" ...]
#   Extra arguments become bullet points in the changelog entry.
#   Set NO_BUMP=1 to rebuild the current version without a new changelog entry.

set -eu

cd "$(dirname "$0")"

for tool in dpkg-buildpackage dpkg-parsechangelog dh; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "error: $tool not found (install debhelper / dpkg-dev)" >&2
		exit 1
	}
done

package=$(sed -n "s/^Source:[[:space:]]*//p" debian/control | head -n1)
upstream=$(sed -n "s/^[[:space:]]*version[[:space:]]*:[[:space:]]*'\([^']*\)'.*/\1/p" meson.build | head -n1)
[ -n "$upstream" ] || { echo "error: could not read version from meson.build" >&2; exit 1; }

current=$(dpkg-parsechangelog -SVersion)

if [ "${NO_BUMP:-0}" = "1" ]; then
	version=$current
else
	case "$current" in
		"$upstream"+ssh*)
			n=${current##*+ssh}
			case "$n" in
				''|*[!0-9]*) echo "error: unparsable revision in $current" >&2; exit 1 ;;
			esac
			version="$upstream+ssh$((n + 1))"
			;;
		*)
			# first build on this upstream version, or just rebased
			version="$upstream+ssh1"
			;;
	esac

	distro=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-unstable}")
	name=$(git config user.name 2>/dev/null || echo "$USER")
	email=$(git config user.email 2>/dev/null || echo "$USER@$(hostname)")

	tmp=$(mktemp)
	{
		printf '%s (%s) %s; urgency=medium\n\n' "$package" "$version" "$distro"
		if [ $# -gt 0 ]; then
			for line in "$@"; do printf '  * %s\n' "$line"; done
		else
			printf '  * Rebuild from %s\n' "$(git rev-parse --short HEAD 2>/dev/null || echo 'working tree')"
		fi
		printf '\n -- %s <%s>  %s\n\n' "$name" "$email" "$(date -R)"
		cat debian/changelog
	} > "$tmp"
	mv "$tmp" debian/changelog
	echo "==> debian/changelog: $current -> $version"
fi

echo "==> building $package $version"
dpkg-buildpackage -b -us -uc

arch=$(dpkg --print-architecture)
deb="../${package}_${version}_${arch}.deb"

[ -f "$deb" ] || { echo "error: expected $deb was not produced" >&2; exit 1; }

echo
sh check-deb.sh "$deb"
echo
echo "==> built: $(cd .. && pwd)/${deb#../}"
echo
# Installing with dpkg -i (or apt install ./file.deb) resets the package
# selection to "install", which silently drops an apt-mark hold. Re-apply it
# after every install, not just the first.
echo "    install: sudo apt install $deb && sudo apt-mark hold $package"
echo "    (the hold is cleared by every install, so always re-run apt-mark hold)"
