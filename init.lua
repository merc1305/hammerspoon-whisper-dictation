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
local bufferPath = "/tmp/dictation-buffer.raw"
local resultPath = "/tmp/dictation.txt"
local errorPath = "/tmp/dictation.err"
local statusPath = "/tmp/dictation.status"
local pidPath = "/tmp/dictation-whisper.pid"
local historyPath = os.getenv("HOME") .. "/.local/share/whisper/history.jsonl"

local minDurationSeconds = 0.5
local prerollSeconds = 0.5
local bytesPerSecond = 32000 -- 16 kHz * mono * s16 (2 bytes)
local maxBufferBytes = 256 * 1024 * 1024 -- ~2.2 hours, then the buffer is rotated

-- trigger mode: "ptt" (hold fn) is the default; "toggle" = tap fn to start, tap to stop.
local triggerMode = "ptt"
local toggleMaxSeconds = 300 -- safety auto-stop if a toggle session is left running
local toggleStartAlert = true -- brief on-screen hint when a toggle session starts
local hotkeyWatchdogInterval = 2 -- seconds between health checks of the fn event tap
local menubarEnabled = true -- show a menu-bar icon (in addition to the on-screen dot)
local menubarHistoryCount = 10 -- how many recent dictations the dropdown lists

local transcribing = false
local fnWasDown = false
local transcribePollTimer = nil
local pasteTimer = nil

-- continuous recorder state (pre-buffer)
local recorderTask = nil
local recorderStopping = false
local recorderRestartTimer = nil
local lastBufferSize = 0
local lastGrowthAt = 0

-- current dictation state (fn held down)
local captureActive = false
local captureStartBytes = 0
local captureSizeAtPress = 0
local capturePressedAt = 0
local capturePollTimer = nil
local toggleAutoStopTimer = nil -- auto-stop timer for an active toggle session

local function trim(text)
  return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
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
    indicatorCanvas:behavior({ "canJoinAllSpaces", "stationary", "ignoresCycle" })
  else
    indicatorCanvas:frame(indicatorFrame())
  end

  return indicatorCanvas
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
  indicatorEnsureCanvas():show()
  indicatorTimer = hs.timer.doEvery(interval, indicatorRender)
end

local function indicatorPulse(state, duration)
  indicatorCancelHide()
  indicatorStopTimer()
  indicatorState = state
  indicatorTick = 0
  indicatorRender()
  indicatorEnsureCanvas():show()
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
  local modeLabel = (triggerMode == "toggle") and "Toggle" or "Push-to-talk"
  menu[#menu + 1] = { title = "Dictation — " .. modeLabel, disabled = true }
  menu[#menu + 1] = { title = "-" }

  local entries = menubarHistoryEntries()
  if #entries == 0 then
    menu[#menu + 1] = { title = "No dictations yet", disabled = true }
  else
    for _, e in ipairs(entries) do
      local when = e.ts and os.date("%H:%M", e.ts) or "--:--"
      local engine = e.engine or "unknown"
      local text = e.text or ""
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
  menu[#menu + 1] = { title = "Settings: edit ~/.hammerspoon/init.lua", disabled = true }
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

local function pasteText(text)
  hs.pasteboard.setContents(text)

  if pasteTimer then
    pasteTimer:stop()
    pasteTimer = nil
  end

  pasteTimer = hs.timer.doAfter(0.25, function()
    pasteTimer = nil
    local app = hs.application.frontmostApplication()
    if app then
      app:activate()
    end
    hs.eventtap.keyStroke({ "cmd" }, "v", 0)
  end)
end

-- ===== continuous recorder (pre-buffer) =====

local function recorderIsRunning()
  return recorderTask ~= nil and recorderTask:isRunning()
end

local function startRecorder()
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
    "-af", "volume=12dB",
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
  if captureActive then
    return
  end

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

local function transcribe(startBytes, endBytes)
  if transcribing then
    return
  end
  if not fileExists(transcribeScriptPath) then
    showError("transcribe script not found")
    return
  end

  transcribing = true
  clearTranscribePollTimer()
  indicatorShowProcessing()

  os.remove(resultPath)
  os.remove(errorPath)
  os.remove(statusPath)
  os.remove(pidPath)

  local command = string.format(
    "%q --cut %q %d %d >/dev/null 2>&1 &",
    transcribeScriptPath, bufferPath, startBytes, endBytes
  )
  hs.execute(command, true)

  local deadline = hs.timer.secondsSinceEpoch() + 180
  local poll
  local function schedulePoll()
    clearTranscribePollTimer()
    transcribePollTimer = hs.timer.doAfter(0.2, poll)
  end

  poll = function()
    transcribePollTimer = nil

    if not transcribing then
      return
    end

    local status = trim(readTextFile(statusPath))

    if status == "done" then
      transcribing = false

      local text = trim(readTextFile(resultPath))
      if text == "" then
        showError("no speech recognized")
        return
      end

      pasteText(text)
      indicatorShowSuccess()
      return
    end

    if status == "ignored" then
      transcribing = false
      indicatorHide()
      return
    end

    if status:match("^error") then
      transcribing = false
      showError("transcription failed")
      print("transcribe failed: " .. readTextFile(errorPath))
      return
    end

    if hs.timer.secondsSinceEpoch() <= deadline then
      schedulePoll()
      return
    end

    transcribing = false

    local pid = trim(readTextFile(pidPath))
    if pid:match("^%d+$") then
      hs.execute("/bin/kill -TERM " .. pid .. " >/dev/null 2>&1", true)
    end

    showError("transcription timed out")
  end

  schedulePoll()
end

-- ===== fn-key dictation: cut a slice out of the buffer =====

local function startCapture()
  if captureActive or transcribing then
    return
  end

  captureActive = true
  capturePressedAt = hs.timer.secondsSinceEpoch()

  if not recorderIsRunning() then
    -- cold start: the recorder was somehow down, the beginning may get clipped
    startRecorder()
    captureSizeAtPress = 0
    captureStartBytes = 0
  else
    captureSizeAtPress = fileSize(bufferPath)
    local preroll = math.floor(prerollSeconds * bytesPerSecond)
    captureStartBytes = alignDown(math.max(0, captureSizeAtPress - preroll))
  end

  indicatorShowRecording()
end

local function finishCapture()
  if not captureActive then
    return
  end

  captureActive = false
  if toggleAutoStopTimer then
    toggleAutoStopTimer:stop()
    toggleAutoStopTimer = nil
  end
  local holdDuration = hs.timer.secondsSinceEpoch() - capturePressedAt

  if holdDuration < minDurationSeconds then
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
        showError("no audio captured")
        restartRecorder()
        return
      end
      transcribe(captureStartBytes, endBytes)
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
    toggleAutoStopTimer = hs.timer.doAfter(toggleMaxSeconds, function()
      toggleAutoStopTimer = nil
      if captureActive then
        finishCapture()
      end
    end)
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
  fnWasDown = false
  if captureActive then
    captureActive = false
    indicatorHide()
  end
  dictationFnTap:start()
  print("dictation fn event tap was disabled — re-armed")
  return true
end

-- ===== watchdog: recorder alive, buffer growing, rotation =====

dictationRecorderWatchdog = hs.timer.doEvery(5, function()
  if captureActive then
    return
  end

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
    restartRecorder()
  end
end)
hs.audiodevice.watcher.start()

dictationFnTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
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
    dictationMenubar:setTooltip("Whisper dictation")
    setMenubarState("idle")
  end
end

indicatorHide()

-- kill an orphaned recorder from a previous config load, then start ours
hs.execute("/usr/bin/pkill -f 'dictation-buffer.raw' >/dev/null 2>&1", true)
dictationStartupTimer = hs.timer.doAfter(0.5, startRecorder)
