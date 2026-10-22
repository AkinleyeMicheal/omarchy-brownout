# Brownout

An emergency power profile for [Omarchy](https://omarchy.org) laptops: when you
unplug or the battery drops below a threshold, the desktop quietly sheds
non-essential load — dim screen, no compositor effects, power-saver, and an
optional set of **user-chosen** services paused — then restores everything when
power returns.

It is a battery *survival mode*, not a settings toggle: it engages on its own,
it remembers what it changed, and it puts every knob back exactly as it found
it.

- **Bar widget** — a leaf in the status bar; dim by default, urgent red while
  active. Click it for status, the mode switch, and a pause chooser.
- **Hysteresis + grace** — engages at 20% (or after 10 s unplugged) and
  releases when AC returns (debounced against UPower glitches), so neither the
  café-table cable wiggle nor a 48%-unplug can rebuild your desktop twice.
  Battery-percentage recovery only ends a *low-battery* engagement; it can
  never flip an unplug engagement back and forth.
- **Nothing is paused by default.** Brownout ships a usage sampler and shows
  you real CPU/energy history per user service, then lets you pick what to stop
  (`brownout top`, or the popup's checkbox list). It never terminates apps.
- **Reversible by construction** — engage records what each action changed;
  release undoes exactly that, in reverse order, and keeps going if one step
  fails so a partial profile can't be left behind.

## Preview

```
$ brownout status
mode:      auto
engaged:   true
reason:    battery at 18%
power:     on battery, battery 18%
paused:    syncthing, dropbox
daemon:    running
```

The bar glyph follows the state: `󰁬` at 35% opacity when idle, in the theme's
urgent colour while engaged.

## Install

From the repo root:

```bash
cd fonsgaudii.brownout
./install.sh
```

The installer is idempotent — run it any time to sync the plugin after editing.
It validates the manifest, copies the plugin to
`~/.config/omarchy/plugins/fonsgaudii.brownout`, links `brownout` into
`~/.local/bin`, installs and starts the user service **fonsgaudii-brownout**,
wires the Omarchy hooks, places the widget in the bar's right section, installs
the `SUPER + ALT + B` popup binding, and runs a health check.

Requirements (checked by `brownout doctor`): `hyprctl`, upower, `jq`,
`python3`, `notify-send`, and a working Omarchy notification command. Wi-Fi
power save additionally wants `iw` plus a sudoers rule (below).

### Uninstall

```bash
./install.sh --remove
```

Removes the plugin, CLI link, service and hooks. Your config
(`~/.config/brownout.conf`) and history (`~/.local/state/brownout/`) are kept;
delete those two by hand for a clean slate.

### Tests

```bash
./tests/sandbox.sh
```

Drives the real daemon inside a stubbed sandbox (11 cases, 35 assertions):
grace + hysteresis, debounced release, unplug-glitch immunity, percentage
recovery semantics per engagement type, manual release suppression, forced
modes, service pause/resume, threshold persistence, blocklist enforcement,
live config reload and removed-unit filtering.

## What it changes

On **engage**, in this order (each step skipped if its config option is off, and
each notes what it changed in `state.json`):

| Action | Detail |
| --- | --- |
| Brightness | Drops to `BRIGHTNESS_FLOOR_PCT` — but only if currently brighter. Uses Omarchy's brightness command, so the on-screen OSD shows the change. |
| Hyprland | Disables blur, shadows, animations, and compositor window transparency via `hyprctl eval`, restoring the previous `hyprctl getoption` values on release. |
| Power profile | `powerprofilesctl set power-saver`. |
| Services | Stops every unit in `PAUSE_SERVICES`. Empty by default. |
| Keyboard backlight | Turns the backlight off (no-op if the hardware has none). |
| Wi-Fi | Opt-in only: `iw … set power_save on`, restored to the prior value. |
| Refresh rate | Opt-in only: caps the built-in panel to `REFRESH_RATE_HZ`, or `auto` for the lowest advertised mode at the current resolution. |

On **release** the same actions unwind in reverse order. Returning to AC also
re-runs Omarchy's `omarchy-powerprofiles-set ac`, which repairs a power profile
you changed by hand while brownout was engaged.

Safety rails: a blocklist regex covering the session, audio and portal units is
enforced in both the library and the CLI, so `PAUSE_SERVICES` cannot take down
your session. No apps are ever signalled, and only **user** units are touched.

### EcoMode coverage: included vs. deliberately omitted

Brownout implements the parts of a Windows-style "EcoMode" spec that can be
done safely, reversibly, and without root:

| Included | How |
| --- | --- |
| Automatic + manual states | Auto / On / Off, hysteresis, AC debounce, notifications. |
| CPU/GPU power direction | PPD `power-saver`, which owns EPP, governor and boost policy on Omarchy. |
| Display power | Brightness floor with OSD, optional fixed/`auto` refresh cap, keyboard backlight off. |
| Compositor simplification | Blur, shadows, animations and compositor window opacity saved and restored. |
| Background load | Usage-ranked pause chooser for **user** services; empty by default. |
| Radio power | Wi-Fi power save, explicitly opt-in with a narrow sudoers rule. |
| Trigger control | Popup stepper and `brownout threshold`, persisted to config. |

Omitted on purpose:

- **Direct CPU max-frequency caps, core parking, boost sysfs writes.** Those
  need root and duplicate/fight PPD; writing them behind PPD's back makes the
  system unpredictable. PPD's `power-saver` is the supported lever.
- **SIGSTOP/SIGTERM of applications.** Freezing arbitrary apps risks data loss
  and breaks audio, VoIP and sync semantics. Brownout stops user *services*,
  which systemd can resume cleanly, and shows their real cost before you pick.
- **Blocking updates/telemetry/indexing.** Omarchy updates are manual, Arch has
  no telemetry pipeline, and system timers need root. Add specific user units
  to `PAUSE_SERVICES` if you have an indexing or sync daemon.
- **Rewriting idle/suspend timeouts.** Omarchy's `hypridle` config is
  user-owned; swapping it mid-session can cause surprise locks or suspends.
- **Bluetooth/rfkill and network blocking.** These can drop input devices or
  calls; Wi-Fi power save is the one radio knob offered, and it is opt-in.
- **Charge limits.** Firmware/EC-specific; not portable across laptops.

## Modes

| Mode | Behaviour |
| --- | --- |
| `auto` (default) | Engage on unplug/low battery, release on AC/recovery. |
| `on` | Force the profile now. Stays engaged even on AC, until you switch back. |
| `off` | Suppress automatic engagement. Releases anything active. |

The state machine: engage when discharging at ≤ `ENGAGE_THRESHOLD`, or
`UNPLUG_GRACE_SECONDS` after unplugging. Release when AC has been present for
`AC_RELEASE_SECONDS`, or when a *low-battery* engagement's pack recovers to
≥ `RELEASE_THRESHOLD`. Each unplug episode triggers at most one engagement, so
release can never be followed by the same open episode re-engaging it.

## CLI

```
brownout on|off|auto        set mode (on forces the profile; off suppresses auto)
brownout toggle             cycle auto -> on -> off -> auto
brownout release            roll the profile back now, stay in auto
brownout threshold [N]      show/set the auto-engage battery % (5-50)
brownout status [--json]    current state; --json for scripting
brownout top [--json] [--limit N] [--live]
                            rank user services by CPU/energy use over 24 h,
                            plus an on-battery CPU-min/7d column; --live adds
                            a 2 s live CPU sample
brownout pause-toggle UNIT  add/remove a unit from the pause list
brownout pause-add UNIT
brownout pause-remove UNIT
brownout reapply            re-apply profile actions (theme-set hook uses this)
brownout simulate <unplug|plug|low [pct]|recover [pct]|clear>
                            drive the state machine without touching the cable
brownout doctor             environment and installation health check
brownout log [-n N]         tail the audit log
```

Notes:

- `brownout` is its own command. Omarchy's dispatcher only scans packaged
  `/usr/share/omarchy/bin`, so there is no `omarchy brownout` subcommand.
- `simulate` writes a marker file the watcher reads instead of upower, so you
  can test the whole cycle safely. `brownout simulate clear` returns to reality.
- All commands are safe to run concurrently with the daemon: engage/release
  take a lock and state writes are atomic.

## Bar widget

Placed in the right section of the bar. The glyph is `nf-fa-leaf` (U+F06C) from
Nerd Font, rendering in the bar's foreground colour at 35% opacity when idle and
in the urgent colour when engaged.

Click opens the popup:

- **Status**: state, power source, active reason, and a one-line profile summary.
- **Mode switch**: Auto / On / Off.
- **Auto-engage threshold**: −5 / +5 stepper (5–50%). Writes
  `ENGAGE_THRESHOLD` to the config; the release threshold stays at least 5
  points above it.
- **Pause during brownout** — every user service with real usage numbers
  (24 h average CPU, CPU-minutes, on-battery CPU-minutes over 7 days, memory).
  Click a row to toggle a checkbox; the pause list is applied live and persisted
  to `PAUSE_SERVICES`. Rows update from the sampler.
- **Pinned header, scrollable list** — status, mode switch and the threshold
  stepper stay visible; the service list scrolls inside a height-capped card
  (~560 px) with a draggable scrollbar (mouse wheel works over the list too).

**Keyboard:** `SUPER + ALT + B` opens/closes the same popup from anywhere. The
installer writes it as a marked block in `~/.config/hypr/bindings.lua`; edit or
move that line if you prefer another combo (it runs
`omarchy-shell shell toggle fonsgaudii.brownout`, so it works from scripts too).

The widget reads `~/.local/state/brownout/state.json` (watched, plus a
5 s refresh) and shells out to `brownout top --json` for candidates, so the
QML side stays thin and the daemon owns all state.

## Usage sampling and the pause chooser

The daemon samples every user service once a minute into
`~/.local/state/brownout/usage/usage.jsonl`, tagging each sample with whether
the machine was on battery. Raw minute samples are kept for
`COMPACT_RAW_HOURS` (48 h) and then compacted to hourly rows, with
`HISTORY_RETENTION_DAYS` (14 days) of history overall.

That history is the point: the chooser shows what a service actually costs
*before* you pause it, including a battery-specific column so you can see which
services are only expensive on battery. `brownout top` shows the same data in
the terminal.

`PAUSE_SERVICES` is empty out of the box. You fill it from the popup or:

```bash
brownout pause-add syncthing.service
brownout pause-remove syncthing.service
```

## Configuration

Copy `brownout.conf.example` to `~/.config/brownout.conf` (the installer does
this on first run). It is sourced by bash: `KEY=value`, no spaces around `=`.

| Key | Default | Meaning |
| --- | --- | --- |
| `ENGAGE_THRESHOLD` | `20` | Engage at or below this battery %. |
| `RELEASE_THRESHOLD` | `25` | End a low-battery engagement at/above this %. Must exceed `ENGAGE_THRESHOLD` (auto-repaired). |
| `UNPLUG_GRACE_SECONDS` | `10` | Delay after unplugging before engaging. |
| `AC_RELEASE_SECONDS` | `3` | AC must persist this long before release (UPower debounce). |
| `BRIGHTNESS_FLOOR_PCT` | `25` | Dim target (only ever lowers). |
| `DISABLE_BLUR` | `true` | Strip Hyprland blur while engaged. |
| `DISABLE_SHADOWS` | `true` | Strip window shadows while engaged. |
| `DISABLE_TRANSPARENCY` | `true` | Force compositor window opacity to 1.0 while engaged. |
| `DISABLE_ANIMATIONS` | `true` | Strip Hyprland animations while engaged. |
| `USE_POWER_SAVER` | `true` | Switch PPD to power-saver. |
| `KEYBOARD_BACKLIGHT_OFF` | `true` | Kill keyboard backlight. |
| `PAUSE_SERVICES` | `""` | Space-separated user units to stop. **Empty by default.** |
| `WIFI_POWER_SAVE` | `false` | Toggle Wi-Fi power save (needs sudoers, below). |
| `WIFI_INTERFACE` | `""` | Wi-Fi iface; empty autodetects. |
| `REFRESH_RATE_HZ` | `0` | Cap panel refresh while engaged; `auto` = lowest mode at current resolution; `0` disables. |
| `NOTIFY` | `true` | Desktop notifications on engage/release. |
| `POLL_SECONDS` | `5` | Power-state poll cadence. |
| `SAMPLE_INTERVAL_SECONDS` | `60` | Usage sampler cadence. |
| `HISTORY_RETENTION_DAYS` | `14` | Sampler history retention. |
| `COMPACT_RAW_HOURS` | `48` | Raw sample window before compaction. |
| `TOP_LIMIT` | `8` | Rows in `brownout top` / popup. |
| `LOG_MAX_LINES` | `5000` | Audit log cap. |

After editing, no restart is needed for most keys (they are re-read on each
transition); `systemctl --user restart fonsgaudii-brownout` guarantees it.

## Wi-Fi power save (optional, off by default)

Brownout will not touch Wi-Fi unless you explicitly opt in, because mutating
radio power save needs root. To enable it, grant passwordless sudo for exactly
the `iw` invocations used:

```bash
sudo tee /etc/sudoers.d/brownout-iw >/dev/null <<'EOF'
# brownout: toggle Wi-Fi power save without a password
fonsgaudii ALL=(root) NOPASSWD: /usr/bin/iw dev * set power_save on, \
                                /usr/bin/iw dev * set power_save off, \
                                /usr/bin/iw dev * set power_save auto
EOF
sudo chmod 0440 /etc/sudoers.d/brownout-iw
```

Then set `WIFI_POWER_SAVE=true`. The daemon never prompts: it uses `sudo -n`
only, and if the rule is missing it logs a warning and continues with the rest
of the profile.

## Notifications

With `NOTIFY=true`, engaging and releasing each raise one low-priority Omarchy
notification. The engaging notification offers a **Release now** action that
runs `brownout release` — useful when you're at 19% and would rather keep the
desktop as-is.

## Troubleshooting

Start with:

```bash
brownout doctor
brownout status
brownout log -n 50
systemctl --user status fonsgaudii-brownout.service
```

Common cases:

- **Widget missing from the bar.** `omarchy plugin list | grep brownout`
  should show it enabled as a third-party bar-widget;
  `omarchy-shell shell rescanPlugins` or `omarchy restart shell` rebuilds the bar.
- **Glyph renders as tofu or the wrong shape.** The bar needs a Nerd Font
  (Omarchy ships JetBrainsMono Nerd Font). Brownout uses U+F06C (`nf-fa-leaf`);
  the popup's checkboxes use U+F0131/U+F0132.
- **It engaged but nothing dimmed.** Brightness is only lowered, never raised,
  and the Omarchy brightness helper must be on `PATH`. Check the log for the
  action's line.
- **PPD shows `balanced` while engaged.** Either `USE_POWER_SAVER=false`, or
  something re-set the profile; `brownout reapply` re-applies the profile.
- **A service won't pause.** The blocklist refuses session/audio/portal units,
  and only *user* units are managed. Try `brownout pause-add` and read the
  error.
- **Engaged at 30%?** Check `REFRESH_RATE_HZ` — a mode switch on some panels
  makes upower report a battery-percentage jump; this is also why refresh
  capping is opt-in.
- **Stuck engaged after a crash.** The daemon records engagement in
  `state.json`; `brownout release` always rolls back, and the service restarts
  cleanly. A `brownout fallback-engage` hook covers the 10% battery-low path if
  the daemon is dead.
- **Repeated engage/release flapping.** The daemon now budgets one engagement
  per unplug episode and debounces the AC edge, so this should not happen. If
  it does, capture the transition lines with `brownout log -n 80` — they name
  the trigger (`unplugged from AC`, `battery at N%`, `plugged in`) — and check
  that `RELEASE_THRESHOLD` is above `ENGAGE_THRESHOLD` (values are clamped at
  startup, and the effective values are logged on every start).

Logs live in `~/.local/state/brownout/brownout.log` (bounded by
`LOG_MAX_LINES`); usage history in `~/.local/state/brownout/usage/`.

## Architecture

```
┌───────────────────────────┐        state.json        ┌──────────────────────┐
│ brownout-watch (systemd   │  ──────────────────────▶ │ BarWidget.qml        │
│ --user daemon, 5 s poll)  │  ◀────────────────────── │ (thin view: file +   │
│  • upower power source    │      brownout CLI        │  `brownout top`)     │
│  • grace + hysteresis     │  ◀────────────────────── │                      │
│  • engage/release actions │                          └──────────────────────┘
│  • usage sampler          │
└────────────┬──────────────┘
             │ sources
      lib/brownout-lib.bash   (config, state, lock, notify, actions, sampler)
             │
   bin/brownout (CLI) · lib/brownout-report.py (aggregation + compaction)
```

Design decisions worth knowing:

- **The daemon, not the shell, owns state.** A shell restart or crash must not
  leave the machine stuck dimmed with services stopped. The watcher is a small
  bash service; the QML widget only renders `state.json`.
- **Actions are recorded before they are applied**, so release has something to
  restore even if a later step fails mid-profile.
- **Hyprland 0.56 uses the Lua config API**, so effects are toggled with
  `hyprctl eval 'hl.config({…})'`, not `hyprctl keyword`.
- **No sudoers changes by default**, no app termination, no default pausing:
  the invasive options are the ones you must opt into.

## Files

```
fonsgaudii.brownout/
├── manifest.json              plugin manifest (bar-widget)
├── BarWidget.qml              bar glyph + popup
├── Model.js                   parsing/formatting helpers for the widget
├── bin/brownout               CLI
├── bin/brownout-watch         daemon (systemd --user)
├── lib/brownout-lib.bash      shared core
├── lib/brownout-report.py     usage aggregation/compaction
├── hooks/                     theme-set reapply, battery-low fallback
├── systemd/                   user unit
├── brownout.conf.example      annotated config
└── install.sh                 installer / uninstaller
```

Runtime files: `~/.config/brownout.conf`, `~/.local/state/brownout/`
(`state.json`, `brownout.log`, `usage/`).
