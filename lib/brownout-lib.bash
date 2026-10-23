# shellcheck shell=bash
# brownout-lib.bash — shared library for the brownout plugin (sourced, never executed).
#
# Layout contract:
#   ~/.config/brownout.conf                     user config (KEY="value"), sourced
#   ~/.local/state/brownout/state.json          machine state (jq-managed, atomic writes)
#   ~/.local/state/brownout/brownout.log        audit log
#   ~/.local/state/brownout/usage/usage.jsonl   sampled per-unit resource history
#   ~/.local/state/brownout/simulate.json       test overrides (brownout simulate)
#   ~/.local/state/brownout/brownout.lock       flock serializing state mutations

BROWNOUT_HOME="${BROWNOUT_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/brownout}"
BROWNOUT_CONFIG="${BROWNOUT_CONFIG:-$HOME/.config/brownout.conf}"
BROWNOUT_STATE_FILE="$BROWNOUT_HOME/state.json"
BROWNOUT_LOG_FILE="$BROWNOUT_HOME/brownout.log"
BROWNOUT_USAGE_DIR="$BROWNOUT_HOME/usage"
BROWNOUT_USAGE_FILE="$BROWNOUT_USAGE_DIR/usage.jsonl"
BROWNOUT_LOCK_FILE="$BROWNOUT_HOME/brownout.lock"
BROWNOUT_SIM_FILE="$BROWNOUT_HOME/simulate.json"
BROWNOUT_LAST_SAMPLE_FILE="$BROWNOUT_HOME/last-sample.tsv"

# Units that must never be paused by brownout (session/audio/portal core).
# Matching is a regex on the unit name; keep in sync with brownout-report.py.
BROWNOUT_PAUSE_BLOCKLIST_REGEX='^(pipewire|wireplumber|dbus|systemd|xdg|portal|wayland|omarchy|gnome-keyring|at-spi|dconf|hyprland|quickshell|fonsgaudii-brownout|.*-brownout\.service)'

bl_ensure_dirs() {
  mkdir -p "$BROWNOUT_HOME" "$BROWNOUT_USAGE_DIR"
}

# ---------------------------------------------------------------------------
# Logging / notifications
# ---------------------------------------------------------------------------

bl_log() {
  local level=$1
  shift
  bl_ensure_dirs
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >>"$BROWNOUT_LOG_FILE"
  # Keep the log bounded (cheap prune every ~200 writes).
  local max_lines=${LOG_MAX_LINES:-5000}
  if (($(wc -l <"$BROWNOUT_LOG_FILE" 2>/dev/null || echo 0) > max_lines + 200)); then
    tail -n "$max_lines" "$BROWNOUT_LOG_FILE" >"$BROWNOUT_LOG_FILE.tmp" &&
      mv "$BROWNOUT_LOG_FILE.tmp" "$BROWNOUT_LOG_FILE"
  fi
}

bl_notify() {
  # bl_notify <urgency> <glyph> <headline> [description] [--exec <cmd...>]
  [[ $NOTIFY == true ]] || return 0
  command -v omarchy-notification-send >/dev/null 2>&1 || return 0
  omarchy-notification-send -u "$1" -g "$2" --app-name brownout "${@:3}" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

bl_config_defaults() {
  ENGAGE_THRESHOLD=20
  RELEASE_THRESHOLD=25
  UNPLUG_GRACE_SECONDS=10
  AC_RELEASE_SECONDS=3
  BRIGHTNESS_FLOOR_PCT=25
  DISABLE_BLUR=true
  DISABLE_SHADOWS=true
  DISABLE_TRANSPARENCY=true
  DISABLE_ANIMATIONS=true
  USE_POWER_SAVER=true
  PAUSE_SERVICES=""
  KEYBOARD_BACKLIGHT_OFF=true
  WIFI_POWER_SAVE=false
  WIFI_INTERFACE=""
  REFRESH_RATE_HZ=0
  NOTIFY=true
  POLL_SECONDS=5
  SAMPLE_INTERVAL_SECONDS=60
  HISTORY_RETENTION_DAYS=14
  COMPACT_RAW_HOURS=48
  TOP_LIMIT=8
  LOG_MAX_LINES=5000
}

bl_config_load() {
  bl_config_defaults
  if [[ -r $BROWNOUT_CONFIG ]]; then
    # shellcheck disable=SC1090
    source "$BROWNOUT_CONFIG"
  fi
  # Hysteresis needs room: engaging at <= ENGAGE_THRESHOLD and then releasing
  # as soon as pct >= RELEASE_THRESHOLD would flap forever if the two levels
  # were equal (or inverted). Repair instead of trusting bad arithmetic.
  if ! [[ ${ENGAGE_THRESHOLD:-} =~ ^[0-9]+$ ]]; then ENGAGE_THRESHOLD=20; fi
  if ! [[ ${RELEASE_THRESHOLD:-} =~ ^[0-9]+$ ]] ||
    ((RELEASE_THRESHOLD <= ENGAGE_THRESHOLD)); then
    RELEASE_THRESHOLD=$((ENGAGE_THRESHOLD + 5))
  fi
  # "auto" asks for the lowest available mode for the current resolution.
  if [[ ${REFRESH_RATE_HZ:-0} != auto && ! ${REFRESH_RATE_HZ:-0} =~ ^[0-9]+$ ]]; then
    REFRESH_RATE_HZ=0
  fi
  BROWNOUT_CONFIG_MTIME=$(stat -c %Y "$BROWNOUT_CONFIG" 2>/dev/null || echo 0)
}

bl_config_reload_if_changed() {
  # Returns 0 (true) when the config was reloaded, 1 when unchanged.
  local mtime
  mtime=$(stat -c %Y "$BROWNOUT_CONFIG" 2>/dev/null || echo 0)
  [[ ${BROWNOUT_CONFIG_MTIME:-0} == "$mtime" ]] && return 1
  bl_config_load
  return 0
}

# ---------------------------------------------------------------------------
# Power readings (with simulate overrides)
# ---------------------------------------------------------------------------

bl_raw_on_battery() {
  [[ $(busctl get-property org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower OnBattery 2>/dev/null) == "b true" ]] && echo 1 || echo 0
}

bl_raw_battery_pct() {
  busctl get-property org.freedesktop.UPower /org/freedesktop/UPower/devices/DisplayDevice \
    org.freedesktop.UPower.Device Percentage 2>/dev/null | awk '{printf "%d", $2}'
}

bl_sim_get() {
  # bl_sim_get <key> -> value or empty
  [[ -r $BROWNOUT_SIM_FILE ]] || return 0
  jq -r --arg k "$1" '.[$k] // empty' "$BROWNOUT_SIM_FILE" 2>/dev/null
}

bl_on_battery() {
  local sim
  sim=$(bl_sim_get on_battery)
  if [[ -n $sim ]]; then echo "$sim"; else bl_raw_on_battery; fi
}

bl_battery_pct() {
  local sim
  sim=$(bl_sim_get pct)
  if [[ -n $sim ]]; then echo "$sim"; else bl_raw_battery_pct; fi
}

# ---------------------------------------------------------------------------
# State file (atomic, jq-managed)
# ---------------------------------------------------------------------------

bl_state_init() {
  bl_ensure_dirs
  [[ -s $BROWNOUT_STATE_FILE ]] && jq -e . "$BROWNOUT_STATE_FILE" >/dev/null 2>&1 && return 0
  cat >"$BROWNOUT_STATE_FILE" <<'EOF'
{
  "version": 1,
  "mode": "auto",
  "engaged": false,
  "reason": "",
  "trigger": "",
  "engaged_at": 0,
  "unplugged_at": 0,
  "plugged_at": 0,
  "unplug_handled": false,
  "battery_pct": -1,
  "on_battery": 0,
  "engage_threshold": 20,
  "release_threshold": 25,
  "last_transition_at": 0,
  "profile": {},
  "paused_config": []
}
EOF
}

bl_state_get() {
  # bl_state_get <jq-path> [default]
  local def=${2:-}
  local out
  out=$(jq -r "$1 // empty" "$BROWNOUT_STATE_FILE" 2>/dev/null)
  echo "${out:-$def}"
}

bl_state_set() {
  # bl_state_set <jq-assignment-expr> [extra jq args...]  e.g. '.mode = "on"'
  local expr=$1
  shift
  local tmp
  tmp=$(mktemp "$BROWNOUT_HOME/state.XXXXXX")
  if jq "$@" "$expr" "$BROWNOUT_STATE_FILE" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$BROWNOUT_STATE_FILE"
  else
    rm -f "$tmp"
    bl_log ERROR "state write failed: $expr"
    return 1
  fi
}

bl_lock_acquire() {
  bl_ensure_dirs
  exec 9>"$BROWNOUT_LOCK_FILE"
  flock -w 10 9 || {
    bl_log WARN "could not acquire lock within 10s"
    return 1
  }
}

bl_lock_release() {
  flock -u 9 2>/dev/null || true
  exec 9>&- 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Profile actions. Each save step records the original value into
# state.profile exactly once; each release step restores and clears it.
# ---------------------------------------------------------------------------

bl_paused_services() {
  # Normalized, blocklist-filtered list from config.
  local svc
  for svc in $PAUSE_SERVICES; do
    [[ -z $svc ]] && continue
    if [[ $svc =~ $BROWNOUT_PAUSE_BLOCKLIST_REGEX ]]; then
      bl_log WARN "config lists blocklisted unit '$svc' — ignoring"
      continue
    fi
    echo "$svc"
  done
}

bl_action_ppd_apply() {
  [[ $USE_POWER_SAVER == true ]] || return 0
  command -v powerprofilesctl >/dev/null 2>&1 || {
    bl_log WARN "powerprofilesctl missing; skipping power saver"
    return 0
  }
  local cur
  cur=$(powerprofilesctl get 2>/dev/null || echo balanced)
  if ! jq -e '.profile.ppd' "$BROWNOUT_STATE_FILE" >/dev/null 2>&1; then
    bl_state_set ".profile.ppd = \"$cur\""
  fi
  if [[ $cur != power-saver ]]; then
    powerprofilesctl set power-saver 2>/dev/null && bl_log INFO "ppd: $cur -> power-saver"
  fi
}

bl_action_ppd_release() {
  local prev trigger
  prev=$(bl_state_get '.profile.ppd' "")
  [[ -n $prev ]] || return 0
  trigger=${RELEASE_TRIGGER:-}
  if [[ $trigger == "plugged in" ]]; then
    # On a real AC transition Omarchy's battery service already ran
    # omarchy-powerprofiles-set ac (signal-driven, before our poll). Calling it
    # again is idempotent and also repairs cases where that event never fired
    # (simulate, missed event, service disabled).
    if command -v omarchy-powerprofiles-set >/dev/null 2>&1; then
      if omarchy-powerprofiles-set ac >/dev/null 2>&1; then
        bl_log INFO "ppd: ac profile applied via omarchy-powerprofiles-set (was $prev)"
      else
        bl_log WARN "ppd: omarchy-powerprofiles-set ac failed; restoring $prev"
        powerprofilesctl set "$prev" 2>/dev/null || true
      fi
    else
      powerprofilesctl set "$prev" 2>/dev/null || true
      bl_log INFO "ppd: power-saver -> $prev (no omarchy helper)"
    fi
  else
    powerprofilesctl set "$prev" 2>/dev/null && bl_log INFO "ppd: power-saver -> $prev"
  fi
  bl_state_set 'del(.profile.ppd)'
  return 0
}

bl_action_brightness_apply() {
  command -v brightnessctl >/dev/null 2>&1 || return 0
  local max cur target prev_pct
  max=$(brightnessctl max 2>/dev/null) || return 0
  cur=$(brightnessctl get 2>/dev/null) || return 0
  ((max > 0 && cur > 0)) || return 0
  target=$((max * BRIGHTNESS_FLOOR_PCT / 100))
  ((cur <= target)) && return 0 # already dim enough; do not save or touch
  prev_pct=$(((cur * 100 + max / 2) / max))
  bl_state_set ".profile.brightness_pct = $prev_pct"
  if command -v omarchy >/dev/null 2>&1; then
    omarchy brightness display "${BRIGHTNESS_FLOOR_PCT}%" >/dev/null 2>&1 ||
      brightnessctl set "${BRIGHTNESS_FLOOR_PCT}%" >/dev/null 2>&1 || true
  else
    brightnessctl set "${BRIGHTNESS_FLOOR_PCT}%" >/dev/null 2>&1 || true
  fi
  bl_log INFO "brightness: ${prev_pct}% -> ${BRIGHTNESS_FLOOR_PCT}%"
}

bl_action_brightness_release() {
  local prev
  prev=$(bl_state_get '.profile.brightness_pct' "")
  [[ -n $prev ]] || return 0
  if command -v omarchy >/dev/null 2>&1; then
    omarchy brightness display "${prev}%" >/dev/null 2>&1 ||
      brightnessctl set "${prev}%" >/dev/null 2>&1 || true
  else
    brightnessctl set "${prev}%" >/dev/null 2>&1 || true
  fi
  bl_log INFO "brightness: restored ${prev}%"
  bl_state_set 'del(.profile.brightness_pct)'
}

bl_hypr_option() {
  # bl_hypr_option <name> -> 1/0 (options serialize as int, float, or bool
  # depending on the option type)
  bl_hyprctl getoption "$1" -j 2>/dev/null | jq -r '
    if .int != null then .int
    elif .float != null then (.float | floor)
    elif .bool != null then (if .bool then 1 else 0 end)
    else 0 end' 2>/dev/null || echo 0
}

bl_hypr_float() {
  # Exact float value of an option (opacity must be restored precisely).
  bl_hyprctl getoption "$1" -j 2>/dev/null | jq -r '
    if .float != null then (.float | tostring)
    elif .int != null then (.int | tostring)
    else empty end' 2>/dev/null
}

bl_hypr_sig() {
  # Hyprland's instance signature, resolved from the live IPC socket. systemd
  # user services start before (or outlive) the compositor and therefore do
  # not reliably inherit HYPRLAND_INSTANCE_SIGNATURE; hyprctl without it fails
  # with "HYPRLAND_INSTANCE_SIGNATURE not set". Resolve it per call so the
  # watcher keeps working across compositor restarts too.
  local sig=${HYPRLAND_INSTANCE_SIGNATURE:-} sock
  if [[ -n $sig && -S ${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr/$sig/.socket.sock ]]; then
    printf '%s' "$sig"
    return 0
  fi
  sock=$(ls -t "${XDG_RUNTIME_DIR:-/run/user/$UID}"/hypr/*/.socket.sock 2>/dev/null | head -1)
  [[ -n $sock ]] || return 1
  basename "$(dirname "$sock")"
}

bl_hyprctl() {
  # hyprctl against the current Hyprland instance.
  local sig
  sig=$(bl_hypr_sig) || return 1
  HYPRLAND_INSTANCE_SIGNATURE=$sig hyprctl "$@"
}

bl_hypr_profile_has() {
  jq -e --arg k "$1" '.profile | has($k)' "$BROWNOUT_STATE_FILE" >/dev/null 2>&1
}

bl_hypr_save() {
  # bl_hypr_save <profile-key> <numeric-value> — record the pre-engage value once.
  local key=$1 value=$2
  [[ $value =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  bl_hypr_profile_has "$key" && return 0
  bl_state_set ".profile.${key} = ${value}"
}

bl_action_hyprland_apply() {
  # Hyprland 0.56 (Omarchy's Lua config) rejects `hyprctl keyword` with
  # "keyword can't work with non-legacy parsers. Use eval." — runtime option
  # changes go through `hyprctl eval` with the nested hl.config() table form.
  command -v hyprctl >/dev/null 2>&1 || return 0
  if ! bl_hyprctl version >/dev/null 2>&1; then
    bl_log WARN "hyprland: IPC unavailable; compositor actions skipped"
    return 0
  fi
  local saved_blur saved_anims saved_shadow op_a op_i
  saved_blur=$(bl_hypr_option decoration:blur:enabled)
  saved_anims=$(bl_hypr_option animations:enabled)
  saved_shadow=$(bl_hypr_option decoration:shadow:enabled)
  op_a=$(bl_hypr_float decoration:active_opacity)
  op_i=$(bl_hypr_float decoration:inactive_opacity)

  local dec="" tbl="" did=()
  if [[ $DISABLE_BLUR == true && $saved_blur == 1 ]]; then
    bl_hypr_save blur "$saved_blur"
    dec+="blur = { enabled = false }"
    did+=("blur")
  fi
  if [[ $DISABLE_SHADOWS == true && $saved_shadow == 1 ]]; then
    bl_hypr_save shadow "$saved_shadow"
    dec+="${dec:+, }shadow = { enabled = false }"
    did+=("shadows")
  fi
  # Window opacity is client-independent: 1.0 removes Hyprland's compositor
  # transparency. (Terminal/editor transparency set by the app itself remains.)
  if [[ $DISABLE_TRANSPARENCY == true && -n $op_a && -n $op_i ]] &&
    awk -v a="$op_a" -v i="$op_i" 'BEGIN{exit !(a < 0.999 || i < 0.999)}'; then
    if bl_hypr_save opacity_active "$op_a" && bl_hypr_save opacity_inactive "$op_i"; then
      dec+="${dec:+, }active_opacity = 1.0, inactive_opacity = 1.0"
      did+=("opacity")
    fi
  fi
  [[ -n $dec ]] && tbl="decoration = { $dec }"
  if [[ $DISABLE_ANIMATIONS == true && $saved_anims == 1 ]]; then
    bl_hypr_save animations "$saved_anims"
    tbl+="${tbl:+, }animations = { enabled = false }"
    did+=("animations")
  fi

  if ((${#did[@]} > 0)); then
    if bl_hyprctl eval "hl.config({ $tbl })" >/dev/null 2>&1; then
      bl_log INFO "hyprland: ${did[*]} disabled"
    else
      bl_log WARN "hyprland: apply FAILED (${did[*]})"
    fi
  fi
  local errs
  errs=$(bl_hyprctl configerrors 2>/dev/null)
  if [[ -n $errs ]]; then
    bl_log WARN "hyprctl configerrors: $errs"
  fi
  return 0
}

bl_action_hyprland_release() {
  local prev_blur prev_anims prev_shadow prev_oa prev_oi
  prev_blur=$(bl_state_get '.profile.blur' "")
  prev_anims=$(bl_state_get '.profile.animations' "")
  prev_shadow=$(bl_state_get '.profile.shadow' "")
  prev_oa=$(bl_state_get '.profile.opacity_active' "")
  prev_oi=$(bl_state_get '.profile.opacity_inactive' "")
  bl_state_set 'del(.profile.blur, .profile.animations, .profile.shadow, .profile.opacity_active, .profile.opacity_inactive)'
  command -v hyprctl >/dev/null 2>&1 || return 0
  [[ -n $prev_blur || -n $prev_anims || -n $prev_shadow || -n $prev_oa || -n $prev_oi ]] || return 0
  if ! bl_hyprctl version >/dev/null 2>&1; then
    bl_log WARN "hyprland: IPC unavailable; cannot restore compositor settings"
    return 0
  fi

  local dec="" tbl="" restored=()
  if [[ -n $prev_blur ]]; then
    dec+="blur = { enabled = $([[ $prev_blur == 1 ]] && echo true || echo false) }"
    restored+=("blur=$prev_blur")
  fi
  if [[ -n $prev_shadow ]]; then
    dec+="${dec:+, }shadow = { enabled = $([[ $prev_shadow == 1 ]] && echo true || echo false) }"
    restored+=("shadow=$prev_shadow")
  fi
  if [[ $prev_oa =~ ^[0-9]+([.][0-9]+)?$ && $prev_oi =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    dec+="${dec:+, }active_opacity = $prev_oa, inactive_opacity = $prev_oi"
    restored+=("opacity=$prev_oa/$prev_oi")
  fi
  [[ -n $dec ]] && tbl="decoration = { $dec }"
  if [[ -n $prev_anims ]]; then
    tbl+="${tbl:+, }animations = { enabled = $([[ $prev_anims == 1 ]] && echo true || echo false) }"
    restored+=("animations=$prev_anims")
  fi
  if [[ -n $tbl ]] && bl_hyprctl eval "hl.config({ $tbl })" >/dev/null 2>&1; then
    bl_log INFO "hyprland: restored ${restored[*]}"
  else
    bl_log WARN "hyprland: restore FAILED ($tbl)"
  fi
  return 0
}

bl_action_services_apply() {
  local svc stopped=()
  while IFS= read -r svc; do
    [[ -z $svc ]] && continue
    if systemctl --user is-active --quiet "$svc" 2>/dev/null; then
      if systemctl --user stop "$svc" 2>/dev/null; then
        stopped+=("$svc")
        bl_log INFO "service paused: $svc"
      else
        bl_log WARN "failed to stop $svc"
      fi
    else
      bl_log INFO "service $svc not active; nothing to do"
    fi
  done < <(bl_paused_services)
  if ((${#stopped[@]} > 0)); then
    bl_state_set '.profile.paused = $s' --argjson s "$(printf '%s\n' "${stopped[@]}" | jq -R . | jq -cs .)"
  fi
}

bl_action_services_release() {
  local svc
  while IFS= read -r svc; do
    [[ -z $svc ]] && continue
    if systemctl --user start "$svc" 2>/dev/null; then
      bl_log INFO "service resumed: $svc"
    else
      bl_log WARN "failed to resume $svc"
    fi
  done < <(bl_state_get '.profile.paused[]?' "")
  bl_state_set 'del(.profile.paused)'
}

bl_action_kbd_apply() {
  [[ $KEYBOARD_BACKLIGHT_OFF == true ]] || return 0
  command -v omarchy >/dev/null 2>&1 || return 0
  if omarchy brightness keyboard off >/dev/null 2>&1; then
    bl_state_set '.profile.kbd = true'
    bl_log INFO "keyboard backlight off"
  fi
}

bl_action_kbd_release() {
  [[ $(bl_state_get '.profile.kbd' "") == true ]] || return 0
  omarchy brightness keyboard restore >/dev/null 2>&1 || true
  bl_log INFO "keyboard backlight restored"
  bl_state_set 'del(.profile.kbd)'
}

bl_wifi_iface() {
  if [[ -n $WIFI_INTERFACE ]]; then
    echo "$WIFI_INTERFACE"
  else
    iw dev 2>/dev/null | awk '/Interface/{print $2; exit}'
  fi
}

bl_action_wifi_apply() {
  [[ $WIFI_POWER_SAVE == true ]] || return 0
  local iface
  iface=$(bl_wifi_iface)
  [[ -z $iface ]] && {
    bl_log INFO "wifi power save: no interface found"
    return 0
  }
  # Interface names flow into argv of a passwordless-root iw call and into the
  # state snapshot: only accept plain connector names.
  if ! [[ $iface =~ ^[A-Za-z0-9._-]+$ ]]; then
    bl_log WARN "wifi power save: refusing odd interface name '$iface'"
    return 0
  fi
  # Never block on a password prompt inside the daemon: sudo -n only.
  if ! timeout 3 sudo -n true 2>/dev/null; then
    bl_log WARN "wifi power save enabled in config but passwordless sudo is unavailable; see README"
    return 0
  fi
  local prev
  prev=$(iw dev "$iface" get power_save 2>/dev/null | awk '{print $2}')
  bl_state_set ".profile.wifi = \"$iface:${prev:-disable}\""
  timeout 5 sudo -n iw dev "$iface" set power_save on 2>/dev/null &&
    bl_log INFO "wifi power_save on ($iface, was ${prev:-unknown})"
}

bl_action_wifi_release() {
  local rec iface prev
  rec=$(bl_state_get '.profile.wifi' "")
  [[ -n $rec ]] || return 0
  iface=${rec%%:*}
  prev=${rec#*:}
  timeout 5 sudo -n iw dev "$iface" set power_save "$prev" 2>/dev/null || true
  bl_log INFO "wifi power_save restored to $prev ($iface)"
  bl_state_set 'del(.profile.wifi)'
}

bl_action_refresh_apply() {
  [[ ${REFRESH_RATE_HZ:-0} != 0 ]] || return 0
  command -v hyprctl >/dev/null 2>&1 || return 0
  local json name w h r target
  json=$(bl_hyprctl monitors -j 2>/dev/null) || return 0
  read -r name w h r < <(jq -r '.[0] | "\(.name) \(.width) \(.height) \(.refreshRate)"' <<<"$json") || true
  [[ -n ${name:-} && $name =~ ^[A-Za-z0-9_-]+$ ]] || return 0
  if [[ $REFRESH_RATE_HZ == auto ]]; then
    # Stay on the current resolution; pick its lowest advertised refresh rate.
    target=$(jq -r --arg res "${w}x${h}" '
      .[0] | [ .availableModes[]?
        | select(startswith($res + "@"))
        | capture("@(?<r>[0-9.]+)Hz$").r
        | tonumber ] | min // empty' <<<"$json")
    if [[ -z $target ]]; then
      bl_log INFO "monitor $name: no ${w}x${h} refresh alternatives; unchanged"
      return 0
    fi
  else
    target=$REFRESH_RATE_HZ
  fi
  [[ $target =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
  # Already at or below the target: leave the mode alone and save nothing.
  if awk -v cur="${r:-60}" -v tgt="$target" 'BEGIN{exit !(cur <= tgt + 0.05)}'; then
    return 0
  fi
  bl_state_set ".profile.monitor = \"$name,${w}x${h}@${r}\""
  # Runtime monitor changes also require the Lua eval API (see hyprland apply).
  if bl_hyprctl eval "hl.monitor({ output = '$name', mode = '${w}x${h}@${target}' })" >/dev/null 2>&1; then
    bl_log INFO "monitor $name: ${w}x${h}@${r} -> ${target}Hz"
  else
    bl_state_set 'del(.profile.monitor)'
    bl_log WARN "monitor refresh cap FAILED ($name @${target})"
  fi
  return 0
}

bl_action_refresh_release() {
  local rec name mode
  rec=$(bl_state_get '.profile.monitor' "")
  [[ -n $rec ]] || return 0
  bl_state_set 'del(.profile.monitor)'
  name=${rec%%,*}
  mode=${rec#*,}
  [[ -n $name && -n $mode && $name =~ ^[A-Za-z0-9_-]+$ && $mode =~ ^[0-9]+x[0-9]+@[0-9.]+$ ]] || return 0
  if bl_hyprctl eval "hl.monitor({ output = '$name', mode = '$mode' })" >/dev/null 2>&1; then
    bl_log INFO "monitor restored: $name $mode"
  else
    bl_log WARN "monitor restore FAILED: $name $mode"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Engage / release orchestration
# ---------------------------------------------------------------------------

bl_engage() {
  # bl_engage <reason> [trigger]  (caller holds the lock)
  # trigger: low | unplug | forced | manual. It records why the profile is
  # engaged so release logic can distinguish "battery recovered" (only valid
  # after a low-battery engagement) from "AC came back".
  local reason=$1 trigger=${2:-manual}
  bl_state_init
  [[ $(bl_state_get '.engaged' false) == true ]] && return 0
  bl_log INFO "ENGAGE ($reason) battery=$(bl_battery_pct)% on_battery=$(bl_on_battery)"
  bl_state_set ".engaged = true | .reason = \"$reason\" | .trigger = \"$trigger\" | .engaged_at = $(date +%s) | .last_transition_at = $(date +%s)"
  # Consume the current unplug episode: once this engagement has served its
  # purpose, releasing it must not be undone two polls later by the same
  # still-open unplug timer.
  if [[ $trigger == low || $trigger == unplug ]]; then
    bl_state_set '.unplug_handled = true'
  fi

  local action
  for action in ppd brightness hyprland services kbd wifi refresh; do
    "bl_action_${action}_apply" || bl_log WARN "$action apply failed (continuing)"
  done

  local paused
  paused=$(bl_state_get '.profile.paused | join(", ")' "")
  local body="$reason"
  [[ -n $paused ]] && body="$reason — paused: $paused"
  bl_notify low  "Brownout active" "$body" --exec brownout release
  return 0
}

bl_release() {
  # bl_release <trigger>  (caller holds the lock)
  local trigger=$1
  bl_state_init
  [[ $(bl_state_get '.engaged' false) == true ]] || return 0
  bl_log INFO "RELEASE ($trigger)"
  RELEASE_TRIGGER=$trigger
  # Reverse order; each step must run even if an earlier one reports failure,
  # otherwise a partial profile would be left behind.
  local action
  for action in refresh wifi kbd services hyprland brightness ppd; do
    "bl_action_${action}_release" || bl_log WARN "$action release failed (continuing)"
  done
  bl_state_set ".engaged = false | .reason = \"\" | .trigger = \"\" | .engaged_at = 0 | .last_transition_at = $(date +%s)"
  bl_notify low 󰄲 "Power restored" "Brownout profile rolled back ($trigger)"
  return 0
}

bl_reapply() {
  # Re-run the profile actions for an engaged state (post theme-set etc).
  bl_state_init
  [[ $(bl_state_get '.engaged' false) == true ]] || return 0
  bl_log INFO "REAPPLY profile (engaged)"
  local action
  for action in ppd brightness hyprland kbd wifi refresh; do
    "bl_action_${action}_apply" || bl_log WARN "$action reapply failed (continuing)"
  done
  return 0
}

# ---------------------------------------------------------------------------
# Sampling (per-unit resource history for the pause chooser)
# ---------------------------------------------------------------------------

bl_sample_units() {
  # Appends one JSONL line per user service unit:
  #   {"t":epoch,"u":"unit","c":cpu_percent,"m":mem_bytes,"b":on_battery,"w":minutes,"agg":0}
  bl_ensure_dirs
  local now interval on_bat prev_ts
  now=$(date +%s)
  on_bat=$(bl_on_battery)
  prev_ts=0
  [[ -r $BROWNOUT_LAST_SAMPLE_FILE ]] && prev_ts=$(head -1 "$BROWNOUT_LAST_SAMPLE_FILE" 2>/dev/null | cut -f1)
  interval=$((now - ${prev_ts:-0}))
  # First sample ever or a wildly stale one: just prime the deltas file.
  if [[ $prev_ts == 0 || $interval -lt 10 || $interval -gt 3600 ]]; then
    interval=$SAMPLE_INTERVAL_SECONDS
  fi

  local cur_file unit cpu_ns mem_ns prev_ns pct mem line
  cur_file=$(mktemp "$BROWNOUT_HOME/sample.XXXXXX")
  printf '%s\n' "$now" >"$cur_file"

  while IFS= read -r unit; do
    [[ -z $unit ]] && continue
    cpu_ns=$(systemctl --user show "$unit" -p CPUUsageNSec --value 2>/dev/null)
    mem_ns=$(systemctl --user show "$unit" -p MemoryCurrent --value 2>/dev/null)
    [[ $cpu_ns =~ ^[0-9]+$ ]] || cpu_ns=0
    [[ $mem_ns =~ ^[0-9]+$ ]] || mem_ns=0
    printf '%s\t%s\t%s\n' "$unit" "$cpu_ns" "$mem_ns" >>"$cur_file"
  done < <(systemctl --user list-units --type=service --all --no-legend --plain 2>/dev/null | awk '{print $1}')

  local minutes
  minutes=$(awk -v i="$interval" 'BEGIN{printf "%.2f", i/60}')
  {
    while IFS=$'\t' read -r unit cpu_ns mem_ns; do
      [[ $unit =~ ^[0-9]+$ ]] && continue # the timestamp line
      prev_ns=0
      if [[ -r $BROWNOUT_LAST_SAMPLE_FILE ]]; then
        prev_ns=$(awk -F'\t' -v u="$unit" '$1==u{print $2; exit}' "$BROWNOUT_LAST_SAMPLE_FILE")
      fi
      [[ $prev_ns =~ ^[0-9]+$ ]] || prev_ns=0
      pct=$(awk -v d="$((cpu_ns - prev_ns))" -v i="$interval" 'BEGIN{ if(i<=0){print 0} else {printf "%.2f", d/1e9/i*100} }')
      jq -cn --arg u "$unit" --argjson t "$now" --argjson c "${pct:-0}" --argjson m "$mem_ns" \
        --argjson b "$on_bat" --argjson w "$minutes" \
        '{t:$t,u:$u,c:$c,m:$m,b:$b,w:$w}'
    done < <(tail -n +2 "$cur_file")
  } >>"$BROWNOUT_USAGE_FILE" 2>/dev/null

  mv "$cur_file" "$BROWNOUT_LAST_SAMPLE_FILE"
  return 0
}

bl_compact_usage() {
  command -v python3 >/dev/null 2>&1 || return 0
  local libdir=$1
  python3 "$libdir/brownout-report.py" compact \
    --file "$BROWNOUT_USAGE_FILE" \
    --retention-days "$HISTORY_RETENTION_DAYS" \
    --raw-hours "$COMPACT_RAW_HOURS" 2>>"$BROWNOUT_LOG_FILE" || true
}
