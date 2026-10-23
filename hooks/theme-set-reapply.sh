#!/bin/bash
# theme-set hook: re-apply the brownout profile after a theme change.
# Theme switches rewrite ~/.config/hypr looknfeel, which clobbers the
# hyprctl keyword overrides brownout set while engaged.
set -uo pipefail
command -v brownout >/dev/null 2>&1 || exit 0
brownout reapply
