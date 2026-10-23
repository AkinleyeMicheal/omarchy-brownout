#!/bin/bash
# tests/sandbox.sh — regression suite for the brownout state machine.
#
# Drives the real `brownout-watch` daemon inside a throwaway sandbox with
# stubbed system tools (busctl, brightnessctl, systemctl, powerprofilesctl,
# hyprctl, omarchy) so engage/release transitions are exercised without
# touching the desktop. Each case gets a fresh sandbox.
#
# Run: ./tests/sandbox.sh          (prints one ✓/✗ per assertion, exits nonzero
#                                   on any failure)

set -u
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
PLUGIN="$REPO"
[[ -x $PLUGIN/bin/brownout ]] || { echo "sandbox: plugin not found at $PLUGIN" >&2; exit 2; }

PASS=0
FAIL=0
FAILED=()

t_pass() { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
t_fail() {
  FAIL=$((FAIL + 1))
  FAILED+=("$1")
  printf '  \033[31m✗\033[0m %s\n' "$1"
}

SB=""
WPID=0
cleanup() {
  [[ $WPID -gt 1 ]] && kill "$WPID" 2>/dev/null
  [[ $WPID -gt 1 ]] && wait "$WPID" 2>/dev/null
  rm -rf "$SB" 2>/dev/null
}
trap cleanup EXIT

new_case() {
  local name=$1
  printf '\n== %s\n' "$name"
  [[ $WPID -gt 1 ]] && kill "$WPID" 2>/dev/null
  [[ $WPID -gt 1 ]] && wait "$WPID" 2>/dev/null
  WPID=0
  rm -rf "$SB"
  SB=$(mktemp -d "${TMPDIR:-/tmp}/brownout-sandbox.XXXXXX")
  mkdir -p "$SB/bin" "$SB/state"
}

wait_state() {
  # wait_state <jq-expr> [timeout-s]
  local expr=$1 timeout=${2:-8}
  local end=$(( $(date +%s) + timeout ))
  while (($(date +%s) < end)); do
    jq -e "$expr" "$SB/state/state.json" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  return 1
}

check() {
  # check <desc> <jq-expr> [timeout-s]
  local desc=$1 expr=$2 timeout=${3:-8}
  if wait_state "$expr" "$timeout"; then
    t_pass "$desc"
  else
    t_fail "$desc — state: $(jq -c . "$SB/state/state.json" 2>/dev/null || echo missing)"
  fi
}

bcli() {
  env BROWNOUT_HOME="$SB/state" BROWNOUT_CONFIG="$SB/conf" \
    BROWNOUT_FAKE_UNITS="$SB/units.txt" BROWNOUT_FAKE_PPD="$SB/ppd" \
    BROWNOUT_FAKE_BRIGHT="$SB/brightness" \
    BROWNOUT_FAKE_OMARCHY_LOG="$SB/omarchy.log" \
    BROWNOUT_FAKE_NOTIFY_LOG="$SB/notify.log" \
    PATH="$SB/bin:$PATH" "$PLUGIN/bin/brownout" "$@"
}

start_watcher() {
  env BROWNOUT_HOME="$SB/state" BROWNOUT_CONFIG="$SB/conf" \
    BROWNOUT_FAKE_UNITS="$SB/units.txt" BROWNOUT_FAKE_PPD="$SB/ppd" \
    BROWNOUT_FAKE_BRIGHT="$SB/brightness" \
    BROWNOUT_FAKE_OMARCHY_LOG="$SB/omarchy.log" \
    BROWNOUT_FAKE_NOTIFY_LOG="$SB/notify.log" \
    PATH="$SB/bin:$PATH" "$PLUGIN/bin/brownout-watch" >/dev/null 2>&1 &
  WPID=$!
}

write_conf() {
  local pause=${1:-} notify=${2:-false}
  cat >"$SB/conf" <<EOF
POLL_SECONDS=1
NOTIFY=$notify
UNPLUG_GRACE_SECONDS=2
AC_RELEASE_SECONDS=2
BRIGHTNESS_FLOOR_PCT=25
DISABLE_BLUR=false
DISABLE_SHADOWS=false
DISABLE_TRANSPARENCY=false
DISABLE_ANIMATIONS=false
USE_POWER_SAVER=false
KEYBOARD_BACKLIGHT_OFF=false
WIFI_POWER_SAVE=false
SAMPLE_INTERVAL_SECONDS=3600
PAUSE_SERVICES="$pause"
EOF
}

mk_stubs() {
  local b=$SB/bin
  cat >"$b/busctl" <<'EOF'
#!/bin/bash
echo "b false"
EOF
  cat >"$b/systemctl" <<'EOF'
#!/bin/bash
UNITS="${BROWNOUT_FAKE_UNITS:?}"
cmd=""; unit=""
for a in "$@"; do
  case $a in -*) ;; *) if [[ -z $cmd ]]; then cmd=$a; else unit=$a; fi ;; esac
done
case $cmd in
  is-active) grep -qxF "$unit" "$UNITS" && echo active || echo inactive ;;
  stop) grep -vxF "$unit" "$UNITS" > "$UNITS.tmp" 2>/dev/null; mv "$UNITS.tmp" "$UNITS" ;;
  start) grep -qxF "$unit" "$UNITS" 2>/dev/null || echo "$unit" >>"$UNITS" ;;
  list-units|list-unit-files) cat "$UNITS" ;;
  show) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  cat >"$b/powerprofilesctl" <<'EOF'
#!/bin/bash
PPD="${BROWNOUT_FAKE_PPD:?}"
case $1 in
  get) cat "$PPD" ;;
  set) echo "$2" >"$PPD" ;;
esac
EOF
  cat >"$b/brightnessctl" <<'EOF'
#!/bin/bash
BR="${BROWNOUT_FAKE_BRIGHT:?}"
case $1 in
  get) cat "$BR" ;;
  max) echo 100 ;;
  set) echo "${1%\%}" >"$BR" ;;
esac
EOF
  cat >"$b/omarchy" <<'EOF'
#!/bin/bash
BR="${BROWNOUT_FAKE_BRIGHT:?}"
case "$1 $2" in
  "brightness display") echo "${3%\%}" >"$BR" ;;
  "brightness keyboard") echo "kbd $3" >>"${BROWNOUT_FAKE_OMARCHY_LOG:?}" ;;
esac
EOF
  cat >"$b/omarchy-powerprofiles-set" <<'EOF'
#!/bin/bash
echo "$2" >"${BROWNOUT_FAKE_PPD:?}"
EOF
  cat >"$b/omarchy-notification-send" <<'EOF'
#!/bin/bash
echo "notify $*" >>"${BROWNOUT_FAKE_NOTIFY_LOG:?}"
EOF
  cat >"$b/hyprctl" <<'EOF'
#!/bin/bash
case $1 in
  version) exit 0 ;;
  getoption) echo '{"bool": false}' ;;
  configerrors) exit 0 ;;
  monitors) echo '[]' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$b"/*
}

# ---------------------------------------------------------------------------
new_case "unplug engages after grace and stays engaged"
write_conf "" true
mk_stubs
echo 100 >"$SB/brightness"; echo balanced >"$SB/ppd"; : >"$SB/notify.log"
printf '{"on_battery":1,"pct":100}' >"$SB/state/simulate.json"
start_watcher
check "engages after grace" '.engaged == true and .reason == "unplugged from AC"' 8
check "brightness recorded then floored" \
  '.profile.brightness_pct == 100' 4
sleep 1 # apply actions finish after the state flip
[[ $(cat "$SB/brightness") == 25 ]] && t_pass "brightness stub dimmed to 25"
grep -q "notify" "$SB/notify.log" && t_pass "notification sent (NOTIFY=true)"
sleep 3
jq -e '.engaged == true' "$SB/state/state.json" >/dev/null 2>&1 &&
  t_pass "no flap: still engaged 3s later" ||
  t_fail "released too early"
grep -q RELEASE "$SB/state/brownout.log" && t_fail "unexpected RELEASE in log" ||
  t_pass "log clean of RELEASE"

# ---------------------------------------------------------------------------
new_case "debounced AC return releases; brief AC glitch does not"
write_conf "" false
mk_stubs
echo 100 >"$SB/brightness"; echo balanced >"$SB/ppd"
printf '{"on_battery":1,"pct":90}' >"$SB/state/simulate.json"
start_watcher
check "engaged after unplug" '.engaged == true' 8
printf '{"on_battery":0,"pct":90}' >"$SB/state/simulate.json"
check "releases after AC debounce" '.engaged == false' 8
sleep 2 # let the release actions finish before asserting side effects
[[ $(cat "$SB/brightness") == 100 ]] && t_pass "brightness restored to 100"
# Glitch: AC present for less than AC_RELEASE_SECONDS must not release.
printf '{"on_battery":1,"pct":90}' >"$SB/state/simulate.json"
check "re-engaged on new episode" '.engaged == true' 8
releases_before=$(grep -c RELEASE "$SB/state/brownout.log")
printf '{"on_battery":0,"pct":90}' >"$SB/state/simulate.json"
sleep 1.2 # < AC_RELEASE_SECONDS (2) + poll
printf '{"on_battery":1,"pct":90}' >"$SB/state/simulate.json"
sleep 3
releases_after=$(grep -c RELEASE "$SB/state/brownout.log")
[[ $releases_after == $releases_before ]] &&
  t_pass "AC glitch shorter than debounce did not release" ||
  t_fail "1.2s AC glitch released the profile ($releases_before -> $releases_after)"

# ---------------------------------------------------------------------------
new_case "low-battery engagement releases on recovery"
write_conf "" false
mk_stubs
echo 100 >"$SB/brightness"; echo balanced >"$SB/ppd"
printf '{"on_battery":1,"pct":18}' >"$SB/state/simulate.json"
start_watcher
check "engages at 18%" '.engaged == true and .reason == "battery at 18%"' 8
printf '{"on_battery":1,"pct":30}' >"$SB/state/simulate.json"
check "releases when battery recovers to 30%" '.engaged == false' 8

# ---------------------------------------------------------------------------
new_case "unplug engagement never exits on percentage recovery (flap regression)"
write_conf "" false
mk_stubs
echo 100 >"$SB/brightness"
printf '{"on_battery":1,"pct":48}' >"$SB/state/simulate.json"
start_watcher
check "engaged after unplugging at 48%" '.engaged == true and .trigger == "unplug"' 8
sleep 6
jq -e '.engaged == true' "$SB/state/state.json" >/dev/null 2>&1 &&
  t_pass "still engaged at 48% after 6s (no release/re-engage loop)" ||
  t_fail "flapped at 48%"

# ---------------------------------------------------------------------------
new_case "manual release suppresses the same unplug episode"
write_conf "" false
mk_stubs
echo 100 >"$SB/brightness"
printf '{"on_battery":1,"pct":90}' >"$SB/state/simulate.json"
start_watcher
check "engaged" '.engaged == true' 8
bcli release >/dev/null 2>&1
check "released manually" '.engaged == false and .unplug_handled == true' 6
sleep 4
jq -e '.engaged == false' "$SB/state/state.json" >/dev/null 2>&1 &&
  t_pass "did not re-engage the same episode" ||
  t_fail "re-engaged after manual release"

# ---------------------------------------------------------------------------
new_case "mode on forces engagement on AC; off releases"
write_conf "" false
mk_stubs
echo 100 >"$SB/brightness"; echo balanced >"$SB/ppd"
start_watcher
bcli on >/dev/null 2>&1
check "forced on engages" '.engaged == true and .mode == "on"' 6
bcli off >/dev/null 2>&1
check "forced off releases" '.engaged == false and .mode == "off"' 6

# ---------------------------------------------------------------------------
new_case "PAUSE_SERVICES stops on engage and resumes on release"
write_conf "syncthing.service" false
mk_stubs
echo 100 >"$SB/brightness"
echo syncthing.service >"$SB/units.txt"
printf '{"on_battery":1,"pct":90}' >"$SB/state/simulate.json"
start_watcher
check "engaged" '.engaged == true' 8
sleep 2 # service stop happens during engage actions
grep -qxF syncthing.service "$SB/units.txt" &&
  t_fail "service not stopped" || t_pass "service stopped while engaged"
check "paused units recorded" '.profile.paused | length == 1' 4
printf '{"on_battery":0,"pct":90}' >"$SB/state/simulate.json"
check "released" '.engaged == false' 8
sleep 2
grep -qxF syncthing.service "$SB/units.txt" &&
  t_pass "service resumed on release" || t_fail "service not resumed"

# ---------------------------------------------------------------------------
new_case "threshold get/set persists config and state"
write_conf "" false
mk_stubs
out=$(bcli threshold)
[[ $out == 20 ]] && t_pass "default threshold reported" || t_fail "threshold get: got '$out'"
bcli threshold 35 >/dev/null 2>&1
grep -q '^ENGAGE_THRESHOLD=35' "$SB/conf" &&
  t_pass "config updated" || t_fail "config not updated"
grep -q '^RELEASE_THRESHOLD=40' "$SB/conf" &&
  t_pass "release kept above engage" || t_fail "release not raised"
bcli threshold 10 >/dev/null 2>&1
grep -q '^RELEASE_THRESHOLD=40' "$SB/conf" &&
  t_pass "higher release preserved on lower engage" ||
  t_fail "release clobbered by lower engage"
if bcli threshold 99 >/dev/null 2>&1; then
  t_fail "out-of-range threshold accepted"
else
  t_pass "out-of-range threshold rejected"
fi

# ---------------------------------------------------------------------------
new_case "never-pause blocklist enforced by CLI"
write_conf "" false
mk_stubs
if bcli pause-add pipewire.service >/dev/null 2>&1; then
  t_fail "blocklisted unit accepted"
else
  t_pass "blocklisted unit rejected"
fi

# ---------------------------------------------------------------------------
new_case "config file changes are picked up live"
write_conf "" false
mk_stubs
echo 100 >"$SB/brightness"
start_watcher
sleep 2
printf 'ENGAGE_THRESHOLD=30\nRELEASE_THRESHOLD=35\n' >>"$SB/conf"
check "state exposes new threshold" '.engage_threshold == 30' 6
grep -q "config reloaded (engage<=30" "$SB/state/brownout.log" &&
  t_pass "watcher logged config reload" ||
  t_fail "config reload not detected"

# ---------------------------------------------------------------------------
new_case "top excludes units that no longer exist"
write_conf "" false
mk_stubs
echo syncthing.service >"$SB/units.txt"
mkdir -p "$SB/state/usage"
now=$(date +%s)
printf '{"t":%d,"u":"dead.service","c":5,"m":1048576,"b":1,"w":1}\n{"t":%d,"u":"syncthing.service","c":9,"m":2097152,"b":1,"w":1}\n' "$now" "$now" >"$SB/state/usage/usage.jsonl"
ids=$(bcli top --json --limit 5 | jq -r '.units[].id' | sort -u)
grep -q 'dead.service' <<<"$ids" &&
  t_fail "removed unit still offered in the popup" ||
  t_pass "removed unit filtered out of candidates"
grep -q 'syncthing.service' <<<"$ids" &&
  t_pass "existing unit still listed" || t_fail "existing unit dropped"

# ---------------------------------------------------------------------------
printf '\n== summary\n'
printf 'pass: %d  fail: %d\n' "$PASS" "$FAIL"
if ((FAIL > 0)); then
  printf 'failed cases:\n'
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
printf 'all green\n'
