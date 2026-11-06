#!/bin/bash

# Take omarchy-matrix out again: plugins, Hyprland layout, commands and menu
# entries. Workspaces saved in matrix mode go back to Omarchy's default layout.

set -euo pipefail

CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}
PLUGINS="$CONFIG/omarchy/plugins"
HYPR="$CONFIG/hypr"
BIN="$HOME/.local/bin"
MENU="$CONFIG/omarchy/extensions/omarchy-menu.jsonc"
MODES="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/workspace-layouts"
STAMP=$(date +%s)

say() { printf '\033[1momarchy-matrix:\033[0m %s\n' "$*"; }

for id in matrix.layout-mode matrix.frames; do
  omarchy plugin disable "$id" >/dev/null 2>&1 || true
  rm -rf "${PLUGINS:?}/$id"
done
say "plugins removed"

# Saved matrix modes would name a layout Hyprland no longer has.
for file in "$MODES"/*.lua; do
  [[ -f $file ]] || continue
  if grep -q 'mode = "matrix"\|default = "matrix"\|lua:matrix' "$file"; then
    rm -f "$file"
  fi
done

if [[ -f $HYPR/hyprland.lua ]] && grep -q 'require("hypr.omarchy-matrix")' "$HYPR/hyprland.lua"; then
  cp "$HYPR/hyprland.lua" "$HYPR/hyprland.lua.bak.$STAMP"
  sed -i '/^-- Matrix workspace layout (omarchy-matrix)\.$/d; /^require("hypr.omarchy-matrix")$/d' "$HYPR/hyprland.lua"
fi
rm -f "$HYPR/omarchy-matrix.lua"
rm -f "$BIN/matrix-layout-default" "$BIN/matrix-panel-mem"

if [[ -f $MENU ]] && grep -q '// omarchy-matrix begin' "$MENU"; then
  cp "$MENU" "$MENU.bak.$STAMP"
  sed -i '/^  \/\/ omarchy-matrix begin$/,/^  \/\/ omarchy-matrix end$/d' "$MENU"
fi

hyprctl reload >/dev/null 2>&1 || true
omarchy restart shell >/dev/null 2>&1 || true
say "uninstalled"
