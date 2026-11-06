-- Matrix layout: a scrolling layout whose columns can hold several stacked
-- windows. Columns scroll horizontally and each column scrolls vertically.
--
-- Workspace layout name: "lua:matrix", Omarchy workspace mode "matrix" (SUPER + L
-- or the bar button cycles dwindle -> scrolling -> floating -> matrix; SUPER +
-- ALT + L or right click goes back; Appearance > Workspace Layout sets it as the
-- default).
--
--   SUPER + J                 Pull the most visible neighbour window into this column
--                             (left neighbour goes above, right neighbour goes below)
--   SUPER + SHIFT + J         Expel the active window into its own column to the right
--   SUPER + arrows            Move focus through the matrix
--   SUPER + SHIFT + LEFT/RIGHT  Take the window out of its column to that side, or, when it
--                             is alone, move it to the bottom of the neighbouring column
--   SUPER + SHIFT + UP/DOWN   Move the window up or down inside its column
--   SUPER + mouse wheel       Vertical wheel scrolls the column, horizontal wheel the row
--   Mouse wheel (no SUPER)    Over a header or a gap: change column (up/left = left,
--                             down/right = right). Inside a window, horizontal scroll
--                             changes column only for NO_HSCROLL apps; others get it.
--   3-finger swipe            Change column (fingers left = column to the right)
--   SUPER + -/= (and SHIFT, ALT, CTRL variants), SUPER + right drag
--                             Resize the column width and the window height
--   SUPER + left drag         Drop a window on a neighbouring column (below its visible window)
--
-- Every window gets a header row drawn by the matrix.frames shell plugin
-- (~/.config/omarchy/plugins/matrix.frames), which reads the state
-- this file writes to $XDG_RUNTIME_DIR/omarchy-matrix.json.

local LAYOUT = "lua:matrix"

-- Height of the header row above each window, in logical pixels. Stacked
-- windows leave just enough room above and below for a neighbour's header.
local HEADER = 24

-- Smallest column width / window height, as a fraction of the screen.
local MIN_SIZE = 0.1

-- Apps that never scroll sideways themselves, so horizontal scroll inside
-- them changes column. Lua patterns matched against the window class. Any
-- other app receives its horizontal scroll: Hyprland can't tell when an app
-- has reached the end of it.
local NO_HSCROLL = {
  "^Alacritty$",
  "^kitty$",
  "^foot$",
  "^com%.mitchellh%.ghostty$",
}

local STATE_FILE = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/omarchy-matrix.json"

matrix = matrix or {}
matrix.ws = matrix.ws or {}

local function notify(message)
  hl.exec_cmd(o.notify(message))
end

local function number_config(key, fallback)
  local ok, value = pcall(hl.get_config, key)
  if ok and type(value) == "number" then
    return value
  end
  return fallback
end

local function gaps_in()
  local ok, value = pcall(hl.get_config, "general.gaps_in")
  if ok and type(value) == "table" then
    return {
      top = value.top or 5,
      right = value.right or 5,
      bottom = value.bottom or 5,
      left = value.left or 5,
    }
  end
  local n = ok and type(value) == "number" and value or 5
  return { top = n, right = n, bottom = n, left = n }
end

local function clamp(value, low, high)
  return math.max(low, math.min(value, high))
end

local function is_matrix_window(window)
  return window ~= nil
    and not window.floating
    and window.workspace ~= nil
    and window.workspace.tiled_layout == LAYOUT
end

-- Omarchy workspace modes (Appearance > Workspace Layout, SUPER + L): matrix is
-- one more mode next to dwindle, scrolling and floating. Saved modes reload with
-- the config, so these start empty on every load.
matrix.modes = {}
matrix.default_mode = nil
matrix.borderless = {}

-- "matrix" in saved files and menus, "lua:matrix" for Hyprland.
local function layout_of(mode)
  return (mode == "matrix" or mode == LAYOUT) and LAYOUT or mode
end

local function mode_name(layout)
  return layout == LAYOUT and "matrix" or layout
end

-- Mode of a workspace as Omarchy names it: dwindle, scrolling, floating or matrix.
local function mode_of(workspace)
  local id = tonumber(workspace.id) or 0
  local mode = id >= 1 and (matrix.modes[tostring(id)] or matrix.default_mode) or nil
  if mode == "floating" then
    return "floating"
  end
  return mode_name(workspace.tiled_layout or "dwindle")
end

local function active_is_matrix()
  local workspace = hl.get_active_workspace()
  return workspace ~= nil and workspace.tiled_layout == LAYOUT and mode_of(workspace) ~= "floating"
end

local function state_for(id)
  local state = matrix.ws[id]
  if not state then
    state = { cols = {}, sx = 0, heights = {} }
    matrix.ws[id] = state
  end
  state.id = id
  state.heights = state.heights or {}
  return state
end

local function find(state, address)
  for c, col in ipairs(state.cols) do
    for r, addr in ipairs(col.wins) do
      if addr == address then
        return c, r
      end
    end
  end
end

local function new_column(address)
  return { wins = { address }, row = 1, sy = 0 }
end

-- Bring the stored grid in line with the windows Hyprland gives us: drop
-- closed windows and open new ones as columns right of the last focused one.
local function sync(state, targets)
  local present = {}
  for _, target in ipairs(targets) do
    if target.window then
      present[target.window.address] = true
    end
  end

  local anchor = state.last and find(state, state.last) or #state.cols
  local cols = {}
  local known = {}
  for c, col in ipairs(state.cols) do
    local wins = {}
    local focused = col.wins[col.row or 1]
    for _, addr in ipairs(col.wins) do
      if present[addr] then
        table.insert(wins, addr)
        known[addr] = true
      end
    end
    if #wins > 0 then
      col.wins = wins
      col.row = 1
      for r, addr in ipairs(wins) do
        if addr == focused then
          col.row = r
        end
      end
      table.insert(cols, col)
    elseif c <= anchor then
      anchor = anchor - 1
    end
  end
  state.cols = cols

  for addr in pairs(state.heights) do
    if not present[addr] then
      state.heights[addr] = nil
    end
  end

  anchor = clamp(anchor, 0, #state.cols)
  for _, target in ipairs(targets) do
    local addr = target.window and target.window.address
    if addr and not known[addr] then
      anchor = anchor + 1
      table.insert(state.cols, anchor, new_column(addr))
      known[addr] = true
    end
  end
end

-- Scroll offset that keeps [first, last) visible inside a view of length view.
local function follow(offset, first, last, view, total, center)
  if last - first >= view then
    offset = first
  elseif center then
    offset = (first + last) / 2 - view / 2
  elseif first < offset then
    offset = first
  elseif last > offset + view then
    offset = last - view
  end
  return clamp(offset, 0, math.max(0, total - view))
end

-- Column width as a fraction of the screen width. A lone column always spans
-- the whole workspace.
local function column_fraction(state, col)
  if #state.cols == 1 then
    return 1
  end
  return col.width or number_config("scrolling.column_width", 0.5)
end

-- Matrix windows get no Hyprland border; the shell draws one frame of this
-- width around the header and the window together.
local function border_size()
  return number_config("general.border_size", 2)
end

-- First color of a Hyprland gradient as #AARRGGBB, for the shell.
local function border_color(key, fallback)
  local ok, value = pcall(hl.get_config, key)
  if ok and type(value) == "table" then
    local colors = value.colors or value
    local first = colors[1]
    if type(first) == "number" then
      return string.format("#%08X", first)
    elseif type(first) == "string" and first:match("^0x%x%x%x%x%x%x%x%x$") then
      return "#" .. first:sub(3):upper()
    end
  end
  return fallback
end

-- Glassy windows (Appearance > Windows > Window Opacity): the headers turn
-- see-through and blurred like the terminals. The toggle file loads after this
-- one, so it is looked up on disk.
local TOGGLES_DIR = (os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or "") .. "/.local/state")) .. "/omarchy/toggles/hypr"

local function glassy()
  local file = io.open(TOGGLES_DIR .. "/window-glassy.lua", "r")
  if file then
    file:close()
    return true
  end
  return false
end

-- Width / height of layout.single_window_aspect_ratio (Appearance > Windows >
-- 1-Window Ratio), or nil when it is off.
local function single_window_ratio()
  local ok, value = pcall(hl.get_config, "layout.single_window_aspect_ratio")
  if ok and type(value) == "table" then
    local x, y = tonumber(value.x or value[1]) or 0, tonumber(value.y or value[2]) or 0
    if x > 0 and y > 0 then
      return x / y
    end
  end
  return nil
end

-- Space a neighbour's header needs to stay visible above or below a window.
local function peek_size()
  return HEADER + border_size() + gaps_in().top
end

-- Window height as a fraction of the screen height. A lone window fills the
-- column; stacked windows default to the full height minus a header peek for
-- each neighbour, and keep any height they were resized to.
local function row_fraction(state, col, r, area_h)
  if #col.wins <= 1 then
    return 1
  end
  local custom = state.heights[col.wins[r]]
  if custom then
    return custom
  end
  local peeks = (r > 1 and 1 or 0) + (r < #col.wins and 1 or 0)
  return (area_h - peeks * peek_size()) / area_h
end

-- ----------------------------------------------------------------- export

local function json_value(value)
  local kind = type(value)
  if kind == "table" then
    if #value > 0 or next(value) == nil and value.__array then
      local parts = {}
      for _, item in ipairs(value) do
        table.insert(parts, json_value(item))
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for key, item in pairs(value) do
      if key ~= "__array" then
        table.insert(parts, json_value(tostring(key)) .. ":" .. json_value(item))
      end
    end
    if #parts == 0 and value.__array then
      return "[]"
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif kind == "string" then
    return '"' .. value:gsub('[%c"\\]', function(ch)
      return string.format("\\u%04x", ch:byte())
    end) .. '"'
  elseif kind == "number" then
    return string.format("%.2f", value)
  elseif kind == "boolean" then
    return tostring(value)
  end
  return "null"
end

-- Windows from the winpodx Windows VM are FreeRDP RemoteApp windows; the
-- header shows a Windows mark for them. Cached per pid (reset when large).
local vm_pids = {}
local vm_pid_count = 0

local function is_vm_window(window)
  -- Placeholder panel of a VM app that is starting (~/.local/bin/winpodx-placeholder).
  if (window.class or ""):find("^wpx%.placeholder%.") then return true end
  local pid = window.pid
  if not pid or pid <= 0 then return false end
  if vm_pids[pid] == nil then
    if vm_pid_count > 256 then vm_pids, vm_pid_count = {}, 0 end
    local comm = ""
    local f = io.open("/proc/" .. pid .. "/comm", "r")
    if f then
      comm = f:read("*l") or ""
      f:close()
    end
    vm_pids[pid] = comm:match("^xfreerdp") ~= nil
    vm_pid_count = vm_pid_count + 1
  end
  return vm_pids[pid]
end

-- Write the per-monitor layouts and the visible matrix headers for the shell.
function matrix.export()
  local active = hl.get_active_window()
  local active_address = active and active.address or ""
  local data = {
    header = HEADER,
    border = border_size(),
    -- Window corners (Appearance > Windows > Window Corners): the shell rounds
    -- the frame around header and window to match.
    rounding = number_config("decoration.rounding", 0),
    glassy = glassy(),
    active_color = border_color("general.col.active_border", "#FFCACCCC"),
    inactive_color = border_color("general.col.inactive_border", "#FF595959"),
    monitors = {},
    headers = { __array = true },
  }

  for _, monitor in ipairs(hl.get_monitors()) do
    local workspace = monitor.active_workspace
    if workspace then
      data.monitors[monitor.name] = mode_of(workspace)
      local state = matrix.ws[workspace.id]
      if workspace.tiled_layout == LAYOUT and state and state.headers and not workspace.has_fullscreen then
        for _, header in ipairs(state.headers) do
          local window = hl.get_window("address:" .. header.address)
          if window and not window.floating and window.workspace and window.workspace.id == workspace.id then
            table.insert(data.headers, {
              address = header.address,
              class = window.class or "",
              title = window.title or "",
              vm = is_vm_window(window),
              xwayland = window.xwayland == true,
              pid = window.pid or 0,
              monitor = monitor.name,
              x = header.x - monitor.x,
              y = header.y - monitor.y,
              w = header.w,
              h = header.h,
              frame_x = header.frame.x - monitor.x,
              frame_y = header.frame.y - monitor.y,
              frame_w = header.frame.w,
              frame_h = header.frame.h,
              bottom = header.bottom,
              active = header.address == active_address,
              left = header.left,
              right = header.right,
              up = header.up,
              down = header.down,
            })
          end
        end
      end
    end
  end

  local tmp = STATE_FILE .. ".tmp"
  local file = io.open(tmp, "w")
  if file then
    file:write(json_value(data))
    file:close()
    os.rename(tmp, STATE_FILE)
  end
end

-- ----------------------------------------------------------------- layout

local function recalculate(ctx)
  local targets = ctx.targets
  local first = targets[1] and targets[1].window
  if not first or not first.workspace then
    return
  end

  local state = state_for(first.workspace.id)
  local area = ctx.area
  matrix.ensure_borderless(first.workspace)
  state.area = { x = area.x, y = area.y, w = area.w, h = area.h }

  sync(state, targets)

  local active = hl.get_active_window()
  local focused = active and find(state, active.address) and active.address or state.last
  local fc, fr = nil, nil
  if focused then
    fc, fr = find(state, focused)
  end
  if fc then
    state.last = focused
    state.cols[fc].row = fr
  end

  local center = number_config("scrolling.focus_fit_method", 1) == 0
  local peek = peek_size()
  local gaps = gaps_in()
  local border = border_size()

  local xs, total_w = {}, 0
  for _, col in ipairs(state.cols) do
    col.w = area.w * column_fraction(state, col)
    total_w = total_w + col.w
  end
  -- Columns that don't reach across the screen stretch to fill it.
  if total_w > 0 and total_w < area.w then
    for _, col in ipairs(state.cols) do
      col.w = col.w * area.w / total_w
    end
    total_w = area.w
  end
  local x = 0
  for c, col in ipairs(state.cols) do
    xs[c] = x
    x = x + col.w
  end
  -- A lone column keeps the 1-Window Ratio, centered, like a lone dwindle window.
  local ratio = single_window_ratio()
  if #state.cols == 1 and ratio and area.h * ratio < area.w then
    state.cols[1].w = area.h * ratio
    xs[1] = (area.w - state.cols[1].w) / 2
  end
  state.xs = xs

  if fc then
    state.sx = follow(state.sx or 0, xs[fc], xs[fc] + state.cols[fc].w, area.w, total_w, center)
  else
    state.sx = clamp(state.sx or 0, 0, math.max(0, total_w - area.w))
  end

  local boxes, headers = {}, {}
  for c, col in ipairs(state.cols) do
    local ys, hs, total_h = {}, {}, 0
    for r = 1, #col.wins do
      ys[r] = total_h
      hs[r] = area.h * row_fraction(state, col, r, area.h)
      total_h = total_h + hs[r]
    end

    if c == fc then
      local top = ys[fr] - (fr > 1 and peek or 0)
      local bottom = ys[fr] + hs[fr] + (fr < #col.wins and peek or 0)
      col.sy = follow(col.sy or 0, top, bottom, area.h, total_h, center)
    else
      col.sy = clamp(col.sy or 0, 0, math.max(0, total_h - area.h))
    end

    for r, addr in ipairs(col.wins) do
      local box = {
        x = area.x + xs[c] - state.sx,
        y = area.y + ys[r] - col.sy,
        w = col.w,
        h = hs[r],
      }

      -- The panel is the cell minus gaps_in on edges inside the work area,
      -- like any tiled window. Inside it: a border, the header row and the
      -- window, drawn as one framed element.
      local frame = {
        x = box.x + (box.x <= area.x + 0.5 and 0 or gaps.left),
        y = box.y + (box.y <= area.y + 0.5 and 0 or gaps.top),
      }
      frame.w = box.x + box.w - (box.x + box.w >= area.x + area.w - 0.5 and 0 or gaps.right) - frame.x
      frame.h = box.y + box.h - (box.y + box.h >= area.y + area.h - 0.5 and 0 or gaps.bottom) - frame.y

      local header_bottom = box.y < area.y - 0.5
      local header = {
        address = addr,
        frame = frame,
        x = frame.x + border,
        w = frame.w - 2 * border,
        h = HEADER,
        bottom = header_bottom,
        left = c > 1,
        right = c < #state.cols,
        up = r > 1,
        down = r < #col.wins,
      }

      -- A window whose top has scrolled off screen shows its header at the
      -- bottom, so the visible peek of it is still its header.
      local window_y
      if header_bottom then
        header.y = frame.y + frame.h - border - HEADER
        window_y = frame.y + border
      else
        header.y = frame.y + border
        window_y = header.y + HEADER
      end
      boxes[addr] = {
        x = frame.x + border,
        y = window_y,
        w = frame.w - 2 * border,
        h = frame.h - 2 * border - HEADER,
      }

      table.insert(headers, header)
    end
  end
  state.boxes = boxes
  state.headers = headers

  -- Hyprland insets a placed box by gaps_in on every edge that isn't exactly
  -- on the work area edge, so grow the box by that much to land the window on
  -- the exact rectangle (nudging off the area edge if they would coincide).
  local function placement(win)
    local function outer(edge, gap, area_edge, sign)
      local value = edge + sign * gap
      if math.abs(value - area_edge) < 0.5 then
        value = value + sign * 0.01
      end
      return value
    end
    local x1 = outer(win.x, gaps.left, area.x, -1)
    local y1 = outer(win.y, gaps.top, area.y, -1)
    local x2 = outer(win.x + win.w, gaps.right, area.x + area.w, 1)
    local y2 = outer(win.y + win.h, gaps.bottom, area.y + area.h, 1)
    return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
  end

  -- A window that scrolls in from off screen (where it may have sat over a
  -- neighbouring monitor with another scale) can stay drawn clipped until its
  -- size changes. Place newly visible windows 1px short, then restore them.
  state.shown = state.shown or {}
  local nudged = false
  for _, target in ipairs(targets) do
    local addr = target.window and target.window.address
    local box = addr and boxes[addr]
    if box then
      local visible = box.x < area.x + area.w and box.x + box.w > area.x and box.y < area.y + area.h and box.y + box.h > area.y
      local place = placement(box)
      if visible and not state.shown[addr] then
        place.w = place.w - 1
        nudged = true
      end
      state.shown[addr] = visible
      target:place(place)
    end
  end
  for addr in pairs(state.shown) do
    if not boxes[addr] then
      state.shown[addr] = nil
    end
  end

  if nudged then
    local id = state.id
    -- Layout messages reach only the active workspace; elsewhere the window
    -- stays 1px short until that workspace's next relayout.
    matrix.nudge_timer = hl.timer(function()
      local workspace = hl.get_active_workspace()
      if workspace and workspace.id == id then
        hl.dispatch(hl.dsp.layout("refresh"))
      end
    end, { timeout = 400, type = "oneshot" })
  end

  matrix.export()
end

local function refresh()
  hl.dispatch(hl.dsp.layout("refresh"))
end

local function focus_address(address)
  hl.dispatch(hl.dsp.focus({ window = "address:" .. address }))
end

-- Width of column c that is inside the current viewport.
local function visible_width(state, c)
  local col = state.cols[c]
  local left = state.xs and state.xs[c]
  if not left or not col.w then
    return 0
  end
  local view = state.area and state.area.w or 0
  return math.max(0, math.min(left + col.w, state.sx + view) - math.max(left, state.sx))
end

-- A matrix window (the active one by default) with its state, column and row.
local function locate(window)
  if not is_matrix_window(window) then
    return nil
  end
  local state = state_for(window.workspace.id)
  local c, r = find(state, window.address)
  if not c then
    return nil
  end
  return window, state, c, r
end

local function current()
  return locate(hl.get_active_window())
end

local function locate_address(address)
  return locate(hl.get_window("address:" .. address))
end

-- The matrix window under the cursor, from the boxes of visible workspaces.
local function window_at_cursor()
  local pos = hl.get_cursor_pos()
  if not pos then
    return nil
  end
  for id, state in pairs(matrix.ws) do
    local workspace = hl.get_workspace(id)
    if workspace and workspace.visible and state.boxes then
      for addr, box in pairs(state.boxes) do
        if pos.x >= box.x and pos.x < box.x + box.w and pos.y >= box.y - HEADER and pos.y < box.y + box.h + HEADER then
          return locate_address(addr)
        end
      end
    end
  end
end

-- Column of state under global x, or nil.
local function column_at(state, x)
  if not state.area or not state.xs then
    return nil
  end
  for c, col in ipairs(state.cols) do
    local left = state.area.x + state.xs[c] - state.sx
    if x >= left and x < left + col.w then
      return c
    end
  end
end

-- ----------------------------------------------------------------- actions

function matrix.consume()
  local window, state, c, r = current()
  if not window then
    return hl.dispatch(hl.dsp.layout("togglesplit"))
  end

  local left = c > 1 and visible_width(state, c - 1) or -1
  local right = c < #state.cols and visible_width(state, c + 1) or -1
  if left < 0 and right < 0 then
    return notify("No neighbouring window to join this column")
  end

  local from_left = left > right
  local n = from_left and c - 1 or c + 1
  local neighbour = state.cols[n]
  local moved = table.remove(neighbour.wins, neighbour.row or 1)
  neighbour.row = clamp(neighbour.row or 1, 1, math.max(1, #neighbour.wins))

  local col = state.cols[c]
  table.insert(col.wins, from_left and r or r + 1, moved)
  col.row = from_left and r + 1 or r

  if #neighbour.wins == 0 then
    table.remove(state.cols, n)
  end

  refresh()
end

-- Take a window out of its column into a new column on that side.
local function expel(state, c, r, direction)
  local col = state.cols[c]
  local address = table.remove(col.wins, r)
  col.row = clamp(r, 1, #col.wins)
  table.insert(state.cols, direction == "l" and c or c + 1, new_column(address))
end

-- Move the window at (c, r) into column target, at row position (nil = bottom).
local function move_to_column(state, c, r, target, position)
  local address = table.remove(state.cols[c].wins, r)
  local col = state.cols[target]
  position = position and clamp(position, 1, #col.wins + 1) or #col.wins + 1
  table.insert(col.wins, position, address)
  col.row = position

  local source = state.cols[c]
  if #source.wins == 0 then
    table.remove(state.cols, c)
  else
    source.row = clamp(r, 1, #source.wins)
  end
end

local function swap_rows(state, c, r, direction)
  local col = state.cols[c]
  local other = r + (direction == "u" and -1 or 1)
  if not col.wins[other] then
    return false
  end
  col.wins[r], col.wins[other] = col.wins[other], col.wins[r]
  col.row = other
  return true
end

function matrix.expel()
  local window, state, c, r = current()
  if not window or #state.cols[c].wins < 2 then
    return
  end
  expel(state, c, r, "r")
  refresh()
end

local fallback_focus = { l = "l", r = "r", u = "u", d = "d" }

function matrix.focus(direction)
  local window, state, c, r = current()
  if not window then
    return hl.dispatch(hl.dsp.focus({ direction = fallback_focus[direction] }))
  end

  local target
  if direction == "u" or direction == "d" then
    target = state.cols[c].wins[r + (direction == "u" and -1 or 1)]
  else
    local col = state.cols[c + (direction == "l" and -1 or 1)]
    target = col and col.wins[col.row or 1]
  end

  if target then
    focus_address(target)
  elseif direction == "l" or direction == "r" then
    -- Past the first or last column: let Hyprland move to the next monitor.
    hl.dispatch(hl.dsp.focus({ direction = direction }))
  end
end

-- Up/down moves the window inside its column. Left/right takes it out of a
-- stacked column to that side, or moves a lone window to the bottom of the
-- neighbouring column.
function matrix.move(direction)
  local window, state, c, r = current()
  if not window then
    return hl.dispatch(hl.dsp.window.swap({ direction = direction }))
  end

  if direction == "u" or direction == "d" then
    if not swap_rows(state, c, r, direction) then
      return
    end
  elseif #state.cols[c].wins > 1 then
    expel(state, c, r, direction)
  else
    local n = c + (direction == "l" and -1 or 1)
    if not state.cols[n] then
      return
    end
    move_to_column(state, c, r, n)
  end

  refresh()
end

-- Header buttons: close, move to the bottom of the left/right column, or one
-- row up/down.
function matrix.header_action(address, action)
  if action == "close" then
    -- winpodx-close-window closes normally, and lets a second close kill a
    -- hung Windows VM window.
    local closer = (os.getenv("HOME") or "") .. "/.local/bin/winpodx-close-window"
    local found = io.open(closer, "r")
    if found then
      found:close()
      if address:match("^0x%x+$") then
        return hl.exec_cmd(closer .. " " .. address)
      end
    end
    return hl.dispatch(hl.dsp.window.close({ window = "address:" .. address }))
  end

  local window, state, c, r = locate_address(address)
  if not window then
    return
  end

  if action == "focus" then
    return focus_address(address)
  elseif action == "u" or action == "d" then
    if not swap_rows(state, c, r, action) then
      return
    end
  elseif action == "l" or action == "r" then
    local n = c + (action == "l" and -1 or 1)
    if not state.cols[n] then
      return
    end
    move_to_column(state, c, r, n)
  else
    return
  end

  state.last = address
  focus_address(address)
  refresh()
end

-- Mouse wheel: follow the matrix on matrix workspaces, otherwise keep the
-- default behaviour of the binding.
function matrix.wheel(direction, otherwise)
  if current() then
    return matrix.focus(direction)
  end
  if otherwise then
    hl.dispatch(otherwise)
  end
end

local function contains(rect, pos)
  return pos.x >= rect.x and pos.x < rect.x + rect.w and pos.y >= rect.y and pos.y < rect.y + rect.h
end

local function floating_at(workspace, pos)
  for _, window in ipairs(workspace:get_windows() or {}) do
    if window.floating and window.at and window.size then
      local rect = {
        x = window.at.x or window.at[1],
        y = window.at.y or window.at[2],
        w = window.size.x or window.size[1],
        h = window.size.y or window.size[2],
      }
      if contains(rect, pos) then
        return true
      end
    end
  end
  return false
end

-- The matrix workspace state under the cursor and the tiled window whose box
-- holds it (nil over a header or a gap). Nothing over fullscreen or floating
-- windows.
local function matrix_at_cursor()
  local pos = hl.get_cursor_pos()
  if not pos then
    return nil
  end
  for id, state in pairs(matrix.ws) do
    local workspace = hl.get_workspace(id)
    if workspace and workspace.visible and workspace.tiled_layout == LAYOUT and state.area and contains(state.area, pos) then
      if workspace.fullscreen_window or floating_at(workspace, pos) then
        return nil
      end
      for addr, box in pairs(state.boxes or {}) do
        if contains(box, pos) then
          return state, hl.get_window("address:" .. addr)
        end
      end
      return state, nil
    end
  end
end

local function no_hscroll(window)
  for _, pattern in ipairs(NO_HSCROLL) do
    if (window.class or ""):match(pattern) then
      return true
    end
  end
  return false
end

-- Focus the column left or right of the focused one in state (or of the last
-- focused one when focus is elsewhere). Stops at the first and last column.
local function step_column(state, direction)
  local active = hl.get_active_window()
  local c = active and find(state, active.address)
  if not c and state.last then
    c = find(state, state.last)
  end
  local col = c and state.cols[c + (direction == "l" and -1 or 1)]
  if col then
    focus_address(col.wins[col.row or 1])
  end
end

-- Plain mouse wheel (bound non-consuming, so the window under the cursor
-- still gets the event): change column over headers and gaps, and inside
-- NO_HSCROLL apps for horizontal scroll.
function matrix.scroll(direction)
  local state, window = matrix_at_cursor()
  if not state then
    return
  end
  local horizontal = direction == "l" or direction == "r"
  if window and not (horizontal and no_hscroll(window)) then
    return
  end
  step_column(state, (direction == "u" or direction == "l") and "l" or "r")
end

-- Three-finger swipe: change column on matrix workspaces, move focus elsewhere.
function matrix.swipe(direction)
  local workspace = hl.get_active_workspace()
  if workspace and workspace.tiled_layout == LAYOUT and not workspace.fullscreen_window then
    return step_column(state_for(workspace.id), direction)
  end
  hl.dispatch(hl.dsp.focus({ direction = direction }))
end

-- Grow column c by dx and the window at row r by dy, in pixels.
local function resize_by(state, c, r, dx, dy, base)
  local col = state.cols[c]
  local area = state.area
  if not area then
    return false
  end

  local addr = col.wins[r]
  local start_w = base and base.w or column_fraction(state, col)
  local start_h = base and base.h or row_fraction(state, col, r, area.h)
  local changed = false

  if dx ~= 0 and #state.cols > 1 then
    local width = clamp(start_w + dx / area.w, MIN_SIZE, 1)
    changed = changed or width ~= col.width
    col.width = width
  end
  if dy ~= 0 and #col.wins > 1 then
    local height = clamp(start_h + dy / area.h, MIN_SIZE, 1)
    changed = changed or height ~= state.heights[addr]
    state.heights[addr] = height
  end
  return changed
end

function matrix.resize(dx, dy)
  local window, state, c, r = current()
  if not window then
    return hl.dispatch(hl.dsp.window.resize({ x = dx, y = dy, relative = true }))
  end
  if resize_by(state, c, r, dx, dy) then
    refresh()
  end
end

-- SUPER + right drag. Hyprland's own mouse resize does nothing for Lua
-- layouts, so follow the cursor with a timer until the button is released.
local RIGHT_BUTTON = 273

function matrix.drag_stop()
  if matrix.drag and matrix.drag.timer then
    pcall(matrix.drag.timer.set_enabled, matrix.drag.timer, false)
  end
  matrix.drag = nil
end

function matrix.drag_start()
  matrix.drag_stop()
  local window, state, c, r = window_at_cursor()
  local cursor = hl.get_cursor_pos()
  if not window or not cursor then
    return
  end

  local col = state.cols[c]
  local ok, down = pcall(hl.is_key_down, RIGHT_BUTTON)
  local drag = {
    address = window.address,
    state = state,
    x = cursor.x,
    y = cursor.y,
    base = { w = column_fraction(state, col), h = row_fraction(state, col, r, state.area.h) },
    track_button = ok and down == true,
  }

  drag.timer = hl.timer(function()
    if matrix.drag ~= drag then
      return
    end
    if drag.track_button and not hl.is_key_down(RIGHT_BUTTON) then
      return matrix.drag_stop()
    end
    -- Safety net in case the release bind is missed.
    drag.ticks = (drag.ticks or 0) + 1
    if drag.ticks > 900 then
      return matrix.drag_stop()
    end
    local dc, dr = find(drag.state, drag.address)
    local pos = hl.get_cursor_pos()
    if not dc or not pos then
      return matrix.drag_stop()
    end
    if resize_by(drag.state, dc, dr, pos.x - drag.x, pos.y - drag.y, drag.base) then
      refresh()
    end
  end, { timeout = 16, type = "repeat" })

  matrix.drag = drag
end

-- SUPER + left drag: remember the window under the cursor and, on release,
-- drop it below the visible window of the column under the cursor.
function matrix.grab_start()
  local window = window_at_cursor()
  matrix.grab = window and { address = window.address } or nil
end

function matrix.grab_stop()
  local grab = matrix.grab
  matrix.grab = nil
  if not grab then
    return
  end

  local window, state, c, r = locate_address(grab.address)
  local pos = hl.get_cursor_pos()
  if not window or not pos then
    return
  end

  local target = column_at(state, pos.x)
  if target and target ~= c then
    local col = state.cols[target]
    move_to_column(state, c, r, target, (col.row or #col.wins) + 1)
    state.last = grab.address
    focus_address(grab.address)
  end
  refresh()
end

local LAYOUTS_DIR = (os.getenv("HOME") or "") .. "/.local/state/omarchy/workspace-layouts"

-- Saved per-workspace mode, in the format of Omarchy's
-- omarchy-hyprland-workspace-layout-toggle, so its scripts read it back.
local function mode_source(id, mode)
  return string.format('o.workspace_mode({ workspace = "%s", mode = "%s" })\n', id, mode)
end

-- Files saved before matrix became an Omarchy mode hold a bare workspace rule;
-- rewrite them before Omarchy's toggles restore them.
do
  local listing = io.popen("ls " .. o.shell_quote(LAYOUTS_DIR) .. " 2>/dev/null")
  for name in (listing and listing:read("*a") or ""):gmatch("([^\n]+)\n") do
    local id = name:match("^(%d+)%.lua$")
    local path = LAYOUTS_DIR .. "/" .. name
    local file = id and io.open(path, "r")
    if file then
      local text = file:read("*a")
      file:close()
      local layout = text:find("hl.workspace_rule", 1, true) and text:match('layout = "([^"]+)"')
      if layout then
        local out = io.open(path, "w")
        if out then
          out:write(mode_source(id, mode_name(layout)))
          out:close()
        end
      end
    end
  end
  if listing then
    listing:close()
  end
end

-- Layout of a workspace's rule. Floating keeps the tiled layout underneath, as
-- Omarchy does; matrix workspaces drop Hyprland's border since the shell frames
-- header and window together.
local function general_layout()
  local ok, value = pcall(hl.get_config, "general.layout")
  return ok and type(value) == "string" and value ~= "" and value or "dwindle"
end

local function apply_rule(id, mode)
  local layout = layout_of(mode)
  if mode == "floating" then
    local workspace = hl.get_workspace(tonumber(id))
    layout = workspace and workspace.tiled_layout or general_layout()
  end
  local borderless = layout == LAYOUT and mode ~= "floating"
  hl.workspace_rule({ workspace = id, layout = layout, no_border = borderless })
  matrix.borderless[id] = borderless
end

-- A matrix workspace without a rule of its own (default layout matrix, a
-- workspace above the ones set up at load) gets its border dropped on its first
-- layout pass.
function matrix.ensure_borderless(workspace)
  local id = tonumber(workspace and workspace.id)
  if not id or id < 1 or matrix.borderless[tostring(id)] ~= nil then
    return
  end
  matrix.borderless[tostring(id)] = true
  hl.timer(function()
    apply_rule(tostring(id), "matrix")
  end, { timeout = 1, type = "oneshot" })
end

-- Omarchy's workspace modes, taught matrix: saved files, the default layout
-- and the toggles all go through o.workspace_mode.
local workspace_modes = require("default.hypr.workspace-modes")
local native_workspace_mode = o.workspace_mode

function o.workspace_mode(spec)
  local copy = {}
  for key, value in pairs(spec) do
    copy[key] = value
  end

  if copy.default then
    matrix.default_mode = mode_name(copy.default)
    copy.default = layout_of(copy.default)
    return native_workspace_mode(copy)
  end

  local id = tostring(copy.workspace)
  local mode = mode_name(copy.mode)
  copy.mode = layout_of(copy.mode)
  matrix.modes[id] = mode
  native_workspace_mode(copy)
  apply_rule(id, mode)
end

-- Once every saved mode has loaded: with matrix as the default, drop the border
-- of the usual workspaces now, and keep special workspaces (the scratchpad)
-- tiled, since headers are drawn for regular workspaces only.
local native_apply = workspace_modes.apply
workspace_modes.apply = function(...)
  native_apply(...)
  if matrix.default_mode == "matrix" then
    hl.workspace_rule({ workspace = "s[true]", layout = "dwindle" })
    for i = 1, 10 do
      local id = tostring(i)
      if not matrix.modes[id] then
        apply_rule(id, "matrix")
      end
    end
  end
end

local function default_mode()
  return matrix.default_mode or mode_name(general_layout())
end

-- Same order as Omarchy's SUPER + L, with matrix after floating.
local CYCLE = { "dwindle", "scrolling", "floating", "matrix" }
local MESSAGES = {
  dwindle = "layout.workspaceTiling",
  scrolling = "layout.workspaceScrolling",
  floating = "layout.workspaceFloating",
}

-- Layout changes replace one notification instead of stacking, as Omarchy's do.
local function notify_layout(mode)
  local message = MESSAGES[mode] and ('"$(omarchy-i18n ' .. MESSAGES[mode] .. ')"') or '"Workspace layout set to matrix"'
  local script = 'state="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/workspace-layout-notification"; last=; '
    .. '[[ -r $state ]] && read -r last <"$state"; '
    .. 'if id=$(omarchy-notification-send -p -r "${last:-0}" -g 󱂬 ' .. message .. ') && [[ $id =~ ^[0-9]+$ ]]; then '
    .. 'mkdir -p "$(dirname "$state")" && printf "%s\\n" "$id" >"$state"; fi'
  hl.exec_cmd("bash -c " .. o.shell_quote(script))
end

local function titlebars_loaded()
  for _, plugin in ipairs(hl.get_loaded_plugins and hl.get_loaded_plugins() or {}) do
    if plugin.name == "hyprbars" then
      return true
    end
  end
  return false
end

-- Cycle dwindle -> scrolling -> floating -> matrix (back = reverse) on the
-- workspace shown on monitor (or the active one), saved like Omarchy's
-- omarchy-hyprland-workspace-layout-toggle so it survives reloads.
function matrix.toggle_layout(monitor, back)
  local workspace = monitor and hl.get_active_workspace(monitor) or hl.get_active_workspace()
  if not workspace or workspace.special or (tonumber(workspace.id) or 0) < 1 then
    return
  end

  local current = mode_of(workspace)
  local index = 1
  for i, mode in ipairs(CYCLE) do
    if mode == current then
      index = i
    end
  end
  local next_mode = CYCLE[(index - 1 + (back and -1 or 1)) % #CYCLE + 1]
  local id = tostring(workspace.id)

  -- Every window lands somewhere new when the layout changes; nudge them all.
  if matrix.ws[workspace.id] then
    matrix.ws[workspace.id].shown = {}
  end

  if not pcall(o.workspace_mode, { workspace = id, mode = next_mode }) then
    return hl.exec_cmd("bash -c " .. o.shell_quote('omarchy-notification-send -g 󱂬 "$(omarchy-i18n layout.needsReload)"'))
  end

  local path = LAYOUTS_DIR .. "/" .. id .. ".lua"
  if next_mode == default_mode() then
    -- Back on the default, the workspace follows it again.
    os.remove(path)
  else
    os.execute("mkdir -p " .. o.shell_quote(LAYOUTS_DIR))
    local file = io.open(path, "w")
    if file then
      file:write(mode_source(id, next_mode))
      file:close()
    end
  end

  matrix.sync_follow_mouse()
  matrix.export()
  notify_layout(next_mode)
  hl.exec_cmd("omarchy-shell -q omarchy.workspaces refresh; omarchy-shell -q omarchy.dock refresh")
  -- Titlebars for floating workspaces load with the config.
  if next_mode == "floating" and not titlebars_loaded() then
    hl.exec_cmd("omarchy-restart-hyprctl")
  end
end

-- Matrix workspaces focus windows on click instead of on hover. Floating ones
-- are left to Omarchy, which focuses on click too.
matrix.follow_mouse_default = matrix.follow_mouse_default or number_config("input.follow_mouse", 1)

function matrix.sync_follow_mouse()
  local workspace = hl.get_active_workspace()
  if workspace and mode_of(workspace) == "floating" then
    return
  end
  local wanted = active_is_matrix() and 2 or matrix.follow_mouse_default
  if number_config("input.follow_mouse", wanted) ~= wanted then
    hl.config({ input = { follow_mouse = wanted } })
  end
end

-- Glassy windows: blur behind the see-through headers like behind the windows.
if glassy() then
  hl.layer_rule({
    match = { namespace = "^omarchy-matrix-frames$" },
    blur = true,
    ignore_alpha = 0.3,
  })
end

hl.layout.register("matrix", {
  recalculate = recalculate,
  layout_msg = function(_, msg)
    return msg == "refresh"
  end,
})

-- ----------------------------------------------------------------- events

for _, subscription in ipairs(matrix.subscriptions or {}) do
  if subscription and subscription.remove then
    pcall(subscription.remove, subscription)
  end
end
matrix.subscriptions = {}

local function subscribe(event, callback)
  local ok, subscription = pcall(hl.on, event, callback)
  if ok then
    table.insert(matrix.subscriptions, subscription)
  end
end

-- Keep the viewport on the focused window and remember each column's row.
subscribe("window.active", function(window)
  if is_matrix_window(window) then
    local state = state_for(window.workspace.id)
    if find(state, window.address) then
      state.last = window.address
      if active_is_matrix() then
        return refresh()
      end
    end
  end
  matrix.export()
end)

local function resync()
  matrix.sync_follow_mouse()
  matrix.export()
end

for _, event in ipairs({ "workspace.active", "monitor.focused", "window.close", "window.destroy", "window.fullscreen", "window.move_to_workspace", "window.title" }) do
  subscribe(event, resync)
end

matrix.startup_timer = hl.timer(resync, { timeout = 300, type = "oneshot" })

-- ----------------------------------------------------------------- bindings

hl.unbind("SUPER + J")
o.bind("SUPER + J", "Toggle window split / join column (matrix)", matrix.consume)
o.bind("SUPER + SHIFT + J", "Expel window from column (matrix)", matrix.expel)
hl.unbind("SUPER + L")
o.bind("SUPER + L", "Cycle workspace layout (tiling/scrolling/floating/matrix)", function()
  matrix.toggle_layout()
end)
hl.unbind("SUPER + ALT + L")
o.bind("SUPER + ALT + L", "Cycle workspace layout back", function()
  matrix.toggle_layout(nil, true)
end)

local arrows = { LEFT = "l", RIGHT = "r", UP = "u", DOWN = "d" }
local arrow_names = { l = "left", r = "right", u = "above", d = "below" }
local move_names = {
  l = "Swap window to the left / move out of column (matrix)",
  r = "Swap window to the right / move out of column (matrix)",
  u = "Swap window up",
  d = "Swap window down",
}
for key, direction in pairs(arrows) do
  hl.unbind("SUPER + " .. key)
  o.bind("SUPER + " .. key, "Focus on " .. arrow_names[direction] .. " window", function()
    matrix.focus(direction)
  end)
  hl.unbind("SUPER + SHIFT + " .. key)
  o.bind("SUPER + SHIFT + " .. key, move_names[direction], function()
    matrix.move(direction)
  end)
end

-- Same keys and steps as Omarchy's resize bindings; on matrix workspaces x
-- changes the column width and y the window height.
local resizes = {
  { "SUPER + code:20", "Expand window left", -100, 0 },
  { "SUPER + code:21", "Shrink window left", 100, 0 },
  { "SUPER + SHIFT + code:20", "Shrink window up", 0, -100 },
  { "SUPER + SHIFT + code:21", "Expand window down", 0, 100 },
  { "SUPER + ALT + code:20", "Expand window left a little", -25, 0 },
  { "SUPER + ALT + code:21", "Shrink window left a little", 25, 0 },
  { "SUPER + SHIFT + ALT + code:20", "Shrink window up a little", 0, -25 },
  { "SUPER + SHIFT + ALT + code:21", "Expand window down a little", 0, 25 },
  { "SUPER + CTRL + code:20", "Expand window left a lot", -300, 0 },
  { "SUPER + CTRL + code:21", "Shrink window left a lot", 300, 0 },
  { "SUPER + CTRL + SHIFT + code:20", "Shrink window up a lot", 0, -300 },
  { "SUPER + CTRL + SHIFT + code:21", "Expand window down a lot", 0, 300 },
}
for _, resize in ipairs(resizes) do
  local keys, description, dx, dy = resize[1], resize[2], resize[3], resize[4]
  hl.unbind(keys)
  o.bind(keys, description, function()
    matrix.resize(dx, dy)
  end)
end

-- Extra press/release binds next to Omarchy's SUPER + left/right drag, which
-- keep working on the other layouts.
hl.bind("SUPER + mouse:273", function()
  if window_at_cursor() then
    matrix.drag_start()
  end
end, { non_consuming = true })
hl.bind("SUPER + mouse:273", matrix.drag_stop, { release = true, non_consuming = true })
hl.bind("mouse:273", matrix.drag_stop, { release = true, non_consuming = true, transparent = true })

hl.bind("SUPER + mouse:272", matrix.grab_start, { non_consuming = true })
hl.bind("SUPER + mouse:272", matrix.grab_stop, { release = true, non_consuming = true })
hl.bind("mouse:272", matrix.grab_stop, { release = true, non_consuming = true, transparent = true })

hl.unbind("SUPER + mouse_down")
hl.unbind("SUPER + mouse_up")
o.bind("SUPER + mouse_down", "Scroll down in column (matrix) / next workspace", function()
  matrix.wheel("d", hl.dsp.focus({ workspace = "e+1" }))
end)
o.bind("SUPER + mouse_up", "Scroll up in column (matrix) / previous workspace", function()
  matrix.wheel("u", hl.dsp.focus({ workspace = "e-1" }))
end)
o.bind("SUPER + mouse_right", "Scroll right (matrix)", function()
  matrix.wheel("r")
end)
o.bind("SUPER + mouse_left", "Scroll left (matrix)", function()
  matrix.wheel("l")
end)

local wheels = { mouse_up = "u", mouse_down = "d", mouse_left = "l", mouse_right = "r" }
for key, direction in pairs(wheels) do
  hl.bind(key, function()
    matrix.scroll(direction)
  end, { non_consuming = true, description = "Change column from headers and gaps (matrix)" })
end

-- With natural scrolling the content follows the fingers, so a swipe to the
-- left brings in the column on the right.
hl.gesture({ fingers = 3, direction = "left", action = function()
  matrix.swipe("r")
end })
hl.gesture({ fingers = 3, direction = "right", action = function()
  matrix.swipe("l")
end })
