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

-- Localize frequently used library functions for faster access on embedded Lua
local mfloor = math.floor
local mabs = math.abs
local msin = math.sin
local mcos = math.cos
local msqrt = math.sqrt
local mpi = math.pi
local mmax = math.max
local sfind = string.find
local sbyte = string.byte
local ssub = string.sub
local sformat = string.format

local RAD_FACTOR = mpi / 180

function M.safeNumber(value, default)
  if value == nil then
    return default or 0
  end
  -- Fast path: try tonumber directly (works for most numeric strings and numbers)
  local num = tonumber(value)
  if num ~= nil then
    return num
  end
  -- Slow path: only when tonumber fails (e.g. comma decimal separator)
  local text = tostring(value)
  if sfind(text, ",", 1, true) then
    num = tonumber((text:gsub(",", ".")))
    if num ~= nil then
      return num
    end
  end
  return default or 0
end

local safeNumber = M.safeNumber

-- Resolve atan2 once at load time
local atan2Fn
do
  local compat = rawget(math, "atan2")
  if compat ~= nil then
    atan2Fn = compat
  elseif math.atan ~= nil then
    atan2Fn = function(y, x)
      local ok, value = pcall(math.atan, y, x)
      if ok and type(value) == "number" then
        return value
      end
      if x > 0 then return math.atan(y / x) end
      if x < 0 and y >= 0 then return math.atan(y / x) + mpi end
      if x < 0 and y < 0 then return math.atan(y / x) - mpi end
      if x == 0 and y > 0 then return mpi / 2 end
      if x == 0 and y < 0 then return -mpi / 2 end
      return 0
    end
  else
    atan2Fn = function() return 0 end
  end
end

local function haversine(lat1, lon1, lat2, lon2)
  local r = 6371000
  local dLat = (lat2 - lat1) * RAD_FACTOR
  local dLon = (lon2 - lon1) * RAD_FACTOR
  local sinDLat = msin(dLat * 0.5)
  local sinDLon = msin(dLon * 0.5)
  local a = sinDLat * sinDLat
    + mcos(lat1 * RAD_FACTOR) * mcos(lat2 * RAD_FACTOR)
    * sinDLon * sinDLon
  local c = 2 * atan2Fn(msqrt(a), msqrt(1 - a))
  return r * c
end

-- ---------------------------------------------------------------------------
-- CSV parsing
-- ---------------------------------------------------------------------------

function M.parseCsvLine(line)
  local out = {}
  local pos = 1
  local len = #line
  if len == 0 then
    out[1] = ""
    return out
  end
  while pos <= len do
    if sbyte(line, pos) == 34 then  -- '"'
      pos = pos + 1
      local startPos = pos
      local parts = {}
      while pos <= len do
        local q = sfind(line, '"', pos, true)
        if q == nil then
          parts[#parts + 1] = ssub(line, startPos)
          pos = len + 1
          break
        end
        if q < len and sbyte(line, q + 1) == 34 then
          parts[#parts + 1] = ssub(line, startPos, q)
          startPos = q + 2
          pos = q + 2
        else
          parts[#parts + 1] = ssub(line, startPos, q - 1)
          pos = q + 2
          break
        end
      end
      out[#out + 1] = table.concat(parts)
    else
      local comma = sfind(line, ',', pos, true)
      if comma then
        out[#out + 1] = ssub(line, pos, comma - 1)
        pos = comma + 1
        if pos > len then
          out[#out + 1] = ""
        end
      else
        out[#out + 1] = ssub(line, pos)
        pos = len + 1
      end
    end
  end
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
  local y, mo, d = dateText:match("(%d+)%-(%d+)%-(%d+)")
  local hh, mm, ss, frac = timeText:match("(%d+):(%d+):(%d+)%.?(%d*)")
  if y == nil or hh == nil then
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
  -- Arithmetic-only timestamp: avoids os.time() which is expensive on radio.
  -- Absolute value does not matter, only differences between rows.
  y = tonumber(y)
  mo = tonumber(mo)
  d = tonumber(d)
  local dayNum = y * 365 + math.floor(y / 4) + mo * 31 + d
  local dayMs = (tonumber(hh) * 3600 + tonumber(mm) * 60 + tonumber(ss)) * 1000 + ms
  return dayNum * 86400000 + dayMs
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
  local s = tostring(text)
  -- Find first non-space token
  local s1, e1 = sfind(s, "%S+")
  if s1 == nil then
    return 0, 0
  end
  -- Find second non-space token
  local s2, e2 = sfind(s, "%S+", e1 + 1)
  if s2 == nil then
    return safeNumber(ssub(s, s1, e1), 0), 0
  end
  return safeNumber(ssub(s, s1, e1), 0), safeNumber(ssub(s, s2, e2), 0)
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
-- Row-to-state mapping — pre-allocated candidate tables (avoid per-call alloc)
-- ---------------------------------------------------------------------------

local CAND_LAT      = {"lat", "latitude"}
local CAND_LON      = {"lon", "longitude"}
local CAND_ALT      = {"Alt(m)", "alt_m", "altitude_m"}
local CAND_GSPD     = {"GSpd(kmh)"}
local CAND_GSPD_MPS = {"speed_mps", "gspd_mps"}
local CAND_COG      = {"Hdg(\194\176)", "course_deg", "heading_deg"}
local CAND_SATS     = {"Sats", "sats"}
local CAND_VSPD     = {"VSpd(m/s)", "vspd_mps"}
local CAND_RSSI     = {"1RSS(dB)", "TRSS(dB)", "rssi", "rssi_db"}
local CAND_RQLY     = {"RQly(%)", "rqly"}
local CAND_TQLY     = {"TQly(%)", "tqly"}
local CAND_RXBATT   = {"RxBt(V)", "rxbatt_v", "voltage_v"}
local CAND_CURR     = {"Curr(A)", "current_a"}
local CAND_CAPA     = {"Capa(mAh)", "capacity_mah"}
local CAND_BATPCT   = {"Bat%(%)", "bat_pct", "fuel_pct"}
local CAND_PITCH    = {"Ptch(rad)", "pitch_rad"}
local CAND_ROLL     = {"Roll(rad)", "roll_rad"}
local CAND_PITCHDEG = {"pitch_deg"}
local CAND_ROLLDEG  = {"roll_deg"}

function M.updateFromRow(row, state)
  local header = state.header

  local lat = 0
  local lon = 0
  if state.formatActive == "edgetx" and (header["GPS"] ~= nil or header["GPS_2"] ~= nil) then
    local gpsIdx = header["GPS"] or header["GPS_2"]
    lat, lon = M.parseGpsLatLon(row[gpsIdx])
  else
    lat = M.extractValue(row, header, CAND_LAT, 0)
    lon = M.extractValue(row, header, CAND_LON, 0)
  end

  local altM = M.extractValue(row, header, CAND_ALT, 0)
  local gspdKmh = M.extractValue(row, header, CAND_GSPD, 0)
  if gspdKmh == 0 then
    local gspdMps = M.extractValue(row, header, CAND_GSPD_MPS, 0)
    gspdKmh = gspdMps * 3.6
  end

  local cog = M.extractValue(row, header, CAND_COG, 0)
  local sats = M.extractValue(row, header, CAND_SATS, 0)
  local vspd = M.extractValue(row, header, CAND_VSPD, 0)
  local rssi = M.extractValue(row, header, CAND_RSSI, 0)
  local rqly = M.extractValue(row, header, CAND_RQLY, 100)
  local tqly = M.extractValue(row, header, CAND_TQLY, 100)
  local rxbatt = M.extractValue(row, header, CAND_RXBATT, 0)
  local curr = M.extractValue(row, header, CAND_CURR, 0)
  local capa = M.extractValue(row, header, CAND_CAPA, 0)
  local batpct = M.extractValue(row, header, CAND_BATPCT, 0)
  local pitchRad = M.extractValue(row, header, CAND_PITCH, 0)
  local rollRad = M.extractValue(row, header, CAND_ROLL, 0)
  if pitchRad == 0 then
    local pitchDeg = M.extractValue(row, header, CAND_PITCHDEG, 0)
    pitchRad = pitchDeg * RAD_FACTOR
  end
  if rollRad == 0 then
    local rollDeg = M.extractValue(row, header, CAND_ROLLDEG, 0)
    rollRad = rollDeg * RAD_FACTOR
  end

  state.lat = lat
  state.lon = lon
  state.altM = altM
  state.gspdKmh = gspdKmh
  state.cog = cog
  state.sats = sats
  state.vspd = vspd
  state.rssi = mabs(rssi)
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
    -- Skip expensive trig when position hasn't changed
    if lat ~= state._prevLat or lon ~= state._prevLon then
      state.homeDist = haversine(state.homeLat, state.homeLon, lat, lon)
      state._prevLat = lat
      state._prevLon = lon
    end
  end
end

-- ---------------------------------------------------------------------------
-- Buffered File I/O
-- ---------------------------------------------------------------------------

M.BUFFER_SIZE = 10       -- parsed rows kept per buffer fill
M.MAX_RAW_READS = 50    -- safety cap on raw lines read per fill cycle

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
  local speed = mmax(0.1, state.speed or 1)
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
