-- Regression test for the Hammerspoon menu-bar trigger setting.
-- Runs init.lua against a small hs stub; it never touches the real Hammerspoon settings.

local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)/[^/]+$") or "."
local settingKey = "whisperDictation.triggerMode"

local realGetenv = os.getenv
os.getenv = function(name)
  if name == "HOME" then
    return "/tmp/whisper-own-settings-test-home"
  end
  return realGetenv(name)
end
os.remove = function() return true end

local settingsStore = {}
local lastMenubar = nil
local lastEventTap = nil
local lastIndicatorCanvas = nil
local alerts = {}
local now = 0

local function timer(callback)
  return {
    callback = callback,
    stop = function() end,
  }
end

local canvasMethods = {}
function canvasMethods:level() return self end
function canvasMethods:behavior(value) self._behavior = value; return self end
function canvasMethods:frame(value) self._frame = value; return self end
function canvasMethods:replaceElements(value) self._elements = value; return self end
function canvasMethods:show()
  self._visible = true
  self._showCount = (self._showCount or 0) + 1
  self._calls = self._calls or {}
  self._calls[#self._calls + 1] = "show"
  return self
end
function canvasMethods:orderAbove()
  self._visible = true
  self._orderAboveCount = (self._orderAboveCount or 0) + 1
  self._calls = self._calls or {}
  self._calls[#self._calls + 1] = "orderAbove"
  return self
end
function canvasMethods:hide() self._visible = false; return self end
function canvasMethods:imageFromCanvas() return {} end
function canvasMethods:delete() return nil end

hs = {
  alert = {
    closeAll = function() end,
    show = function(message) alerts[#alerts + 1] = message end,
  },
  application = {
    frontmostApplication = function()
      return { activate = function() end }
    end,
  },
  audiodevice = {
    defaultInputDevice = function()
      return { name = function() return "Test microphone" end }
    end,
    watcher = {
      setCallback = function() end,
      start = function() end,
    },
  },
  caffeinate = {
    watcher = {
      systemDidWake = 1,
      new = function(callback)
        return { callback = callback, start = function() end }
      end,
    },
  },
  canvas = {
    new = function(frame)
      local canvas = setmetatable({ _frame = frame }, { __index = canvasMethods })
      if frame.w == 52 and frame.h == 15 then
        lastIndicatorCanvas = canvas
      end
      return canvas
    end,
  },
  eventtap = {
    event = { types = { flagsChanged = 1 } },
    keyStroke = function() end,
    new = function(_, callback)
      local tap = { callback = callback, enabled = false }
      function tap:start() self.enabled = true; return self end
      function tap:stop() self.enabled = false; return self end
      function tap:isEnabled() return self.enabled end
      lastEventTap = tap
      return tap
    end,
  },
  execute = function() return "" end,
  fs = {
    attributes = function(path)
      if path == "/usr/local/bin/ffmpeg" then
        return { size = 1 }
      end
      if path == "/tmp/dictation-buffer.raw" then
        return { size = 0 }
      end
      return nil
    end,
  },
  json = { decode = function() return {} end },
  menubar = {
    new = function()
      local item = {}
      function item:setMenu(builder) self.menuBuilder = builder; return self end
      function item:setTooltip(value) self.tooltip = value; return self end
      function item:setIcon(value) self.icon = value; return self end
      lastMenubar = item
      return item
    end,
  },
  pasteboard = { setContents = function() end },
  reload = function() end,
  screen = {
    mainScreen = function()
      return { frame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
    end,
  },
  settings = {
    get = function(key) return settingsStore[key] end,
    set = function(key, value) settingsStore[key] = value end,
  },
  task = {
    new = function()
      local task = { running = false }
      function task:start() self.running = true; return true end
      function task:isRunning() return self.running end
      function task:interrupt() self.running = false end
      return task
    end,
  },
  timer = {
    doAfter = function(_, callback) return timer(callback) end,
    doEvery = function(_, callback) return timer(callback) end,
    secondsSinceEpoch = function() return now end,
  },
}

local function assertEqual(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
  end
end

local function tableContains(values, expected)
  for _, value in ipairs(values or {}) do
    if value == expected then
      return true
    end
  end
  return false
end

local function findItem(menu, title)
  for _, item in ipairs(menu) do
    if item.title == title then
      return item
    end
  end
  error("menu item not found: " .. title)
end

local function loadConfig()
  lastMenubar = nil
  lastEventTap = nil
  lastIndicatorCanvas = nil
  assert(loadfile(root .. "/init.lua"))()
  assert(lastMenubar, "init.lua did not create the menu-bar item")
  assert(lastEventTap, "init.lua did not create the fn event tap")
  return lastMenubar, lastEventTap
end

local function modeItems(menubar, expectedMode)
  local menu = menubar.menuBuilder()
  local label = (expectedMode == "toggle") and "Toggle" or "Push-to-talk"
  assertEqual(menu[1].title, "Dictation — " .. label, "menu header")

  local preferences = findItem(menu, "Settings").menu
  local ptt = findItem(preferences, "Push-to-talk — hold fn")
  local toggle = findItem(preferences, "Toggle — tap fn to start / stop")
  assertEqual(ptt.checked, expectedMode == "ptt", "PTT checkmark")
  assertEqual(toggle.checked, expectedMode == "toggle", "Toggle checkmark")
  return ptt, toggle
end

-- Missing and corrupted preferences both fail closed to push-to-talk.
local menubar = loadConfig()
local _, toggleItem = modeItems(menubar, "ptt")

-- A menu click applies immediately and persists through a full config reload.
toggleItem.fn()
assertEqual(settingsStore[settingKey], "toggle", "saved Toggle mode")
modeItems(menubar, "toggle")
assertEqual(menubar.tooltip, "Whisper dictation — Toggle", "updated tooltip")

menubar = loadConfig()
modeItems(menubar, "toggle")

settingsStore[settingKey] = "corrupt"
menubar = loadConfig()
modeItems(menubar, "ptt")

-- The setter also guards against a stale menu callback changing mode mid-capture.
settingsStore[settingKey] = "toggle"
local eventTap
menubar, eventTap = loadConfig()
local pttItem
pttItem, toggleItem = modeItems(menubar, "toggle")
eventTap.callback({ getFlags = function() return { fn = true } end })
assert(lastIndicatorCanvas, "capture did not create the bottom indicator canvas")
assertEqual(lastIndicatorCanvas._showCount, nil, "recording indicator bypassed key-window show")
assertEqual(lastIndicatorCanvas._orderAboveCount, 1, "recording indicator forced on screen")
assertEqual(lastIndicatorCanvas._calls[#lastIndicatorCanvas._calls], "orderAbove",
  "recording indicator presented through orderAbove")
assertEqual(tableContains(lastIndicatorCanvas._behavior, "fullScreenAuxiliary"), true,
  "indicator participates in full-screen Spaces")
pttItem, toggleItem = modeItems(menubar, "toggle")
assertEqual(pttItem.disabled, true, "PTT disabled during capture")
assertEqual(toggleItem.disabled, true, "Toggle disabled during capture")
pttItem.fn()
assertEqual(settingsStore[settingKey], "toggle", "mode unchanged during capture")
assertEqual(alerts[#alerts], "Stop the current dictation before changing mode", "capture guard alert")

-- Stop the toggle capture, then switch back to PTT through the same UI.
eventTap.callback({ getFlags = function() return { fn = false } end })
now = 1
eventTap.callback({ getFlags = function() return { fn = true } end })
assertEqual(lastIndicatorCanvas._showCount, nil, "processing indicator bypassed key-window show")
assertEqual(lastIndicatorCanvas._orderAboveCount, 2, "processing indicator forced on screen")
assertEqual(lastIndicatorCanvas._calls[#lastIndicatorCanvas._calls], "orderAbove",
  "processing indicator presented through orderAbove")
pttItem = modeItems(menubar, "toggle")
assertEqual(pttItem.disabled, false, "PTT enabled after capture")
pttItem.fn()
assertEqual(settingsStore[settingKey], "ptt", "saved PTT mode")
modeItems(menubar, "ptt")

os.getenv = realGetenv
print("PASS init.lua settings + forced bottom-indicator presentation")
