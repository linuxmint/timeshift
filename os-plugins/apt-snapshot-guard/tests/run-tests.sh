#!/bin/bash
# Behavioural tests for the pre-invoke hook.
#
# The hook is fail-closed and blocks dpkg, so the thing worth testing is not
# that it works -- it is every path on which it decides to let apt through, and
# every path on which it refuses. Those are the two ways it can be wrong, and
# both are silent.
#
# Everything is redirected away from the real system via the ASG_* overrides
# and a stub `timeshift` on PATH, so this touches no config, no log, no lock
# and above all no snapshot repository. Run it as root (the hook expects to be
# root) from anywhere:
#
#   sudo os-plugins/apt-snapshot-guard/tests/run-tests.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
HOOK=$HERE/../lib/apt-snapshot-guard/pre-invoke
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# A PATH the real timeshift cannot be reached through.
#
# Prepending a stub directory to the inherited PATH is not enough: the moment a
# test removes the stub -- which is exactly what the "no timeshift on PATH"
# case does -- the search falls through to /usr/bin and the hook takes a REAL
# snapshot into the REAL repository. That happened twice while writing these
# tests, so the sandbox is now built by construction rather than by care.
#
# $WORK/sbin holds symlinks to precisely the tools the hook needs and nothing
# else, and PATH is set to the stub dir plus that. There is no timeshift in
# either unless a test puts one there.
mkdir -p "$WORK/bin" "$WORK/sbin"
for t in sh dash bash date cat rm mkdir sleep printf awk tr cut sed grep \
         flock timeout id command test touch ls; do
	src=$(command -v "$t" 2>/dev/null) || continue
	ln -sf "$src" "$WORK/sbin/$t" 2>/dev/null
done
SANDBOX_PATH=$WORK/bin:$WORK/sbin

if command -v timeshift >/dev/null 2>&1; then
	# Prove the sandbox works before relying on it.
	if PATH=$SANDBOX_PATH command -v timeshift >/dev/null 2>&1; then
		echo "REFUSING TO RUN: the real timeshift is reachable from the test PATH" >&2
		exit 1
	fi
fi

make_stub() {
	cat > "$WORK/bin/timeshift" <<'EOF'
#!/bin/sh
echo "stub timeshift $*"
exit "${STUB_RC:-0}"
EOF
	chmod +x "$WORK/bin/timeshift"
}
make_stub

# Run the hook with everything pointed at the scratch dir. $1 is the config
# body; the rest is extra environment.
run_hook() {
	cat > "$WORK/config"
	rm -f "$WORK/stamp" "$WORK/lock"
	env PATH="$SANDBOX_PATH" \
		ASG_CONFIG="$WORK/config" ASG_LOG="$WORK/log" \
		ASG_STAMP="$WORK/stamp" ASG_LOCK="$WORK/lock" \
		ASG_BYPASS="$WORK/bypass" ASG_GUIHELPER="$WORK/nonexistent-gui" \
		STUB_RC="${STUB_RC:-0}" \
		"$HOOK" >>"$WORK/out" 2>&1
}

base() {
	printf 'ENABLED=1\nWINDOW=0\nTIMEOUT=20\nUSE_DAEMON=0\n%s\n' "${1:-}"
}

echo "apt-snapshot-guard: behavioural tests"

# --- the happy path ----------------------------------------------------------
base | STUB_RC=0 run_hook
[ $? -eq 0 ] && ok "a successful snapshot lets apt proceed" \
             || bad "a successful snapshot must exit 0"

# --- fail closed -------------------------------------------------------------
# No tty here, and the GUI helper is deliberately absent, so this is the
# unattended-upgrades path: it must refuse.
base | STUB_RC=1 run_hook
[ $? -ne 0 ] && ok "a failed snapshot with no terminal aborts apt" \
             || bad "a failed snapshot must NOT let apt proceed"

# --- the master switch -------------------------------------------------------
base 'ENABLED=0' | STUB_RC=1 run_hook
[ $? -eq 0 ] && ok "ENABLED=0 skips the guard entirely" \
             || bad "ENABLED=0 must let apt through"

# A typo must NOT silently disable a guard that blocks dpkg.
base 'ENABLED=banana' | STUB_RC=1 run_hook
[ $? -ne 0 ] && ok "ENABLED=banana keeps the guard on (fails closed)" \
             || bad "an unparseable ENABLED must not disable the guard"

# ...but a spelled-out boolean is honoured rather than treated as a typo.
base 'ENABLED=false' | STUB_RC=1 run_hook
[ $? -eq 0 ] && ok "ENABLED=false is understood as off" \
             || bad "ENABLED=false should disable the guard"

# --- the bypass flag ---------------------------------------------------------
touch "$WORK/bypass"
base | STUB_RC=1 run_hook
rc=$?
if [ $rc -eq 0 ] && [ ! -e "$WORK/bypass" ]; then
	ok "the bypass flag is consumed and lets apt through"
else
	bad "bypass: exit=$rc flag_present=$([ -e "$WORK/bypass" ] && echo yes || echo no)"
fi

# Consuming it must stamp, or invocations 2..N of one transaction re-snapshot.
touch "$WORK/bypass"
base | STUB_RC=1 run_hook >/dev/null
[ -s "$WORK/stamp" ] && ok "a consumed bypass stamps the dedupe window" \
                     || bad "a consumed bypass must write the stamp"

# --- the dedupe window -------------------------------------------------------
date +%s > "$WORK/stamp"
env PATH="$SANDBOX_PATH" ASG_CONFIG="$WORK/config" ASG_LOG="$WORK/log" \
	ASG_STAMP="$WORK/stamp" ASG_LOCK="$WORK/lock" ASG_BYPASS="$WORK/bypass" \
	ASG_GUIHELPER="$WORK/nonexistent-gui" STUB_RC=1 \
	"$WORK/sbin/sh" -c "printf 'ENABLED=1\nWINDOW=900\nTIMEOUT=20\nUSE_DAEMON=0\n' > $WORK/config; exec $HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok "a recent snapshot skips a second one inside WINDOW" \
             || bad "the dedupe window must skip, not re-snapshot"

# --- a timeout must cancel the job, on the PATH branch too -------------------
#
# The job belongs to timeshiftd and outlives the client watching it, so killing
# the client on a timeout stops nothing: apt gets refused while the snapshot
# carries on writing and holding the repository write lock, and the next apt run
# then waits out its own full budget behind it. That was observed for real --
# apt refused, rsync still running twenty minutes later.
#
# It used to be cancelled only when the hook had chosen the explicit-socket
# branch, because the PATH binary was the Vala one and did the work in its own
# process. Since the cutover both branches are the same Go client, so both need
# the cancel.
#
# The stub exits 124 itself rather than being timed out for real: 124 is exactly
# what timeout(1) would report, and waiting for it would cost 30s (the floor in
# remaining_budget) to exercise one branch.
cat > "$WORK/bin/timeshift" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/calls"
case "\$1" in
--cancel) exit 0 ;;
esac
exit 124
EOF
chmod +x "$WORK/bin/timeshift"
rm -f "$WORK/calls"

base | run_hook
rc=$?
if [ $rc -ne 0 ] && grep -q -- '--cancel' "$WORK/calls" 2>/dev/null; then
	ok "a timeout cancels the running job and still fails closed"
else
	bad "timeout: exit=$rc cancelled=$(grep -c -- '--cancel' "$WORK/calls" 2>/dev/null || echo 0)"
fi

make_stub   # restore the ordinary stub for anything after this

# --- missing timeshift -------------------------------------------------------
rm -f "$WORK/bin/timeshift"
base | run_hook
[ $? -ne 0 ] && ok "no timeshift on PATH aborts apt" \
             || bad "a missing timeshift must not let apt through"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
