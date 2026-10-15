# Metrics

Spool measures its own speed, its cost and the problems it has, on your Mac only. You read the numbers with
`spool report`. This page tells what Spool measures, where the files are, how to read the report, and how to
turn it off.

## Privacy

- Local only. Spool sends nothing. No part of the metrics opens a network connection.
- No window titles, no key presses, no text that you type. A mark keeps the note that you give it, and nothing else
  that you typed.
- Apps are named by their bundle ID only (for example `com.apple.Safari`).
- Spool keeps 90 days. It deletes older day files by itself. It always keeps the newest 90 days that have a
  file, so a clock that is far ahead cannot delete real data, and if you use Spool only on some days, you keep
  your last 90 days of use.

## Turn it on or off

Metrics are on by default. To turn them off, clear **Settings > General > Metrics > Measure speed and usage on this
Mac (local only)**, or set this in `config.json`:

```json
"metrics": { "enabled": false }
```

The change applies at once, without a restart. When metrics are off, Spool records nothing and writes no metrics
file. The files that are already there stay.

To delete the data, quit Spool and delete the folder `~/Library/Application Support/Spool/metrics`.
**Open metrics folder** in Settings > General shows it in Finder.

## Where the files are

| File | What it is |
|---|---|
| `~/Library/Application Support/Spool/metrics/YYYY-MM-DD.json` | The numbers of one local day |
| `~/Library/Application Support/Spool/metrics/YYYY-MM-DD.local.json` | Only when `YYYY-MM-DD.json` is from a newer Spool or cannot be read. Spool never replaces that file and writes the numbers of this run here. The report adds the two files together |
| `~/Library/Application Support/Spool/metrics/running` | Exists while Spool runs. If it is there at launch, the last run did not quit cleanly |
| `~/Library/Application Support/Spool/metrics/marks/<date and time>/` | One mark (see "Marks") |

Spool keeps the numbers in memory and writes the day file 60 s after the first change, when `spool report` asks
for them, and when you quit. There is no repeating timer: when nothing happens, Spool writes nothing.

If a write fails (for example, the disk is full), Spool keeps the numbers in memory and tries again later. The
wait doubles after each failure: 2 min, 4 min, 8 min, and so on, up to 1 h. After a write that works, the wait is
60 s again. This retry is the only write that repeats, and it stops when a write works. `engine.log` gets one line
for each new error, and one line when a write works again.

The day is the local day of the Mac clock. When the clock changes (a time zone, a manual change), the numbers go to
the day of the new time, also to an earlier day. Spool adds them to the file of that day.

## What Spool measures

| Part | Numbers | Where in the day file |
|---|---|---|
| Time | Seconds the engine ran (managed windows) | `activeSeconds` |
| Speed | Frame write: all window writes of one frame | `frameWrite` |
| | Spool's part of a frame write: the frame write time without the AX calls of the slowest app. The AX calls wait for the app and WindowServer; this part is Spool's own code | `frameOwn` |
| | Command latency: from a command to its first frame that moves a window. A command that moves no window (for example focus-left at the first column) or that comes during a swipe gives no sample | `commandLatency` |
| | Command settle: from a command to the end of its animation. Only a command that moved a window has one. When the animation ends with the first frame (animations off), the settle is the time until that frame is on the windows, the same as the latency. A swipe that stops the animation removes the sample | `commandSettle` |
| | Time between two frames of one animation, and the frames later than 1.5 times the display period | `tickInterval`, `ticks`, `slowTicks` |
| Cost | CPU time of the Spool process (user and system) and its idle wakeups, only while the engine runs. The highest memory of the process since it started (physical footprint) | `cpuSeconds`, `wakeups`, `peakRSSMB` |
| Use | Each command, with where it came from: `hotkey`, `cli`, `url`, `menu`, `tab` (a click on a tab bar) or `gesture` | `commands` |
| | Columns on a strip, each time the number changes or a strip opens (`1` to `9`, `10+`) | `columnsPerStrip` |
| Problems | Engine start, stop and restart, unclean exits, repaired app observers, a lost Accessibility permission, focus through the slow fallback, `config.json` errors, refused shortcuts, apps that do not answer, swipes, flings, marks | `events` |
| Per app | Time of the AX calls of one window write, failed writes, friction. A write to a window that closed first is not a failed write and has no time | `apps` |

Today no gesture runs a command: a swipe scrolls the strip and counts as the event `swipe` (and `fling` when the
speed of your fingers picked the column). The source `gesture` is there for gesture commands. A swipe is not a
command, so it gives no command latency and no command settle.

Cost in detail:

- `cpuSeconds` and `wakeups` count only the time while the engine runs. CPU time and wakeups while the engine is
  stopped are not counted. So `cpu-while-active` is the CPU time of the running engine in percent of its running
  time.
- `wakeups` are the package idle wakeups of the process: the "Idle Wake Ups" column of Activity Monitor.
- `peakRSSMB` is the highest physical footprint of the process since it started, in MB (the "Memory" column of
  Activity Monitor shows the current footprint). The day file keeps the highest value of the day.

Friction is a sign that Spool did something that you or an app did not want. Spool counts it per app:

| Friction | When |
|---|---|
| `app.correction` | The app moved or resized a tiled window, and Spool put it back |
| `user.drag` | You dragged a tiled window and Spool put it back (drag-to-reorder is off, or you dropped it outside a managed display). A reorder or a move to another display is not friction |
| `user.resize` | You resized a tiled window with the mouse |
| `float.tiled` | You used toggle-float on a tiled window. Maybe this app must float (an app rule) |
| `unfloat.auto` | You used toggle-float on a window that a rule or the smart check floated. Maybe it must tile |
| `early.resize` | You changed the width of a window in the first 10 s after it opened. Maybe the default width is wrong for this app |
| `focus.bounce` | A focus move and then the opposite move within 1 s |

## The day file

One JSON object per day, with sorted keys. In short:

```json
{
  "schema": 2,
  "day": "2026-10-14",
  "appVersions": ["1.4.0"],
  "activeSeconds": 25210.5,
  "frameWrite": { "counts": [0, 3, 120], "count": 4211, "sum": 5120.2, "max": 31.0 },
  "frameOwn": { "counts": [3900, 300, 11], "count": 4211, "sum": 420.5, "max": 2.1 },
  "commandLatency": { "counts": [0, 0, 14], "count": 512, "sum": 2900.1, "max": 22.4 },
  "commandSettle": { "counts": [0, 0, 2], "count": 498, "sum": 140000.0, "max": 610.0 },
  "tickInterval": { "counts": [0, 0, 0], "count": 30000, "sum": 501000.0, "max": 70.1 },
  "ticks": 30000,
  "slowTicks": 41,
  "cpuSeconds": 61.2,
  "wakeups": 120400,
  "peakRSSMB": 48.5,
  "events": { "engine.start": 1, "swipe": 34, "mark": 1 },
  "commands": { "focus-right": { "hotkey": 220, "cli": 3 } },
  "columnsPerStrip": { "3": 410, "4": 120 },
  "apps": { "com.apple.Safari": { "axWrite": { "counts": [0, 5, 80], "count": 900, "sum": 1500.0, "max": 12.0 }, "axErrors": 0, "friction": { "user.drag": 2 } } }
}
```

A histogram (`frameWrite` and the others) has `counts` per bucket, the `count` of samples, their `sum` and the
`max`, all in ms. The bucket bounds are fixed (`Histogram.bounds` in `Sources/SpoolCore/Metrics.swift`), so days add
up. The example shortens `counts`.

`schema` 2 added `frameOwn`. Spool reads a schema 1 file, without `frameOwn`. An older Spool does not change a
schema 2 file: it writes `YYYY-MM-DD.local.json`.

## Read the report

```sh
spool report
spool report --days 30
spool report --json
```

`spool report` shows the last 7 days (`--days` from 1 to 90). It works also when Spool does not run: it reads the
day files. When Spool runs, it first asks Spool to write the numbers that are still in memory.

The report has these parts:

- The period and the time the engine ran.
- The live budgets, each with PASS, FAIL or no data. Without day files, every budget shows no data, also
  `unclean-exits`: with no file, Spool knows nothing. Then the first line of the report is
  `Spool metrics: no data yet`. The budgets are in [SPEC.md](SPEC.md#live-budget).
  `slow-tick-ratio` is the slow frames in percent of all frames. `cpu-while-active` is the CPU time in percent of the
  time the engine ran.
- Speed (p50, p95 and the highest value), cost and problems.
- The 10 most used commands, with their sources.
- The 10 highest friction counts, per app and kind.
- The 10 apps with the slowest AX writes. A slow app makes every animation slow, not only its own windows.
- Day files that Spool could not read. A broken file does not stop the report.

`--json` prints the full report as JSON, for scripts.

## Marks

When something goes wrong (a window in the wrong place, a slow animation), save a mark at that moment:

- Press `⌃⌥⇧M`.
- Or choose **Mark This Moment** in the menu bar menu.
- Or run `spool mark` with a note, for example `spool mark Safari jumped to the left`.
- Or open `spool://mark`.

A mark is a new folder in `metrics/marks/` with:

| File | What it is |
|---|---|
| `note.txt` | Your note (empty from the shortcut, the menu and the URL) |
| `state.json` | The strips and windows (the data of `spool state`), with every window title removed |
| `stats.json` | The performance counters (the data of `spool stats`) |
| `day.json` | The numbers of today, so far |
| `engine.log` | The last 60 s of the engine log |

`spool mark` prints `Saving a mark (see engine.log for the folder)`, because Spool writes the folder after it
answers. The engine log (`~/Library/Logs/Spool/engine.log`) names the folder of each mark. Marks need metrics on. Spool does not delete marks; delete the
folders that you do not need.
