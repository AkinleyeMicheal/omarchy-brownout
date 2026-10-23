#!/bin/bash
# install.sh — install the brownout plugin into this Omarchy system.
# Idempotent: re-run any time to sync the installed copy and re-apply wiring.
#
#   ./install.sh           copy plugin into ~/.config/omarchy/plugins, link the
#                          CLI, install the user unit + hooks, place the widget
#   ./install.sh --remove  reverse it (keeps your config and state)
set -euo pipefail

SRC=$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
PLUGIN_ID="fonsgaudii.brownout"
DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
BIN_LINK="$HOME/.local/bin/brownout"
UNIT_NAME="fonsgaudii-brownout.service"
UNIT_SRC="$SRC/systemd/$UNIT_NAME"
UNIT_DEST="$HOME/.config/systemd/user/$UNIT_NAME"
CONFIG="$HOME/.config/brownout.conf"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
BINDINGS="$HOME/.config/hypr/bindings.lua"
BIND_MARK_BEGIN="-- >>> brownout plugin >>>"
BIND_MARK_END="-- <<< brownout plugin <<<"
BIND_KEY="SUPER + ALT + B"

# Remove only the brownout block from bindings.lua, leaving every other
# personal binding (and any edits the user made around it) untouched.
strip_binding_block() {
  [[ -f $BINDINGS ]] || return 0
  local tmp="$BINDINGS.brownout.$$"
  awk -v begin="$BIND_MARK_BEGIN" -v end="$BIND_MARK_END" '
    $0 == begin { skip = 1; next }
    $0 == end   { skip = 0; next }
    !skip       { print }
  ' "$BINDINGS" >"$tmp" && mv "$tmp" "$BINDINGS"
}

install_binding() {
  mkdir -p "$(dirname "$BINDINGS")"
  touch "$BINDINGS"
  strip_binding_block
  cat >>"$BINDINGS" <<EOF

$BIND_MARK_BEGIN
-- Open the brownout popup (same as clicking the leaf in the bar).
o.bind("$BIND_KEY", "Brownout", "omarchy-shell shell toggle fonsgaudii.brownout")
$BIND_MARK_END
EOF
}

reload_hyprland() {
  command -v hyprctl >/dev/null 2>&1 || return 0
  hyprctl reload >/dev/null 2>&1 || true
}

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '    \033[1;32m✓\033[0m %s\n' "$*"; }

remove() {
  say "removing $PLUGIN_ID"
  systemctl --user disable --now "$UNIT_NAME" 2>/dev/null || true
  omarchy-shell shell setPluginEnabled "$PLUGIN_ID" false >/dev/null 2>&1 || true
  rm -f "$UNIT_DEST" "$BIN_LINK"
  rm -rf "$DEST"
  rm -f "$HOME/.config/omarchy/hooks/theme-set.d/theme-set-reapply.sh" \
        "$HOME/.config/omarchy/hooks/battery-low.d/battery-low-fallback.sh"
  strip_binding_block
  reload_hyprland
  systemctl --user daemon-reload 2>/dev/null || true
  omarchy-shell shell rescanPlugins 2>/dev/null || true
  ok "removed (config $CONFIG and state kept)"
  exit 0
}

[[ ${1:-} == --remove ]] && remove

# 1. Validate the plugin folder against Omarchy's manifest schema.
say "validating plugin manifest"
omarchy plugin validate "$SRC"
ok "manifest valid"

# 2. Sync the plugin folder (state/config live outside it, so this is safe).
say "installing plugin to $DEST"
mkdir -p "$HOME/.config/omarchy/plugins" "$HOME/.local/bin"
tmp="$DEST.new.$$"
rm -rf "$tmp"
mkdir -p "$tmp"
(cd "$SRC" && tar --exclude=.git --exclude=install.sh --exclude=tests --exclude=screenshots \
  --exclude=.gitignore --exclude=LICENSE --exclude=README.md --exclude=__pycache__ --exclude='*.pyc' -cf - .) | (cd "$tmp" && tar -xf -)
chmod +x "$tmp"/bin/* "$tmp"/hooks/*.sh
# A previous interrupted copy left a zero-padded file behind; refuse to install
# anything empty or carrying NUL padding.
for f in bin/brownout bin/brownout-watch lib/brownout-lib.bash \
  lib/brownout-report.py BarWidget.qml Model.js manifest.json; do
  if [[ ! -s $tmp/$f ]]; then
    echo "install: $f is missing or empty" >&2
    exit 1
  fi
  if ! tr -d '\000' <"$tmp/$f" | cmp -s - "$tmp/$f"; then
    echo "install: $f contains NUL padding" >&2
    exit 1
  fi
done
rm -rf "$DEST.old" && { [[ -d $DEST ]] && mv "$DEST" "$DEST.old" || true; }
mv "$tmp" "$DEST"
rm -rf "$DEST.old"
ok "plugin files synced"

# 3. CLI on PATH.
ln -sfn "$DEST/bin/brownout" "$BIN_LINK"
ok "CLI linked: $BIN_LINK"

# 4. Config skeleton (never overwrites an existing one).
if [[ ! -f $CONFIG ]]; then
  cp "$DEST/brownout.conf.example" "$CONFIG"
  ok "default config written to $CONFIG"
else
  ok "existing config kept"
fi

# 5. systemd user unit.
say "installing user service"
mkdir -p "$HOME/.config/systemd/user"
cp "$UNIT_SRC" "$UNIT_DEST"
systemctl --user daemon-reload
systemctl --user enable --now "$UNIT_NAME" 2>/dev/null
systemctl --user restart "$UNIT_NAME"
ok "service enabled and running"

# 6. Hooks (theme-set reapply + battery-low fallback).
say "installing hooks"
mkdir -p "$HOME/.config/omarchy/hooks/theme-set.d" "$HOME/.config/omarchy/hooks/battery-low.d"
cp "$SRC/hooks/theme-set-reapply.sh" "$HOME/.config/omarchy/hooks/theme-set.d/theme-set-reapply.sh"
cp "$SRC/hooks/battery-low-fallback.sh" "$HOME/.config/omarchy/hooks/battery-low.d/battery-low-fallback.sh"
chmod +x "$HOME/.config/omarchy/hooks/theme-set.d/theme-set-reapply.sh" \
         "$HOME/.config/omarchy/hooks/battery-low.d/battery-low-fallback.sh"
ok "theme-set + battery-low hooks installed"

# 7. Keybinding: one dedicated combo opens the widget popup.
say "installing keybinding ($BIND_KEY)"
install_binding
reload_hyprland
ok "binding installed in $BINDINGS (marked block, safe to move)"

# 8. Shell: rescan plugins, enable the widget, place it in the right section.
say "registering bar widget"
omarchy-shell shell rescanPlugins 2>/dev/null || true
if ! omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1; then
  # Already enabled or enable is a no-op for bar widgets — fine.
  true
fi
if [[ -f $SHELL_JSON ]] && ! jq -e --arg id "$PLUGIN_ID" \
    '[.bar.layout // {} | to_entries[] | .value[]?] | any(.id == $id)' \
    "$SHELL_JSON" >/dev/null 2>&1; then
  omarchy bar put "$PLUGIN_ID" --section right >/dev/null 2>&1 || \
    omarchy bar put "$PLUGIN_ID" >/dev/null 2>&1 || true
fi
ok "widget registered"

# 9. Health check.
say "doctor"
"$DEST/bin/brownout" doctor || true

cat <<'MSG'

    brownout is installed.
      command:   brownout status | on | off | auto | top | doctor
      popup:     SUPER + ALT + B  (or click the leaf in the bar)
      config:    ~/.config/brownout.conf
      widget:    leaf glyph in the bar (right section) — click for controls
      history:   ~/.local/state/brownout/
MSG
