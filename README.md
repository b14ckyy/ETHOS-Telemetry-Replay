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
3. It exports the replayed values as ETHOS Lua sources such as `ReplayGPS`, `ReplayGSpd`, and `ReplayRoll`.

The widget can also render its own compact status view on screen so you can verify that replay is running and which values are currently active.

## Package contents

```text
main.lua                 Widget entry point and UI
modules/
  csv.lua                CSV parsing, header mapping, buffered I/O
  sources.lua            Virtual ETHOS sensor definitions and registration
  replay.lua             Playback engine (file lifecycle, timing, advancement)
  config.lua             Persistent settings read/write with validation
settings.conf            User-editable configuration file
DemoTelemetry.csv        Sample EdgeTX log for testing
README.md                This documentation
```

## Installation

Copy the whole folder to the SD card of the radio into the simulator script tree.

Example target layout:

```text
/scripts/TelemetryReplay/
  main.lua
  modules/
    csv.lua
    sources.lua
    replay.lua
    config.lua
  settings.conf
  DemoTelemetry.csv       <--- optional
```

The script discovers CSV logs from the same folder that contains `main.lua`.

## Important runtime requirement

The widget must be added to at least one ETHOS screen so that its `wakeup()` callback runs continuously in the background. Without an active widget instance, the replay state will not advance and the exported virtual sensors will remain static.

A tiny widget slot is sufficient. The widget does not need to be visually prominent.

## ETHOS widget identity

- Widget key: `tlmrpl`
- Widget name in ETHOS: `Telemetry Replay`

## Configuration

Settings can be changed in two ways:

1. **ETHOS Configure screen** – open the widget settings from the ETHOS UI
2. **settings.conf** – edit the text file directly on the SD card

Both methods are equivalent. Changes made via Configure are written to `settings.conf` immediately. The file is re-read every time you press Play.

Invalid values in `settings.conf` are silently replaced with their defaults on the next load.

### Available settings

| Setting | Values | Default | Description |
|---|---|---|---|
| Log file | any `.csv` in the script folder | first file | File to replay |
| Speed | 0.25x, 0.5x, 1x, 2x, 3x, 4x, 5x | 1x | Replay speed multiplier |
| Start offset | 0 – 3600 s | 0 | Skip into the log before replay starts |
| Format | auto, edgetx, generic | auto | CSV format detection mode |
| Max sensor rate | 0.5, 1, 2, 5 Hz | 5 | Limits how often sensor values update (wall-clock) |
| Loop | true / false | false | Restart replay at end of file |
| GPS format | Decimal, DMS | Decimal | Coordinate display format |
| Altitude unit | m, ft | m | Altitude display and source unit |
| Speed unit | km/h, m/s, knots | km/h | Ground speed display and source unit |
| VSpd unit | m/s, ft/s | m/s | Vertical speed display and source unit |
| Attitude unit | rad, deg | rad | Pitch/Roll display and source unit |

### Max sensor rate

High-frequency logs (e.g. INAV at 30–60 Hz) can overwhelm ETHOS with too many source updates. The max sensor rate setting throttles updates to the configured wall-clock frequency. Rows between updates are skipped during buffering. The effective filter interval is `speed × 1000 / maxSensorRate` milliseconds of log time.

## Widget menu

The widget menu (long press on the widget) provides:

- **Replay: Start** – (re)starts replay from the configured offset
- **Replay: Pause/Resume** – toggles pause
- **Replay: Stop** – stops replay and closes the file
- **Jump +1 min** / **Jump +5 min** – skips forward in the log

All menu actions are deferred to `wakeup()` to stay within the ETHOS instruction count limit.

## On-screen status view

The widget view shows:

- active file and detected format
- status line with running/paused state, progress %, log timestamp, speed
- GPS coordinates (decimal or DMS depending on setting)
- altitude, ground speed, COG, satellites, vertical speed
- RSSI, RQly, TQly, receiver voltage
- current, consumed capacity, battery percent
- home distance
- pitch and roll

Labels and values automatically reflect the selected units (e.g. "Alt ft" when feet are chosen).

## Exported virtual sensors

The widget registers the following ETHOS Lua sources (enable in Model > Lua).

| Source name | Key | Default unit | Dec | Description |
|---|---|---|---:|---|
| `ReplayGPS` | `RT_GPS` | degree | 6 | Combined GPS (lat + lon) |
| `ReplayLat` | `RT_LAT` | degree | 6 | Latitude |
| `ReplayLon` | `RT_LON` | degree | 6 | Longitude |
| `ReplayAlt` | `RT_ALT` | m / ft | 1 | Altitude (unit follows setting) |
| `ReplayGSpd` | `RT_GSPD` | km/h / m/s / kn | 1 | Ground speed (unit follows setting) |
| `ReplayCOG` | `RT_COG` | degree | 1 | Course over ground |
| `ReplaySats` | `RT_SATS` | raw | 0 | Satellite count |
| `ReplayVSpd` | `RT_VSPD` | m/s / ft/s | 2 | Vertical speed (unit follows setting) |
| `ReplayRSSI` | `RT_RSSI` | raw | 0 | RSSI |
| `ReplayRQly` | `RT_RQ` | raw | 0 | Receiver link quality |
| `ReplayTQly` | `RT_TQ` | raw | 0 | Transmitter link quality |
| `ReplayRxBt` | `RT_RXB` | volt | 2 | Receiver voltage |
| `ReplayCurr` | `RT_CUR` | ampere | 2 | Current draw |
| `ReplayCapa` | `RT_CAP` | mAh | 0 | Consumed capacity |
| `ReplayBat%` | `RT_BAT` | percent | 0 | Battery or fuel percentage |
| `ReplayHome` | `RT_HOME` | meter | 1 | Distance from first valid GPS point |
| `ReplayPitch` | `RT_PIT` | rad / deg | 3/1 | Pitch (unit follows setting) |
| `ReplayRoll` | `RT_ROL` | rad / deg | 3/1 | Roll (unit follows setting) |

Unit conversions are applied both to the ETHOS source output and the widget display. Sources that follow a unit setting dynamically update their ETHOS unit constant so that downstream widgets show the correct label.

## Using the sensors in ETHOS

Once the widget is on a screen, the replay sensors can be used like any other ETHOS source.

Examples:

- bind `ReplayGPS` or `ReplayLat`/`ReplayLon` to a map widget
- bind `ReplayGSpd` to a line graph to visualize speed changes over time
- bind `ReplayHome` to a value box to verify distance calculations
- bind `ReplayPitch` and `ReplayRoll` to an artificial horizon widget

## CSV log handling

All replay logs are read from the same directory as `main.lua`.

Rules:

- files must use the `.csv` extension
- the widget scans the folder on startup and in configuration mode
- the active file is selected through the widget configuration page

## Supported formats

### `auto` (default)

The widget auto-detects the format from the CSV header. If `Date`, `Time`, and either `GPS` or `GPS_2` are present, the widget treats the file as EdgeTX. Otherwise it falls back to the generic format.

### EdgeTX CSV

Expected header columns: `Date`, `Time`, `GPS` (or `GPS_2`).

Commonly used columns:

`Alt(m)`, `GSpd(kmh)`, `Hdg(°)`, `Sats`, `VSpd(m/s)`, `1RSS(dB)` / `TRSS(dB)`, `RQly(%)`, `TQly(%)`, `RxBt(V)`, `Curr(A)`, `Capa(mAh)`, `Bat%(%)`, `Ptch(rad)`, `Roll(rad)`

GPS parsing: the `GPS` field must contain latitude and longitude as a single text field with two numeric values separated by whitespace.

Timing: derived from `Date` + `Time`. Fractional seconds are supported.

### Generic CSV

Intended for custom telemetry exporters or converted logs.

Preferred columns:

`timestamp_ms`, `lat`/`latitude`, `lon`/`longitude`, `alt_m`/`altitude_m`, `speed_mps`/`gspd_mps`, `course_deg`/`heading_deg`, `sats`, `vspd_mps`, `rssi`/`rssi_db`, `rqly`, `tqly`, `rxbatt_v`/`voltage_v`, `current_a`, `capacity_mah`, `bat_pct`/`fuel_pct`, `pitch_rad`/`pitch_deg`, `roll_rad`/`roll_deg`

Notes:

- speed from generic logs is expected in m/s and converted internally to km/h
- pitch and roll in degrees are converted internally to radians
- if `timestamp_ms` is not available, the widget falls back to a fixed 100 ms step

## Buffered I/O

The replay engine reads CSV data in batches of 50 parsed rows. This avoids reading row-by-row (which would be too slow) and avoids loading the entire file into memory (which could exceed ETHOS limits). A safety cap of 500 raw line reads per fill cycle prevents runaway loops in files with very sparse valid data.

## Internal design

### Shared replay state

Replay values are stored in a shared table at `_G.__TelemetryReplayState`. This allows widget lifecycle code and source callbacks to access the same state reliably.

### Per-source callback closures

Each virtual sensor is registered with its own bound `init` and `wakeup` callback. This avoids relying on `source:name()` or `source:key()` at runtime.

### ETHOS instruction count safety

All menu actions are deferred to `wakeup()` via flags (`pendingStart`, `pendingJump`). The `wakeup()` callback benefits from ETHOS preemption support (suspend/resume), while `menu()` does not. Heavy operations in `menu()` would trigger the "Max instructions count reached" error.

### Module loading

ETHOS does not support standard Lua `require()`. Modules are loaded via `loadfile(scriptDir .. "modules/name.lua")()`.

## Limitations

- only reads CSV logs from the script folder
- the widget must exist on a screen for background replay
- home distance is derived from the first valid GPS sample, not from a logged home field
- pitch and roll are stored internally in radians regardless of the attitude unit setting
- unsupported columns are ignored rather than causing failure


## Future extension ideas

- more exported sources such as heading error, climb rate trend, or GPS fix quality
- optional derived home bearing or distance-to-waypoint calculations
- replay pause, scrub, and jump controls in the widget UI
- support for additional CSV dialects
- optional module split into parser, replay engine, and ETHOS binding layers
