#!/usr/bin/env bash
# Offline test for the adjustable standby timer in videokiosk2-installer.sh.
# Extracts the timer functions from the installer's wrapper template, stubs the hook
# and log, and shrinks one "minute" to one second so the whole run takes ~25 s.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$TMP"' EXIT
FAILED=0

pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAILED=1; }

mkdir -p "$TMP/hooks" "$TMP/state"
cat >"$TMP/hooks/tvStandby.sh" <<EOF
#!/bin/bash
date +%s >>"$TMP/hook-ran"
EOF
chmod +x "$TMP/hooks/tvStandby.sh"

awk '/^standby_adjust_minutes\(\)/ {p=1} /^start_vlc\(\)/ {p=0} p' "$ROOT/videokiosk2-installer.sh" \
    | sed "s|__HOOK_DIR__|$TMP/hooks|g" >"$TMP/timer.sh"
[[ -s "$TMP/timer.sh" ]] || { echo "could not extract timer functions"; exit 1; }

log() { echo "$*" >>"$TMP/log"; }
STANDBY_STATE_DIR="$TMP/state"
STANDBY_TICK_SECONDS=1
STANDBY_UNIT_SECONDS=1
STANDBY_MAX_ADJUST_MINUTES=720
STANDBY_TIMER_PID=""
# shellcheck disable=SC1091
source "$TMP/timer.sh"

reset() {
    cancel_standby_actions
    rm -f "$TMP/hook-ran" "$STANDBY_STATE_DIR"/standby*
    STANDBY_TIMER_PID=""
}
state_of() { sed -n 's/.*"state":"\([a-z]*\)".*/\1/p' "$STANDBY_STATE_DIR/standby.json" 2>/dev/null; }
field() { sed -n "s/.*\"$1\":\([-0-9]*\).*/\1/p" "$STANDBY_STATE_DIR/standby.json" 2>/dev/null; }
wait_hook() { local i; for ((i = 0; i < $1 * 10; i++)); do [[ -f "$TMP/hook-ran" ]] && return 0; sleep 0.1; done; return 1; }

# 1. fires after the base time and records the fired state
reset; STANDBY_AFTER_MINUTES=3
schedule_standby_actions; sleep 1.5
[[ "$(state_of)" == counting && "$(field base_minutes)" == 3 ]] && pass "counting state written" || fail "counting state: $(cat "$STANDBY_STATE_DIR/standby.json" 2>&1)"
wait_hook 5 && pass "hook runs at the base time" || fail "hook never ran"
sleep 0.5; [[ "$(state_of)" == fired ]] && pass "fired state written" || fail "state after fire: $(state_of)"

# 2. cancel stops the hook, clears the adjustment and writes idle
reset; STANDBY_AFTER_MINUTES=4
schedule_standby_actions; echo 5 >"$STANDBY_STATE_DIR/standby-adjust"; sleep 1.2
cancel_standby_actions; sleep 5
[[ ! -f "$TMP/hook-ran" ]] && pass "cancel prevents the hook" || fail "hook ran after cancel"
[[ "$(state_of)" == idle && ! -e "$STANDBY_STATE_DIR/standby-adjust" ]] && pass "cancel writes idle and clears adjustment" || fail "after cancel: $(state_of)"

# 3. +adjustment postpones the deadline, -adjustment brings it forward
reset; STANDBY_AFTER_MINUTES=3
schedule_standby_actions; echo 3 >"$STANDBY_STATE_DIR/standby-adjust"; sleep 4.5
[[ ! -f "$TMP/hook-ran" ]] && pass "+3 postpones past the base time" || fail "hook ran despite +3"
[[ "$(field adjust_minutes)" == 3 ]] && pass "adjustment reported in state" || fail "adjust field: $(field adjust_minutes)"
wait_hook 4 && pass "hook runs at base+adjust" || fail "hook never ran after +3"
reset; STANDBY_AFTER_MINUTES=6
schedule_standby_actions; echo -4 >"$STANDBY_STATE_DIR/standby-adjust"
wait_hook 4 && pass "-4 brings the deadline forward" || fail "hook never ran after -4"

# 4. junk and out-of-range adjustments are tamed
reset; STANDBY_AFTER_MINUTES=3
echo "banana" >"$STANDBY_STATE_DIR/standby-adjust"
[[ "$(standby_adjust_minutes)" == 0 ]] && pass "junk adjustment ignored" || fail "junk gave $(standby_adjust_minutes)"
echo -100 >"$STANDBY_STATE_DIR/standby-adjust"
[[ "$(standby_adjust_minutes)" == -3 ]] && pass "adjustment clamped to -base" || fail "clamp gave $(standby_adjust_minutes)"
echo 99999 >"$STANDBY_STATE_DIR/standby-adjust"
[[ "$(standby_adjust_minutes)" == 720 ]] && pass "adjustment clamped to the maximum" || fail "max clamp gave $(standby_adjust_minutes)"

# 5. disabled writes a disabled state and starts no timer
reset; STANDBY_AFTER_MINUTES=0
schedule_standby_actions
[[ "$(state_of)" == disabled && -z "$STANDBY_TIMER_PID" ]] && pass "STANDBY_AFTER_MINUTES=0 disables the timer" || fail "disabled state: $(state_of)"

# 6. a missing state directory must not break the timer
reset; STANDBY_AFTER_MINUTES=2; SAVED="$STANDBY_STATE_DIR"; STANDBY_STATE_DIR="$TMP/nowhere"
schedule_standby_actions
wait_hook 5 && pass "timer still fires without a state directory" || fail "no hook without state dir"
STANDBY_STATE_DIR="$SAVED"

exit "$FAILED"
