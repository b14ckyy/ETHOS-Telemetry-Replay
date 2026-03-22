-- sources.lua
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
-- ETHOS virtual source definitions and registration
-- for ETHOS Telemetry Replay
--
-- Defines the sourceConfig table that maps internal state fields to
-- ETHOS Lua sources. Developers can add new sensors by extending
-- the sourceConfig table with additional entries.

local M = {}

-- ---------------------------------------------------------------------------
-- Unit conversion helpers
-- ---------------------------------------------------------------------------

local function convertAlt(v, s)
  if s.altUnit == "ft" then return v * 3.28084 end
  return v
end

local function convertSpeed(v, s)
  if s.speedUnit == "ms" then return v / 3.6 end
  if s.speedUnit == "knots" then return v / 1.852 end
  return v
end

local function convertVspd(v, s)
  if s.vspdUnit == "fts" then return v * 3.28084 end
  return v
end

local function convertAttitude(v, s)
  if s.attitudeUnit == "deg" then
    local deg = v * 180 / math.pi
    if deg > 180 then deg = deg - 360 end
    if deg < -180 then deg = deg + 360 end
    return deg
  end
  return v
end

local function getAltUnit(s)
  if s.altUnit == "ft" then return UNIT_FEET end
  return UNIT_METER
end

local function getSpeedUnit(s)
  if s.speedUnit == "ms" then return UNIT_METER_PER_SECOND end
  if s.speedUnit == "knots" then return UNIT_KNOT end
  return UNIT_KMH
end

local function getVspdUnit(s)
  if s.vspdUnit == "fts" then return UNIT_FEET_PER_SECOND end
  return UNIT_METER_PER_SECOND
end

local function getAttitudeUnit(s)
  if s.attitudeUnit == "deg" then return UNIT_DEGREE end
  return UNIT_RADIAN
end

-- Each entry defines one virtual ETHOS sensor:
--   key       – unique ETHOS source key
--   name      – display name shown in ETHOS source picker
--   unit      – default ETHOS unit constant
--   decimals  – default decimal places
--   field     – state field name that holds the current replay value
--   convert   – optional fn(value, state) for unit conversion
--   unitFn    – optional fn(state) returning the dynamic ETHOS unit constant
--   decimalsFn – optional fn(state) returning dynamic decimal places
--   isGps     – true for combined GPS source
M.sourceConfig = {
  { key = "RT_GPS",  name = "ReplayGPS",   unit = UNIT_DEGREE,             decimals = 6, field = "lat", isGps = true },
  { key = "RT_LAT",  name = "ReplayLat",   unit = UNIT_DEGREE,             decimals = 6, field = "lat" },
  { key = "RT_LON",  name = "ReplayLon",   unit = UNIT_DEGREE,             decimals = 6, field = "lon" },
  { key = "RT_ALT",  name = "ReplayAlt",   unit = UNIT_METER,              decimals = 1, field = "altM",
    convert = convertAlt, unitFn = getAltUnit },
  { key = "RT_GSPD", name = "ReplayGSpd",  unit = UNIT_KMH,               decimals = 1, field = "gspdKmh",
    convert = convertSpeed, unitFn = getSpeedUnit },
  { key = "RT_COG",  name = "ReplayCOG",   unit = UNIT_DEGREE,             decimals = 1, field = "cog" },
  { key = "RT_SATS", name = "ReplaySats",  unit = UNIT_RAW,                decimals = 0, field = "sats" },
  { key = "RT_VSPD", name = "ReplayVSpd",  unit = UNIT_METER_PER_SECOND,   decimals = 2, field = "vspd",
    convert = convertVspd, unitFn = getVspdUnit },
  { key = "RT_RSSI", name = "ReplayRSSI",  unit = UNIT_RAW,                decimals = 0, field = "rssi" },
  { key = "RT_RQ",   name = "ReplayRQly",  unit = UNIT_RAW,                decimals = 0, field = "rqly" },
  { key = "RT_TQ",   name = "ReplayTQly",  unit = UNIT_RAW,                decimals = 0, field = "tqly" },
  { key = "RT_RXB",  name = "ReplayRxBt",  unit = UNIT_VOLTS,              decimals = 2, field = "rxbatt" },
  { key = "RT_CUR",  name = "ReplayCurr",  unit = UNIT_AMPERE,             decimals = 2, field = "curr" },
  { key = "RT_CAP",  name = "ReplayCapa",  unit = UNIT_MILLIAMPERE_HOUR,   decimals = 0, field = "capa" },
  { key = "RT_BAT",  name = "ReplayBat%",  unit = UNIT_PERCENT,            decimals = 0, field = "batpct" },
  { key = "RT_HOME", name = "ReplayHome",  unit = UNIT_METER,              decimals = 1, field = "homeDist" },
  { key = "RT_PIT",  name = "ReplayPitch", unit = UNIT_RAW,                decimals = 3, field = "pitch",
    convert = convertAttitude, unitFn = getAttitudeUnit,
    decimalsFn = function(s) return s.attitudeUnit == "deg" and 1 or 3 end },
  { key = "RT_ROL",  name = "ReplayRoll",  unit = UNIT_RAW,                decimals = 3, field = "roll",
    convert = convertAttitude, unitFn = getAttitudeUnit,
    decimalsFn = function(s) return s.attitudeUnit == "deg" and 1 or 3 end },
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

local function makeSourceWakeup(cfg, getSharedState)
  return function(source)
    if source == nil or type(source.value) ~= "function" then
      return
    end
    local shared = getSharedState()
    if cfg.isGps then
      local lat = shared.lat or 0
      local lon = shared.lon or 0
      local ok = pcall(function() source:value(lat, lon) end)
      if not ok then
        pcall(function() source:value(lat) end)
      end
      return
    end
    local value = shared[cfg.field]
    if value == nil then value = 0 end
    if cfg.convert then
      value = cfg.convert(value, shared)
    end
    pcall(function() source:value(value) end)
    if cfg.unitFn then
      pcall(function() source:unit(cfg.unitFn(shared)) end)
    end
    if cfg.decimalsFn then
      pcall(function() source:decimals(cfg.decimalsFn(shared)) end)
    end
  end
end

function M.registerSources(getSharedState)
  if system == nil or type(system.registerSource) ~= "function" then
    return
  end
  for i = 1, #M.sourceConfig do
    local cfg = M.sourceConfig[i]
    pcall(function()
      system.registerSource({
        key = cfg.key,
        name = cfg.name,
        init = makeSourceInit(cfg),
        wakeup = makeSourceWakeup(cfg, getSharedState)
      })
    end)
  end
end

return M
