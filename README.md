# Striple

A scrolling window manager for macOS. Windows sit side by side on an endless horizontal strip, one strip per display and per Space. Opening a window never makes the other windows smaller. You move the view along the strip with the keyboard, a trackpad swipe or the CLI.

```
            what you see (the display)
          ┌───────────────────────────┐
 ┌──────┐ │ ┌──────────┐ ┌──────────┐ │ ┌──────┐ ┌──────┐
 │ Mail │ │ │  Editor  │ │ Terminal │ │ │ Docs │ │ Chat │   ← one strip
 └──────┘ │ └──────────┘ └──────────┘ │ └──────┘ └──────┘
          └───────────────────────────┘
   ⌃⌥H / ⌃⌥← focus left        ⌃⌥L / ⌃⌥→ focus right
```

Striple is a clean-room app. It follows the public descriptions of niri, PaperWM and the public feature pages of similar macOS apps. No third-party binary was decompiled. See [docs/SPEC.md](docs/SPEC.md).

## Features

| | Feature | Where |
|---|---|---|
| F1 | Endless horizontal strip per display and per Space | always on |
| F2 | Spring animations; a new shortcut press retargets the running animation | Settings > General |
| F3 | Stacks: more windows in one column, up and down | `⌃⌥[` `⌃⌥]`, `⌃⌥J` `⌃⌥K` |
| F4 | Tabbed columns | `⌃⌥⇧T` |
| F5 | Preset widths, full width, wider and narrower, heights in a stack | `⌃⌥R` `⌃⌥F` `⌃⌥=` `⌃⌥-` |
| F6 | Inner and outer gaps, sizes that respect the Dock and the menu bar | Settings > General |
| F7 | Center the focused column: never, on overflow, always | Settings > General, `⌃⌥C` |
| F8 | Focus border and dimming of other windows | Settings > General |
| F9 | Minimap of the strip when the view moves | Settings > General |
| F10 | Trackpad swipe with 3 or 4 fingers, with fling and snap | Settings > General |
| F11 | Drag a window to a new place in the strip; resize from an edge sets the column width | mouse |
| F12 | Multi-monitor, one strip each, turn Striple off per display | Settings > Displays, `⌃⌥N` |
| F13 | The strips come back after a restart of the app, also on Spaces not on screen (restored when you go there) and after a start while the screen is locked | automatic |
| F14 | Launch at login and start tiling at launch | Settings > General |
| F15 | Per-app rules (tile, float, fixed place) and smart floating for dialogs | Settings > App Rules |
| F16 | CLI, URL scheme and Raycast scripts | [docs/CLI.md](docs/CLI.md) |
| F17 | Sparkle updates, engine log, restart after a crash; repairs a dead app observer and stops cleanly when the Accessibility permission is removed | menu bar menu |
| F18 | Native fullscreen windows leave the strip and come back | automatic |
| F19 | No focus stealing by apps that open windows on their own | Settings > General |
| F20 | Focus follows mouse, mouse follows focus | Settings > General |
| F21 | Guided start and a Mac Setup check | first launch, Settings > Mac Setup |
| F22 | Every shortcut can be changed | Settings > Shortcuts, [docs/SHORTCUTS.md](docs/SHORTCUTS.md) |
| F23 | Every setting applies at once; `config.json` edits load automatically | always on |
| F24 | Local metrics: speed, cost, problems and use on this Mac only, `striple report`, and marks of bad moments | Settings > General, [docs/METRICS.md](docs/METRICS.md) |

## Performance

Measured on this Mac (Apple silicon, macOS 26) with `make bench` on 2026-10-12, load average 6.8:

| Metric | Budget (docs/SPEC.md) | Measured |
|---|---|---|
| Layout and placement of 50 columns, per frame | < 50 µs | 7.3 µs |
| Frame write, 6 apps with 2 ms AX latency each, p95 of 100 rounds | < 4 ms | 2.65 ms (one after the other: 15.0 ms) |
| Applier time in that frame write (wall time minus the slowest write), p95 | < 2 ms | 0.10 ms |
| Idle | no timer, no display link | the ticker stops when all windows are at rest |

How Striple stays fast:

- Each app gets its own write queue, so a slow app does not hold up the others.
- When an app is still busy, only the newest frame for each window is kept. Older frames are dropped, not queued.
- A frame that has not changed is not written again.
- Frames are rounded per origin and per size, so a scrolling window keeps its width and gets no extra resize.
- `AXEnhancedUserInterface` (which makes Chrome and Electron apps animate every move) is read and turned off once per app per animation, not on every frame.
- The animation ticker runs only while something moves.

`striple stats` shows the live p50 and p95 frame-write time and command latency, and the apps with the slowest AX writes.

## Install

Requirements: macOS 13 or later, the Xcode Command Line Tools (`xcode-select --install`).

```sh
make install
open /Applications/Striple.app
```

`make install` builds `dist/Striple.app` and copies it to `/Applications`.

At first launch the guide asks for the **Accessibility** permission (System Settings > Privacy & Security > Accessibility). That is the only permission Striple needs.

An ad hoc signed build gets a new signature with each rebuild, and macOS then forgets the permission. To keep it, make a local signing certificate once. See [docs/INSTALL.md](docs/INSTALL.md#keep-the-accessibility-permission-after-a-rebuild).

## Use

- Shortcuts: [docs/SHORTCUTS.md](docs/SHORTCUTS.md). All defaults use `⌃⌥`.
- CLI: the app includes `striple` (`Striple.app/Contents/Helpers/striple`). `make install` links it to `~/.local/bin/striple`. See [docs/CLI.md](docs/CLI.md).

  ```sh
  striple focus-right
  striple state
  striple stats
  ```

  `striple state` shows the strips as text. Add `--json` for scripts. `striple stats` shows live performance numbers.

- URL scheme: `open -g striple://focus-right`, `open striple://settings/shortcuts`.
- Menu bar: start or stop tiling, settings, the engine log, updates, a mark.

### Measure

Striple measures its own speed, cost and problems on this Mac. Nothing leaves the Mac, and Striple keeps no window
titles and no keys. See [docs/METRICS.md](docs/METRICS.md).

```sh
striple report
striple mark Safari jumped to the left
```

`striple report` shows the last 7 days and checks the live budgets. When something goes wrong, press `⌃⌥⇧M` or run
`striple mark` with a note: Striple saves the state of that moment. To turn the metrics off, use Settings > General.

Settings live in `~/Library/Application Support/Striple/config.json`. The engine log is `~/Library/Logs/Striple/engine.log`.
If you edit the file and it has an error, Striple keeps the last good settings and Settings shows the error and where it is.
If a setting changes before you fix the file, Striple keeps your file as `config.json.broken`.
After each good load or save, Striple writes a copy named `config.json.lastgood`. If `config.json` has an error when
Striple starts, Striple uses that copy, not the factory settings. While the file has an error, the menu bar menu
shows "Problem With config.json…". Only a change that you make saves over the file while it has an error.
If you delete the broken file, Striple writes a new `config.json` with the settings in use.
If `config.json` is missing when Striple starts, Striple writes it again from `config.json.lastgood`. To go back to
the factory settings, quit Striple and delete both files.
Edits load automatically, also from editors and tools that write the file in place (for example `nano` or
`jq … > config.json`). A change in Settings first reads an edit that was not loaded yet, so it never replaces it.
`config.json` can be a symlink into a dotfiles repo. Striple saves to the file the link points to, so the link stays,
and edits to that file load too. If that file is read-only (for example managed by Nix), a change in Settings shows
"Could not save config.json" and stays in use until Striple quits. Striple does not make the folder a link points to:
if that folder does not exist yet (the dotfiles repo is not cloned), the message names the folder, and "Open File"
shows the link in Finder. When the file comes, or the folder is replaced (for example by a new clone), Striple
loads it within a few seconds.
If Striple cannot read the file (for example it was made with `sudo`), Striple uses the settings it has (at start,
from `config.json.lastgood`), does not write over the file, and shows "Could not save config.json". After you fix the
permissions (`chmod` or `chown`), Striple loads the file within a few seconds.
Striple never replaces the link with a plain file, also not a link in a loop.

When you quit Striple (from the menu, at logout, or with a plain `kill`), every window that is out of view comes back onto the screen.

## Build and test

```sh
make build
make test
make bench
make app
make dmg
make e2e
```

| Target | What it does |
|---|---|
| `make build` | Debug build. |
| `make test` | All unit tests (core, engine, IPC, E2E kit), except `SigningScriptTests`. |
| `make test-quiet` | The quiet lane for a managed Mac: only the suites that start no process and make no executable file (`scripts/quiet-tests.sh`). A test file that starts a process or sets an execute bit is out of the lane. `scripts/quiet-tests.sh --list` shows the selection. |
| `make test-signing` | `SigningScriptTests` only. They run `make-signing-cert.sh` against fake tools with neutral names (`STRIPLE_SECURITY`, `STRIPLE_CODESIGN`), never a file named `security`. On a managed Mac the endpoint security tool can still report the keychain-like arguments. The suite runs only with `STRIPLE_SIGNING_TESTS=1`, so a plain `swift test` skips it too. |
| `make bench` | The frame-write and layout benchmarks in release mode. |
| `make app` | Makes `dist/Striple.app` (universal, signed). |
| `make dmg` | Makes `dist/Striple-<version>.dmg`. |
| `make e2e` | Live end-to-end test on real windows of a test app ([docs/E2E.md](docs/E2E.md)). |

## Project layout

| Path | What |
|---|---|
| `Sources/StripleCore` | Pure model: strip operations, layout, animation, config, rules, session, IPC types. No AppKit. |
| `Sources/StripleEngine` | Talks to macOS: AX window control, hotkeys, trackpad, displays, Spaces, overlays, IPC server. |
| `Sources/StripleApp` | Menu bar app, settings, guided start, shortcut recorder, updates. |
| `Sources/striple-cli` | The `striple` command. |
| `Sources/striple-e2e`, `Sources/striple-e2e-windows`, `Sources/StripleE2EKit` | Live E2E test: runner, test window app, pure checks. See [docs/E2E.md](docs/E2E.md). |
| `Integrations/Raycast` | Raycast script commands. |
| `scripts`, `Packaging` | App bundle, signing, LaunchAgent, DMG, install. |

## Known limits

- Window focus uses private SkyLight calls, as other window managers on macOS do. A future macOS can change them; Striple then falls back to normal app activation.
- Trackpad swipes use the private MultitouchSupport framework.
- On a Mac that your employer manages, ask IT before you use Striple. See [Use on a managed work Mac](docs/INSTALL.md#use-on-a-managed-work-mac).
- Releases are signed with a personal certificate and are not notarized, so they are for the owner's own Macs. Updates come from [fskroes/striple-releases](https://github.com/fskroes/striple-releases). See [docs/RELEASING.md](docs/RELEASING.md).
