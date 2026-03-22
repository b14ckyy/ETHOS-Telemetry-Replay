-- EthosTelemetryReplay
-- Copyright (C) 2026 Marc Hoffmann (https://github.com/b14ckyy)
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program. If not, see <https://www.gnu.org/licenses/>.
--
--
-- Telemetry Replay Widget (ETHOS)
-- Replays CSV telemetry logs as virtual Lua sources for debugging on real hardware.
-- Place this script on the radio (e.g. /scripts/ethosmaps/helper/TelemetryReplay/main.lua)
-- and add it as a widget so wakeup() runs in the background.
--
-- Log files are read from the same folder as this script by default.
--

local widget = {}
local function getSharedState()
  local shared = rawget(_G, "__TelemetryReplayState")
  if shared == nil then
    shared = {}
    _G.__TelemetryReplayState = shared
  end
  return shared
end
local state = getSharedState()
local formatChoices = {
  {"auto", 1},
  {"edgetx", 2},
  {"generic", 3},
}

local speedChoices = {
  {"0.25x", 1},
  {"0.5x",  2},
  {"1x",    3},
  {"2x",    4},
  {"3x",    5},
  {"4x",    6},
  {"5x",    7},
}
local speedValues = { 0.25, 0.5, 1, 2, 3, 4, 5 }

local rateChoices = {
  {"0.5 Hz", 1},
  {"1 Hz",   2},
  {"2 Hz",   3},
  {"5 Hz",   4},
}
local rateValues = { 0.5, 1, 2, 5 }

local gpsFormatChoices = {
  {"Decimal", 1},
  {"DMS", 2},
}
local gpsFormatValues = {"decimal", "dms"}

local altUnitChoices = {
  {"m", 1},
  {"ft", 2},
}
local altUnitValues = {"m", "ft"}

local speedUnitChoices = {
  {"km/h", 1},
  {"m/s", 2},
  {"knots", 3},
}
local speedUnitValues = {"kmh", "ms", "knots"}

local vspdUnitChoices = {
  {"m/s", 1},
  {"ft/s", 2},
}
local vspdUnitValues = {"ms", "fts"}

local attitudeUnitChoices = {
  {"rad", 1},
  {"deg", 2},
}
local attitudeUnitValues = {"rad", "deg"}

local function getRateChoiceIndex()
  local r = state.maxSensorRate or 5
  for i = 1, #rateValues do
    if rateValues[i] == r then return i end
  end
  return 4 -- default 5 Hz
end

local function setRateChoice(index)
  state.maxSensorRate = rateValues[index] or 5
end

local function choiceIndex(values, current, default)
  for i = 1, #values do
    if values[i] == current then return i end
  end
  return default or 1
end

local function getSpeedChoiceIndex()
  local s = state.speed or 1
  for i = 1, #speedValues do
    if speedValues[i] == s then return i end
  end
  return 3 -- default 1x
end

local function setSpeedChoice(index)
  state.speed = speedValues[index] or 1
end

local function getFormatChoiceIndex()
  if state.format == "edgetx" then
    return 2
  end
  if state.format == "generic" then
    return 3
  end
  return 1
end

local function setFormatChoice(value)
  if value == 2 then
    state.format = "edgetx"
  elseif value == 3 then
    state.format = "generic"
  else
    state.format = "auto"
  end
end

local function getTimeMs()
  if system ~= nil and type(system.getTimeCounter) == "function" then
    local ms = system.getTimeCounter()
    if type(ms) == "number" and ms >= 0 then
      return ms
    end
  end
  return os.clock() * 1000
end

-- ---------------------------------------------------------------------------
-- Module loading
-- ---------------------------------------------------------------------------

local function getScriptDir()
  if debug ~= nil and type(debug.getinfo) == "function" then
    local info = debug.getinfo(1, "S")
    if info and info.source then
      local src = info.source
      if src:sub(1, 1) == "@" then
        src = src:sub(2)
      end
      local dir = src:match("(.*/)")
      if dir ~= nil then
        return dir
      end
    end
  end
  return "/scripts/TelemetryReplay/"
end

local scriptDir = getScriptDir()
local csv = assert(loadfile(scriptDir .. "modules/csv.lua"))()
local sources = assert(loadfile(scriptDir .. "modules/sources.lua"))()
local replay = assert(loadfile(scriptDir .. "modules/replay.lua"))()
local config = assert(loadfile(scriptDir .. "modules/config.lua"))()

local safeNumber = csv.safeNumber

-- Localize frequently used library functions
local mfloor = math.floor
local mabs = math.abs
local mmax = math.max
local sformat = string.format
local mpi = math.pi

-- TODO: enable ETHOS system log scanning once ETHOS log parsing is implemented
-- local ETHOS_LOG_DIR = "/logs/"
-- local function listEthosLogFiles()
--   return csv.listLogFiles(ETHOS_LOG_DIR)
-- end

-- ---------------------------------------------------------------------------
-- Display formatting
-- ---------------------------------------------------------------------------

-- Pre-cached format strings for known decimal counts
local FMT_CACHE = {}
for d = 0, 6 do
  FMT_CACHE[d] = "%." .. tostring(d) .. "f"
end

local function formatFixed(value, decimals)
  local number = safeNumber(value, 0)
  if decimals == nil or decimals <= 0 then
    return tostring(mfloor(number + 0.5))
  end
  local fmt = FMT_CACHE[decimals]
  if fmt == nil then
    fmt = "%." .. tostring(decimals) .. "f"
  end
  return sformat(fmt, number)
end

local function formatReplayValue(field)
  if field == "cog" or field == "homeDist" then
    return formatFixed(state[field], 1)
  end
  if field == "rxbatt" or field == "curr" then
    return formatFixed(state[field], 2)
  end
  return tostring(mfloor(safeNumber(state[field], 0) + 0.5))
end

local function formatDms(decimal, isLat)
  local abs = mabs(decimal)
  local deg = mfloor(abs)
  local minFull = (abs - deg) * 60
  local min = mfloor(minFull)
  local sec = (minFull - min) * 60
  local dir
  if isLat then
    dir = decimal >= 0 and "N" or "S"
  else
    dir = decimal >= 0 and "E" or "W"
  end
  return sformat("%d\176%02d'%04.1f\"%s", deg, min, sec, dir)
end

local function formatSpeedLabel()
  local s = state.speed or 1
  if s == mfloor(s) then
    return tostring(mfloor(s)) .. "x"
  end
  return sformat("%.2gx", s)
end

local function formatLogTimestamp()
  if state.origBaseLogMs == nil or state.nextRowMs == nil then
    return "--:--"
  end
  local elapsedSec = mfloor((state.nextRowMs - state.origBaseLogMs) / 1000)
  if elapsedSec < 0 then elapsedSec = 0 end
  local mm = mfloor(elapsedSec / 60)
  local ss = elapsedSec % 60
  return sformat("%02d:%02d", mm, ss)
end

local function formatProgressPct()
  if state.origBaseLogMs == nil or state.endLogMs == nil or state.nextRowMs == nil then
    return ""
  end
  local total = state.endLogMs - state.origBaseLogMs
  if total <= 0 then
    return ""
  end
  local current = state.nextRowMs - state.origBaseLogMs
  local pct = mfloor(current / total * 100)
  if pct < 0 then pct = 0 end
  if pct > 100 then pct = 100 end
  return tostring(pct) .. "%"
end

local function buildStatusText()
  if not state.running then
    return "Stopped"
  end
  local pct = formatProgressPct()
  local ts = formatLogTimestamp()
  local spd = formatSpeedLabel()
  local parts = state.paused and "Paused" or "Running"
  if pct ~= "" then parts = parts .. " " .. pct end
  parts = parts .. " " .. ts .. " " .. spd
  return parts
end

local function buildTelemetryRows()
  -- GPS display
  local gpsText
  if state.gpsFormat == "dms" then
    gpsText = formatDms(state.lat or 0, true) .. " " .. formatDms(state.lon or 0, false)
  else
    gpsText = formatFixed(state.lat, 6) .. " / " .. formatFixed(state.lon, 6)
  end

  -- Altitude
  local altVal = safeNumber(state.altM, 0)
  local altLabel = "Alt m"
  if state.altUnit == "ft" then
    altVal = altVal * 3.28084
    altLabel = "Alt ft"
  end

  -- Speed
  local spdVal = safeNumber(state.gspdKmh, 0)
  local spdLabel = "GSpd km/h"
  if state.speedUnit == "ms" then
    spdVal = spdVal / 3.6
    spdLabel = "GSpd m/s"
  elseif state.speedUnit == "knots" then
    spdVal = spdVal / 1.852
    spdLabel = "GSpd kn"
  end

  -- VSpd
  local vspdVal = safeNumber(state.vspd, 0)
  local vspdLabel = "VSpd m/s"
  if state.vspdUnit == "fts" then
    vspdVal = vspdVal * 3.28084
    vspdLabel = "VSpd ft/s"
  end

  -- Pitch/Roll
  local pitchVal = safeNumber(state.pitch, 0)
  local rollVal = safeNumber(state.roll, 0)
  local prLabel = "P/R rad"
  local prDec = 3
  if state.attitudeUnit == "deg" then
    pitchVal = pitchVal * 180 / mpi
    rollVal = rollVal * 180 / mpi
    prLabel = "P/R deg"
    prDec = 1
  end

  return {
    { "File", state.logFile or "-" },
    { "Format", state.formatActive or state.format or "-" },
    { "Status", buildStatusText() },
    { "GPS", gpsText },
    { altLabel, formatFixed(altVal, 1) },
    { spdLabel, formatFixed(spdVal, 1) },
    { "COG deg", formatReplayValue("cog") },
    { "Sats", formatReplayValue("sats") },
    { vspdLabel, formatFixed(vspdVal, 2) },
    { "RSSI", formatReplayValue("rssi") },
    { "RQly", formatReplayValue("rqly") },
    { "TQly", formatReplayValue("tqly") },
    { "RxBt V", formatReplayValue("rxbatt") },
    { "Curr A", formatReplayValue("curr") },
    { "Capa mAh", formatReplayValue("capa") },
    { "Bat %", formatReplayValue("batpct") },
    { "Home m", formatReplayValue("homeDist") },
    { prLabel, formatFixed(pitchVal, prDec) .. " / " .. formatFixed(rollVal, prDec) },
  }
end

-- ---------------------------------------------------------------------------
-- Widget lifecycle
-- ---------------------------------------------------------------------------

local function refreshLogList()
  state.logDir = scriptDir
  state.files = csv.listLogFiles(state.logDir)
  if #state.files == 0 then
    state.files = { "DemoTelemetry.csv" }
  end
  if state.fileIndex == nil or state.fileIndex < 1 or state.fileIndex > #state.files then
    state.fileIndex = 1
  end
  state.logFile = state.files[state.fileIndex]
end

local function saveSettings()
  config.save(scriptDir, state)
end

local function create()
  config.load(scriptDir, state)
  state.files = state.files or {}
  refreshLogList()
  replay.resetReplayState(state)
  return {}
end

local function paint()
  local w, h = lcd.getWindowSize()
  local rows = buildTelemetryRows()
  local leftX = 4
  local valueX = mfloor(w * 0.46)
  local y = 4
  local rowHeight = 12

  lcd.font(FONT_S)
  lcd.color(WHITE)
  lcd.drawText(leftX, y, "Telemetry Replay")
  y = y + 14

  lcd.font(FONT_XS)
  for i = 1, #rows do
    if y + rowHeight > h then
      break
    end
    local label = rows[i][1]
    local value = rows[i][2]
    lcd.drawText(leftX, y, label)
    lcd.drawText(valueX, y, tostring(value))
    y = y + rowHeight
  end

  if state.lastError ~= nil and state.lastError ~= "" and y + rowHeight <= h then
    lcd.drawText(leftX, y, "Err: " .. tostring(state.lastError))
  end
end

local function configure(widgetInstance)
  refreshLogList()
  local line = form.addLine("Log file")
  local choices = {}
  for i = 1, #state.files do
    choices[#choices + 1] = { state.files[i], i }
  end
  form.addChoiceField(line, form.getFieldSlots(line)[0], choices,
    function() return state.fileIndex end,
    function(value)
      state.fileIndex = value
      state.logFile = state.files[state.fileIndex]
      saveSettings()
    end
  )

  line = form.addLine("Speed")
  form.addChoiceField(line, form.getFieldSlots(line)[0],
    speedChoices,
    function() return getSpeedChoiceIndex() end,
    function(value) setSpeedChoice(value); saveSettings() end
  )

  line = form.addLine("Start offset (s)")
  form.addNumberField(line, nil, 0, 3600,
    function() return mfloor(state.startOffsetSec or 0) end,
    function(value) state.startOffsetSec = value; saveSettings() end
  )

  line = form.addLine("Format")
  form.addChoiceField(line, form.getFieldSlots(line)[0],
    formatChoices,
    function() return getFormatChoiceIndex() end,
    function(value) setFormatChoice(value); saveSettings() end
  )

  line = form.addLine("Max sensor rate")
  form.addChoiceField(line, form.getFieldSlots(line)[0],
    rateChoices,
    function() return getRateChoiceIndex() end,
    function(value) setRateChoice(value); saveSettings() end
  )

  line = form.addLine("Loop")
  form.addBooleanField(line, form.getFieldSlots(line)[0],
    function() return state.loop end,
    function(value) state.loop = value; saveSettings() end
  )

  line = form.addLine("GPS format")
  form.addChoiceField(line, form.getFieldSlots(line)[0],
    gpsFormatChoices,
    function() return choiceIndex(gpsFormatValues, state.gpsFormat, 1) end,
    function(v) state.gpsFormat = gpsFormatValues[v] or "decimal"; saveSettings() end
  )

  line = form.addLine("Altitude unit")
  form.addChoiceField(line, form.getFieldSlots(line)[0],
    altUnitChoices,
    function() return choiceIndex(altUnitValues, state.altUnit, 1) end,
    function(v) state.altUnit = altUnitValues[v] or "m"; saveSettings() end
  )

  line = form.addLine("Speed unit")
  form.addChoiceField(line, form.getFieldSlots(line)[0],
    speedUnitChoices,
    function() return choiceIndex(speedUnitValues, state.speedUnit, 1) end,
    function(v) state.speedUnit = speedUnitValues[v] or "kmh"; saveSettings() end
  )

  line = form.addLine("VSpd unit")
  form.addChoiceField(line, form.getFieldSlots(line)[0],
    vspdUnitChoices,
    function() return choiceIndex(vspdUnitValues, state.vspdUnit, 1) end,
    function(v) state.vspdUnit = vspdUnitValues[v] or "ms"; saveSettings() end
  )

  line = form.addLine("Attitude unit")
  form.addChoiceField(line, form.getFieldSlots(line)[0],
    attitudeUnitChoices,
    function() return choiceIndex(attitudeUnitValues, state.attitudeUnit, 1) end,
    function(v) state.attitudeUnit = attitudeUnitValues[v] or "rad"; saveSettings() end
  )
end

local function wakeup()
  -- Process deferred commands from menu() (runs with preemption support)
  if state.pendingStart then
    state.pendingStart = nil
    config.load(scriptDir, state)
    refreshLogList()
    replay.startReplay(state, csv, getTimeMs)
  end
  if state.pendingJump then
    local secs = state.pendingJump
    state.pendingJump = nil
    replay.jumpForward(state, csv, getTimeMs, secs)
  end

  if state.running then
    replay.advanceReplay(state, csv, getTimeMs)
  end
  local nowMs = getTimeMs()
  if lcd ~= nil and type(lcd.invalidate) == "function" then
    local lastUiRefreshMs = state.lastUiRefreshMs or 0
    if nowMs - lastUiRefreshMs >= 1000 then
      state.lastUiRefreshMs = nowMs
      lcd.invalidate()
    end
  end
end

local function menu()
  return {
    { "Replay: Start", function() state.pendingStart = true end },
    { "Replay: Pause/Resume", function()
        if state.running then
          if state.paused then
            if state.pauseStartMs then
              state.pausedElapsed = (state.pausedElapsed or 0) + (getTimeMs() - state.pauseStartMs)
              state.pauseStartMs = nil
            end
            state.paused = false
          else
            state.pauseStartMs = getTimeMs()
            state.paused = true
          end
        end
      end },
    { "Replay: Stop", function()
        state.running = false
        replay.closeFileHandle(state)
      end },
    { "Jump +1 min", function() state.pendingJump = 60 end },
    { "Jump +5 min", function() state.pendingJump = 300 end },
  }
end

local function buildWidgetDef()
  return {
    key = "tlmrpl",
    name = "Telemetry Replay",
    create = create,
    configure = configure,
    wakeup = wakeup,
    paint = paint,
    menu = menu,
  }
end

local function init()
  refreshLogList()
  sources.registerSources(getSharedState)
  if system and system.registerWidget then
    system.registerWidget(buildWidgetDef())
  end
end

-- Return widget definition so the script is discoverable when loaded as a widget script.
local def = buildWidgetDef()
def.init = init
return def
