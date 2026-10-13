# Live end-to-end test

`make e2e` runs the real `dist/Striple.app` against the windows of a small test app. It drives Striple with the
`striple` command and checks the real window frames. It never moves the windows of other apps.

`make test` does not run it. The unit tests of its pure parts (`Tests/StripleE2EKitTests`) are in `make test`.

## Run it

```sh
make e2e
```

This builds `dist/Striple.app` (`make app`), the runner `striple-e2e` and the test app `striple-e2e-windows`,
then runs the test. One run takes about 20 seconds after the build.

Options go in `E2E_ARGS`:

```sh
make e2e E2E_ARGS="--out /tmp/striple/e2e/mine"
```

| Option | Default | What |
|---|---|---|
| `--app <path>` | `dist/Striple.app` | The Striple app to test. |
| `--out <dir>` | `/tmp/striple/e2e/<yyyyMMdd-HHmmss>` | The report folder. |
| `--bundle-dir <dir>` | `.build/e2e` | Where the runner makes the test app bundle. |
| `--windows-binary <path>` | next to `striple-e2e` | The `striple-e2e-windows` binary. |
| `--animations on\|off` | `on` | `off` sets `animation.enabled` to false in the test config: every command is one frame write of the final frames. Scenario h uses the budget of the mode. |
| `--steal-focus` | off | Tests the focus recovery: a second test app (`StripleE2EThief`) takes the focus after step 1 and before step 3 of scenario b. Scenario b passes only when the runner gave the focus back both times. Takes no value. |

You can also start the runner directly after a build:

```sh
"$(swift build --show-bin-path)/striple-e2e" --app dist/Striple.app
```

### Before you start

- Quit your own Striple. The runner refuses to run when one is running (exit 2).
- The terminal must have the Accessibility permission. The runner starts Striple from the terminal with `exec`,
  so Striple gets the permission of the terminal.
- The screen must be unlocked.
- During the run, the test app comes to the front a few times. Do not type: your keys can go to a test window.
  If you click another app, the runner gives the focus back to the test window before each command. In
  scenarios b, c, d and i it gives the focus back only after it saw another app take it, at most 3 times per run
  (see "Focus taken by another app"). Any other lost focus fails the scenario.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | All checks passed. |
| 1 | A check failed. The report tells which and why. |
| 2 | The test did not start. The message says why. The causes: wrong arguments; another E2E run is active; the test Striple of an earlier run does not stop; the app or the test app binary is missing; no display; the screen is locked; no Accessibility permission; another Striple runs or answers on the default socket; no temporary `STRIPLE_HOME`. Nothing of this run was started. Fix the cause, or retry later. |
| 130 | The runner got SIGINT (Ctrl-C), SIGTERM or SIGHUP. It cleaned up (rule 4 in [Safety](#safety)) and wrote no report. A signal that comes after the runner started to write the report is ignored: the run ends with the code of the report. |

`make e2e` prints `make: *** [e2e] Error 1` or `Error 2` with the code of the runner.

## The report

The runner prints the report and its path, for example `/tmp/striple/e2e/20261012-181527/report.md`.
The folder also has:

| File | What |
|---|---|
| `report.md` | A table: scenario, PASS or FAIL, details. |
| `run.log` | What the runner did, with each command and its time. |
| `engine.log` | The log of the tested Striple. |
| `striple-stdout.log` | Standard output and error of the tested Striple. |
| `windows-app.log` | Output of the test app. |
| `windows.json` | The last frames that the test app reported. |
| `commands.txt` | The commands the runner sent to the test app. |

## What it checks

The test app opens 3 windows. Striple tiles them as columns on the main display. Each check polls the frames
until they are correct and did not change for 250 ms (`SettleTracker`), for a maximum of 3 seconds (10 seconds
for the first tiling, 5 seconds after the test app opens a window in scenario e). A check that reaches its maximum
fails its scenario with the last failures it saw. Frames may differ by 2 points (rounding).

Every strip check of a to f and i also checks:

- The scroll and the frame of every column. The runner calculates the scroll of the default center mode
  `onOverflow` itself: 0 when all columns fit, else the focused column centred but never past the ends of the
  strip. The strip x of a column is the left edge of the work area + its position in the strip - scroll. Then
  `StripGeometry.expected` gives the frame Striple must write. It is a second copy of `Layout.physical` and
  `Layout.park`, so the check does not trust the code it checks. It rounds the x and the width to whole points,
  as `Layout.pixelAligned` does:
  - A column fully on the display is at its strip x, at the top of the work area, with the work-area height.
  - A column that hangs over an edge with no display there stays at its strip x. Its gap to the next column is
    checked too.
  - A column that hangs toward another display is moved to that edge, or parked when its middle is past the edge.
  - A column past an edge (less than `layout.parkedSliver` on the display) is parked:
    - With a display on one side only, every parked column goes to the free side.
    - With displays on both sides, it stays inside the display horizontally (at its left or right edge) and
      goes to the bottom.
    - Else it goes to the sliver of its side: at the bottom, or at the same y when a display is below.
    - A parked column keeps its size.

  The x, the y, the width and the height must match, with 2 points for rounding. One exception: macOS can stop
  a window that Striple parks at the bottom higher than Striple asked. It keeps the title bar on the screen
  (28 points on the test display). So the y of such a window may be up to 40 points higher
  (`FrameChecks.titleBarStop`).

  A display is a neighbour when its edge is at most 2 points from the edge of the main display and the two
  overlap by more than 2 points along that edge (the rule of `Displays.make`).

  The order, gap and "all fit" checks use the places that `expected` gives. Only when the runner has no scroll
  (a strip window is missing, or the focused column does not exist, which fails already) does it read the place
  from the frame alone (`FrameChecks.place`). With a display below only, a visible column with at most
  `layout.parkedSliver` + 2 points on the display then reads as parked.
- The focus. When the test app is frontmost and its key window is in the strip, that window is in Striple's
  focused column. The expected scroll follows that column, so the two must agree.
- The windows. Each window of the test app is a column or floats, never both and never neither.
- The count. The runner expects the number of windows it opened and closed. It never takes the count from
  `striple state`, so a lost column fails and does not change what the next scenario expects.

| Scenario | Checks |
|---|---|
| a. Tiling | All windows are columns: the top and height of the work area (visible frame minus the outer gaps), the width of the default proportion, left to right, `layout.innerGap` between neighbours. At least one column is visible, and the focused column is fully in view. Columns that are out of view are parked at the edge of the display and keep a sliver on it. If this scenario fails, b to f and i are SKIP: the strip is in an unknown state. |
| b. Focus | `focus-window` on the last column, then `focus-left` to the first column and `focus-right` back to the last: always 2 × (columns - 1) steps. After each step the focused column is fully in view at the expected scroll, and Striple's focus and the system focus (test app active, that window key) are on it. In this scenario the runner does not give the focus back, except after another app took it (see "Focus taken by another app"): a step that loses it fails. |
| c. Move | `focus-window` on the focused column, then `move-left` to the first place and `move-right` to the last. The order in `striple state` and the order of the frames change as expected. The moved window keeps the focus after each step: the runner does not give it back, except after another app took it, so a lost focus fails. |
| d. Widths | `focus-window` on the focused column, then `cycle-width` twice, `toggle-full-width` twice, and `cycle-width` until the default width. The focused window gets the width of the preset (`p * (work width + gap) - gap`), full width starts at the left edge, and the other columns move with the same gap. The order, the focused column and the focus do not change: the runner does not give the focus back, except after another app took it. |
| e. Close and open | Needs 3 or more columns. The test app closes the window of column 2: the other columns close the hole and keep their order. The runner gives the focus to column 1. The test app opens one more window: it becomes column 2, directly to the right of the focused column, and not at the end ([SPEC.md](SPEC.md)). The other columns keep their order. |
| f. Float | `toggle-float`: the window leaves the strip and the other columns close the gap. `toggle-float` again: it is a column again. |
| i. Close while moving | `cycle-width` on column 1, then at once the test app closes the window of column 2 while Striple animates it. The other columns close the hole, column 1 keeps the focus, and `AX errors` does not go up: a write to the closed window is a closed-window write, not an error. The details name the closed-window writes of the scenario. Then `cycle-width` back to the default width and a new window. Whether a write reaches the window after it closed depends on the timing, so 0 closed-window writes is not a failure; the unit tests (`FrameApplierTests`) cover that case exactly. |
| h. Performance | `striple stats --json`: frame write p50/p95, Striple's part of a frame write (the wall time without the AX calls), command latency, AX errors. The runner adds the CLI round trip and the settle time it measured. A settle that reached its maximum is a sample at its full time and is also counted. Fails when AX errors > 0, frame write p95 ≥ 16 ms (one frame at 60 Hz), Striple's part p95 ≥ 1 ms or not reported, command latency p95 ≥ 16.7 ms, settle p95 ≥ 2 s (`--animations off`: ≥ 1 s), or a settle reached its maximum. SKIP when Striple wrote no frames or no settle was timed (`PerformanceBudget.verdict`). A run has 27 settles (a 1, b 5, c 5, d 6, e 3, f 2, i 5). Scenario b always ends on the last column, so the count does not change between runs. The p95 (nearest rank) of 27 samples is the second slowest one. |
| g. Quit | SIGTERM to Striple. Before it, at least one test window must be off screen (parked or over an edge), else the quit has nothing to restore and the scenario fails. Striple exits with status 0. The test app shows the same windows as before the SIGTERM, as many as the runner expects, and each is fully on a display. |
| Safety: other apps | See below. |
| Safety: managed windows | Every window in every `striple state` the runner read has the bundle ID of the test app. SKIP when the runner read no state (`ManagedCheck.verdict`). |

Before each command (except in scenarios b, c, d and i) the runner gives a test window the focus, because Striple
acts on the focused window. If the window does not get the focus within 10 seconds, the command is not sent and the scenario
fails.

### Focus taken by another app

Another app can take the focus during a run (a terminal that gets output, a notification). In scenarios b, c, d
and i the runner does not give the focus back, because Striple must keep it there. So such a theft made those
scenarios fail as if Striple had lost the focus. Now the runner tells the two apart:

- The test app records every app activation (`NSWorkspace.didActivateApplicationNotification`) in its report.
- When the focus is not on the window the runner expects, it looks at the newest activation since the focus was
  last right (`FocusTheft.thief`). If that is an app that is not the test app and not Striple, it is a theft.
- On a theft, the runner gives the focus back with `focus-window` and waits up to 3 s. The scenario details name
  each theft (`focus given back after: ...`). After 3 thefts in a run, a theft fails the scenario.
- Striple that takes the focus itself still fails. When Striple's own focus is on another test window, the runner
  does not give the focus back (`FocusTheft.mayGiveBack`): Striple moved it, so the scenario fails.
- After each `focus-window` and each command of b, c, d, e and i, the strip check (order, focused column,
  scroll) runs before the focus check. So the `focus-window` of a recovery cannot put right a wrong column or
  scroll before it is checked.
- A row lists its thefts also when it fails, because a theft can explain the failure.

`--steal-focus` makes 2 thefts on purpose, so this recovery is tested. Scenario b counts its thefts from its
start, so a third one (for example at the start) fails it.

The report header says PASS only when every row is PASS. A SKIP proves nothing, so it counts as a failure, the
same as in the exit code.

The width math comes from `Config()` defaults, the same as the config file of the run. The work area comes from
`NSScreen.screens[0]`, converted to top-left coordinates (the coordinates of AX and `CGWindowList`).

## Safety

The test runs on your work Mac, next to your own windows. These rules keep it away from them:

1. **Only test windows are managed.** Striple starts with `STRIPLE_MANAGE_ONLY=com.fskroes.Striple.e2e-windows`.
   Every path that adopts a window goes through one gate, `WindowTracker.isManageable`, which calls
   `Policy.isManageableApp`. With the list set, a window of another app is never adopted, so Striple never moves,
   resizes, parks, restores or focuses it.
2. **Your windows are measured.** Before the test app starts, the runner records the bounds of every window of
   other apps below the menu bar level (layers 0 to 23: normal windows, floating and modal panels) with
   `CGWindowListCopyWindowInfo`, also windows on other Spaces and minimized windows. System processes (the Dock,
   the window server, Stage Manager and others in `SafetyCheck.systemOwners`) are left out. After Striple quit (the runner stops it first if needed, because Striple moves windows when it quits),
   it compares them: 0 points of change allowed. A window that closed or opened during the run is not a change.
   The result is SKIP, which counts as a failure, when the compare proves too little: no snapshot was taken
   before the run, no window of a regular app was open, or fewer than half of these windows still exist. The menu bar, status items and notifications (layer 24 and up) change on their own, so
   they are not compared. Windows of background processes (not a regular app before or after the run, for
   example the AutoFill helper of Safari) are compared, but a change there is only listed under "Not counted":
   Striple manages only regular apps, and these windows resize themselves. An app that was regular before or
   after counts as an app. One run saw 5 AutoFill windows change by the same 14 points while no Striple
   command touched them.
3. **Your settings are not touched.** Striple starts with `STRIPLE_HOME` set to a new `/tmp/striple-e2e-XXXXXX`
   folder with a `config.json` (`onboardingDone: true`, other values default). The socket, config, session and logs
   are in that folder. The login item is not registered or changed, and Sparkle does not check for updates. The folder is deleted at the end.
4. **Always clean up.** At the end, on a failure and on Ctrl-C, the runner quits the test app, sends SIGTERM to
   Striple (SIGKILL after 5 seconds), copies the engine log and deletes `STRIPLE_HOME`.
5. **A crashed run is cleaned up by the next run.** While a run is active, the runner keeps
   `/tmp/striple/e2e/active-run.json`: its own PID, the PID of the test Striple, the start time of each, and
   `STRIPLE_HOME`. A crash or a SIGKILL of the runner leaves the file. The next run reads it in its preflight:
   - If that runner still runs, the new run stops (exit 2). It does not touch a live run.
   - If the process at the Striple PID has the same start time and is a `Striple` binary, it is the orphaned test
     Striple: SIGTERM, then SIGKILL after 5 seconds. A PID that the system gave to another process is never
     signalled, because its start time differs.
   - The old `STRIPLE_HOME` is deleted, but only a `/tmp/striple-e2e-XXXXXX` folder.
   - A test app that is left over is quit by its bundle ID.

If you move one of your windows yourself during a run, the safety check fails and names the window. Run again.

## Test-only environment variables

Do not use these for normal work.

| Variable | Effect |
|---|---|
| `STRIPLE_HOME` | When set and not empty, the support files (config, session, socket, lock) are in this folder and the logs in `$STRIPLE_HOME/Logs`. Striple does not read or change the login item, and does not start Sparkle (`Updater.isEnabled`). `StriplePaths.resolve(environment:home:)` decides. |
| `STRIPLE_MANAGE_ONLY` | A comma-separated list of bundle IDs. Striple manages only windows of these apps. Set but empty: Striple manages no app (a test seam fails closed). `Policy.manageOnlyBundleIDs(environment:)` and `Policy.isAllowed(bundleID:manageOnly:)` decide. |
| `STRIPLE_SOCKET` | Used by the `striple` command, not the app. The runner sets it to `$STRIPLE_HOME/striple.sock`. See [CLI.md](CLI.md#socket). |

## The test app

`striple-e2e-windows --count <n> --report <file> --commands <file>` is a normal AppKit app. The runner puts it in
`.build/e2e/StripleE2EWindows.app` with bundle ID `com.fskroes.Striple.e2e-windows` and signs it ad hoc, because
Striple matches apps by bundle ID. It replaces a bundle at that path only when its `Info.plist` has the test
bundle ID. With another app at that path, the runner does not touch it: the Setup row fails (exit 1).

- It opens `n` titled, resizable windows `E2E 1` … `E2E n` on the main display.
- Every 100 ms it writes the report file atomically: its PID, the visible windows (title, window number, frame in
  top-left coordinates), whether it is the active app, and its key window. The runner reads frames from this file
  and needs no AX.
- It runs new lines of the commands file: `open`, `close <title>`, `quit`, `activate`.
- It records the app activations of the Mac (`activationCount` and the newest 64 in `activations`), so the runner
  can see when another app took the focus.

With `--steal-focus`, the runner also makes `.build/e2e/StripleE2EThief.app` (bundle ID
`com.fskroes.Striple.e2e-thief`, the same binary with no windows). It starts in the background (`open -g`) and,
with no windows, does not activate itself, so its launch is no theft. The runner also moves its focus mark past
every activation before the thief started. Each steal is an `open` of the running thief: an app cannot make
itself active on macOS 14 and later, but `open` can. The runner quits it at the end, and before a run it quits one
that is left over.

## Limits

- The test uses the main display only. With a display next to it, Striple moves a column that hangs toward that
  display to the edge, over the column next to it: the gap check skips a column at such an edge, but its x is
  still checked. With a display on one side only, Striple parks every hidden column on the free side, so the
  check of the parked side order is skipped then.
- The test app takes the focus during the run.
- The runner gives the focus back after another app took it (see "Focus taken by another app"), at most 3 times
  per run.
- Timing numbers depend on the machine and on what else runs. The budget in scenario h has room for that. The
  passing live runs on 2026-10-13 (held sizes, first frame in the key handler) measured:

  | Mode | Runs | Frame write p95 | Striple's part p95 | Command latency p95 | Settle p95 |
  |---|---|---|---|---|---|
  | `--animations on` | 9 | 0.80 to 1.14 ms | 0.05 to 0.11 ms | 2.24 to 12.32 ms | 775 to 914 ms |
  | `--animations off` | 7 | 2.38 to 10.05 ms | 0.04 to 0.20 ms | 3.04 to 10.08 ms | 467 to 572 ms |

  The highest values (1.14, 12.32, 10.05 and 10.08 ms) are from the two runs directly after `make test`, at a
  load average of 7.5. With animations on, the frame write p95 was below 1 ms in the other runs, except one at a
  load average of 9.8 (1.01 ms).

  Before these changes (2026-10-12): frame write p95 4.64 ms and command latency p95 22.91 ms with animations on.
  With animations off every frame resizes the windows, and one AX size write costs the test app about 1.5 ms,
  so a frame write stays above 1 ms there. A heavy load on the Mac can still make a run fail. Run again when
  other work used the CPU.
