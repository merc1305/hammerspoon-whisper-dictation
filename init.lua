-- Push-to-talk Whisper dictation for macOS.
--
-- Hold fn — speak — release fn: the transcribed text is pasted into the active app.
--
-- Architecture: ffmpeg runs CONTINUOUSLY, appending raw PCM to a ring buffer file.
-- Pressing fn does not start a recording — it just remembers the current buffer
-- offset (minus a pre-roll, so the first syllable is never clipped by a cold start).
-- Releasing fn waits until the tail of the phrase lands in the buffer, then cuts
-- the byte range out and hands it to dictation-transcribe.sh (Groq API first,
-- local whisper.cpp as fallback).

-- Local CLI diagnostics and recovery without enabling AppleScript execution.
require("hs.ipc")

local ffmpegPath = "/usr/local/bin/ffmpeg"
-- install.sh rewrites the line above to the detected brew ffmpeg. If the path is missing
-- anyway (e.g. a manual copy onto Apple Silicon, where brew lives in /opt/homebrew),
-- fall back to whatever ffmpeg is on PATH.
if not hs.fs.attributes(ffmpegPath) then
  local resolved = (hs.execute("command -v ffmpeg 2>/dev/null") or ""):gsub("%s+$", "")
  if resolved ~= "" then
    ffmpegPath = resolved
  end
end
local transcribeScriptPath = os.getenv("HOME") .. "/.local/bin/dictation-transcribe.sh"
local dataPath = os.getenv("HOME") .. "/.local/share/whisper"
local recordingsPath = dataPath .. "/recordings"
local bufferPath = dataPath .. "/capture-buffer.raw"
local captureJournalPath = dataPath .. "/active-capture.json"
local lastWavPath = dataPath .. "/last.wav"
hs.fs.mkdir(dataPath)
hs.fs.mkdir(recordingsPath)
local historyPath = os.getenv("HOME") .. "/.local/share/whisper/history.jsonl"

local minDurationSeconds = 0.5
local prerollSeconds = 0.5
local bytesPerSecond = 32000 -- 16 kHz * mono * s16 (2 bytes)
local maxBufferBytes = 256 * 1024 * 1024 -- ~2.2 hours, then the buffer is rotated

-- trigger mode: "ptt" (hold fn) is the default; "toggle" = tap fn to start, tap to stop.
-- The menu-bar setting is stored outside this file so it survives config reloads/updates.
local triggerModeSettingKey = "whisperDictation.triggerMode"
local triggerMode = "ptt"
if hs.settings and hs.settings.get then
  local savedTriggerMode = hs.settings.get(triggerModeSettingKey)
  if savedTriggerMode == "ptt" or savedTriggerMode == "toggle" then
    triggerMode = savedTriggerMode
  end
end
local toggleStartAlert = true -- brief on-screen hint when a toggle session starts
local toggleLimitSettingKey = "whisperDictation.toggleLimitSeconds"
local toggleLimitSeconds = hs.settings.get(toggleLimitSettingKey)
if toggleLimitSeconds ~= 0 and toggleLimitSeconds ~= 600 and toggleLimitSeconds ~= 1800 then
  toggleLimitSeconds = 600
end
local captureLimitWarned = false
local hotkeyWatchdogInterval = 2 -- seconds between health checks of the fn event tap
local menubarEnabled = true -- show a menu-bar icon (in addition to the on-screen dot)
local menubarHistoryCount = 10 -- how many recent dictations the dropdown lists

local transcribing = false
local activeJobPath = nil
local fnWasDown = false
local transcribePollTimer = nil
local pasteTimer = nil

-- continuous recorder state (pre-buffer)
local recorderTask = nil
local recorderStopping = false
local recorderRestartTimer = nil
local recorderNeedsRestart = false
local lastBufferSize = 0
local lastGrowthAt = 0

-- current dictation state (fn held down)
local captureStartBytes = 0
local captureActive = false
local captureFinalizing = false
local captureTarget = nil
local captureNotice = nil
local finishCapture, retryLastRecording, savePendingCapture
local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end
local function saveCaptureJournal(endBytes)
  local file = io.open(captureJournalPath .. ".tmp", "w")
  if not file then return false end
  file:write(hs.json.encode({ start = captureStartBytes, finish = endBytes }))
  file:close()
  return os.rename(captureJournalPath .. ".tmp", captureJournalPath)
end
local captureSizeAtPress = 0
local capturePressedAt = 0
local capturePollTimer = nil

local function triggerModeLabel(mode)
  return (mode == "toggle") and "Toggle" or "Push-to-talk"
end

local function setTriggerMode(mode)
  if mode ~= "ptt" and mode ~= "toggle" then
    return false
  end
  if captureActive then
    hs.alert.closeAll(0)
    hs.alert.show("Stop the current dictation before changing mode")
    return false
  end

  triggerMode = mode
  if hs.settings and hs.settings.set then
    hs.settings.set(triggerModeSettingKey, mode)
  end
  if dictationMenubar then
    dictationMenubar:setTooltip("Whisper dictation — " .. triggerModeLabel(mode))
  end

  hs.alert.closeAll(0)
  if mode == "toggle" then
    hs.alert.show("Mode: Toggle — tap fn to start or stop")
  else
    hs.alert.show("Mode: Push-to-talk — hold fn to speak")
  end
  return true
end

local function trim(text)
  return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function setToggleLimit(seconds)
  if captureActive then return end
  toggleLimitSeconds = seconds
  hs.settings.set(toggleLimitSettingKey, seconds)
end

-- ===== on-screen indicator (small dot at the bottom of the screen) =====

local indicatorCanvas = nil
local indicatorTimer = nil
local indicatorHideTimer = nil
local indicatorState = "hidden"
local indicatorTick = 0
local indicatorWidth = 52
local indicatorHeight = 15
local indicatorBottomOffset = 18

local indicatorColors = {
  recording = { red = 0.94, green = 0.60, blue = 0.48, alpha = 0.95 },
  processing = { red = 0.52, green = 0.72, blue = 0.92, alpha = 0.95 },
  success = { red = 0.18, green = 0.82, blue = 0.42, alpha = 0.98 },
  error = { red = 1.00, green = 0.18, blue = 0.24, alpha = 0.98 },
}

-- ===== menu-bar icon state (separate palette from the on-screen dot) =====
local setMenubarState -- forward declaration; assigned once the icon builder exists below
local menubarState = "idle"
local menubarIcons = {} -- lazy cache of one hs.image per state
local menubarColors = {
  idle = { red = 0.55, green = 0.55, blue = 0.58, alpha = 1.0 },
  recording = { red = 0.95, green = 0.20, blue = 0.24, alpha = 1.0 },
  transcribing = { red = 1.00, green = 0.60, blue = 0.10, alpha = 1.0 },
}

local function indicatorStopTimer()
  if indicatorTimer then
    indicatorTimer:stop()
    indicatorTimer = nil
  end
end

local function indicatorCancelHide()
  if indicatorHideTimer then
    indicatorHideTimer:stop()
    indicatorHideTimer = nil
  end
end

local function indicatorFrame()
  local screen = hs.screen.mainScreen()
  if not screen then
    return { x = 0, y = 0, w = indicatorWidth, h = indicatorHeight }
  end

  local frame = screen:frame()
  return {
    x = frame.x + ((frame.w - indicatorWidth) / 2),
    y = frame.y + frame.h - indicatorBottomOffset - indicatorHeight,
    w = indicatorWidth,
    h = indicatorHeight,
  }
end

local function indicatorEnsureCanvas()
  if not indicatorCanvas then
    indicatorCanvas = hs.canvas.new(indicatorFrame())
    indicatorCanvas:level("overlay")
    indicatorCanvas:behavior({
      "canJoinAllSpaces",
      "fullScreenAuxiliary",
      "stationary",
      "ignoresCycle",
    })
  else
    indicatorCanvas:frame(indicatorFrame())
  end

  return indicatorCanvas
end

local function indicatorPresent()
  local canvas = indicatorEnsureCanvas()
  -- hs.canvas:show() asks AppKit to make a shape-only window key, which current
  -- macOS refuses. orderAbove() displays the overlay without activating it.
  canvas:orderAbove()
end

local function indicatorDot(cx, cy, diameter, color)
  return {
    type = "circle",
    action = "fill",
    center = { x = cx, y = cy },
    radius = diameter / 2,
    fillColor = color,
    withShadow = true,
    shadow = {
      blurRadius = 3,
      color = { white = 0, alpha = 0.45 },
      offset = { h = 0, w = 0 },
    },
  }
end

local function indicatorElements()
  local elements = {}
  local cx = indicatorWidth / 2
  local cy = indicatorHeight / 2

  local dotSize = 6 -- single dot size for all states

  if indicatorState == "recording" then
    -- breathing dot: constant size, only the brightness pulses
    local wave = 0.5 + (0.5 * math.sin(indicatorTick * 0.30))
    local color = {
      red = indicatorColors.recording.red,
      green = indicatorColors.recording.green,
      blue = indicatorColors.recording.blue,
      alpha = 0.55 + (0.45 * wave),
    }
    table.insert(elements, indicatorDot(cx, cy, dotSize, color))
  elseif indicatorState == "processing" then
    -- three running dots, like a typing indicator
    local count = 3
    local gap = 5
    local totalWidth = (count * dotSize) + ((count - 1) * gap)
    local startX = (indicatorWidth - totalWidth) / 2

    for i = 1, count do
      local phase = (indicatorTick * 0.32) - ((i - 1) * 0.85)
      local lift = math.sin(phase)
      if lift < 0 then
        lift = 0
      end
      local x = startX + ((i - 1) * (dotSize + gap)) + (dotSize / 2)
      local y = cy + 1 - (lift * 2.5)
      local color = {
        red = indicatorColors.processing.red,
        green = indicatorColors.processing.green,
        blue = indicatorColors.processing.blue,
        alpha = 0.45 + (0.55 * lift),
      }
      table.insert(elements, indicatorDot(x, y, dotSize, color))
    end
  elseif indicatorState == "success" then
    table.insert(elements, indicatorDot(cx, cy, dotSize, indicatorColors.success))
  elseif indicatorState == "error" then
    table.insert(elements, indicatorDot(cx, cy, dotSize, indicatorColors.error))
  end

  return elements
end

local function indicatorRender()
  if indicatorState == "hidden" then
    return
  end

  indicatorTick = indicatorTick + 1
  indicatorEnsureCanvas():replaceElements(indicatorElements())
end

local function indicatorHide()
  indicatorCancelHide()
  indicatorStopTimer()
  indicatorState = "hidden"

  if indicatorCanvas then
    indicatorCanvas:hide()
  end

  if setMenubarState then setMenubarState("idle") end
end

local function indicatorShowAnimated(state, interval)
  indicatorCancelHide()
  indicatorStopTimer()
  indicatorState = state
  indicatorTick = 0
  indicatorRender()
  indicatorPresent()
  indicatorTimer = hs.timer.doEvery(interval, indicatorRender)
end

local function indicatorPulse(state, duration)
  indicatorCancelHide()
  indicatorStopTimer()
  indicatorState = state
  indicatorTick = 0
  indicatorRender()
  indicatorPresent()
  indicatorHideTimer = hs.timer.doAfter(duration, indicatorHide)
end

local function indicatorShowRecording()
  indicatorShowAnimated("recording", 0.08)
  if setMenubarState then setMenubarState("recording") end
end

local function indicatorShowProcessing()
  indicatorShowAnimated("processing", 0.08)
  if setMenubarState then setMenubarState("transcribing") end
end

local function indicatorShowSuccess()
  indicatorPulse("success", 0.45)
  if setMenubarState then setMenubarState("idle") end
end

local function indicatorShowError()
  indicatorPulse("error", 0.75)
  if setMenubarState then setMenubarState("idle") end
end

local function showError(message)
  indicatorShowError()
  hs.alert.closeAll(0)
  hs.alert.show(message)
end

-- ===== helpers =====

local function fileExists(path)
  local file = io.open(path, "rb")
  if file then
    file:close()
    return true
  end
  return false
end

local function fileSize(path)
  local attrs = hs.fs.attributes(path)
  if attrs and attrs.size then
    return attrs.size
  end
  return 0
end

local function alignDown(bytes)
  return bytes - (bytes % 2)
end

local function readTextFile(path)
  local file = io.open(path, "rb")
  if not file then
    return ""
  end
  local text = file:read("*a") or ""
  file:close()
  return text
end

-- Read the dictation history journal, newest-first, up to `limit` entries (default 20).
-- The file is oldest-first (the shell worker appends), so we walk it backwards. Global
-- so the menu bar (and any other consumer) can call it; blank/corrupt lines are skipped.
function dictationHistoryRead(limit)
  limit = limit or 20
  local entries = {}
  local file = io.open(historyPath, "r")
  if not file then
    return entries
  end

  local lines = {}
  for line in file:lines() do
    if line and line:gsub("%s", "") ~= "" then
      lines[#lines + 1] = line
    end
  end
  file:close()

  for i = #lines, 1, -1 do
    local ok, entry = pcall(hs.json.decode, lines[i])
    if ok and type(entry) == "table" then
      entries[#entries + 1] = entry
      if #entries >= limit then
        break
      end
    end
  end

  return entries
end

-- ===== menu-bar icon + history dropdown =====

-- Lazily build and cache one hs.image per state via a throwaway canvas.
local function menubarIconFor(state)
  if menubarIcons[state] then
    return menubarIcons[state]
  end

  local size = 22
  local color = menubarColors[state] or menubarColors.idle
  local canvas = hs.canvas.new({ x = 0, y = 0, w = size, h = size })
  if state == "idle" then
    canvas[1] = {
      type = "circle",
      action = "stroke",
      strokeColor = color,
      strokeWidth = 1.8,
      center = { x = size / 2, y = size / 2 },
      radius = (size / 2) - 3,
    }
  else
    canvas[1] = {
      type = "circle",
      action = "fill",
      fillColor = color,
      center = { x = size / 2, y = size / 2 },
      radius = (size / 2) - 4,
    }
  end

  local image = canvas:imageFromCanvas()
  canvas:delete()
  menubarIcons[state] = image
  return image
end

-- Assign the forward-declared upvalue (NOT a new local) so the indicator hooks share it.
setMenubarState = function(state)
  menubarState = state
  if dictationMenubar then
    -- template=false (second arg) is mandatory: keep our colors instead of a mono glyph.
    dictationMenubar:setIcon(menubarIconFor(state), false)
  end
end

-- Collapse whitespace and clip a dictation to a short, UTF-8-safe preview.
local function menubarPreview(text)
  local t = (text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  local limit = 48
  if utf8 and utf8.len then
    local n = utf8.len(t)
    if n and n > limit then
      local cut = utf8.offset(t, limit + 1)
      if cut then
        t = t:sub(1, cut - 1) .. "…"
      end
    end
  elseif #t > limit then
    t = t:sub(1, limit) .. "…"
  end
  return t
end

-- Recent dictations newest-first, capped to menubarHistoryCount. Prefer the global reader;
-- fall back to parsing the jsonl directly if it is somehow unavailable.
local function menubarHistoryEntries()
  if type(dictationHistoryRead) == "function" then
    local ok, entries = pcall(dictationHistoryRead, menubarHistoryCount)
    if ok and type(entries) == "table" then
      return entries
    end
  end

  local entries = {}
  local file = io.open(historyPath, "r")
  if not file then
    return entries
  end
  local lines = {}
  for line in file:lines() do
    if line and line:gsub("%s", "") ~= "" then
      lines[#lines + 1] = line
    end
  end
  file:close()
  for i = #lines, 1, -1 do
    local ok, entry = pcall(hs.json.decode, lines[i])
    if ok and type(entry) == "table" then
      entries[#entries + 1] = entry
      if #entries >= menubarHistoryCount then
        break
      end
    end
  end
  return entries
end

-- Built fresh every time the menu opens (passed to setMenu as a function).
local function menubarBuildMenu()
  local menu = {}
  if captureActive then
    local seconds = math.floor(hs.timer.secondsSinceEpoch() - capturePressedAt)
    menu[#menu + 1] = { title = string.format("Recording %d:%02d — stop and transcribe", math.floor(seconds / 60), seconds % 60), fn = function() finishCapture() end }
  elseif captureFinalizing then
    menu[#menu + 1] = { title = "Saving recording…", disabled = true }
  elseif transcribing then
    menu[#menu + 1] = { title = "Transcribing — recording is saved", disabled = true }
  end
  if fileExists(captureJournalPath) and not captureActive then
    menu[#menu + 1] = {
      title = "Save interrupted recording and resume",
      disabled = captureFinalizing or transcribing,
      fn = function() savePendingCapture() end,
    }
  end
  menu[#menu + 1] = {
    title = "Retry last recording — Ctrl+B",
    disabled = captureActive or captureFinalizing or transcribing
      or (not fileExists(lastWavPath) and not fileExists(captureJournalPath)),
    fn = function() retryLastRecording() end,
  }
  menu[#menu + 1] = { title = "Open saved recordings", fn = function() hs.execute("/usr/bin/open " .. shellQuote(recordingsPath)) end }
  menu[#menu + 1] = { title = "Dictation — " .. triggerModeLabel(triggerMode), disabled = true }
  menu[#menu + 1] = { title = "-" }

  local entries = menubarHistoryEntries()
  if #entries == 0 then
    menu[#menu + 1] = { title = "No dictations yet", disabled = true }
  else
    for _, e in ipairs(entries) do
      local when = (type(e.ts) == "number") and os.date("%H:%M", e.ts) or "--:--"
      local engine = e.engine or "unknown"
      local text = tostring(e.text or "")
      menu[#menu + 1] = {
        title = string.format("%s  ·  %s  [%s]", when, menubarPreview(text), engine),
        fn = function()
          hs.pasteboard.setContents(text) -- copy again, no auto-paste
        end,
      }
    end
  end

  menu[#menu + 1] = { title = "-" }

  local last = entries[1]
  menu[#menu + 1] = {
    title = "Copy last dictation",
    disabled = (last == nil),
    fn = last and function()
      hs.pasteboard.setContents(last.text or "")
    end or nil,
  }
  menu[#menu + 1] = {
    title = "Clear history",
    disabled = (#entries == 0),
    fn = (#entries > 0) and function()
      os.remove(historyPath)
    end or nil,
  }

  menu[#menu + 1] = { title = "-" }
  menu[#menu + 1] = {
    title = "Settings",
    menu = {
      {
        title = "Push-to-talk — hold fn",
        checked = (triggerMode == "ptt"),
        disabled = captureActive,
        fn = function() setTriggerMode("ptt") end,
      },
      {
        title = "Toggle — tap fn to start / stop",
        checked = (triggerMode == "toggle"),
        disabled = captureActive,
        fn = function() setTriggerMode("toggle") end,
      },
      {
        title = "Toggle recording limit",
        disabled = captureActive,
        menu = {
          { title = "10 minutes", checked = toggleLimitSeconds == 600, fn = function() setToggleLimit(600) end },
          { title = "30 minutes", checked = toggleLimitSeconds == 1800, fn = function() setToggleLimit(1800) end },
          { title = "No limit", checked = toggleLimitSeconds == 0, fn = function() setToggleLimit(0) end },
        },
      },
      { title = "-" },
      { title = "Advanced: edit ~/.hammerspoon/init.lua", disabled = true },
    },
  }
  menu[#menu + 1] = { title = "Reload config", fn = function() hs.reload() end }

  return menu
end

local function clearTranscribePollTimer()
  if transcribePollTimer then
    transcribePollTimer:stop()
    transcribePollTimer = nil
  end
end

local function defaultAudioInput()
  local device = hs.audiodevice.defaultInputDevice()
  if device and device:name() and device:name() ~= "" then
    return ":" .. device:name()
  end
  return ":0"
end

local function pasteText(text, target)
  hs.pasteboard.setContents(text)

  if pasteTimer then
    pasteTimer:stop()
    pasteTimer = nil
  end

  pasteTimer = hs.timer.doAfter(0.25, function()
    pasteTimer = nil
    local app = hs.application.frontmostApplication()
    if target and (not app or app:pid() ~= target.pid
        or (target.window and (not hs.window.focusedWindow() or hs.window.focusedWindow():id() ~= target.window))) then
      hs.alert.show("Text copied — focus changed. Use Cmd+V to paste")
      return
    end
    hs.eventtap.keyStroke({ "cmd" }, "v", 0)
  end)
end

-- ===== continuous recorder (pre-buffer) =====

local function recorderIsRunning()
  return recorderTask ~= nil and recorderTask:isRunning()
end

local function startRecorder()
  if captureFinalizing or transcribing or fileExists(captureJournalPath) then return false end
  if recorderIsRunning() then
    return true
  end

  recorderTask = nil
  os.remove(bufferPath)

  local args = {
    "-y",
    "-hide_banner",
    "-loglevel", "error",
    "-f", "avfoundation",
    "-i", defaultAudioInput(),
    "-ar", "16000",
    "-ac", "1",
    "-f", "s16le",
    "-flush_packets", "1",
    bufferPath,
  }

  recorderTask = hs.task.new(ffmpegPath, function(exitCode, stdout, stderr)
    recorderTask = nil
    if not recorderStopping and exitCode ~= 0 then
      print("dictation recorder exited: " .. tostring(exitCode) .. " " .. tostring(stderr))
    end
    recorderStopping = false
    if captureActive then
      finishCapture("Microphone stopped — captured audio saved; retry with Ctrl+B")
    end
  end, function()
    return true
  end, args)

  if not recorderTask or not recorderTask:start() then
    recorderTask = nil
    return false
  end

  lastBufferSize = 0
  lastGrowthAt = hs.timer.secondsSinceEpoch()
  return true
end

local function stopRecorder()
  if recorderTask then
    recorderStopping = true
    if recorderTask:isRunning() then
      -- interrupt() sends SIGINT (graceful stop — ffmpeg finalizes its output).
      -- NEVER use terminate()/SIGKILL here: it truncates the tail of the recording.
      recorderTask:interrupt()
    end
  end
end

local function restartRecorder()
  if captureActive or captureFinalizing or transcribing then
    recorderNeedsRestart = true
    return
  end

  recorderNeedsRestart = false
  stopRecorder()

  if recorderRestartTimer then
    recorderRestartTimer:stop()
  end
  recorderRestartTimer = hs.timer.doAfter(0.4, function()
    recorderRestartTimer = nil
    startRecorder()
  end)
end

-- ===== transcription =====

local function transcribe(startBytes, endBytes, retry, saveOnly)
  if transcribing then return end
  if not fileExists(transcribeScriptPath) then
    captureFinalizing = false
    showError("Transcribe script missing — audio remains in capture buffer")
    return
  end
  transcribing = true
  clearTranscribePollTimer()
  indicatorShowProcessing()
  local target, notice = captureTarget, captureNotice
  local jobPath = recordingsPath .. "/" .. os.date("%Y%m%d-%H%M%S") .. "-" .. hs.host.uuid()
  activeJobPath = jobPath
  hs.fs.mkdir(jobPath)
  local resultPath, statusPath = jobPath .. "/transcript.txt", jobPath .. "/status"
  local command = shellQuote(transcribeScriptPath) .. " --job " .. shellQuote(jobPath)
  if saveOnly then command = command .. " --save-only" end
  if retry then
    command = command .. " --retry"
  else
    command = command .. string.format(" --cut %s %d %d", shellQuote(bufferPath), startBytes, endBytes)
  end
  local exited = false
  dictationWorkerTask = hs.task.new("/bin/bash", function(code, stdout, stderr)
    exited = true
    if code ~= 0 then print("dictation worker exited: " .. tostring(code) .. " " .. tostring(stderr)) end
  end, { "-l", "-c", command })
  if not dictationWorkerTask or not dictationWorkerTask:start() then
    transcribing, captureFinalizing = false, false
    showError("Could not start transcription — recording remains saved")
    return
  end

  local poll
  local function schedulePoll()
    transcribePollTimer = hs.timer.doAfter(0.2, poll)
  end
  poll = function()
    transcribePollTimer = nil
    -- The worker acknowledges only after committing the complete recovery WAV.
    if not retry and fileExists(jobPath .. "/audio-ready") then
      os.remove(captureJournalPath)
      captureFinalizing = false
    end
    local status = trim(readTextFile(statusPath))
    local progress = trim(readTextFile(jobPath .. "/progress"))
    if dictationMenubar and progress ~= "" then dictationMenubar:setTitle("… " .. progress) end
    if status == "done" or status == "saved" or status == "ignored" or status:match("^error") or exited then
      transcribing, captureFinalizing = false, false
      if dictationMenubar then dictationMenubar:setTitle("") end
      if saveOnly then
        if status == "saved" and not fileExists(captureJournalPath) then
          indicatorHide()
          startRecorder()
          hs.alert.show("Recording saved locally — Fn ready; Ctrl+B to transcribe", 6)
        else
          showError("Could not save recording — audio kept; use Save interrupted recording and resume")
          print("capture recovery failed: " .. readTextFile(jobPath .. "/error.log"))
        end
      elseif status == "done" then
        local text = trim(readTextFile(resultPath))
        if text == "" then
          showError("No speech recognized — audio saved; Ctrl+B to retry")
        else
          pasteText(text, target)
          indicatorShowSuccess()
          if notice then hs.alert.show(notice, 6) end
        end
      elseif status == "ignored" then
        indicatorHide()
      else
        showError("Transcription failed — audio saved; Ctrl+B to retry")
        print("transcribe failed: " .. readTextFile(jobPath .. "/error.log"))
      end
      return
    end
    schedulePoll()
  end
  schedulePoll()
end

savePendingCapture = function()
  if captureActive or captureFinalizing or transcribing then return end
  local ok, pending = pcall(hs.json.decode, readTextFile(captureJournalPath))
  local size = alignDown(fileSize(bufferPath))
  if not ok or type(pending) ~= "table" or type(pending.start) ~= "number"
      or pending.start < 0 or pending.start % 2 ~= 0
      or (pending.finish ~= nil and (type(pending.finish) ~= "number"
        or pending.finish % 2 ~= 0 or pending.finish > size))
      or (pending.finish or size) <= pending.start then
    showError("Cannot recover recording metadata — original audio kept in capture buffer")
    return
  end
  captureTarget, captureNotice = nil, nil
  captureFinalizing = true
  transcribe(pending.start, pending.finish or size, false, true)
end

local function rememberTarget()
  local app = hs.application.frontmostApplication()
  local window = hs.window.focusedWindow()
  return app and { pid = app:pid(), window = window and window:id() } or nil
end

retryLastRecording = function()
  if captureActive or captureFinalizing or transcribing then
    hs.alert.show("Finish the current dictation first")
    return
  end
  -- A failed snapshot/reload still has a journal and the original raw buffer.
  local ok, pending = pcall(hs.json.decode, readTextFile(captureJournalPath))
  captureTarget, captureNotice = rememberTarget(), nil
  if ok and type(pending) == "table" and type(pending.start) == "number" then
    transcribe(pending.start, pending.finish or alignDown(fileSize(bufferPath)))
  elseif fileExists(lastWavPath) then
    transcribe(nil, nil, true)
  else
    showError("No saved recording yet")
  end
end

-- ===== fn-key dictation: cut a slice out of the buffer =====

local function startCapture()
  if captureActive or captureFinalizing or transcribing then
    hs.alert.show("Please wait — the previous dictation is still processing")
    return
  end
  if fileExists(captureJournalPath) then
    showError("Recording pending — use Save interrupted recording and resume in the menu")
    return
  end
  if recorderNeedsRestart then
    restartRecorder()
    hs.alert.show("Microphone reconnecting — try Fn again in a moment")
    return
  end

  captureTarget, captureNotice = rememberTarget(), nil
  captureActive = true
  captureLimitWarned = false
  capturePressedAt = hs.timer.secondsSinceEpoch()

  if not recorderIsRunning() then
    -- cold start: the recorder was somehow down, the beginning may get clipped
    if not startRecorder() then
      captureActive = false
      showError("Microphone could not start")
      return
    end
    captureSizeAtPress = 0
    captureStartBytes = 0
  else
    captureSizeAtPress = fileSize(bufferPath)
    local preroll = math.floor(prerollSeconds * bytesPerSecond)
    captureStartBytes = alignDown(math.max(0, captureSizeAtPress - preroll))
  end

  if not saveCaptureJournal() then
    captureActive = false
    showError("Cannot save recording — check free disk space")
    return
  end
  lastBufferSize, lastGrowthAt = fileSize(bufferPath), hs.timer.secondsSinceEpoch()
  indicatorShowRecording()
end

finishCapture = function(notice, saveOnly)
  if not captureActive then
    return
  end

  captureActive = false
  captureFinalizing = true
  captureNotice = notice
  if notice then
    -- Warn as soon as capture is interrupted, even if recognition takes minutes.
    hs.alert.closeAll(0)
    hs.alert.show(notice, 6)
  end
  if dictationMenubar then dictationMenubar:setTitle("") end
  local holdDuration = hs.timer.secondsSinceEpoch() - capturePressedAt

  if holdDuration < minDurationSeconds and not notice then
    captureFinalizing = false
    os.remove(captureJournalPath)
    indicatorHide()
    return
  end

  indicatorShowProcessing()

  -- wait until ffmpeg flushes the tail of the phrase into the buffer
  local targetBytes = captureSizeAtPress + math.floor(holdDuration * bytesPerSecond)
  local pollDeadline = hs.timer.secondsSinceEpoch() + 0.8

  if capturePollTimer then
    capturePollTimer:stop()
    capturePollTimer = nil
  end

  local poll
  poll = function()
    capturePollTimer = nil

    local size = fileSize(bufferPath)
    if size >= targetBytes or hs.timer.secondsSinceEpoch() > pollDeadline then
      local endBytes = alignDown(size)
      if endBytes <= captureStartBytes then
        captureFinalizing = false
        showError("No audio captured — check the microphone")
        os.remove(captureJournalPath)
        restartRecorder()
        return
      end
      saveCaptureJournal(endBytes)
      transcribe(captureStartBytes, endBytes, false, saveOnly)
      return
    end

    capturePollTimer = hs.timer.doAfter(0.05, poll)
  end

  poll()
end

-- toggle mode: one tap starts a capture, the next tap ends it. Reuses the exact same
-- startCapture/finishCapture as push-to-talk — only the triggering edge differs.
local function toggleCapture()
  if captureActive then
    finishCapture()
    return
  end

  startCapture()
  if captureActive then
    if toggleStartAlert then
      hs.alert.closeAll(0)
      hs.alert.show("Dictation on — tap fn again to stop")
    end

  end
end

-- Re-arm the global fn event tap if macOS silently disabled it (after sleep, under load,
-- or when secure input steals it). Separate from the ffmpeg recorder watchdog. Logs only
-- on the disabled->re-armed transition; :start() on an enabled tap is a safe no-op.
local function rearmHotkeyTapIfDisabled()
  if not dictationFnTap then
    return false
  end
  if dictationFnTap:isEnabled() then
    return false
  end
  local flags = hs.eventtap.checkKeyboardModifiers(true)
  fnWasDown = flags.fn or false
  dictationFnTap:start()
  -- Losing the event tap must never discard the audio or stop Toggle recording.
  -- In PTT, a release might have occurred while the tap was disabled: finalize it.
  if captureActive and triggerMode == "ptt" and not fnWasDown then
    finishCapture("Fn recovered — captured audio saved")
  end
  print("dictation fn event tap was disabled — re-armed")
  return true
end

-- ===== watchdog: recorder alive, buffer growing, rotation =====

dictationRecorderWatchdog = hs.timer.doEvery(5, function()
  if captureFinalizing or transcribing or fileExists(captureJournalPath) and not captureActive then return end
  if captureActive then
    local size, now = fileSize(bufferPath), hs.timer.secondsSinceEpoch()
    local elapsed = now - capturePressedAt
    if triggerMode == "toggle" and toggleLimitSeconds > 0 then
      if elapsed >= toggleLimitSeconds then
        finishCapture("Toggle time limit reached — saving audio locally", true)
        return
      elseif elapsed >= toggleLimitSeconds - 60 and not captureLimitWarned then
        captureLimitWarned = true
        hs.alert.show("Toggle stops in one minute — tap Fn to finish and transcribe", 6)
      end
    end
    if size > lastBufferSize then
      lastBufferSize, lastGrowthAt = size, now
    elseif now - lastGrowthAt > 12 then
      recorderNeedsRestart = true
      finishCapture("Microphone stalled — captured audio saved; check your microphone")
    end
    if dictationMenubar and captureActive then
      local seconds = math.floor(now - capturePressedAt)
      dictationMenubar:setTitle(string.format("%d:%02d", math.floor(seconds / 60), seconds % 60))
    end
    return
  end

  if recorderNeedsRestart then restartRecorder(); return end

  if not recorderIsRunning() then
    if not recorderRestartTimer then
      startRecorder()
    end
    return
  end

  local size = fileSize(bufferPath)
  local now = hs.timer.secondsSinceEpoch()

  if size > lastBufferSize then
    lastBufferSize = size
    lastGrowthAt = now
  elseif now - lastGrowthAt > 12 then
    print("dictation recorder stalled, restarting")
    restartRecorder()
    return
  end

  if size > maxBufferBytes and not transcribing then
    restartRecorder()
  end
end)

-- restart the recorder after wake: avfoundation often breaks after sleep
dictationWakeWatcher = hs.caffeinate.watcher.new(function(event)
  if event == hs.caffeinate.watcher.systemDidWake then
    restartRecorder()
    rearmHotkeyTapIfDisabled()
  end
end)
dictationWakeWatcher:start()

-- default microphone changed (headset plugged/unplugged) — restart
hs.audiodevice.watcher.setCallback(function(event)
  if event == "dIn " then
    if captureActive then finishCapture("Microphone changed — captured audio saved; start a new dictation") end
    restartRecorder()
  end
end)
hs.audiodevice.watcher.start()

dictationFnTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
  -- Arrow/navigation events can also carry the secondary-Fn flag. Only the physical
  -- Fn key changes recording state (macOS virtual keycode 63).
  if event:getKeyCode() ~= 63 then return false end
  local flags = event:getFlags()
  local fnDown = flags.fn or false

  if triggerMode == "toggle" then
    -- react only to the press edge; the release does nothing
    if fnDown and not fnWasDown then
      fnWasDown = true
      toggleCapture()
    elseif not fnDown and fnWasDown then
      fnWasDown = false
    end
  else
    -- push-to-talk (default): hold to record, release to transcribe
    if fnDown and not fnWasDown then
      fnWasDown = true
      startCapture()
    elseif not fnDown and fnWasDown then
      fnWasDown = false
      finishCapture()
    end
  end

  return false
end)

dictationFnTap:start()
-- separate health watchdog for the fn event tap, independent of the recorder watchdog
dictationHotkeyWatchdog = hs.timer.doEvery(hotkeyWatchdogInterval, rearmHotkeyTapIfDisabled)

-- menu-bar icon (in addition to the on-screen dot); dictationMenubar is a global so it
-- survives config reloads.
if menubarEnabled then
  dictationMenubar = hs.menubar.new()
  if dictationMenubar then
    dictationMenubar:setMenu(menubarBuildMenu)
    dictationMenubar:setTooltip("Whisper dictation — " .. triggerModeLabel(triggerMode))
    setMenubarState("idle")
  end
end

indicatorHide()

hs.shutdownCallback = function()
  -- The persisted journal survives reload/quit. The next launch snapshots the flushed
  -- buffer before allowing a new recording to replace it.
  if captureActive then saveCaptureJournal() end
  stopRecorder()
end

-- Preserve the ring buffer through reloads until any interrupted capture is recovered.
-- SIGINT flushes ffmpeg; never unlink a buffer still needed by a pending journal.
hs.execute("/usr/bin/pkill -INT -f 'ffmpeg.*(dictation-buffer|capture-buffer).raw' >/dev/null 2>&1", true)
hs.execute("/bin/chmod 700 " .. shellQuote(dataPath) .. " " .. shellQuote(recordingsPath))
dictationStartupTimer = hs.timer.doAfter(0.5, function()
  if fileExists(captureJournalPath) then
    savePendingCapture()
  else
    startRecorder()
  end
end)
dictationRetryHotkey = hs.hotkey.bind({ "ctrl" }, "b", retryLastRecording)

-- Read-only diagnostics for the local hs CLI; no transcript or microphone contents.
function dictationStatus()
  return {
    state = captureActive and "recording" or captureFinalizing and "saving"
      or transcribing and "transcribing" or "idle",
    mode = triggerMode,
    toggleLimitSeconds = toggleLimitSeconds,
    recorderRunning = recorderIsRunning(),
    bufferBytes = fileSize(bufferPath),
    pendingCapture = fileExists(captureJournalPath),
    lastJob = activeJobPath,
    fnTapEnabled = dictationFnTap:isEnabled(),
  }
end
