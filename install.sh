#!/bin/bash

# Install omarchy-matrix: the matrix workspace layout for Hyprland, its window
# frames and bar button for the Omarchy shell, and its place in the Omarchy
# menu and workspace modes. Run again to update; uninstall.sh takes it out.

set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}
PLUGINS="$CONFIG/omarchy/plugins"
HYPR="$CONFIG/hypr"
BIN="$HOME/.local/bin"
MENU="$CONFIG/omarchy/extensions/omarchy-menu.jsonc"
STAMP=$(date +%s)

say() { printf '\033[1momarchy-matrix:\033[0m %s\n' "$*"; }
fail() { printf 'omarchy-matrix: %s\n' "$*" >&2; exit 1; }

# The shell learns about new plugin folders on a rescan; wait until it lists them.
wait_known() {
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  local id tries
  for id in "$@"; do
    for tries in $(seq 50); do
      omarchy plugin list --json 2>/dev/null | jq -e --arg id "$id" 'any(.[]; .id == $id)' >/dev/null && break
      sleep 0.2
    done
  done
}

command -v omarchy >/dev/null || fail "Omarchy is not installed (no omarchy command)"
command -v hyprctl >/dev/null || fail "Hyprland is not running (no hyprctl)"
[[ -f $HYPR/hyprland.lua ]] || fail "$HYPR/hyprland.lua not found: this needs Omarchy's Lua Hyprland config"

for plugin in "$SRC"/plugins/*/; do
  omarchy plugin validate "$plugin" || fail "invalid plugin: $plugin"
done

# Shell plugins.
mkdir -p "$PLUGINS"
for plugin in "$SRC"/plugins/*/; do
  id=$(basename "$plugin")
  rm -rf "${PLUGINS:?}/$id"
  cp -r "$plugin" "$PLUGINS/$id"
  say "plugin $id"
done

# Hyprland layout, loaded before Omarchy's toggles so saved matrix workspace
# modes can be restored.
cp "$SRC/hypr/omarchy-matrix.lua" "$HYPR/omarchy-matrix.lua"
if ! grep -q 'require("hypr.omarchy-matrix")' "$HYPR/hyprland.lua"; then
  cp "$HYPR/hyprland.lua" "$HYPR/hyprland.lua.bak.$STAMP"
  python3 - "$HYPR/hyprland.lua" <<'EOF'
import sys
path = sys.argv[1]
text = open(path).read()
line = '-- Matrix workspace layout (omarchy-matrix).\nrequire("hypr.omarchy-matrix")\n\n'
anchor = 'require("default.hypr.toggles")'
at = text.find(anchor)
if at < 0:
    text = text.rstrip("\n") + "\n\n" + line
else:
    start = text.rfind("\n\n", 0, at)
    start = 0 if start < 0 else start + 2
    text = text[:start] + line + text[start:]
open(path, "w").write(text)
EOF
  say "hyprland.lua loads hypr/omarchy-matrix.lua (backup: hyprland.lua.bak.$STAMP)"
fi

# Commands.
mkdir -p "$BIN"
install -m 755 "$SRC/bin/matrix-layout-default" "$BIN/matrix-layout-default"
install -m 755 "$SRC/bin/matrix-panel-mem" "$BIN/matrix-panel-mem"
say "commands in $BIN"

# Menu: Appearance > Workspace Layout with matrix. The tiles of the bar button
# need omarchy-menu-plus; the stock menu gets glyphs.
if [[ -d $PLUGINS/menuplus.menu ]]; then
  icons=(layout:dwindle layout:scrolling layout:floating layout:matrix)
else
  icons=(󱓻 󰝥 󰔶 󰕰)
fi
mkdir -p "$(dirname "$MENU")"
[[ -f $MENU ]] || printf '{\n}\n' >"$MENU"
cp "$MENU" "$MENU.bak.$STAMP"
python3 - "$MENU" "$SRC/menu/workspace-layout.jsonc" "${icons[@]}" <<'EOF'
import sys
path, block_path, dwindle, scrolling, floating, matrix = sys.argv[1:7]
BEGIN, END = "  // omarchy-matrix begin", "  // omarchy-matrix end"
block = open(block_path).read().rstrip("\n")
for key, value in (("DWINDLE", dwindle), ("SCROLLING", scrolling), ("FLOATING", floating), ("MATRIX", matrix)):
    block = block.replace("@ICON_%s@" % key, value)
lines = open(path).read().split("\n")
if BEGIN in lines:
    start, end = lines.index(BEGIN), lines.index(END)
    del lines[start:end + 1]
close = max(i for i, l in enumerate(lines) if l.strip() == "}")
# The entry before the block needs its comma.
for i in range(close - 1, -1, -1):
    stripped = lines[i].strip()
    if stripped and not stripped.startswith("//"):
        if not stripped.endswith((",", "{")):
            lines[i] = lines[i] + ","
        break
lines[close:close] = [BEGIN, block, END]
open(path, "w").write("\n".join(lines))
EOF
say "menu entries in $MENU"

wait_known matrix.frames matrix.layout-mode

# Turn the plugins on: the layout button goes next to the Omarchy menu button.
omarchy plugin enable matrix.frames >/dev/null
if omarchy plugin list --json | jq -e '.[] | select(.id == "matrix.layout-mode" and .enabled == true)' >/dev/null; then
  :
elif omarchy plugin list --json | jq -e '.[] | select(.id == "menuplus.menu" and .enabled == true)' >/dev/null; then
  omarchy plugin enable matrix.layout-mode --section left --after menuplus.menu >/dev/null
else
  omarchy plugin enable matrix.layout-mode --section left --after omarchy.menu >/dev/null || omarchy plugin enable matrix.layout-mode --section left >/dev/null
fi

hyprctl reload >/dev/null
errors=$(hyprctl configerrors 2>/dev/null | grep -v '^$' || true)
[[ -z $errors ]] || printf 'Hyprland reports:\n%s\n' "$errors" >&2
omarchy restart shell >/dev/null 2>&1 || true

say "installed. SUPER + L cycles tiling -> scrolling -> floating -> matrix; Appearance > Workspace Layout sets the default."
