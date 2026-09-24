-- Float known windows while they are the sole Dwindle target, remember
-- geometry adjusted with the normal SUPER + mouse drags, and tile them again
-- as soon as another tiled window joins the workspace. Unknown apps stay tiled
-- until the user floats and adjusts them once, which teaches their placement.

local M = {}

-- Placements are fractions of the monitor's usable work area. Add another
-- profile here when an app should participate in solo-dwindle. A tag profile
-- is preferable when Omarchy already groups several app classes under one tag.
local profiles = {
  {
    key = "terminal",
    tag = "terminal",
    default = { x = 0.06, y = 0.48, w = 0.46, h = 0.44 },
  },
}

local poll_ms = 250
local stable_polls_before_save = 3
local stable_polls_before_learning = 2

local state_home = os.getenv("XDG_STATE_HOME")
  or ((os.getenv("HOME") or "") .. "/.local/state")
local state_file = state_home .. "/omarchy/windows/solo-dwindle.tsv"

local learned = {}
local managed = {}
local suppressed = {}
local learning = {}
local tracker
local deferred_reconciles = {}

local function clamp(value, low, high)
  return math.max(low, math.min(value, high))
end

local function round(value)
  return math.floor(value + 0.5)
end

local function component(value, name, index)
  if type(value) ~= "table" then
    return nil
  end

  return tonumber(value[name] or value[index])
end

local function valid_placement(placement)
  if not placement then
    return false
  end

  for _, key in ipairs({ "x", "y", "w", "h" }) do
    local value = placement[key]
    if type(value) ~= "number" or value ~= value or math.abs(value) > 100 then
      return false
    end
  end

  return placement.w > 0 and placement.h > 0
end

local function sanitize_placement(placement)
  local width = clamp(placement.w, 0.12, 1)
  local height = clamp(placement.h, 0.12, 1)

  return {
    x = clamp(placement.x, 0, 1 - width),
    y = clamp(placement.y, 0, 1 - height),
    w = width,
    h = height,
  }
end

local function load_state()
  local file = io.open(state_file, "r")
  if not file then
    return
  end

  for line in file:lines() do
    if line:sub(1, 1) ~= "#" then
      local fields = {}
      for field in line:gmatch("[^\t]+") do
        table.insert(fields, field)
      end

      if #fields == 5 then
        local placement = {
          x = tonumber(fields[2]),
          y = tonumber(fields[3]),
          w = tonumber(fields[4]),
          h = tonumber(fields[5]),
        }

        if valid_placement(placement) then
          learned[fields[1]] = sanitize_placement(placement)
        end
      end
    end
  end

  file:close()
end

local function save_state()
  local keys = {}
  for key in pairs(learned) do
    table.insert(keys, key)
  end
  table.sort(keys)

  local temporary = state_file .. ".tmp"
  local file = io.open(temporary, "w")
  if not file then
    print("solo-dwindle: could not open state file for writing: " .. temporary)
    return false
  end

  file:write("# solo-dwindle v1: key\tx\ty\twidth\theight\n")
  for _, key in ipairs(keys) do
    local placement = learned[key]
    file:write(string.format(
      "%s\t%.6f\t%.6f\t%.6f\t%.6f\n",
      key,
      placement.x,
      placement.y,
      placement.w,
      placement.h
    ))
  end

  file:close()
  if not os.rename(temporary, state_file) then
    print("solo-dwindle: could not replace state file: " .. state_file)
    return false
  end

  return true
end

local function has_tag(window, wanted)
  for _, tag in ipairs(window.tags or {}) do
    if tag:gsub("%*$", "") == wanted then
      return true
    end
  end
  return false
end

local function app_class(window)
  if not window then
    return nil
  end

  local initial = window.initial_class
  if type(initial) == "string" and initial ~= "" then
    return initial
  end

  local current = window.class
  if type(current) == "string" and current ~= "" then
    return current
  end

  return nil
end

local function app_key(window)
  local class = app_class(window)
  if not class then
    return nil
  end

  -- Keep the state file tab-delimited even if an application supplies an odd
  -- class string. Percent is escaped first so the mapping stays unambiguous.
  class = class
    :gsub("%%", "%%25")
    :gsub("\t", "%%09")
    :gsub("\r", "%%0D")
    :gsub("\n", "%%0A")
  return "app:" .. class
end

local function profile_for(window)
  if not window then
    return nil
  end

  for _, profile in ipairs(profiles) do
    local tag_matches = profile.tag and has_tag(window, profile.tag)
    local class_matches = profile.class and window.initial_class == profile.class
    if tag_matches or class_matches then
      return profile
    end
  end

  local key = app_key(window)
  if key and learned[key] then
    return { key = key, label = app_class(window) }
  end

  return nil
end

local function monitor_work_area(monitor)
  if not monitor or not monitor.scale or monitor.scale <= 0 then
    return nil
  end

  local reserved = monitor.reserved or {}
  local left = tonumber(reserved.left or reserved[1]) or 0
  local top = tonumber(reserved.top or reserved[2]) or 0
  local right = tonumber(reserved.right or reserved[3]) or 0
  local bottom = tonumber(reserved.bottom or reserved[4]) or 0
  local position = monitor.position or {}
  local monitor_x = tonumber(monitor.x or position.x or position[1]) or 0
  local monitor_y = tonumber(monitor.y or position.y or position[2]) or 0
  local width = monitor.width / monitor.scale - left - right
  local height = monitor.height / monitor.scale - top - bottom

  if width <= 0 or height <= 0 then
    return nil
  end

  return {
    x = monitor_x + left,
    y = monitor_y + top,
    w = width,
    h = height,
  }
end

local function window_rect(window)
  if not window then
    return nil
  end

  local at = window.at
  local size = window.size
  local x = component(at, "x", 1)
  local y = component(at, "y", 2)
  local width = component(size, "x", 1)
  local height = component(size, "y", 2)

  if not x or not y or not width or not height or width <= 0 or height <= 0 then
    return nil
  end

  return { x = x, y = y, w = width, h = height }
end

local function same_rect(a, b)
  return a and b
    and math.abs(a.x - b.x) < 1
    and math.abs(a.y - b.y) < 1
    and math.abs(a.w - b.w) < 1
    and math.abs(a.h - b.h) < 1
end

local function normalize_rect(window, rect)
  local area = monitor_work_area(window.monitor)
  if not area or not rect then
    return nil
  end

  return sanitize_placement({
    x = (rect.x - area.x) / area.w,
    y = (rect.y - area.y) / area.h,
    w = rect.w / area.w,
    h = rect.h / area.h,
  })
end

local function placement_for(profile)
  return learned[profile.key] or profile.default
end

local function apply_placement(window, profile)
  local area = monitor_work_area(window.monitor)
  if not area then
    return false
  end

  local saved = placement_for(profile)
  if not valid_placement(saved) then
    return false
  end

  local placement = sanitize_placement(saved)
  local width = clamp(round(area.w * placement.w), 160, round(area.w))
  local height = clamp(round(area.h * placement.h), 120, round(area.h))
  local x = round(area.x + area.w * placement.x)
  local y = round(area.y + area.h * placement.y)
  x = clamp(x, round(area.x), round(area.x + area.w - width))
  y = clamp(y, round(area.y), round(area.y + area.h - height))

  hl.dispatch(hl.dsp.window.resize({
    window = window,
    x = width,
    y = height,
    relative = false,
  }))
  hl.dispatch(hl.dsp.window.move({
    window = window,
    x = x,
    y = y,
    relative = false,
  }))

  return true
end

local function apply_placement_soon(window, profile)
  local timer
  timer = hl.timer(function()
    deferred_reconciles[timer] = nil
    pcall(function()
      if window.mapped and window.floating and (window.fullscreen or 0) == 0 then
        apply_placement(window, profile)
      end
    end)
  end, { timeout = 200, type = "oneshot" })
  deferred_reconciles[timer] = true
end

local function remember_geometry(window, profile)
  if not window or not window.floating or (window.fullscreen or 0) ~= 0 then
    return false
  end

  local placement = normalize_rect(window, window_rect(window))
  if not placement then
    return false
  end

  learned[profile.key] = placement
  return save_state()
end

local function group_target_is_visible(window)
  local group = window.group
  return not group or not group.current or group.current.address == window.address
end

local function is_visible_window(window)
  if not window or not window.mapped or window.hidden or window.pinned then
    return false
  end

  return group_target_is_visible(window)
end

local function is_layout_window(window)
  if not is_visible_window(window) then
    return false
  end

  -- Unmanaged floating windows are auxiliary to Dwindle: dialogs and other
  -- transient floats should not make a managed solo window rejoin the tiled
  -- layout. A managed floating window still represents the solo layout target.
  return not window.floating
    or managed[window.address] ~= nil
end

local function workspace_windows(workspace)
  local result = {}
  for _, window in ipairs(workspace:get_windows() or {}) do
    if is_layout_window(window) then
      table.insert(result, window)
    end
  end
  return result
end

local function all_workspace_windows(workspace)
  local result = {}
  for _, window in ipairs(workspace:get_windows() or {}) do
    if is_visible_window(window) then
      table.insert(result, window)
    end
  end
  return result
end

local function refresh_tracker()
  if not tracker then
    return
  end

  -- Keep one lightweight observer alive so float actions performed through
  -- any dispatcher or UI path can teach an unknown sole window.
  tracker:set_enabled(true)
end

local function begin_managing(window, profile)
  if managed[window.address] or (window.fullscreen or 0) ~= 0 then
    return
  end

  local already_floating = window.floating
  managed[window.address] = {
    window = window,
    profile = profile,
    last_rect = nil,
    dirty = false,
    stable_polls = 0,
  }

  if already_floating then
    -- Naturally floating apps commonly start at Hyprland's centered default.
    -- Once their profile is known, restore it just like a manually re-floated
    -- solo window; otherwise that centered launch geometry would overwrite the
    -- learned placement before it could be applied.
    apply_placement(window, profile)
    apply_placement_soon(window, profile)
  else
    hl.dispatch(hl.dsp.window.float({ action = "set", window = window }))
    apply_placement(window, profile)
    apply_placement_soon(window, profile)
  end
  refresh_tracker()
end

local function stop_managing(window, retile, remember, prefer_left)
  local entry = window and managed[window.address]
  if not entry then
    return
  end

  if remember then
    remember_geometry(window, entry.profile)
  end

  managed[window.address] = nil
  if retile and window.mapped and window.floating and (window.fullscreen or 0) == 0 then
    hl.dispatch(hl.dsp.window.float({ action = "unset", window = window }))
    if prefer_left then
      -- The newcomer is already Dwindle's root by the time this window is
      -- reinserted, which normally puts the established window on the right.
      hl.dispatch(hl.dsp.window.swap({ direction = "left", window = window }))
    end
  end
  refresh_tracker()
end

local function same_workspace(window, workspace)
  return window
    and window.workspace
    and workspace
    and window.workspace.id == workspace.id
end

local function stop_managed_on_workspace(workspace, retile, prefer_left)
  local windows = {}
  for _, entry in pairs(managed) do
    if same_workspace(entry.window, workspace) then
      table.insert(windows, entry.window)
    end
  end

  for _, window in ipairs(windows) do
    stop_managing(window, retile, true, prefer_left)
  end
end

local function clear_suppression_on_workspace(workspace)
  for _, window in ipairs(workspace:get_windows() or {}) do
    suppressed[window.address] = nil
  end
end

local function reconcile_workspace(workspace)
  if not workspace then
    return
  end

  if workspace.special then
    stop_managed_on_workspace(workspace, false)
    return
  end

  if workspace.tiled_layout ~= "dwindle" then
    stop_managed_on_workspace(workspace, true)
    return
  end

  -- Preserve the underlying floating geometry while fullscreen. The normal
  -- reconciliation runs as soon as the fullscreen event exits.
  if workspace.has_fullscreen then
    return
  end

  local windows = workspace_windows(workspace)

  -- A known app may launch naturally floating, or remain floating across a
  -- config reload. Adopt it only when it is the sole visible window. If other
  -- floating windows are present, leave them all alone until an existing
  -- managed target or a tiled target identifies the primary window.
  if #windows == 0 then
    local visible = all_workspace_windows(workspace)
    if #visible == 1 and profile_for(visible[1]) then
      windows = visible
    end
  end

  if #windows ~= 1 then
    clear_suppression_on_workspace(workspace)
    stop_managed_on_workspace(workspace, true, #windows == 2)
    return
  end

  local window = windows[1]
  local profile = profile_for(window)
  if not profile then
    stop_managed_on_workspace(workspace, true)
    return
  end

  local entry = managed[window.address]
  if entry and not window.floating then
    -- A manual SUPER+T should win while tiled. Suppression is cleared when the
    -- user floats it again or another layout window joins the workspace.
    managed[window.address] = nil
    suppressed[window.address] = true
    refresh_tracker()
    return
  end

  if not entry and suppressed[window.address] and window.floating then
    suppressed[window.address] = nil
    begin_managing(window, profile)
  elseif not entry and not suppressed[window.address] then
    begin_managing(window, profile)
  end
end

local function observe_learning(workspace, seen)
  if not workspace
    or workspace.special
    or workspace.tiled_layout ~= "dwindle"
    or workspace.has_fullscreen
  then
    return
  end

  -- Including floating windows here is intentional. A naturally floating
  -- dialog is ignored unless this exact window was first observed tiled and
  -- was then adjusted after becoming floating.
  local windows = all_workspace_windows(workspace)
  if #windows ~= 1 then
    return
  end

  local window = windows[1]
  if profile_for(window) then
    return
  end

  local address = window.address
  local key = app_key(window)
  if not address or not key then
    return
  end

  local candidate = learning[address]
  if not window.floating then
    if not candidate then
      candidate = { window = window, key = key }
      learning[address] = candidate
    end
    candidate.window = window
    candidate.key = key
    candidate.floating_rect = nil
    candidate.dirty = false
    candidate.stable_polls = 0
    seen[address] = true
    return
  end

  -- Do not learn windows which were floating from the moment they appeared.
  if not candidate then
    return
  end

  seen[address] = true
  local rect = window_rect(window)
  if not rect then
    return
  end

  if not candidate.floating_rect then
    -- First let the compositor's float animation finish. Only changes after
    -- that settled baseline count as deliberate placement edits.
    candidate.floating_rect = rect
    candidate.float_stable_polls = 0
    candidate.armed = false
    candidate.dirty = false
    candidate.stable_polls = 0
  elseif not same_rect(rect, candidate.floating_rect) then
    candidate.floating_rect = rect
    candidate.float_stable_polls = 0
    if candidate.armed then
      candidate.dirty = true
    end
    candidate.stable_polls = 0
  elseif not candidate.armed then
    candidate.float_stable_polls = candidate.float_stable_polls + 1
    if candidate.float_stable_polls >= stable_polls_before_learning then
      candidate.armed = true
    end
  elseif candidate.dirty then
    candidate.stable_polls = candidate.stable_polls + 1
    if candidate.stable_polls >= stable_polls_before_save then
      local placement = normalize_rect(window, rect)
      if placement then
        learned[key] = placement
        save_state()
        learning[address] = nil
        begin_managing(window, {
          key = key,
          label = app_class(window),
        })
        hl.notification.create({
          text = "Saved solo placement for " .. (app_class(window) or key),
          timeout = 2500,
          icon = "ok",
        })
      end
    end
  end
end

local function reconcile_all()
  local seen = {}
  for _, workspace in ipairs(hl.get_workspaces() or {}) do
    reconcile_workspace(workspace)
    observe_learning(workspace, seen)
  end

  for address in pairs(learning) do
    if not seen[address] then
      learning[address] = nil
    end
  end
  refresh_tracker()
end

-- Window lifecycle events can arrive before the new layout target is fully
-- mapped (or before a closing target has left its workspace). Reconcile once
-- immediately and once after the compositor has settled.
local function reconcile_soon()
  local timer
  timer = hl.timer(function()
    deferred_reconciles[timer] = nil
    reconcile_all()
  end, { timeout = 100, type = "oneshot" })
  deferred_reconciles[timer] = true
end

local function reconcile_now_and_soon()
  reconcile_all()
  reconcile_soon()
end

local function tracker_tick()
  -- This also catches a just-opened target once it becomes mapped, even if
  -- the initial window.open callback observed the workspace too early.
  reconcile_all()

  local stale = {}

  for address, entry in pairs(managed) do
    local window = entry.window

    if not window.mapped then
      table.insert(stale, address)
    elseif not window.floating then
      -- This was a user tiling action; do not accidentally save the full tiled
      -- rectangle over the last floating placement.
      suppressed[address] = true
      table.insert(stale, address)
    elseif (window.fullscreen or 0) == 0 then
      local rect = window_rect(window)
      if rect then
        if not entry.last_rect then
          entry.last_rect = rect
        elseif not same_rect(rect, entry.last_rect) then
          entry.last_rect = rect
          entry.dirty = true
          entry.stable_polls = 0
        elseif entry.dirty then
          entry.stable_polls = entry.stable_polls + 1
          if entry.stable_polls >= stable_polls_before_save then
            remember_geometry(window, entry.profile)
            entry.dirty = false
            entry.stable_polls = 0
          end
        end
      end
    end
  end

  for _, address in ipairs(stale) do
    managed[address] = nil
  end
  refresh_tracker()
end

tracker = hl.timer(tracker_tick, { timeout = poll_ms, type = "repeat" })
tracker:set_enabled(true)

local function restore_managed_on_workspace(workspace)
  for _, entry in pairs(managed) do
    if same_workspace(entry.window, workspace) and (entry.window.fullscreen or 0) == 0 then
      apply_placement(entry.window, entry.profile)
      entry.last_rect = nil
      entry.dirty = false
      entry.stable_polls = 0
    end
  end
end

local function restore_soon(workspace)
  local timer
  timer = hl.timer(function()
    deferred_reconciles[timer] = nil
    restore_managed_on_workspace(workspace)
  end, { timeout = 150, type = "oneshot" })
  deferred_reconciles[timer] = true
end

hl.on("window.open", reconcile_now_and_soon)
hl.on("window.class", reconcile_now_and_soon)
hl.on("window.update_rules", reconcile_now_and_soon)
hl.on("window.fullscreen", reconcile_now_and_soon)

hl.on("window.close", function(window)
  local entry = window and managed[window.address]
  if entry then
    remember_geometry(window, entry.profile)
  end
  reconcile_soon()
end)

hl.on("window.destroy", function(window)
  local address
  if window then
    local ok, value = pcall(function()
      return window.address
    end)
    if ok then
      address = value
    end
  end
  if address then
    managed[address] = nil
    suppressed[address] = nil
    learning[address] = nil
  else
    -- A destroyed window handle may already have all of its properties nulled.
    -- Compare the userdata itself; do not read another property from it.
    for candidate, entry in pairs(managed) do
      if entry.window == window then
        managed[candidate] = nil
        suppressed[candidate] = nil
      end
    end
    for candidate, entry in pairs(learning) do
      if entry.window == window then
        learning[candidate] = nil
      end
    end
  end
  refresh_tracker()
  reconcile_all()
  reconcile_soon()
end)

hl.on("window.move_to_workspace", function(window, workspace)
  local entry = window and managed[window.address]
  if entry then
    remember_geometry(window, entry.profile)
  end
  reconcile_all()
  restore_managed_on_workspace(workspace)
  restore_soon(workspace)
  reconcile_soon()
end)

hl.on("workspace.move_to_monitor", function(workspace)
  restore_managed_on_workspace(workspace)
  reconcile_workspace(workspace)
end)

hl.on("monitor.layout_changed", function()
  for _, workspace in ipairs(hl.get_workspaces() or {}) do
    restore_managed_on_workspace(workspace)
  end
  reconcile_all()
end)

hl.on("hyprland.shutdown", function()
  for _, entry in pairs(managed) do
    remember_geometry(entry.window, entry.profile)
  end
end)

function M.reset_active()
  local window = hl.get_active_window()
  local profile = profile_for(window)
  if not window or not profile then
    return false
  end

  learned[profile.key] = nil
  save_state()
  suppressed[window.address] = nil

  local entry = managed[window.address]
  if entry and profile.default then
    apply_placement(window, profile)
    entry.last_rect = nil
    entry.dirty = false
    entry.stable_polls = 0
  elseif entry then
    -- A learned app has no built-in fallback: forgetting it returns the sole
    -- window to ordinary tiled Dwindle behavior.
    stop_managing(window, true, false)
    learning[window.address] = nil
    reconcile_soon()
  else
    reconcile_workspace(window.workspace)
  end

  hl.notification.create({
    text = (profile.default and "Reset" or "Forgot")
      .. " solo-dwindle placement for "
      .. (profile.label or profile.key),
    timeout = 2500,
    icon = "ok",
  })
  return true
end

function M.reconcile()
  reconcile_all()
end

load_state()

-- Defer the first pass until the newly loaded config and all of its window
-- rules have settled. Keeping a reference prevents the one-shot timer from
-- being collected before it fires.
local bootstrap_timer
bootstrap_timer = hl.timer(function()
  reconcile_all()
  bootstrap_timer = nil
end, { timeout = 75, type = "oneshot" })

return M
