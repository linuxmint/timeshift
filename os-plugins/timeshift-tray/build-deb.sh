#!/bin/sh
# Build a versioned .deb of the timeshift-tray applet.
#
# Each run bumps the patch component of the version (1.0.0 -> 1.0.1 -> ...) by
# prepending a stanza to debian/changelog, then runs an unsigned binary-only
# dpkg-buildpackage and verifies the result with check-deb.sh.
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
current=$(dpkg-parsechangelog -SVersion)

if [ "${NO_BUMP:-0}" = "1" ]; then
	version=$current
else
	# Bump the last dot-separated component, which must be numeric.
	head=${current%.*}
	tail=${current##*.}
	case "$tail" in
		''|*[!0-9]*) echo "error: cannot auto-bump non-numeric version '$current'" >&2; exit 1 ;;
	esac
	version="$head.$((tail + 1))"

	distro=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-unstable}")
	me=${USER:-$(id -un)}
	name=$(git config user.name 2>/dev/null || echo "$me")
	email=$(git config user.email 2>/dev/null || echo "$me@$(hostname)")

	# Keep the outgoing changelog so a failed build can roll the bump back
	# instead of burning the version number.
	orig=$(mktemp)
	cp debian/changelog "$orig"

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
	# mktemp files are 0600 and mv preserves that; the changelog is source.
	chmod 0644 debian/changelog
	echo "==> debian/changelog: $current -> $version"
fi

rollback() {
	# A failed build or a failed verification must not burn the version:
	# restore the changelog and drop the partial artifacts, so the next run
	# bumps from the same place.
	if [ "${NO_BUMP:-0}" != "1" ] && [ -f "${orig:-}" ]; then
		cp -f "$orig" debian/changelog
		chmod 0644 debian/changelog
		rm -f "../${package}_${version}_"* 2>/dev/null || true
		echo "==> build failed; debian/changelog restored to $current" >&2
	fi
	exit 1
}

echo "==> building $package $version"
dpkg-buildpackage -b -us -uc || rollback

# Architecture: all packages produce ..._all.deb regardless of the host arch.
if grep -qi '^Architecture:[[:space:]]*all[[:space:]]*$' debian/control; then
	arch=all
else
	arch=$(dpkg --print-architecture)
fi
deb="../${package}_${version}_${arch}.deb"

[ -f "$deb" ] || { echo "error: expected $deb was not produced" >&2; exit 1; }

echo
# STRICT: a missing verifier fails the build rather than printing "skip".
# A release must not be able to pass because the builder lacked xmllint.
STRICT=1 sh check-deb.sh "$deb" || rollback
[ -n "${orig:-}" ] && rm -f "$orig" || true
echo
echo "==> built: $(cd .. && pwd)/${deb#../}"
