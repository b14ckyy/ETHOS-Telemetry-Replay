-- replay.lua
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
-- Playback engine for ETHOS Telemetry Replay
--
-- Manages file handle lifecycle, replay state, and time-based
-- advancement through CSV log data. All heavy I/O operations
-- (start, advance, jump) run from wakeup() which has preemption
-- support in ETHOS, avoiding instruction count limit issues.

local M = {}

local mmax = math.max

function M.closeFileHandle(state)
  if state.fileHandle ~= nil then
    pcall(state.fileHandle.close, state.fileHandle)
    state.fileHandle = nil
  end
end

function M.resetReplayState(state)
  M.closeFileHandle(state)
  state.header = nil
  state.baseLogMs = nil
  state.origBaseLogMs = nil
  state.endLogMs = nil
  state.nextRowMs = nil
  state.running = false
  state.paused = false
  state.pausedElapsed = nil
  state.startMs = nil
  state.lastUiRefreshMs = 0
  state.homeLat = nil
  state.homeLon = nil
  state.lineBuffer = nil
  state.lineBufferPos = 1
  state.eofReached = nil
  state.lastBufferedTimestamp = nil
  state.seekTargetMs = nil
  state.bytesPerLine = nil
  state.msPerRow = nil
end

-- Read the last data line of the CSV to determine the end timestamp.
-- Uses fh:seek to jump near the end, avoiding a full file scan.
local function readLastTimestamp(state, csv)
  local fh = state.fileHandle
  if fh == nil or state.header == nil then
    return
  end
  -- Remember current position
  local savedPos = fh:seek("cur", 0)
  if savedPos == nil then
    return
  end
  -- Seek to near end of file (last 4KB should contain the final line)
  local fileSize = fh:seek("end", 0)
  if fileSize == nil or fileSize == 0 then
    fh:seek("set", savedPos)
    return
  end
  local offset = mmax(0, fileSize - 4096)
  fh:seek("set", offset)
  -- Discard partial first line if we didn't seek to the start
  if offset > 0 then
    fh:read("*l")
  end
  -- Read remaining lines and keep the last non-empty one
  local lastLine
  while true do
    local line = fh:read("*l")
    if line == nil then break end
    if line ~= "" then
      lastLine = line
    end
  end
  -- Restore file position
  fh:seek("set", savedPos)
  if lastLine then
    local row = csv.parseCsvLine(lastLine)
    local ts = csv.getRowTimeMs(row, state.header, nil)
    if ts ~= nil then
      state.endLogMs = ts
    end
  end
end

function M.openReplayFile(state, csv)
  M.resetReplayState(state)

  if state.logFile == nil or state.logFile == "" then
    return false, "no log selected"
  end
  local path = state.logDir .. state.logFile

  state.rowCount = nil
  state.rowIndex = 0

  local fh = io.open(path, "r")
  if fh == nil then
    return false, "cannot open log"
  end

  local headerLine = fh:read("*l")
  if headerLine == nil then
    fh:close()
    return false, "empty log"
  end

  local headers = csv.parseCsvLine(headerLine)
  state.header = csv.buildHeaderMap(headers)
  state.formatActive = csv.detectFormat(state.header, state.format)
  state.fileHandle = fh

  -- Measure line metrics from data rows 2+3 for byte-based seeking.
  -- Row 1 often has an irregular timestamp (first sample), so we skip it.
  local posRow1 = fh:seek("cur", 0)
  local line1 = fh:read("*l")
  if line1 and line1 ~= "" and posRow1 then
    local posRow2 = fh:seek("cur", 0)
    local line2 = fh:read("*l")
    if line2 and line2 ~= "" then
      local posRow3 = fh:seek("cur", 0)
      local line3 = fh:read("*l")
      if line3 and line3 ~= "" then
        local posRow4 = fh:seek("cur", 0)
        -- Use row2→row3 for both byte length and time interval (rows 2+3 are regular)
        state.bytesPerLine = posRow3 - posRow2
        local row2 = csv.parseCsvLine(line2)
        local row3 = csv.parseCsvLine(line3)
        local ts2 = csv.getRowTimeMs(row2, state.header, 0)
        local ts3 = csv.getRowTimeMs(row3, state.header, ts2 or 0)
        if ts2 and ts3 and ts3 > ts2 then
          state.msPerRow = ts3 - ts2
        end
      end
    end
    -- Seek back to start of data so readNextRow reads from the beginning
    fh:seek("set", posRow1)
  end

  return true
end

-- Byte-based seek: jump approximately N milliseconds forward in the file.
-- Uses measured bytesPerLine and msPerRow to calculate byte offset.
-- After seeking, discards partial line and parses next full line.
-- Returns true if a valid row was found at the new position.
local function byteSeek(state, csv, deltaMs)
  local fh = state.fileHandle
  if fh == nil or state.bytesPerLine == nil or state.msPerRow == nil then
    return false
  end
  if state.msPerRow <= 0 or state.bytesPerLine <= 0 then
    return false
  end
  local rowsToSkip = deltaMs / state.msPerRow
  local bytesToSkip = math.floor(rowsToSkip * state.bytesPerLine)
  if bytesToSkip < state.bytesPerLine then
    return false
  end
  -- Clear buffered data
  state.lineBuffer = nil
  state.lineBufferPos = 1
  state.eofReached = nil
  state.lastBufferedTimestamp = nil
  -- Seek forward from current position
  local newPos = fh:seek("cur", bytesToSkip)
  if newPos == nil then
    return false
  end
  -- Discard partial line (we likely landed mid-line)
  local partial = fh:read("*l")
  if partial == nil then
    -- Overshot EOF, seek back a bit
    fh:seek("end", -4096)
    fh:read("*l")  -- discard partial
  end
  -- Read next full line
  local line = fh:read("*l")
  if line == nil or line == "" then
    return false
  end
  local row = csv.parseCsvLine(line)
  local ts = csv.getRowTimeMs(row, state.header, state.nextRowMs or 0)
  if ts == nil then
    return false
  end
  state.nextRowMs = ts
  csv.updateFromRow(row, state)
  return true
end

function M.startReplay(state, csv, getTimeMs)
  state.lastError = nil
  local ok, err = M.openReplayFile(state, csv)
  if not ok then
    state.lastError = err
    return
  end

  local firstRow, ts = csv.readNextRow(state)
  if firstRow == nil then
    state.lastError = "no data"
    return
  end

  state.baseLogMs = ts
  state.origBaseLogMs = ts
  state.nextRowMs = ts
  state.startMs = getTimeMs()
  state.running = true
  state.paused = false

  -- Determine end timestamp for progress display (reads last CSV line)
  readLastTimestamp(state, csv)

  csv.updateFromRow(firstRow, state)

  local offsetMs = mmax(0, csv.safeNumber(state.startOffsetSec, 0) * 1000)
  if offsetMs > 0 then
    -- Try fast byte-based seek first
    if not byteSeek(state, csv, offsetMs) then
      -- Fallback: incremental seeking via advanceReplay
      state.seekTargetMs = state.baseLogMs + offsetMs
    else
      -- Reset wall-clock reference to new position
      state.startMs = getTimeMs()
      state.baseLogMs = state.nextRowMs
      state.pausedElapsed = 0
    end
  end
end

function M.advanceReplay(state, csv, getTimeMs)
  if not state.running or state.paused then
    return
  end

  -- Incremental seeking (offset or jump)
  if state.seekTargetMs then
    local seeked = 0
    while seeked < 10 do
      local row, rowTs = csv.readNextRow(state)
      if row == nil then
        state.seekTargetMs = nil
        if state.loop then
          M.startReplay(state, csv, getTimeMs)
        else
          state.rowCount = state.rowIndex
          state.running = false
        end
        return
      end
      state.nextRowMs = rowTs
      csv.updateFromRow(row, state)
      seeked = seeked + 1
      if state.nextRowMs >= state.seekTargetMs then
        state.seekTargetMs = nil
        -- Reset wall-clock reference to current position
        state.startMs = getTimeMs()
        state.baseLogMs = state.nextRowMs
        state.pausedElapsed = 0
        if state.paused and state.pauseStartMs then
          state.pauseStartMs = getTimeMs()
        end
        break
      end
    end
    return
  end

  if state.baseLogMs == nil or state.startMs == nil then
    return
  end

  local now = getTimeMs()
  local elapsed = (now - state.startMs) - (state.pausedElapsed or 0)
  local speed = mmax(0.1, state.speed or 1)
  local targetLog = state.baseLogMs + elapsed * speed

  local consumed = 0
  while state.nextRowMs ~= nil and state.nextRowMs <= targetLog and consumed < 10 do
    local row, ts = csv.readNextRow(state)
    if row == nil then
      if state.loop then
        M.startReplay(state, csv, getTimeMs)
      else
        state.rowCount = state.rowIndex
        state.running = false
      end
      return
    end
    state.nextRowMs = ts
    csv.updateFromRow(row, state)
    consumed = consumed + 1
  end
end

function M.jumpForward(state, csv, getTimeMs, seconds)
  if not state.running or state.fileHandle == nil then
    return
  end
  if state.baseLogMs == nil or state.nextRowMs == nil then
    return
  end
  local deltaMs = seconds * 1000
  -- Try fast byte-based seek first
  if byteSeek(state, csv, deltaMs) then
    -- Reset wall-clock reference to new position
    state.startMs = getTimeMs()
    state.baseLogMs = state.nextRowMs
    state.pausedElapsed = 0
    if state.paused and state.pauseStartMs then
      state.pauseStartMs = getTimeMs()
    end
  else
    -- Fallback: incremental seeking via advanceReplay
    state.seekTargetMs = state.nextRowMs + deltaMs
  end
end

return M
