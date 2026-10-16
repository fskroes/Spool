# Spool specification

Spool is a scrolling window manager for macOS. Windows sit side by side on an
endless horizontal strip, one strip per display and per Space. Opening a window
never resizes the other windows.

This is a clean-room implementation. The only inputs are public descriptions of
how scrolling window managers behave (niri, PaperWM, and the public feature
pages of similar macOS apps). No third-party binary was decompiled.

Each feature has acceptance criteria. A feature is done only when every
criterion is met. Criteria that can be checked without a live desktop have a
test in `Tests/`.

## Requirements

- macOS 13 Ventura or later.
- Permission: Accessibility only. No Screen Recording, no Input Monitoring, no SIP changes.

## Features

### F1 Endless horizontal strip
- Every managed window is in a column. Columns sit left to right with a gap between them.
- A new window opens directly to the right of the focused column.
- A new window never changes the width of an existing column.
- One strip per (display, Space) pair.
  - A window always goes to the strip of the display that has its Space, also when it is moved in Mission
    Control to a Space of another display, also when no Space on screen changes. On a display Spool does not
    manage, it floats, and it tiles again when it is moved to a managed display.

### F2 Spring animation and instant shortcuts
- Window moves use a critically damped spring. The spring is analytic, so the
  result does not depend on the frame rate.
- Frames are driven by the display refresh (display link). No timer runs when nothing moves.
- A shortcut changes the layout model synchronously in the key handler. When no animation runs (the display
  link is stopped), the key handler also writes the first frame (`Engine.kick`). From rest, the springs start one
  display refresh period in the past (`Engine.animationStart`, `Engine.firstFrameLead`), so that frame already
  moves the windows. The period is that of the display the link uses next (`Ticker.period`: the main screen's
  refresh interval while the link is stopped, the link's own period while it runs): 1/60 s at 60 Hz, 1/120 s on a
  120 Hz ProMotion display, clamped to 1/240 to 1/30 s. When the link already runs (another strip animates), the
  key handler writes nothing and the next refresh writes the strip's first frame, so that strip starts with no
  lead (`Engine.animationLead`). So the first step is one refresh of motion, and the steps
  after it grow: a fixed 1/60 s lead made the first step larger than the next one on a display faster than 60 Hz.
  "From rest" means settled at that earlier start time, so an animation that settled less than one period ago
  does not read its old held size. The display link writes the frames after it. During an animation the display link writes the next frame. During an animation or
  after a swipe, the springs start at the current time, so nothing jumps.
- The origin follows the spring on every frame. The size does not (`FrameAnimator.writeFrame`): a size write
  makes the app lay out its window again, which costs several times a move. While a size animates, the window
  keeps the larger of the size last written to it before the last retarget and its target size: a growing window
  gets its new size on the first frame, a shrinking one when its size settles (often before its position). When
  the window got its target size, it keeps it until the next retarget. Meanwhile it can cover a part of its
  neighbor. A retarget during the animation (a scroll, a new speed, two commands within one frame) gives no size
  between the two.
- The app or macOS can refuse a part of a size at a position (a window may not reach past a display edge there).
  So a window that got a new size away from its final position gets that size again on the last frame of the
  animation (`Engine.sizedAway`, `FrameWrite.resize`).
- A window can close while Spool writes to it. Until the "window destroyed" notification arrives (about 40 ms
  later), a write to it gets `kAXErrorInvalidUIElement`. Such a write is a closed-window write
  (`WriteResult.gone`), not an AX error: Spool does not retry it, it does not count in `AX errors`, and
  `spool stats` shows it as `Closed-window writes`. An app whose writes in a tick all fail or are gone still
  counts as failing for the self-healing (F17).
- Every other failed AX write counts in `AX errors`. `engine.log` names the window, the app, the AX call and the
  code, for example `ax: frame write to window 7 of com.x (pid 42) failed: size -25200 (failure)`. It logs the
  first 3 failures per app and code, until the engine restarts or rebuilds its state (after a config change
  to the rules or the disabled displays).

### F3 Stacks
- A column can hold several windows stacked vertically.
- Commands: stack into the left column, stack into the right column, pop out to the
  left, pop out to the right, move up and down in a stack, taller, shorter, equalize heights.

### F4 Tabbed columns
- A column can switch to tabbed mode. Each window in the column gets the full column height.
- A tab bar above the column shows the window titles. A click on a tab focuses that window.

### F5 Widths
- Preset widths (default 1/3, 1/2, 2/3 of the usable width) cycled with one shortcut.
- Wider and narrower change the width in steps (default 10 % of the usable width).
- Full width toggles between the full usable width and the previous width.
- Center column scrolls the strip so the focused column is in the middle.

### F6 Gaps and Dock-aware sizing
- Inner gap between columns and between windows in a stack. Outer gaps at the screen edges.
- The usable area excludes the menu bar and the Dock (`NSScreen.visibleFrame`).

### F7 Center-focused-column modes
- `never`: scroll only as much as needed to show the focused column completely.
- `onOverflow`: when all columns fit, the strip is left aligned. When they do not fit, the focused column is centred.
- `always`: the focused column is always centred.

### F8 Focus border and dimming
- Optional border around the focused window (colour and width can be set). Off by default.
- Optional dimming of all other windows (amount can be set). Off by default.

### F9 Strip minimap
- While the user navigates, a small map of the strip shows the columns, the
  visible area and the highlighted window (the focused window, or during a
  swipe the window described below). It fades out after a short delay.
  It can be switched off.
- Each block shows the app icon of its window, if the block is large enough
  (at least 16 x 16 points). The icon is up to 20 points. The icon is made in
  the background, so the first time an app is shown its icon comes a moment
  later. An app with no icon shows a plain block.
- During a trackpad swipe, the highlighted block is the window that gets focus
  if the fingers stop and lift now. After a fast flick, the strip can settle on
  another column; the highlight moves there on release.

### F10 Trackpad swipe
- A 3- or 4-finger horizontal swipe (configurable, or off) scrolls the strip and follows the fingers.
- On release the strip settles on the nearest column. The release velocity goes into the spring.
- Natural or inverted direction.

### F11 Drag to reorder
- Drag a window with the mouse onto another column. On release, the column of the dragged
  window moves to that position and the strip lays out again. It can be switched off.
- A resize from a window edge sets the column width. A press up to 8 pt outside the edge counts, because macOS
  starts a resize there. Any other move while the button is down is put back after the release.
- A drop onto a switched-off display, or outside every display, puts the window back in its own slot.
- After a drop the window animates from where the user let go, also on another display. Its spring starts there
  before the first frame is written (`Engine.retarget`), so it never shows in its old slot for one frame. With
  animations off it goes straight to its new slot.

### F12 Multi-monitor and per-display on/off
- Each display has its own strip, focus and scroll position.
- A window that is out of view next to another display is clamped so it does not spill onto that display.
- One shortcut sends the focused window to the next display.
- Each display can be switched off. Spool does not move windows on a switched-off display.

### F13 Session restore
- Column order, widths, stacks and tabbed mode are saved. After a restart of Spool they
  come back without a reshuffle. Windows are matched by window ID first, then by app and title.
- Windows of hidden apps and minimized windows keep their slot across a restart.
- A restored strip scrolls so its focused column is in view, also when some saved windows are gone.
- Windows of an app that does not answer during the restore wait for it. When it answers, each goes back
  after the window that came before it on the strip.
  - Many apps answer before they make their windows again. So for 5 s after the app answers, a new window of the
    app takes a waiting place. Then Spool looks once more and drops the places that no window took.
  - A waiting window does not move the focused window on screen.
  - A waiting window goes with its strip when that strip is restored to another Space or display.
  - A new window takes a waiting place only when it is on the Space of that place.
  - A window the user floated waits too, and comes back floating when it has the same ID or title.
  - With two copies of one app, the places wait while one copy does not answer. When a copy quits, the
    places go to the other copy.

### F14 Launch at login and auto-start
- Optional launch at login. Optional automatic start of tiling when the app starts.

### F15 Per-app window rules and smart floating
- A rule per app (picked from a list of running and installed apps): float, or a fixed slot on the strip.
- Fixed-size windows (cannot resize) float automatically. Spool's own windows float.
- Dialogs, sheets and other non-standard windows float.

### F16 Automation
- `spool://` URL scheme for every command.
- `spool` command-line tool for every command, plus `state` and `stats` queries.
- Raycast script commands for the main commands.

### F17 Automatic updates, engine log and self-healing
- Updates through Sparkle (`Check for Updates…` in the menu).
- An engine log file that the app can show in Finder.
- If part of the engine fails (event tap disabled, observer lost) it restarts that part and logs why.
  An app that does not answer keeps its old observer until a new one works.
  An app that does not answer at launch is tried again: fast at first, then every 5 s for about two minutes.
  If the process crashes, launchd starts it again.

### F18 Native fullscreen
- Windows in macOS native fullscreen are not managed.

### F19 No focus stealing
- A window that a background app opens is added to the strip, but it does not
  take focus and does not scroll the strip.

### F20 Focus follows mouse and mouse follows focus
- Both optional, both off by default.

### F21 Guided start and Mac Setup
- The first run shows a short guide: Accessibility, the strip, the five essential shortcuts.
- Mac Setup checks the macOS settings below and shows a green tick or a fix for each one:
  Accessibility, swipe between full-screen apps, swipe between pages, three-finger drag,
  automatically rearrange Spaces, displays have separate Spaces, Stage Manager,
  macOS edge tiling (3 settings), other window managers running.

### F22 Rebindable shortcuts
- Every action can have zero or more key combinations. Bindings are stored by key code,
  so they work on non-US layouts. The recorder shows the key label of the current layout.
- Defaults use Control-Option (see `docs/SHORTCUTS.md`).

### F23 Settings apply instantly
- Every setting change shows on screen at once. There is no Save button and no restart.

### F24 Local metrics and marks
- Spool measures its own speed, cost, problems and use, and keeps the numbers on this Mac only:
  one JSON file per local day in `~/Library/Application Support/Spool/metrics/`, kept 90 days.
- No window titles, no key presses, no typed text. Apps are named by bundle ID. The note of a mark is the only user text.
- Speed: frame write, command latency (to the first frame), command settle (to the end of the animation; with animations off, to the write of the frame) and the
  time between frames while an animation runs. Only a command that moves a window gives latency and settle; a
  swipe is not a command, and a command during a swipe gives no sample. Cost: CPU time and idle wakeups of the process while the engine runs, and its peak
  memory, from `getrusage` and `proc_pid_rusage` at each save and at each engine start and stop. Problems: unclean
  exits, observer repairs, a lost permission, the focus fallback, config errors, refused shortcuts, apps that do
  not answer. Use: commands per source, columns per strip (when the number changes), swipes. Friction per app:
  corrections, drags that Spool puts back, resizes, float changes, early resizes, focus bounces.
- No repeating timer: the numbers are saved once 60 s after the first change, when `spool report` asks,
  and at quit. After a failed save, the next try waits 2 min, then 4 min, and so on up to 1 h, until a save works.
  Recording does no I/O.
- `spool report [--days <n>] [--json]` reads the files (also when Spool does not run) and checks the live budget.
- `spool mark [<note>]`, `⌃⌥⇧M`, the menu bar menu and `spool://mark` save a mark: the state without titles,
  the stats, the numbers of today and the last 60 s of the engine log.
- On by default. Settings > General turns it off at once (F23). Off: nothing is recorded or written.
  Details: `docs/METRICS.md`.

### F25 License key
- Spool costs EUR 0.99, one time, with no trial. The buyer gets a license key by email. The format and the check
  are in `docs/LICENSE-KEYS.md`. The check runs on the Mac, with no network call.
- A copy of Spool without a valid key does not start the window manager. This holds on every path: the start at
  launch, the menu, the shortcut, `spool start`, `spool://start` and the Start button in Settings. The engine
  status is "Spool needs a license key".
- At launch without a valid key, Spool shows the license window before the first-launch guide (F21). The window
  has a field for the key (a key wrapped by an email client is accepted), Activate, Buy Spool
  (https://1yc.dev/spool) and Lost your key? (https://1yc.dev/spool/restore). Every key that is not valid gets the
  one text "This license key is not valid."
- A valid key is stored in `license.key` in the data folder. Then the window closes, the window manager starts,
  and the guide shows when the first run is not done. The key stays valid for every later version.
- The menu bar menu has "Activate Spool…" while there is no valid key, and no Start or Restart. Settings >
  General shows "Licensed to <email>".
- `spool://license?key=<key>` activates a valid key. A key that is not valid opens the license window with the
  error. A link with no key opens the license window, or Settings when the copy has a license.
- A new key for a licensed copy does not start a window manager that the user stopped.
- `spool license` prints "Licensed to <email> (order <id>)" and exits with 0, or prints "Not licensed." and exits
  with 1. `spool license <key>` sends the key to the running app, which checks it with its own public key, stores
  it and starts the window manager. A key that is not valid prints "This license key is not valid." and exits with 1.
  These two work while the window manager is gated. A window command while gated prints "Spool needs a license key.
  Open Spool, or run `spool license <key>`." and exits with 1. Queries (`ping`, `state`, `stats`) answer as usual.
- Only a debug binary of `swift build` (it has no bundle ID) needs no license: `spool license` prints "This build
  of Spool needs no license." and exits with 0. A release build always needs a key: a renamed or copied bundle,
  or one without a public key in `Info.plist`, stays unlicensed.
- A release build trusts the public key in its `Info.plist` only when the app has a valid signature of the release
  team. A copy with another key in `Info.plist`, signed again, stays unlicensed, also with a key that the other
  key signed.
- `spool://license?key=<key>` with a valid key also replaces the key of a licensed copy.

## Performance budget

| Metric | Budget | How it is measured |
|---|---|---|
| Layout compute, 50 columns | < 50 µs | `LayoutBenchmarkTests` |
| Frame write, 6 apps at 2 ms AX latency each | p95 < 4 ms parallel, against 12 ms serial. The test gates the applier's own part: wall time minus the slowest write, p95 < 2 ms. The fake write sleeps, and a sleep runs over its time on a busy Mac. | `FrameApplierBenchmarkTests` (`make bench`) with a fake AX writer: 100 rounds, it prints the wall p50 and p95, the applier p95, the serial time and the load average |
| Idle | no display link and no timer when nothing moves | `AnimatorTests` |
| Spool's part of a frame write, same load | p95 < 1 ms: the wall time minus the AX time of the slowest app (`FrameTiming.ownMs`) | `FrameApplierBenchmarkTests.theOwnPartIsUnder1ms` (`make bench`) |
| Live frame cost | p50 and p95 reported, and Spool's part of it | `spool stats` |

## Live budget

`spool report` checks these targets against the metrics of real use (F24). Each one is a maximum.
The table must match `MetricsBudget.live` in `Sources/SpoolCore/Metrics.swift`.

| Name | Limit | Unit | What it is |
|---|---|---|---|
| frame-write-p95 | 8 | ms | p95 of one frame write (all windows of one frame) |
| frame-own-p95 | 1 | ms | p95 of Spool's part of one frame write: the wall time without the AX calls |
| command-latency-p95 | 16.7 | ms | p95 from a command to its first frame |
| command-settle-p95 | 400 | ms | p95 from a command to the end of its animation |
| slow-tick-ratio | 1 | % | frames later than 1.5 times the display period, in percent of all frames |
| cpu-while-active | 1 | % | CPU time of Spool in percent of the time the engine ran |
| unclean-exits | 0 | count | runs that did not end with a clean quit |
