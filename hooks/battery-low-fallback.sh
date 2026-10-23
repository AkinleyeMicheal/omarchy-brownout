#!/bin/bash
# battery-low hook: engage brownout when Omarchy's own battery service fires
# its low-battery warning *and* our watcher is not running (dead/failed).
# When the watcher is alive it owns threshold logic and this exits instantly.
set -uo pipefail
level="${1:-?}"
command -v brownout >/dev/null 2>&1 || exit 0
brownout fallback-engage "$level"
