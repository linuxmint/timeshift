#!/bin/sh
# Build one Go binary for the meson build.
#
# Usage: go-build.sh SRCDIR BUILDDIR OUTPUT PACKAGE VERSION
#
# This wrapper exists for one reason: dpkg-buildpackage runs with an unwritable
# HOME, and a `go build` that falls back to ~/.cache/go-build fails there with
# an error that reads like a compiler problem. Forcing GOCACHE and GOPATH into
# the meson build directory is the fix, and doing it in a script rather than a
# custom_target `env:` keeps the meson_version floor at 0.54.
#
# -buildvcs=false because the deb build tree is not always a git checkout, and
# -trimpath so the binary does not embed build paths.

set -eu

srcdir=$1
builddir=$2
output=$3
package=$4
version=$5

GOCACHE="$builddir/.gocache"
GOPATH="$builddir/.gopath"
GOFLAGS="-mod=mod -buildvcs=false"
GOTOOLCHAIN=local          # never try to download a toolchain during a package build

# Left at cgo's default (enabled), which makes a dynamically linked binary.
# Nothing here needs cgo -- the tree is stdlib only -- but lintian raises
# `statically-linked-binary` as an ERROR, and a distro package has no business
# static-linking libc when every other binary in the deb does not.
export GOCACHE GOPATH GOFLAGS GOTOOLCHAIN

mkdir -p "$GOCACHE" "$GOPATH"

# meson expands @OUTPUT@ relative to the TOP build directory, and we are about
# to cd into the source tree -- so resolve it against this target's build
# directory first. Without this, `go build -o src-go/timeshiftd` lands in
# src-go/src-go/ and meson reports a missing output.
case "$output" in
	/*) ;;
	*)  output="$builddir/$(basename "$output")" ;;
esac

cd "$srcdir"
# -linkmode=external hands the final link to gcc, producing a dynamically
# linked binary. Without it Go links statically whenever nothing in the import
# graph needs libc, and lintian raises `statically-linked-binary` as an ERROR.
# The daemon will import net once the socket lands and would then link
# dynamically on its own, but relying on that would make the packaging result
# depend on the import graph, which is not a thing to leave to chance.
# -buildmode=pie for the same reason: Debian builds position-independent
# executables and lintian warns (hardening-no-pie) about anything that is not.
# It also implies external linking, but both are stated so neither is load-
# bearing on the other's side effects.
exec go build -trimpath -buildmode=pie \
	-ldflags "-X main.version=$version -linkmode=external" \
	-o "$output" "$package"
