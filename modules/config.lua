-- config.lua
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
-- Persistent settings for ETHOS Telemetry Replay
--
-- Reads/writes a simple key=value .conf file.
-- Boolean values are stored as "true"/"false".
-- Numeric values are stored as plain numbers.
-- String values are stored as-is.

local M = {}

local CONF_FILE = "settings.conf"

-- Setting definitions: key, type, default, valid (optional list or {min,max} range)
M.schema = {
  { key = "speed",          type = "number",  default = 1,     valid = {0.25, 0.5, 1, 2, 3, 4, 5} },
  { key = "loop",           type = "boolean", default = false },
  { key = "startOffsetSec", type = "number",  default = 0,     valid = {0, 3600} },
  { key = "format",         type = "string",  default = "auto",  valid = {"auto", "edgetx", "generic"} },
  { key = "maxSensorRate",  type = "number",  default = 5,     valid = {0.5, 1, 2, 5} },
  { key = "fileIndex",      type = "number",  default = 1,     valid = {1, 9999} },
  { key = "gpsFormat",     type = "string",  default = "decimal", valid = {"decimal", "dms"} },
  { key = "altUnit",       type = "string",  default = "m",       valid = {"m", "ft"} },
  { key = "speedUnit",     type = "string",  default = "kmh",     valid = {"kmh", "ms", "knots"} },
  { key = "vspdUnit",      type = "string",  default = "ms",      valid = {"ms", "fts"} },
  { key = "attitudeUnit",  type = "string",  default = "rad",     valid = {"rad", "deg"} },
}

local function parseValue(text, valueType)
  if valueType == "boolean" then
    return text == "true"
  elseif valueType == "number" then
    return tonumber(text)
  else
    return text
  end
end

local function isValid(value, schema)
  if value == nil then
    return false
  end
  if schema.valid == nil then
    return true
  end
  if schema.type == "number" and #schema.valid == 2 and schema.valid[1] < schema.valid[2] then
    -- Check if it could be a discrete list (more than 2 entries or values match known choices)
    local isList = false
    for _, v in ipairs(schema.valid) do
      if v == value then isList = true end
    end
    -- For 2-element valid: treat as range if values are not both in the list
    if not isList then
      return value >= schema.valid[1] and value <= schema.valid[2]
    end
    return true
  end
  for i = 1, #schema.valid do
    if schema.valid[i] == value then
      return true
    end
  end
  return false
end

local function formatValue(value, valueType)
  if valueType == "boolean" then
    return value and "true" or "false"
  elseif valueType == "number" then
    return tostring(value)
  else
    return tostring(value or "")
  end
end

function M.load(scriptDir, state)
  local path = scriptDir .. CONF_FILE
  local fh = io.open(path, "r")
  -- Apply defaults first
  for i = 1, #M.schema do
    local s = M.schema[i]
    if state[s.key] == nil then
      state[s.key] = s.default
    end
  end
  if fh == nil then
    return
  end
  local values = {}
  while true do
    local line = fh:read("*l")
    if line == nil then break end
    -- Skip comments and empty lines
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      local k, v = trimmed:match("^([%w_]+)%s*=%s*(.+)$")
      if k and v then
        -- Strip inline comments (e.g. "value  # hint")
        local stripped = v:match("^(.-)%s+#")
        if stripped then v = stripped end
        values[k] = v
      end
    end
  end
  fh:close()
  local dirty = false
  for i = 1, #M.schema do
    local s = M.schema[i]
    if values[s.key] ~= nil then
      local parsed = parseValue(values[s.key], s.type)
      if isValid(parsed, s) then
        state[s.key] = parsed
      else
        state[s.key] = s.default
        dirty = true
      end
    end
  end
  if dirty then
    M.save(scriptDir, state)
  end
end

function M.save(scriptDir, state)
  local path = scriptDir .. CONF_FILE
  local fh = io.open(path, "w")
  if fh == nil then
    return
  end
  fh:write("# Telemetry Replay Settings\n")
  fh:write("# Edit values here or change them in the widget configure screen.\n")
  fh:write("# Invalid values are replaced with defaults on next load.\n\n")
  for i = 1, #M.schema do
    local s = M.schema[i]
    local hint = ""
    if s.valid then
      if s.type == "string" then
        hint = "  # values: " .. table.concat(s.valid, ", ")
      elseif #s.valid == 2 and s.valid[1] < s.valid[2] and s.type == "number" then
        hint = "  # range: " .. tostring(s.valid[1]) .. " - " .. tostring(s.valid[2])
      else
        local vals = {}
        for j = 1, #s.valid do vals[j] = tostring(s.valid[j]) end
        hint = "  # values: " .. table.concat(vals, ", ")
      end
    elseif s.type == "boolean" then
      hint = "  # values: true, false"
    end
    local val = state[s.key]
    if val == nil then val = s.default end
    fh:write(s.key .. " = " .. formatValue(val, s.type) .. hint .. "\n")
  end
  fh:close()
end

return M
