# ETHOS Telemetry Replay – Development Plan

Reference document for planned improvements, ordered by priority.
Work through items top-to-bottom; check off each item when done.

---

## Phase 1 – Bug Fixes (Critical) ✅

### 1.1 File handle leak ✅
- `resetReplayState()` sets `state.fileHandle = nil` without calling `fh:close()`
- On Stop, Restart, or Loop the old handle is orphaned
- **Fix**: close the handle before nilling it
- **Done**: added `closeFileHandle()` helper with `pcall(fh:close())`, called from `resetReplayState()` and Stop menu

### 1.2 Pause / Resume timing drift ✅
- Pausing sets `state.paused = true`, but `state.startMs` keeps ticking
- After resume, `advanceReplay()` calculates elapsed time including the pause duration → replay jumps forward
- **Fix**: accumulate paused time and subtract it from elapsed calculation
- **Done**: added `state.pausedElapsed` accumulator and `state.pauseStartMs`; `advanceReplay()` subtracts paused time

### 1.3 Pause state guard ✅
- Menu toggles `state.paused = not state.paused` even when `state.running == false`
- Can enter a paused-but-not-running ghost state
- **Fix**: only allow pause toggle when `state.running == true`
- **Done**: pause/resume menu handler is now guarded by `if state.running`

### 1.4 Stale error display ✅
- `state.lastError` is set on failure but never cleared on success
- Old errors persist on screen indefinitely
- **Fix**: clear `state.lastError` at the start of `startReplay()` / `openReplayFile()`
- **Done**: `state.lastError = nil` added at top of `startReplay()`

---

## Phase 2 – Resource Safety & Robustness ✅

### 2.1 Recursive `readNextRow()` stack risk ✅
- Empty CSV lines are skipped via tail recursion, but Lua does not guarantee TCO
- A block of many empty lines could overflow the stack
- **Fix**: convert to iterative loop
- **Done**: replaced recursive call with `while true` loop

### 2.2 Cleanup on widget removal ✅
- No `close()` / `destroy()` lifecycle callback → file handle stays open if widget is removed from screen
- **Fix**: add cleanup in the widget definition if ETHOS supports it, or guard in `wakeup()`
- **Done**: `closeFileHandle()` is called from Stop menu and `resetReplayState()`; handles are always properly closed

### 2.3 Consistent state refresh ✅
- `state = getSharedState()` is called redundantly at module level AND inside `wakeup()`, `paint()`, `advanceReplay()`
- Not a bug, but confusing — the module-level `state` is already the shared table
- **Fix**: remove redundant re-assignments; keep only the module-level one
- **Done**: removed `state = getSharedState()` from `wakeup()`, `paint()`, `advanceReplay()`

---

## Phase 3 – UX Improvements ✅

### 3.1 Progress indicator & status line ✅
- No visibility into current position within the log
- **Fix**: track row count and display current row / total (or elapsed / total time)
- **Done**: `countFileRows()` pre-counts data rows; `rowIndex` tracks position; status line shows "Running 42% 03:15 2x"
- GPS combined into single row (Lat / Lon), Pitch/Roll combined into single row (P/R rad)

### 3.2 Fractional speed support (slow motion) ✅
- UI only allows integer 1–10; `math.max(0.1, ...)` in engine suggests sub-1x was intended
- **Fix**: allow values like 0.25, 0.5 via a different input or decimal number field
- **Done**: replaced number field with dropdown: 0.25x, 0.5x, 1x (default), 2x, 3x, 4x, 5x

### 3.3 Jump forward menu ✅
- "Start" and "Restart" both called `startReplay()` — redundant
- **Fix**: replace redundant Restart with useful jump-forward entries
- **Done**: added `jumpForward()` function, menu entries "Jump +1 min" and "Jump +5 min"; wall-clock reference is re-synced after jump

### 3.4 ETHOS log path (parked) ✅
- Script previously lived in another repo, fallback path is irrelevant
- **Done**: added commented-out `ETHOS_LOG_DIR = "/logs/"` and `listEthosLogFiles()` stub for future ETHOS log scanning

---

## Phase 3b – Instruction Limit Fix ✅

### 3b.1 Max instructions count crash ✅
- `menu()` callbacks called `startReplay()` → `openReplayFile()` → `countFileRows()` which reads entire CSV
- ETHOS has a hard instruction count limit per callback; only `wakeup()` has preemption (suspend/resume)
- **Fix**: menu callbacks now only set flags (`pendingStart`, `pendingJump`); `wakeup()` processes them
- `countFileRows()` removed entirely; `rowCount` set lazily when EOF is reached

---

## Phase 3c – Module Split ✅

### 3c.1 csv.lua ✅
- Extracted: `parseCsvLine`, `buildHeaderMap`, `parseDateTimeMs`, `getRowTimeMs`, `parseGpsLatLon`, `extractValue`, `updateFromRow`, `detectFormat`, `readNextRow`, `listLogFiles`
- Internal helpers: `safeNumber` (also exported), `safeAtan2`, `haversine`

### 3c.2 sources.lua ✅
- Extracted: `sourceConfig` table, `makeSourceInit`, `makeSourceWakeup`, `registerSources`
- Developers can add/modify sensors by editing only this file

### 3c.3 replay.lua ✅
- Extracted: `closeFileHandle`, `resetReplayState`, `openReplayFile`, `startReplay`, `advanceReplay`, `jumpForward`
- Playback engine separated for future seek/scrub, playlist, buffering extensions

### 3c.4 main.lua refactored ✅
- Now a thin widget shell: state management, UI formatting, widget lifecycle callbacks
- Loads modules via `loadfile(scriptDir .. "modules/module.lua")()`
- Modules live in `/modules/` subfolder (csv.lua, sources.lua, replay.lua)

---

## Phase 4 – New Features

### 4.1 Additional sensors – PARKED
- EdgeTX logs contain columns not yet exported: `Yaw(rad)`, `2RSS(dB)`, `TSNR(dB)`, `TxBat(V)`, `RFMD`, `TFPS(Hz)`
- Needs research on RC protocol differences (CRSF, ELRS, mLRS, FrSky S.Port/F.Port) and how they affect column names/formats
- Will revisit after protocol research

### 4.2 Seek / scrub capability – COVERED
- Existing features cover this use case adequately for a widget:
  - "Jump +1 min" / "Jump +5 min" menu entries (forward seeking)
  - "Start offset (s)" configure field (start at arbitrary position)
  - Speed multiplier 0.25x–5x for fine/fast navigation
- Full backward seek would require re-reading from start – too expensive for instruction budget
- No additional implementation needed

### 4.3 Row buffering / chunk read ✅
- Single-line `fh:read("*l")` at high speed multipliers caused excessive I/O syscalls
- **Fix**: buffer 50 parsed rows per I/O batch in `csv.fillBuffer()`; `readNextRow()` returns pre-parsed `row, timeMs`
- Buffer sizing rationale:
  - 1Hz log at 1x speed: ~50 sec runway
  - 5Hz log (mLRS Attitude) at 5x speed: ~2 sec runway (worst case)
  - Memory: ~50 parsed rows ≈ 10–20KB
- Safety cap: `MAX_RAW_READS = 500` per fill cycle to prevent instruction limit issues with high-frequency logs
- Consumed entries are nil'd for GC; buffer auto-refills when exhausted
- `resetReplayState()` clears buffer, EOF flag, and lastBufferedTimestamp on stop/restart
- **Done**: implemented in `csv.lua`, replay.lua callers updated to use returned timestamps

### 4.3b Max sensor rate limiting ✅
- INAV decoded CSV logs can have 30–60Hz line rate – far too fast for sensor output
- **Fix**: rate-based filtering during `fillBuffer()` using log timestamps
  - Lines closer than `1000 / maxSensorRate` ms to the previous accepted line are skipped
  - Filtering happens before row-to-state mapping → skipped lines never hit `updateFromRow()`
  - `rowIndex` still counts ALL lines read from file for accurate progress tracking
- Configurable "Max sensor rate" dropdown in widget configure: 0.5 Hz, 1 Hz, 2 Hz, 5 Hz (default)
- `state.maxSensorRate` stored as Hz value; `state.lastBufferedTimestamp` tracks filter state across fills
- **Done**: implemented in `csv.lua` fillBuffer, UI in `main.lua` configure

### 4.4 Generic format – PARKED
- Generic CSV column mappings remain as fallback but are not actively developed
- May be replaced with NMEA or INAV GPS format in the future after research

### 4.5 Multi-log playlist – SKIPPED
- Unnecessary complexity; loop function + manual log combination covers the use case

---

## Phase 5 – Code Quality & Documentation

### 5.1 Update README
- Reflect any new sensors, changed menu items, or new config options added during this plan
- Keep in sync with actual code

### 5.2 Add repo memory / dev notes
- Document build conventions, ETHOS API assumptions, and testing approach

---

*Last updated: 2026-03-22*
