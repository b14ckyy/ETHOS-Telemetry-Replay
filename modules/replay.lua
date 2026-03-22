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

function M.closeFileHandle(state)
  if state.fileHandle ~= nil then
    pcall(function() state.fileHandle:close() end)
    state.fileHandle = nil
  end
end

function M.resetReplayState(state)
  M.closeFileHandle(state)
  state.header = nil
  state.baseLogMs = nil
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
  state.nextRowMs = ts
  state.startMs = getTimeMs()
  state.running = true
  state.paused = false

  csv.updateFromRow(firstRow, state)

  local offsetMs = math.max(0, csv.safeNumber(state.startOffsetSec, 0) * 1000)
  if offsetMs > 0 then
    local target = state.baseLogMs + offsetMs
    while state.nextRowMs ~= nil and state.nextRowMs < target do
      local row, rowTs = csv.readNextRow(state)
      if row == nil then
        break
      end
      state.nextRowMs = rowTs
      csv.updateFromRow(row, state)
    end
  end
end

function M.advanceReplay(state, csv, getTimeMs)
  if not state.running or state.paused then
    return
  end
  if state.baseLogMs == nil or state.startMs == nil then
    return
  end

  local now = getTimeMs()
  local elapsed = (now - state.startMs) - (state.pausedElapsed or 0)
  local speed = math.max(0.1, state.speed or 1)
  local targetLog = state.baseLogMs + elapsed * speed

  while state.nextRowMs ~= nil and state.nextRowMs <= targetLog do
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
  end
end

function M.jumpForward(state, csv, getTimeMs, seconds)
  if not state.running or state.fileHandle == nil then
    return
  end
  if state.baseLogMs == nil or state.nextRowMs == nil then
    return
  end
  local target = state.nextRowMs + (seconds * 1000)
  while state.nextRowMs < target do
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
  end
  -- Adjust wall-clock reference so advanceReplay stays in sync
  local now = getTimeMs()
  local logElapsed = state.nextRowMs - state.baseLogMs
  local speed = math.max(0.1, state.speed or 1)
  state.startMs = now - (logElapsed / speed)
  state.pausedElapsed = 0
  if state.paused and state.pauseStartMs then
    state.pauseStartMs = now
  end
end

return M
