# ETHOS Telemetry Replay

`EthosTelemetryReplay` is a self-contained ETHOS widget that replays telemetry from CSV logs and publishes the replayed values as ETHOS virtual Lua sources.

It is intended as a development helper for offline testing when no live model telemetry is available.

Typical use cases:

- drive map or HUD widgets from recorded flight logs
- test line graphs, value widgets, alarms, and source bindings in the ETHOS simulator
- reproduce telemetry-related bugs deterministically
- build new ETHOS tools against a stable telemetry playback source

## What it does

The widget performs three jobs at the same time:

1. It reads telemetry rows from a CSV log file.
2. It advances through the log in real time or at a configurable replay speed.
3. It exports the replayed values as ETHOS Lua sources such as `ReplayLat`, `ReplayGSpd`, and `ReplayRoll`.

The widget can also render its own compact status view on screen so you can verify that replay is running and which values are currently active.

## Package contents

The helper folder contains:

- `main.lua`: the widget and virtual source implementation
- `DemoTelemetry.csv`: sample log for testing
- `README.md`: this documentation

## Installation

Copy the whole folder to the SD card of the radio or into the simulator script tree.

Example target layout:

```text
/scripts/EthosTelemetryReplay/
  main.lua
  DemoTelemetry.csv   <--- Optional
  README.md           <--- Optional
```

The script discovers CSV logs from the same folder that contains `main.lua`.

## Important runtime requirement

This is a widget-driven replay system.

The widget must be added to at least one ETHOS screen so that its `wakeup()` callback runs continuously in the background. Without an active widget instance, the replay state will not advance and the exported virtual sensors will remain static.

A tiny widget slot is sufficient. The widget does not need to be visually prominent.

## ETHOS widget identity

- Widget key: `tlmrpl`
- Widget name in ETHOS: `Telemetry Replay`

## Configuration options

The widget exposes the following options in its ETHOS configuration form:

- `Log file`: selects one of the `.csv` files found beside `main.lua`
- `Speed (x)`: replay speed multiplier from `1` to `10`
- `Start offset (s)`: starts replay at an offset into the log
- `Format`: `auto`, `edgetx`, or `generic`
- `Loop`: when enabled, replay restarts at end of file

## On-screen status view

The widget view shows the current replay state and decoded telemetry values, including:

- active file
- active format
- running or paused state
- latitude and longitude
- altitude
- ground speed
- course over ground
- satellites
- vertical speed
- RSSI, RQly, TQly
- receiver voltage
- current and consumed capacity
- battery percent
- home distance
- pitch and roll

This status view is useful as a ground truth reference when another widget does not behave as expected.

## Exported virtual sensors

The widget registers the following ETHOS Lua sources (Need to be enabled in Model > Lua).

| Source name | Key | Unit | Decimals | Meaning |
|---|---|---|---:|---|
| `ReplayLat` | `RT_LAT` | degree | 6 | Latitude |
| `ReplayLon` | `RT_LON` | degree | 6 | Longitude |
| `ReplayAlt` | `RT_ALT` | meter | 1 | Altitude above the logged reference |
| `ReplayGSpd` | `RT_GSPD` | km/h | 1 | Ground speed |
| `ReplayCOG` | `RT_COG` | degree | 1 | Course over ground |
| `ReplaySats` | `RT_SATS` | raw | 0 | Satellite count |
| `ReplayVSpd` | `RT_VSPD` | m/s | 2 | Vertical speed |
| `ReplayRSSI` | `RT_RSSI` | raw | 0 | RSSI |
| `ReplayRQly` | `RT_RQ` | raw | 0 | Receiver link quality |
| `ReplayTQly` | `RT_TQ` | raw | 0 | Transmitter link quality |
| `ReplayRxBt` | `RT_RXB` | volt | 2 | Receiver voltage |
| `ReplayCurr` | `RT_CUR` | ampere | 2 | Current draw |
| `ReplayCapa` | `RT_CAP` | mAh | 0 | Consumed capacity |
| `ReplayBat%` | `RT_BAT` | percent | 0 | Battery or fuel percentage |
| `ReplayHome` | `RT_HOME` | meter | 1 | Distance from first valid GPS point |
| `ReplayPitch` | `RT_PIT` | raw | 3 | Pitch in radians |
| `ReplayRoll` | `RT_ROL` | raw | 3 | Roll in radians |

Notes:

- `ReplayHome` is computed by the widget from the first non-zero GPS position in the log.
- `ReplayPitch` and `ReplayRoll` are exported in radians.
- ETHOS source names are what you choose in line graphs, value boxes, or any other source picker.

## Using the sensors in ETHOS

Once the widget is on a screen, the replay sensors can be used like any other ETHOS source.

Examples:

- bind `ReplayGSpd` to an ETHOS line graph to visualize speed changes over time
- bind `ReplayHome` to a value box to verify distance calculations in another widget
- bind `ReplayLat` and `ReplayLon` inside a custom Lua widget for map or navigation development
- bind `ReplayPitch` and `ReplayRoll` to an artificial horizon or debug instrument widget

## CSV log handling

All replay logs are read from the same directory as `main.lua`.

Rules:

- files must use the `.csv` extension
- the widget scans the folder on startup and in configuration mode
- the active file is selected through the widget configuration page

## Supported formats

### `auto` (currently only EdgeTX Logs)

The widget auto-detects the format from the CSV header.

If `Date`, `Time`, and either `GPS` or `GPS_2` are present, the widget treats the file as EdgeTX.

Otherwise it falls back to the generic format.

### EdgeTX CSV

Expected characteristics:

- `Date`
- `Time`
- `GPS` or `GPS_2`

Commonly used EdgeTX columns:

- `Alt(m)`
- `GSpd(kmh)`
- `Hdg(°)`
- `Sats`
- `VSpd(m/s)`
- `1RSS(dB)` or `TRSS(dB)`
- `RQly(%)`
- `TQly(%)`
- `RxBt(V)`
- `Curr(A)`
- `Capa(mAh)`
- `Bat%(%)`
- `Ptch(rad)`
- `Roll(rad)`

GPS parsing expectations:

- the `GPS` field must contain a latitude/longitude pair as a single text field
- the parser expects the two numeric values separated by whitespace

Timing behavior:

- replay timing is derived from `Date` plus `Time`
- fractional seconds are supported when present

### Generic CSV

The generic mode is intended for custom telemetry exporters or converted logs.

Preferred columns:

- `timestamp_ms`
- `lat` or `latitude`
- `lon` or `longitude`
- `alt_m` or `altitude_m`
- `speed_mps` or `gspd_mps`
- `course_deg` or `heading_deg`
- `sats`
- `vspd_mps`
- `rssi` or `rssi_db`
- `rqly`
- `tqly`
- `rxbatt_v` or `voltage_v`
- `current_a`
- `capacity_mah`
- `bat_pct` or `fuel_pct`
- `pitch_rad` or `pitch_deg`
- `roll_rad` or `roll_deg`

Behavior details:

- speed from generic logs is expected in meters per second and converted internally to km/h
- pitch and roll in degrees are converted internally to radians
- if `timestamp_ms` is not available, the widget falls back to a fixed 100 ms step

## Replay flow and timing model

Replay is stateful and time-based.

The widget stores:

- the start time on the radio or simulator
- the first log timestamp
- the next row timestamp
- the current decoded telemetry values

During each `wakeup()` cycle, it computes the target log time from:

- elapsed runtime since replay start
- the selected speed multiplier

It then consumes all log rows up to the target timestamp and updates the shared telemetry state.

This means the exported sources always reflect the most recent replay state rather than a fixed polling index.

## Internal design relevant for developers

This helper uses two design decisions that are important if you want to reuse the code in another ETHOS project.

### Shared replay state

The script stores replay values in a shared table on `_G`:

```lua
_G.__TelemetryReplayState
```

This allows widget lifecycle code and source callbacks to access the same replay state reliably.

### Per-source callback closures

Each virtual sensor is registered with its own bound `init` and `wakeup` callback.

This avoids relying on `source:name()` or `source:key()` at runtime to identify which source ETHOS is calling. In practice this is the safer approach for simulator and radio compatibility.

If you add more replay sensors in the future, keep that closure-based registration pattern.

## How to embed this into another ETHOS project

If you want to reuse telemetry replay in another widget or development tool, the minimal pattern is:

1. Copy the replay parser and state-management logic into a helper module or into your widget.
2. Keep one shared replay state table in `_G` so every callback sees the same values.
3. Register sources using one closure per source configuration.
4. Ensure at least one widget instance calls `wakeup()` regularly.
5. Read replayed values from the shared state or from the registered ETHOS sources, depending on the target architecture.

Two integration approaches work well:

### Approach A: Keep it as a standalone helper widget

Use `EthosTelemetryReplay` unchanged and consume only the exported sources from your main project.

Advantages:

- clean separation of concerns
- reusable across projects
- easy to debug because the replay widget shows its own state

### Approach B: Embed the replay engine into another widget

Move the parser, row decoding, state update, and source registration into the new project.

Advantages:

- single deployment unit
- tighter integration with project-specific logic

Tradeoff:

- you lose the independent replay status panel unless you recreate it

## Recommended development workflow

1. Put a known CSV log into the helper folder.
2. Add the widget to a small screen slot.
3. Start replay from the widget menu.
4. Bind one or more `Replay*` sensors to standard ETHOS widgets first.
5. After those values behave correctly, bind the same sources in your custom project.

This isolates source-binding problems from application logic problems.

## Limitations and assumptions

- the widget only reads CSV logs from its own folder
- the widget must exist on a screen for background replay to advance
- home distance is derived from the first valid GPS sample, not from a logged home field
- pitch and roll are normalized to radians for export
- unsupported columns are ignored rather than causing failure


## Future extension ideas

- more exported sources such as heading error, climb rate trend, or GPS fix quality
- optional derived home bearing or distance-to-waypoint calculations
- replay pause, scrub, and jump controls in the widget UI
- support for additional CSV dialects
- optional module split into parser, replay engine, and ETHOS binding layers
