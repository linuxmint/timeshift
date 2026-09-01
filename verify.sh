#!/bin/sh
# Everything that can be checked without building a package.
#
# This exists because nothing else ran it. build-all.sh verified the .debs and
# CI builds only on master, so `go test`, `go vet`, `gofmt` and any shell
# linting happened exactly as often as someone remembered -- which for a tree
# that runs as root, deletes backups and blocks dpkg is not often enough.
#
#   ./verify.sh          everything
#   ./verify.sh go       the Go tree only
#   ./verify.sh shell    the shell scripts only
#
# Called by build-deb.sh, so a release cannot be cut from a failing tree.
# Skips cleanly when a tool is missing rather than failing: a machine with no
# linter installed should still be able to build.
# (Note: a comment starting with the word shellcheck is parsed as a directive,
# which is why that word does not begin the line above.)
set -eu

cd "$(dirname "$0")"
what=${1:-all}
rc=0

say()  { printf '\n==> %s\n' "$1"; }
ok()   { printf '  ok      %s\n' "$1"; }
bad()  { printf '  FAIL    %s\n' "$1"; rc=1; }
skip() { printf '  skip    %s\n' "$1"; }

# --- Go ----------------------------------------------------------------------
if [ "$what" = all ] || [ "$what" = go ]; then
	say "Go"
	if ! command -v go >/dev/null 2>&1; then
		skip "go not installed"
	else
		unformatted=$(cd src-go && gofmt -l . 2>/dev/null || true)
		[ -z "$unformatted" ] && ok "gofmt" || bad "gofmt: $unformatted"

		(cd src-go && go vet ./... 2>&1) && ok "go vet" || bad "go vet"

		# -count=1 so a cached PASS from an earlier run cannot stand in for a
		# real one. The btrfs tests skip without root and would otherwise be
		# reported as having run.
		(cd src-go && go test -count=1 ./... >/dev/null 2>&1) \
			&& ok "go test" || { bad "go test"; (cd src-go && go test ./... 2>&1 | grep -vE '^(ok|---)' | head -20); }

		if [ "$(id -u)" = 0 ]; then
			(cd src-go && go test -count=1 ./internal/engines/timeshift/ -run Btrfs >/dev/null 2>&1) \
				&& ok "btrfs tests (root)" || bad "btrfs tests (root)"
		else
			skip "btrfs tests need root: sudo ./verify.sh go"
		fi
	fi
fi

# --- shell -------------------------------------------------------------------
if [ "$what" = all ] || [ "$what" = shell ]; then
	say "Shell"

	# Every script this project ships or builds with. Kept explicit rather than
	# globbed: a find would sweep up build residue under debian/ staging trees,
	# which are copies and would be reported twice.
	scripts="
		build-all.sh build-deb.sh check-deb.sh verify.sh
		os-plugins/apt-snapshot-guard/build-deb.sh
		os-plugins/apt-snapshot-guard/check-deb.sh
		os-plugins/apt-snapshot-guard/tests/run-tests.sh
		os-plugins/apt-snapshot-guard/lib/apt-snapshot-guard/pre-invoke
		os-plugins/apt-snapshot-guard/lib/apt-snapshot-guard/gui-prompt
		src-recovery/build-deb.sh
		src-recovery/check-deb.sh
		src-recovery/sbin/timeshift-recovery
		src-recovery/lib/timeshift-recovery/build-rootfs
		src-recovery/lib/timeshift-recovery/place-payload
		src-recovery/lib/timeshift-recovery/common.sh
		src-go/go-build.sh
		src/timeshift-launcher
	"

	for f in $scripts; do
		[ -f "$f" ] || continue
		# Syntax first, with the interpreter the shebang actually names.
		case $(head -n1 "$f") in
			*bash*) checker="bash -n" ;;
			*)      checker="sh -n" ;;
		esac
		$checker "$f" 2>/dev/null || bad "syntax: $f"
	done
	ok "syntax of $(printf '%s\n' $scripts | grep -c .) shell scripts"

	if command -v shellcheck >/dev/null 2>&1; then
		for f in $scripts; do
			[ -f "$f" ] || continue
			# SC1091: sourced files that are not present at lint time
			# (/etc config, common.sh reached by an absolute install path).
			# --severity=warning, not the default of "everything".
			#
			# The info level is dominated by SC2015 on `cond && ok ... || bad
			# ...`, which is the reporting idiom every check script in this
			# tree uses deliberately -- ok() always returns 0, so the caveat
			# does not apply. Failing on it would mean either rewriting forty
			# correct lines or ignoring the linter, and a linter that is
			# routinely ignored catches nothing.
			#
			# SC1091: sourced files not present at lint time (/etc config,
			# common.sh reached through its absolute install path).
			shellcheck --severity=warning -e SC1091 -x "$f" >/dev/null 2>&1 \
				|| { bad "shellcheck: $f"; shellcheck --severity=warning -e SC1091 -x "$f" 2>&1 | head -20; }
		done
		[ "$rc" = 0 ] && ok "shellcheck" || true
	else
		skip "shellcheck not installed (apt install shellcheck)"
	fi
fi

# --- behavioural tests -------------------------------------------------------
if [ "$what" = all ] || [ "$what" = shell ]; then
	say "apt-snapshot-guard"
	# The hook runs as root and its own tests need to be root to match. They
	# are sandboxed -- their PATH cannot reach a real timeshift -- so they
	# touch no config, no log and no snapshot repository.
	if [ "$(id -u)" != 0 ]; then
		skip "hook tests need root: sudo ./verify.sh shell"
	elif [ -x os-plugins/apt-snapshot-guard/tests/run-tests.sh ]; then
		if os-plugins/apt-snapshot-guard/tests/run-tests.sh >/dev/null 2>&1; then
			ok "hook behaviour"
		else
			bad "hook behaviour"
			os-plugins/apt-snapshot-guard/tests/run-tests.sh 2>&1 | tail -15
		fi
	fi
fi

printf '\n'
[ "$rc" = 0 ] && echo "verify: PASS" || echo "verify: FAIL"
exit "$rc"
