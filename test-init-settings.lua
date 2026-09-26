-- Regression test for the Hammerspoon menu-bar trigger setting.
-- Runs init.lua against a small hs stub; it never touches the real Hammerspoon settings.

local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)/[^/]+$") or "."
local settingKey = "whisperDictation.triggerMode"

package.preload["hs.ipc"] = function() return {} end
local files, sizes, jsonValues, tasks, timers = {}, {}, {}, {}, {}
local now, physicalFn, clipboard, pastes, frontPid, frontWindow = 0, false, "", 0, 1, 1
local growing = true
local recordingTask = nil
local fakeHome = "/tmp/whisper-own-settings-test-home"
local dataPath = fakeHome .. "/.local/share/whisper"
local bufferPath = dataPath .. "/capture-buffer.raw"
local journalPath = dataPath .. "/active-capture.json"
local lastWavPath = dataPath .. "/last.wav"
local lastHotkey
local realGetenv = os.getenv
os.getenv = function(name)
  if name == "HOME" then
    return "/tmp/whisper-own-settings-test-home"
  end
  return realGetenv(name)
end
os.remove = function(path) files[path], sizes[path] = nil, nil; return true end
os.rename = function(src, dst) files[dst], files[src] = files[src], nil; return true end
io.open = function(path, mode)
  if mode and mode:find("w") then
    files[path] = ""
    return { write = function(_, text) files[path] = files[path] .. text end, close = function() end }
  end
  if files[path] == nil then return nil end
  return { read = function() return files[path] end, close = function() end,
    lines = function() return function() return nil end end }
end

local settingsStore = {}
local lastMenubar = nil
local lastEventTap = nil
local lastIndicatorCanvas = nil
local alerts = {}

local function timer(delay, callback, repeating)
  local item = { callback = callback, due = now + delay, interval = repeating and delay,
    stopped = false, stop = function(self) self.stopped = true end }
  timers[#timers + 1] = item
  return item
end
local function advance(seconds)
  local finish = now + seconds
  while true do
    local nextTimer
    for _, t in ipairs(timers) do
      if not t.stopped and t.due <= finish and (not nextTimer or t.due < nextTimer.due) then nextTimer = t end
    end
    if not nextTimer then break end
    now = nextTimer.due
    if growing and recordingTask and recordingTask.running then
      sizes[bufferPath] = math.floor((now - recordingTask.startedAt) * 32000)
    end
    if nextTimer.interval then nextTimer.due = now + nextTimer.interval else nextTimer.stopped = true end
    nextTimer.callback()
  end
  now = finish
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
      return { activate = function() end, pid = function() return frontPid end }
    end,
  },
  window = { focusedWindow = function() return { id = function() return frontWindow end } end },
  host = { uuid = function() return "job-" .. tostring(#tasks) end },
  hotkey = { bind = function(_, _, cb) lastHotkey = cb; return {} end },
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
    keyStroke = function() pastes = pastes + 1 end,
    checkKeyboardModifiers = function() return { fn = physicalFn } end,
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
    mkdir = function() return true end,    attributes = function(path)
      if path == "/usr/local/bin/ffmpeg" then
        return { size = 1 }
      end
      if sizes[path] then return { size = sizes[path] } end
      if files[path] then return { size = #files[path] } end
      return nil
    end,
  },
  json = {
    encode = function(value) local key = "json-" .. tostring(#jsonValues + 1); jsonValues[#jsonValues + 1] = value; jsonValues[key] = value; return key end,
    decode = function(value) if not jsonValues[value] then error("invalid JSON") end; return jsonValues[value] end,
  },
  menubar = {
    new = function()
      local item = {}
      function item:setTitle(value) self.title = value; return self end
      function item:setMenu(builder) self.menuBuilder = builder; return self end
      function item:setTooltip(value) self.tooltip = value; return self end
      function item:setIcon(value) self.icon = value; return self end
      lastMenubar = item
      return item
    end,
  },
  pasteboard = { setContents = function(text) clipboard = text end },
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
    new = function(path, callback, streamOrArgs, args)
      local task = { running = false, path = path, callback = callback, args = args or streamOrArgs }
      function task:start()
        self.running, self.startedAt = true, now
        if self.path ~= "/bin/bash" then recordingTask = self; sizes[bufferPath] = 0 end
        return true
      end
      function task:isRunning() return self.running end
      function task:interrupt() self.running = false end
      tasks[#tasks + 1] = task
      return task
    end,
  },
  timer = {
    doAfter = function(delay, callback) return timer(delay, callback) end,
    doEvery = function(delay, callback) return timer(delay, callback, true) end,
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
  timers, tasks, files, sizes = {}, {}, {}, {}
  now, growing, recordingTask, physicalFn, pastes, frontPid, frontWindow = 0, true, nil, false, 0, 1, 1
  files[fakeHome .. "/.local/bin/dictation-transcribe.sh"] = "worker"
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
  assert(findItem(menu, "Dictation — " .. label), "menu header")

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
eventTap.callback({ getKeyCode = function() return 63 end, getFlags = function() return { fn = true } end })
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
eventTap.callback({ getKeyCode = function() return 63 end, getFlags = function() return { fn = false } end })
advance(1)
eventTap.callback({ getKeyCode = function() return 63 end, getFlags = function() return { fn = true } end })
assertEqual(lastIndicatorCanvas._showCount, nil, "processing indicator bypassed key-window show")
assert(lastIndicatorCanvas._orderAboveCount >= 2, "processing indicator forced on screen")
assertEqual(lastIndicatorCanvas._calls[#lastIndicatorCanvas._calls], "orderAbove",
  "processing indicator presented through orderAbove")
pttItem = modeItems(menubar, "toggle")
assertEqual(pttItem.disabled, false, "PTT enabled after capture")
pttItem.fn()
assertEqual(settingsStore[settingKey], "ptt", "saved PTT mode")
modeItems(menubar, "ptt")

local function fn(down, code)
  physicalFn = down
  lastEventTap.callback({ getKeyCode = function() return code or 63 end, getFlags = function() return { fn = down } end })
end
local function recording()
  return select(1, modeItems(lastMenubar, settingsStore[settingKey])).disabled
end
local function workers()
  local list = {}
  for _, task in ipairs(tasks) do if task.path == "/bin/bash" then list[#list + 1] = task end end
  return list
end
local function complete(text)
  local worker = workers()[#workers()]
  assert(worker, "worker was not launched")
  local job = assert(worker.args[3]:match("%-%-job '([^']+)'"))
  files[job .. "/audio-ready"] = "saved"
  files[job .. "/status"] = "done"
  files[job .. "/transcript.txt"] = text
  files[lastWavPath] = "audio"
  advance(0.6)
end

-- Re-arm while Fn is still held: keep all the audio and wait for the real release.
settingsStore[settingKey] = "ptt"
loadConfig(); advance(1); fn(true); advance(2)
lastEventTap:stop(); dictationHotkeyWatchdog.callback()
assert(recording(), "hotkey watchdog discarded an active PTT capture")
assertEqual(#workers(), 0, "no premature transcription")
advance(2); fn(false); advance(1)
assertEqual(#workers(), 1, "release transcribes recovered capture once")
complete("Entire recovered story")
assertEqual(clipboard, "Entire recovered story", "complete transcript copied")
assertEqual(pastes, 1, "single paste")
assertEqual(files[journalPath], nil, "journal removed only after saved-audio acknowledgement")

-- A release missed while the tap was disabled finalizes the existing range.
loadConfig(); advance(1); fn(true); advance(3)
lastEventTap:stop(); physicalFn = false; dictationHotkeyWatchdog.callback(); advance(1)
assertEqual(#workers(), 1, "missed release recovered")

-- Navigation/other modifier events with a synthetic Fn flag cannot stop/start capture.
loadConfig(); advance(1); fn(true); advance(2); fn(false, 59)
assert(recording(), "non-Fn modifier event stopped capture")
fn(false); advance(1); assertEqual(#workers(), 1, "physical Fn stops capture")

-- Toggle records beyond the old five-minute limit, including event-tap interruption.
settingsStore[settingKey] = "toggle"
loadConfig(); advance(1); fn(true); fn(false); advance(310)
assert(recording(), "toggle stopped at five minutes")
lastEventTap:stop(); dictationHotkeyWatchdog.callback()
assert(recording(), "hotkey watchdog discarded Toggle capture")
advance(5); fn(true); fn(false); advance(1)
assertEqual(#workers(), 1, "long toggle creates one complete recording")

-- Fn during final tail flush/processing cannot overwrite the captured start offset.
loadConfig(); advance(1); fn(true); fn(false); advance(2)
growing = false
fn(true); fn(false); fn(true); fn(false); advance(1)
assertEqual(#workers(), 1, "rapid Fn presses cannot race the finalization")

-- Hardware loss is visible and the bytes already captured are still transcribed.
loadConfig(); advance(1); fn(true); fn(false); advance(2)
growing = false; advance(20)
assertEqual(#workers(), 1, "stalled recorder audio salvaged")
assert(alerts[#alerts]:find("Microphone stalled"), "warn before recognition finishes")
complete("Before microphone stalled")
assert(alerts[#alerts]:find("Microphone stalled"), "hardware interruption warning missing")

-- Processing has no arbitrary 180-second kill; focus changes keep text on clipboard.
loadConfig(); advance(1); fn(true); fn(false); advance(2); fn(true); fn(false); advance(1)
advance(200)
assertEqual(#workers(), 1, "slow worker remains the same job")
frontWindow = 2
complete("Slow but complete")
assertEqual(pastes, 0, "never paste into a different window")
assertEqual(clipboard, "Slow but complete", "text survives a focus change")
lastHotkey(); advance(0.1)
assertEqual(#workers(), 2, "Ctrl+B launches actual retranscription")
assert(workers()[2].args[3]:find("--retry", 1, true), "Ctrl+B must use saved audio")

-- An interrupted capture journal blocks buffer deletion and is recoverable after reload.
loadConfig()
files[journalPath] = hs.json.encode({ start = 16000, finish = 96000 })
sizes[bufferPath] = 200000
advance(6)
assertEqual(#tasks, 0, "startup must not erase an unrecovered buffer")
lastHotkey()
assert(workers()[1].args[3]:find("16000 96000", 1, true), "recovery uses journal boundaries")

os.getenv = realGetenv
print("PASS settings, Fn recovery, >5-minute Toggle, races, microphone loss, retry, focus, reload")
