#!/bin/sh
# Everything that can be checked about the tray applet without a desktop.
#
# Needs no root and no session bus: the D-Bus modules are exercised for the
# shapes they put on the wire, not by talking to a real one, and the daemon is
# a scriptable stand-in on a real unix socket.
#
# Run from anywhere: ./tests/run-tests.sh
set -eu

cd "$(dirname "$0")"
root=$(cd .. && pwd)
rc=0

ok()   { printf '  ok      %s\n' "$1"; }
bad()  { printf '  FAIL    %s\n' "$1"; rc=1; }
skip() { printf '  skip    %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || {
	echo "python3 is not installed; nothing to test" >&2
	exit 1
}

PYTHONPATH="$root/lib/timeshift-tray:$PWD"
export PYTHONPATH
# Keep the source tree free of __pycache__ directories the .deb would then ship.
PYTHONDONTWRITEBYTECODE=1
export PYTHONDONTWRITEBYTECODE

echo "==> syntax"
# py_compile into a scratch directory rather than compileall, which writes
# __pycache__ next to the sources whatever PYTHONDONTWRITEBYTECODE says -- and
# a source tree that grows build residue is a source tree that eventually ships
# it.
compile_all() {
	python3 - "$root"/lib/timeshift-tray/timeshift_tray/*.py \
		"$root"/lib/timeshift-tray/timeshift-tray <<'PY'
import os, py_compile, sys, tempfile
scratch = tempfile.mkdtemp()
for path in sys.argv[1:]:
    py_compile.compile(
        path, cfile=os.path.join(scratch, os.path.basename(path) + "c"),
        doraise=True)
PY
}
if compile_all >/dev/null 2>&1; then
	ok "py_compile: every module"
else
	bad "py_compile"
	compile_all 2>&1 | tail -20
fi

echo
echo "==> shell"
for f in "$root"/libexec/timeshift-tray/*; do
	sh -n "$f" 2>/dev/null && ok "sh -n: ${f#$root/}" || bad "SYNTAX ERROR: $f"
done

echo
echo "==> unit tests"
if python3 -m unittest discover -s . -p 'test_*.py' >/tmp/timeshift-tray-tests.$$ 2>&1; then
	ok "$(tail -3 /tmp/timeshift-tray-tests.$$ | grep -o 'Ran [0-9]* tests.*' || echo 'unittest')"
else
	bad "unittest"
	grep -vE 'DeprecationWarning|_get_event_loop_policy|AbstractEventLoopPolicy' \
		/tmp/timeshift-tray-tests.$$ | tail -30
fi
rm -f /tmp/timeshift-tray-tests.$$

echo
echo "==> lint"
if command -v pyflakes3 >/dev/null 2>&1; then
	if pyflakes3 "$root"/lib/timeshift-tray/timeshift_tray/*.py \
		"$root"/lib/timeshift-tray/timeshift-tray >/dev/null 2>&1; then
		ok "pyflakes3"
	else
		bad "pyflakes3"
		pyflakes3 "$root"/lib/timeshift-tray/timeshift_tray/*.py \
			"$root"/lib/timeshift-tray/timeshift-tray 2>&1 | head -20
	fi
else
	skip "pyflakes3 not installed (apt install pyflakes3)"
fi

echo
[ "$rc" = 0 ] && echo "timeshift-tray tests: PASS" || echo "timeshift-tray tests: FAIL"
exit "$rc"
