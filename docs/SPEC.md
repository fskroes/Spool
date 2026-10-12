# Striple specification

Striple is a scrolling window manager for macOS. Windows sit side by side on an
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
    Control to a Space of another display, also when no Space on screen changes. On a display Striple does not
    manage, it floats, and it tiles again when it is moved to a managed display.

### F2 Spring animation and instant shortcuts
- Window moves use a critically damped spring. The spring is analytic, so the
  result does not depend on the frame rate.
- Frames are driven by the display refresh (display link). No timer runs when nothing moves.
- A shortcut changes the layout model synchronously in the key handler. The first
  frame is written on the next display refresh.

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
  visible area and the focused column. It fades out after a short delay.
  It can be switched off.

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

### F12 Multi-monitor and per-display on/off
- Each display has its own strip, focus and scroll position.
- A window that is out of view next to another display is clamped so it does not spill onto that display.
- One shortcut sends the focused window to the next display.
- Each display can be switched off. Striple does not move windows on a switched-off display.

### F13 Session restore
- Column order, widths, stacks and tabbed mode are saved. After a restart of Striple they
  come back without a reshuffle. Windows are matched by window ID first, then by app and title.
- Windows of hidden apps and minimized windows keep their slot across a restart.
- A restored strip scrolls so its focused column is in view, also when some saved windows are gone.
- Windows of an app that does not answer during the restore wait for it. When it answers, each goes back
  after the window that came before it on the strip.
  - Many apps answer before they make their windows again. So for 5 s after the app answers, a new window of the
    app takes a waiting place. Then Striple looks once more and drops the places that no window took.
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
- Fixed-size windows (cannot resize) float automatically. Striple's own windows float.
- Dialogs, sheets and other non-standard windows float.

### F16 Automation
- `striple://` URL scheme for every command.
- `striple` command-line tool for every command, plus `state` and `stats` queries.
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

## Performance budget

| Metric | Budget | How it is measured |
|---|---|---|
| Layout compute, 50 columns | < 50 µs | `LayoutBenchmarkTests` |
| Frame write, 6 apps at 2 ms AX latency each | p95 < 4 ms parallel, against 12 ms serial | `FrameApplierBenchmarkTests` (`make bench`) with a fake AX writer: 100 rounds, it prints p50, p95 and max |
| Idle | no display link and no timer when nothing moves | `AnimatorTests` |
| Live frame cost | p50 and p95 reported | `striple stats` |
