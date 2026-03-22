-- csv.lua
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
-- CSV parsing and telemetry data extraction module
-- for ETHOS Telemetry Replay
--
-- Handles all CSV file reading, header mapping, field extraction,
-- and mapping of raw CSV columns to normalized telemetry state fields.
-- Supports EdgeTX and generic CSV formats.

local M = {}

-- ---------------------------------------------------------------------------
-- Utility helpers
-- ---------------------------------------------------------------------------

function M.safeNumber(value, default)
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

local safeNumber = M.safeNumber

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

-- ---------------------------------------------------------------------------
-- CSV parsing
-- ---------------------------------------------------------------------------

function M.parseCsvLine(line)
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

function M.buildHeaderMap(headers)
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

function M.parseDateTimeMs(dateText, timeText)
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

function M.getRowTimeMs(row, header, previous)
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
    local ts = M.parseDateTimeMs(row[dateIdx], row[timeIdx])
    if ts ~= nil then
      return ts
    end
  end

  return (previous or 0) + 100
end

function M.parseGpsLatLon(text)
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

function M.extractValue(row, header, candidates, default)
  for i = 1, #candidates do
    local idx = header[candidates[i]]
    if idx ~= nil then
      return safeNumber(row[idx], default or 0)
    end
  end
  return default or 0
end

function M.detectFormat(header, formatSetting)
  if formatSetting ~= nil and formatSetting ~= "auto" then
    return formatSetting
  end
  if header["Date"] ~= nil and header["Time"] ~= nil and (header["GPS"] ~= nil or header["GPS_2"] ~= nil) then
    return "edgetx"
  end
  return "generic"
end

-- ---------------------------------------------------------------------------
-- Row-to-state mapping
-- ---------------------------------------------------------------------------

function M.updateFromRow(row, state)
  local header = state.header

  local lat = 0
  local lon = 0
  if state.formatActive == "edgetx" and (header["GPS"] ~= nil or header["GPS_2"] ~= nil) then
    local gpsIdx = header["GPS"] or header["GPS_2"]
    lat, lon = M.parseGpsLatLon(row[gpsIdx])
  else
    lat = M.extractValue(row, header, {"lat", "latitude"}, 0)
    lon = M.extractValue(row, header, {"lon", "longitude"}, 0)
  end

  local altM = M.extractValue(row, header, {"Alt(m)", "alt_m", "altitude_m"}, 0)
  local gspdKmh = M.extractValue(row, header, {"GSpd(kmh)"}, 0)
  if gspdKmh == 0 then
    local gspdMps = M.extractValue(row, header, {"speed_mps", "gspd_mps"}, 0)
    gspdKmh = gspdMps * 3.6
  end

  local cog = M.extractValue(row, header, {"Hdg(°)", "course_deg", "heading_deg"}, 0)
  local sats = M.extractValue(row, header, {"Sats", "sats"}, 0)
  local vspd = M.extractValue(row, header, {"VSpd(m/s)", "vspd_mps"}, 0)
  local rssi = M.extractValue(row, header, {"1RSS(dB)", "TRSS(dB)", "rssi", "rssi_db"}, 0)
  local rqly = M.extractValue(row, header, {"RQly(%)", "rqly"}, 100)
  local tqly = M.extractValue(row, header, {"TQly(%)", "tqly"}, 100)
  local rxbatt = M.extractValue(row, header, {"RxBt(V)", "rxbatt_v", "voltage_v"}, 0)
  local curr = M.extractValue(row, header, {"Curr(A)", "current_a"}, 0)
  local capa = M.extractValue(row, header, {"Capa(mAh)", "capacity_mah"}, 0)
  local batpct = M.extractValue(row, header, {"Bat%(%)", "bat_pct", "fuel_pct"}, 0)
  local pitchRad = M.extractValue(row, header, {"Ptch(rad)", "pitch_rad"}, 0)
  local rollRad = M.extractValue(row, header, {"Roll(rad)", "roll_rad"}, 0)
  if pitchRad == 0 then
    local pitchDeg = M.extractValue(row, header, {"pitch_deg"}, 0)
    pitchRad = pitchDeg * math.pi / 180
  end
  if rollRad == 0 then
    local rollDeg = M.extractValue(row, header, {"roll_deg"}, 0)
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

-- ---------------------------------------------------------------------------
-- Buffered File I/O
-- ---------------------------------------------------------------------------

M.BUFFER_SIZE = 50       -- parsed rows kept per buffer fill
M.MAX_RAW_READS = 500   -- safety cap on raw lines read per fill cycle

function M.fillBuffer(state)
  if state.fileHandle == nil then
    return
  end
  if state.lineBuffer == nil then
    state.lineBuffer = {}
    state.lineBufferPos = 1
  end
  local buf = state.lineBuffer
  local count = 0
  local rawReads = 0
  local maxRate = state.maxSensorRate or 5
  local speed = math.max(0.1, state.speed or 1)
  local minIntervalMs = speed * 1000 / maxRate
  local lastTs = state.lastBufferedTimestamp

  while count < M.BUFFER_SIZE and rawReads < M.MAX_RAW_READS do
    local line = state.fileHandle:read("*l")
    if line == nil then
      state.eofReached = true
      return
    end
    if line ~= "" then
      rawReads = rawReads + 1
      state.rowIndex = (state.rowIndex or 0) + 1
      local row = M.parseCsvLine(line)
      local ts = M.getRowTimeMs(row, state.header, lastTs or 0)
      if lastTs == nil or (ts - lastTs) >= minIntervalMs then
        buf[#buf + 1] = { row = row, timeMs = ts }
        lastTs = ts
        count = count + 1
      end
    end
  end
  state.lastBufferedTimestamp = lastTs
end

function M.readNextRow(state)
  if state.lineBuffer == nil or state.lineBufferPos > #state.lineBuffer then
    if state.eofReached then
      return nil
    end
    if state.fileHandle == nil then
      return nil
    end
    state.lineBuffer = {}
    state.lineBufferPos = 1
    M.fillBuffer(state)
    if #state.lineBuffer == 0 then
      return nil
    end
  end
  local entry = state.lineBuffer[state.lineBufferPos]
  state.lineBufferPos = state.lineBufferPos + 1
  -- Free consumed entry for GC
  state.lineBuffer[state.lineBufferPos - 1] = nil
  return entry.row, entry.timeMs
end

function M.listLogFiles(dir)
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

return M
