-- EthosTelemetryReplay
-- Copyright (C) 2026 Marc Hoffmann (GitHub: b14ckyy)
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

local function safeNumber(value, default)
  if value == nil then
    return default or 0
  end
  local text = tostring(value):gsub(",", ".")
  local num = tonumber(text)
  if num == nil then
    return default or 0
  end
  return num
end

local function safeAtan2(y, x)
  local atan2Compat = rawget(math, "atan2")
  if atan2Compat ~= nil then
    return atan2Compat(y, x)
  end
  if math.atan ~= nil then
    local ok, value = pcall(math.atan, y, x)
    if ok and type(value) == "number" then
      return value
    end
    if x > 0 then
      return math.atan(y / x)
    end
    if x < 0 and y >= 0 then
      return math.atan(y / x) + math.pi
    end
    if x < 0 and y < 0 then
      return math.atan(y / x) - math.pi
    end
    if x == 0 and y > 0 then
      return math.pi / 2
    end
    if x == 0 and y < 0 then
      return -math.pi / 2
    end
  end
  return 0
end

local function parseCsvLine(line)
  local out = {}
  local field = ""
  local inQuotes = false
  local i = 1
  while i <= #line do
    local c = line:sub(i, i)
    if c == '"' then
      if inQuotes and line:sub(i + 1, i + 1) == '"' then
        field = field .. '"'
        i = i + 1
      else
        inQuotes = not inQuotes
      end
    elseif c == "," and not inQuotes then
      out[#out + 1] = field
      field = ""
    else
      field = field .. c
    end
    i = i + 1
  end
  out[#out + 1] = field
  return out
end

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

local function listLogFiles(dir)
  local files = {}
  local ok, lfs = pcall(require, "lfs")
  if ok and lfs and lfs.dir then
    for name in lfs.dir(dir) do
      if name ~= "." and name ~= ".." then
        if name:lower():match("%.csv$") then
          files[#files + 1] = name
        end
      end
    end
  end
  table.sort(files)
  return files
end

local function buildHeaderMap(headers)
  local map = {}
  local seen = {}
  for i = 1, #headers do
    local base = headers[i]:gsub("^%s+", ""):gsub("%s+$", "")
    if seen[base] then
      seen[base] = seen[base] + 1
      base = base .. "_" .. tostring(seen[base])
    else
      seen[base] = 1
    end
    map[base] = i
  end
  return map
end

local function parseDateTimeMs(dateText, timeText)
  if dateText == nil or timeText == nil then
    return nil
  end
  local y, m, d = dateText:match("(%d+)%-(%d+)%-(%d+)")
  local hh, mm, ss, frac = timeText:match("(%d+):(%d+):(%d+)%.?(%d*)")
  if y == nil then
    return nil
  end
  local ms = 0
  if frac ~= nil and frac ~= "" then
    if #frac == 1 then
      ms = tonumber(frac) * 100
    elseif #frac == 2 then
      ms = tonumber(frac) * 10
    else
      ms = tonumber(frac:sub(1, 3)) or 0
    end
  end
  local sec = os.time({
    year = tonumber(y),
    month = tonumber(m),
    day = tonumber(d),
    hour = tonumber(hh),
    min = tonumber(mm),
    sec = tonumber(ss)
  })
  if sec == nil then
    return nil
  end
  return sec * 1000 + ms
end

local function getRowTimeMs(row, header, previous)
  local idx = header["timestamp_ms"]
  if idx ~= nil then
    local ts = safeNumber(row[idx], -1)
    if ts >= 0 then
      return ts
    end
  end

  local dateIdx = header["Date"]
  local timeIdx = header["Time"]
  if dateIdx ~= nil and timeIdx ~= nil then
    local ts = parseDateTimeMs(row[dateIdx], row[timeIdx])
    if ts ~= nil then
      return ts
    end
  end

  return (previous or 0) + 100
end

local function parseGpsLatLon(text)
  if text == nil then
    return 0, 0
  end
  local parts = {}
  for p in tostring(text):gmatch("[^%s]+") do
    parts[#parts + 1] = p
  end
  if #parts >= 2 then
    return safeNumber(parts[1], 0), safeNumber(parts[2], 0)
  end
  return 0, 0
end

local function haversine(lat1, lon1, lat2, lon2)
  local r = 6371000
  local rad = math.rad
  local dLat = rad(lat2 - lat1)
  local dLon = rad(lon2 - lon1)
  local a = math.sin(dLat / 2) * math.sin(dLat / 2)
    + math.cos(rad(lat1)) * math.cos(rad(lat2))
    * math.sin(dLon / 2) * math.sin(dLon / 2)
  local c = 2 * safeAtan2(math.sqrt(a), math.sqrt(1 - a))
  return r * c
end

local function formatFixed(value, decimals)
  local number = safeNumber(value, 0)
  if decimals == nil or decimals <= 0 then
    return tostring(math.floor(number + 0.5))
  end
  return string.format("%." .. tostring(decimals) .. "f", number)
end

local function formatReplayValue(field)
  if field == "lat" or field == "lon" then
    return formatFixed(state[field], 6)
  end
  if field == "altM" or field == "gspdKmh" or field == "cog" or field == "homeDist" then
    return formatFixed(state[field], 1)
  end
  if field == "vspd" or field == "rxbatt" or field == "curr" then
    return formatFixed(state[field], 2)
  end
  if field == "pitch" or field == "roll" then
    return formatFixed(state[field], 3)
  end
  return tostring(math.floor(safeNumber(state[field], 0) + 0.5))
end

local function buildTelemetryRows()
  return {
    { "File", state.logFile or "-" },
    { "Format", state.formatActive or state.format or "-" },
    { "Status", state.running and (state.paused and "Paused" or "Running") or "Stopped" },
    { "Lat", formatReplayValue("lat") },
    { "Lon", formatReplayValue("lon") },
    { "Alt m", formatReplayValue("altM") },
    { "GSpd km/h", formatReplayValue("gspdKmh") },
    { "COG deg", formatReplayValue("cog") },
    { "Sats", formatReplayValue("sats") },
    { "VSpd m/s", formatReplayValue("vspd") },
    { "RSSI", formatReplayValue("rssi") },
    { "RQly", formatReplayValue("rqly") },
    { "TQly", formatReplayValue("tqly") },
    { "RxBt V", formatReplayValue("rxbatt") },
    { "Curr A", formatReplayValue("curr") },
    { "Capa mAh", formatReplayValue("capa") },
    { "Bat %", formatReplayValue("batpct") },
    { "Home m", formatReplayValue("homeDist") },
    { "Pitch rad", formatReplayValue("pitch") },
    { "Roll rad", formatReplayValue("roll") },
  }
end

local function resetReplayState()
  state.fileHandle = nil
  state.header = nil
  state.baseLogMs = nil
  state.nextRowMs = nil
  state.running = false
  state.paused = false
  state.startMs = nil
  state.lastUiRefreshMs = 0
  state.homeLat = nil
  state.homeLon = nil
end

local function detectFormat(header)
  if state.format ~= nil and state.format ~= "auto" then
    return state.format
  end
  if header["Date"] ~= nil and header["Time"] ~= nil and (header["GPS"] ~= nil or header["GPS_2"] ~= nil) then
    return "edgetx"
  end
  return "generic"
end

local function openReplayFile()
  resetReplayState()

  if state.logFile == nil or state.logFile == "" then
    return false, "no log selected"
  end
  local path = state.logDir .. state.logFile
  local fh = io.open(path, "r")
  if fh == nil then
    return false, "cannot open log"
  end

  local headerLine = fh:read("*l")
  if headerLine == nil then
    fh:close()
    return false, "empty log"
  end

  local headers = parseCsvLine(headerLine)
  state.header = buildHeaderMap(headers)
  state.formatActive = detectFormat(state.header)
  state.fileHandle = fh
  return true
end

local function readNextRow()
  if state.fileHandle == nil then
    return nil
  end
  local line = state.fileHandle:read("*l")
  if line == nil then
    return nil
  end
  if line == "" then
    return readNextRow()
  end
  return parseCsvLine(line)
end

local function extractValue(row, header, candidates, default)
  for i = 1, #candidates do
    local idx = header[candidates[i]]
    if idx ~= nil then
      return safeNumber(row[idx], default or 0)
    end
  end
  return default or 0
end

local function updateFromRow(row)
  local header = state.header

  local lat = 0
  local lon = 0
  if state.formatActive == "edgetx" and (header["GPS"] ~= nil or header["GPS_2"] ~= nil) then
    local gpsIdx = header["GPS"] or header["GPS_2"]
    lat, lon = parseGpsLatLon(row[gpsIdx])
  else
    lat = extractValue(row, header, {"lat", "latitude"}, 0)
    lon = extractValue(row, header, {"lon", "longitude"}, 0)
  end

  local altM = extractValue(row, header, {"Alt(m)", "alt_m", "altitude_m"}, 0)
  local gspdKmh = extractValue(row, header, {"GSpd(kmh)"}, 0)
  if gspdKmh == 0 then
    local gspdMps = extractValue(row, header, {"speed_mps", "gspd_mps"}, 0)
    gspdKmh = gspdMps * 3.6
  end

  local cog = extractValue(row, header, {"Hdg(°)", "course_deg", "heading_deg"}, 0)
  local sats = extractValue(row, header, {"Sats", "sats"}, 0)
  local vspd = extractValue(row, header, {"VSpd(m/s)", "vspd_mps"}, 0)
  local rssi = extractValue(row, header, {"1RSS(dB)", "TRSS(dB)", "rssi", "rssi_db"}, 0)
  local rqly = extractValue(row, header, {"RQly(%)", "rqly"}, 100)
  local tqly = extractValue(row, header, {"TQly(%)", "tqly"}, 100)
  local rxbatt = extractValue(row, header, {"RxBt(V)", "rxbatt_v", "voltage_v"}, 0)
  local curr = extractValue(row, header, {"Curr(A)", "current_a"}, 0)
  local capa = extractValue(row, header, {"Capa(mAh)", "capacity_mah"}, 0)
  local batpct = extractValue(row, header, {"Bat%(%)", "bat_pct", "fuel_pct"}, 0)
  local pitchRad = extractValue(row, header, {"Ptch(rad)", "pitch_rad"}, 0)
  local rollRad = extractValue(row, header, {"Roll(rad)", "roll_rad"}, 0)
  if pitchRad == 0 then
    local pitchDeg = extractValue(row, header, {"pitch_deg"}, 0)
    pitchRad = pitchDeg * math.pi / 180
  end
  if rollRad == 0 then
    local rollDeg = extractValue(row, header, {"roll_deg"}, 0)
    rollRad = rollDeg * math.pi / 180
  end

  state.lat = lat
  state.lon = lon
  state.altM = altM
  state.gspdKmh = gspdKmh
  state.cog = cog
  state.sats = sats
  state.vspd = vspd
  state.rssi = math.abs(rssi)
  state.rqly = rqly
  state.tqly = tqly
  state.rxbatt = rxbatt
  state.curr = curr
  state.capa = capa
  state.batpct = batpct
  state.pitch = pitchRad
  state.roll = rollRad

  if state.homeLat == nil and lat ~= 0 and lon ~= 0 then
    state.homeLat = lat
    state.homeLon = lon
  end

  if state.homeLat ~= nil and lat ~= 0 and lon ~= 0 then
    state.homeDist = haversine(state.homeLat, state.homeLon, lat, lon)
  end
end

local function startReplay()
  local ok, err = openReplayFile()
  if not ok then
    state.lastError = err
    return
  end

  local firstRow = readNextRow()
  if firstRow == nil then
    state.lastError = "no data"
    return
  end

  local ts = getRowTimeMs(firstRow, state.header, 0)
  state.baseLogMs = ts
  state.nextRowMs = ts
  state.startMs = getTimeMs()
  state.running = true
  state.paused = false

  updateFromRow(firstRow)

  local offsetMs = math.max(0, safeNumber(state.startOffsetSec, 0) * 1000)
  if offsetMs > 0 then
    local target = state.baseLogMs + offsetMs
    while state.nextRowMs ~= nil and state.nextRowMs < target do
      local row = readNextRow()
      if row == nil then
        break
      end
      local rowTs = getRowTimeMs(row, state.header, state.nextRowMs)
      state.nextRowMs = rowTs
      updateFromRow(row)
    end
  end
end

local function advanceReplay()
  state = getSharedState()
  if not state.running or state.paused then
    return
  end
  if state.baseLogMs == nil or state.startMs == nil then
    return
  end

  local now = getTimeMs()
  local elapsed = now - state.startMs
  local speed = math.max(0.1, state.speed or 1)
  local targetLog = state.baseLogMs + elapsed * speed

  while state.nextRowMs ~= nil and state.nextRowMs <= targetLog do
    local row = readNextRow()
    if row == nil then
      if state.loop then
        startReplay()
      else
        state.running = false
      end
      return
    end
    local ts = getRowTimeMs(row, state.header, state.nextRowMs)
    state.nextRowMs = ts
    updateFromRow(row)
  end
end

-- ---------------------------------------------------------------------------
-- Ethos Sources
-- ---------------------------------------------------------------------------

local sourceConfig = {
  { key = "RT_LAT",  name = "ReplayLat",  unit = UNIT_DEGREE, decimals = 6, field = "lat" },
  { key = "RT_LON",  name = "ReplayLon",  unit = UNIT_DEGREE, decimals = 6, field = "lon" },
  { key = "RT_ALT",  name = "ReplayAlt",  unit = UNIT_METER,  decimals = 1, field = "altM" },
  { key = "RT_GSPD", name = "ReplayGSpd", unit = UNIT_KMH,    decimals = 1, field = "gspdKmh" },
  { key = "RT_COG",  name = "ReplayCOG",  unit = UNIT_DEGREE, decimals = 1, field = "cog" },
  { key = "RT_SATS", name = "ReplaySats", unit = UNIT_RAW,    decimals = 0, field = "sats" },
  { key = "RT_VSPD", name = "ReplayVSpd", unit = UNIT_METER_PER_SECOND, decimals = 2, field = "vspd" },
  { key = "RT_RSSI", name = "ReplayRSSI", unit = UNIT_RAW,    decimals = 0, field = "rssi" },
  { key = "RT_RQ",   name = "ReplayRQly", unit = UNIT_RAW,    decimals = 0, field = "rqly" },
  { key = "RT_TQ",   name = "ReplayTQly", unit = UNIT_RAW,    decimals = 0, field = "tqly" },
  { key = "RT_RXB",  name = "ReplayRxBt", unit = UNIT_VOLTS,  decimals = 2, field = "rxbatt" },
  { key = "RT_CUR",  name = "ReplayCurr", unit = UNIT_AMPERE, decimals = 2, field = "curr" },
  { key = "RT_CAP",  name = "ReplayCapa", unit = UNIT_MILLIAMPERE_HOUR, decimals = 0, field = "capa" },
  { key = "RT_BAT",  name = "ReplayBat%", unit = UNIT_PERCENT, decimals = 0, field = "batpct" },
  { key = "RT_HOME", name = "ReplayHome", unit = UNIT_METER,  decimals = 1, field = "homeDist" },
  { key = "RT_PIT",  name = "ReplayPitch", unit = UNIT_RAW,    decimals = 3, field = "pitch" },
  { key = "RT_ROL",  name = "ReplayRoll",  unit = UNIT_RAW,    decimals = 3, field = "roll" },
}

local function makeSourceInit(cfg)
  return function(source)
    if source == nil then
      return
    end
    if type(source.unit) == "function" then
      pcall(function() source:unit(cfg.unit) end)
    end
    if type(source.decimals) == "function" then
      pcall(function() source:decimals(cfg.decimals) end)
    end
    if type(source.value) == "function" then
      pcall(function() source:value(0) end)
    end
  end
end

local function makeSourceWakeup(cfg)
  return function(source)
    if source == nil or type(source.value) ~= "function" then
      return
    end
    local shared = getSharedState()
    local value = shared[cfg.field]
    if value == nil then
      value = 0
    end
    pcall(function() source:value(value) end)
  end
end

local function registerSources()
  if system == nil or type(system.registerSource) ~= "function" then
    return
  end
  for i = 1, #sourceConfig do
    local cfg = sourceConfig[i]
    pcall(function()
      system.registerSource({
        key = cfg.key,
        name = cfg.name,
        init = makeSourceInit(cfg),
        wakeup = makeSourceWakeup(cfg)
      })
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Widget lifecycle
-- ---------------------------------------------------------------------------

local function refreshLogList()
  state.logDir = getScriptDir()
  state.files = listLogFiles(state.logDir)
  if #state.files == 0 then
    state.files = { "DemoTelemetry.csv" }
  end
  if state.fileIndex == nil or state.fileIndex < 1 or state.fileIndex > #state.files then
    state.fileIndex = 1
  end
  state.logFile = state.files[state.fileIndex]
end

local function create()
  state.speed = state.speed or 1
  state.loop = state.loop or false
  state.startOffsetSec = state.startOffsetSec or 0
  state.format = state.format or "auto"
  state.files = state.files or {}
  refreshLogList()
  resetReplayState()
  return {}
end

local function paint()
  state = getSharedState()
  local w, h = lcd.getWindowSize()
  local rows = buildTelemetryRows()
  local leftX = 4
  local valueX = math.floor(w * 0.46)
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
    end
  )

  line = form.addLine("Speed (x)")
  form.addNumberField(line, nil, 1, 10,
    function() return math.floor(state.speed or 1) end,
    function(value) state.speed = value end
  )

  line = form.addLine("Start offset (s)")
  form.addNumberField(line, nil, 0, 3600,
    function() return math.floor(state.startOffsetSec or 0) end,
    function(value) state.startOffsetSec = value end
  )

  line = form.addLine("Format")
  form.addChoiceField(line, form.getFieldSlots(line)[0],
    formatChoices,
    function() return getFormatChoiceIndex() end,
    function(value) setFormatChoice(value) end
  )

  line = form.addLine("Loop")
  form.addBooleanField(line, form.getFieldSlots(line)[0],
    function() return state.loop end,
    function(value) state.loop = value end
  )
end

local function wakeup()
  state = getSharedState()
  if state.running then
    advanceReplay()
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
    { "Replay: Start", function() startReplay() end },
    { "Replay: Pause/Resume", function() state.paused = not state.paused end },
    { "Replay: Stop", function() state.running = false end },
    { "Replay: Restart", function() startReplay() end },
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
  registerSources()
  if system and system.registerWidget then
    system.registerWidget(buildWidgetDef())
  end
end

-- Return widget definition so the script is discoverable when loaded as a widget script.
local def = buildWidgetDef()
def.init = init
return def
