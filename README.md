# Spool

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

Spool had the name Striple before. `make install` replaces Striple and Spool moves your settings at its first start. See [Upgrade from Striple](docs/INSTALL.md#upgrade-from-striple).

Spool is a clean-room app. It follows the public descriptions of niri, PaperWM and the public feature pages of similar macOS apps. No third-party binary was decompiled. See [docs/SPEC.md](docs/SPEC.md).

## Features

| | Feature | Where |
|---|---|---|
| F1 | Endless horizontal strip per display and per Space | always on |
| F2 | Spring animations; a new shortcut press retargets the running animation | Settings > Appearance |
| F3 | Stacks: more windows in one column, up and down | `⌃⌥[` `⌃⌥]`, `⌃⌥J` `⌃⌥K` |
| F4 | Tabbed columns | `⌃⌥⇧T` |
| F5 | Preset widths, full width, wider and narrower, heights in a stack | `⌃⌥R` `⌃⌥F` `⌃⌥=` `⌃⌥-` |
| F6 | Inner and outer gaps, sizes that respect the Dock and the menu bar | Settings > Layout |
| F7 | Center the focused column: never, on overflow, always | Settings > Layout, `⌃⌥C` |
| F8 | Focus border and dimming of other windows | Settings > Appearance |
| F9 | Minimap of the strip when the view moves | Settings > Appearance |
| F10 | Trackpad swipe with 3 or 4 fingers, with fling and snap | Settings > Mouse & Trackpad |
| F11 | Drag a window to a new place in the strip; resize from an edge sets the column width | mouse |
| F12 | Multi-monitor, one strip each, turn Spool off per display | Settings > Displays, `⌃⌥N` |
| F13 | The strips come back after a restart of the app, also on Spaces not on screen (restored when you go there) and after a start while the screen is locked | automatic |
| F14 | Launch at login and start tiling at launch | Settings > General |
| F15 | Per-app rules (tile, float, fixed place) and smart floating for dialogs | Settings > App Rules |
| F16 | CLI, URL scheme and Raycast scripts | [docs/CLI.md](docs/CLI.md) |
| F17 | Sparkle updates, engine log, restart after a crash; repairs a dead app observer and stops cleanly when the Accessibility permission is removed | menu bar menu |
| F18 | Native fullscreen windows leave the strip and come back | automatic |
| F19 | No focus stealing by apps that open windows on their own | Settings > General |
| F20 | Focus follows mouse, mouse follows focus | Settings > Mouse & Trackpad |
| F21 | Guided start and a Mac Setup check | first launch, Settings > Mac Setup |
| F22 | Every shortcut can be changed | Settings > Shortcuts, [docs/SHORTCUTS.md](docs/SHORTCUTS.md) |
| F23 | Every setting applies at once; `config.json` edits load automatically | always on |
| F24 | Local metrics: speed, cost, problems and use on this Mac only, `spool report`, and marks of bad moments | Settings > General, [docs/METRICS.md](docs/METRICS.md) |

## Performance

Measured on this Mac (Apple silicon, macOS 26) with `make bench` on 2026-10-13, load average 4.8:

| Metric | Budget (docs/SPEC.md) | Measured |
|---|---|---|
| Layout and placement of 50 columns, per frame | < 50 µs | 6.3 µs |
| Frame write, 6 apps with 2 ms AX latency each, p95 of 100 rounds | < 4 ms | 3.18 ms (one after the other: 18.1 ms) |
| Applier time in that frame write (wall time minus the slowest write), p95 | < 2 ms | 0.13 ms |
| Spool's part of that frame write (wall time minus the AX time of the slowest app), p95 | < 1 ms | 0.12 ms |
| Idle | no timer, no display link | the ticker stops when all windows are at rest |

With the real app and the E2E test app (`make e2e`, 3 windows, 2026-10-13): frame write p95 0.80 to 0.97 ms and
command latency p95 2.2 to 6.2 ms in 7 of 9 runs (1.14 and 12.3 ms in a run at load average 7.5, 1.01 and 7.3 ms in a run at load average 9.8). The rest of a frame write is the time the app and WindowServer need to answer
the AX calls; Spool cannot make that shorter. Details: [docs/E2E.md](docs/E2E.md#limits).

How Spool stays fast:

- Each app gets its own write queue, so a slow app does not hold up the others.
- When an app is still busy, only the newest frame for each window is kept. Older frames are dropped, not queued.
- A frame that has not changed is not written again.
- Frames are rounded per origin and per size, so a scrolling window keeps its width and gets no extra resize.
- During an animation a window keeps one size and only moves: a resize costs the app several times a move. A
  growing window gets its new size on the first frame, a shrinking one when its size settles.
- When no animation runs, the key handler writes the first frame of a command, so the windows start to move
  without a wait for the next display refresh. During an animation the display link writes the next frame.
- `AXEnhancedUserInterface` (which makes Chrome and Electron apps animate every move) is read and turned off once per app per animation, not on every frame.
- The animation ticker runs only while something moves.

`spool stats` shows the live p50 and p95 frame-write time, Spool's part of it (without the AX calls), command latency, and the apps with the slowest AX writes.

## Install

Requirements: macOS 13 or later, the Xcode Command Line Tools (`xcode-select --install`).

```sh
make install
open /Applications/Spool.app
```

`make install` builds `dist/Spool.app` and copies it to `/Applications`.

At first launch the guide asks for the **Accessibility** permission (System Settings > Privacy & Security > Accessibility). That is the only permission Spool needs.

An ad hoc signed build gets a new signature with each rebuild. Then the Accessibility entry no longer matches: the switch still shows on, but Spool has no permission. A stable signing identity prevents this. See [docs/INSTALL.md](docs/INSTALL.md#keep-the-accessibility-permission-after-a-rebuild).

`Packaging/updates.env` pins the signing identity of the Spool releases. Only the maintainer has it. When it is not on your Mac, `make install` stops with "the local signing identity is not found". Then do one of these:

- The maintainer: restore the identity with `scripts/make-signing-cert.sh --import <backup file>`.
- Other builders: sign with an Apple Development or Developer ID identity (from Xcode), `SIGN_IDENTITY="<name or SHA-1>" make install`. Another self-signed identity does not work here: `build-app.sh` then adds the hardened runtime, and that blocks Sparkle.framework. Sparkle updates are signed with the pin. Each time the app changes between your build and an update, click Settings > Mac Setup > **Reset Permission**. Or sign ad hoc, `SIGN_IDENTITY=- make install`, and after each rebuild click Settings > Mac Setup > **Reset Permission** and turn Spool on.

If System Settings shows Spool on, but Spool says "Accessibility permission needed", click Settings > Mac Setup > **Reset Permission**, then turn Spool on. See [docs/INSTALL.md](docs/INSTALL.md#the-switch-is-on-but-spool-has-no-permission).

## Use

- Shortcuts: [docs/SHORTCUTS.md](docs/SHORTCUTS.md). All defaults use `⌃⌥`.
- CLI: the app includes `spool` (`Spool.app/Contents/Helpers/spool`). `make install` links it to `~/.local/bin/spool`. See [docs/CLI.md](docs/CLI.md).

  ```sh
  spool focus-right
  spool state
  spool stats
  ```

  `spool state` shows the strips as text. Add `--json` for scripts. `spool stats` shows live performance numbers.

- URL scheme: `open -g spool://focus-right`, `open spool://settings/shortcuts`.
- Menu bar: start or stop tiling, settings, the engine log, updates, a mark.

### Measure

Spool measures its own speed, cost and problems on this Mac. Nothing leaves the Mac, and Spool keeps no window
titles and no keys. See [docs/METRICS.md](docs/METRICS.md).

```sh
spool report
spool mark Safari jumped to the left
```

`spool report` shows the last 7 days and checks the live budgets. When something goes wrong, press `⌃⌥⇧M` or run
`spool mark` with a note: Spool saves the state of that moment. To turn the metrics off, use Settings > General.

Settings live in `~/Library/Application Support/Spool/config.json`. The engine log is `~/Library/Logs/Spool/engine.log`.
If you edit the file and it has an error, Spool keeps the last good settings and Settings shows the error and where it is.
If a setting changes before you fix the file, Spool keeps your file as `config.json.broken`.
After each good load or save, Spool writes a copy named `config.json.lastgood`. If `config.json` has an error when
Spool starts, Spool uses that copy, not the factory settings. While the file has an error, the menu bar menu
shows "Problem With config.json…". Only a change that you make saves over the file while it has an error.
If you delete the broken file, Spool writes a new `config.json` with the settings in use.
If `config.json` is missing when Spool starts, Spool writes it again from `config.json.lastgood`. To go back to
the factory settings, quit Spool and delete both files.
Edits load automatically, also from editors and tools that write the file in place (for example `nano` or
`jq … > config.json`). A change in Settings first reads an edit that was not loaded yet, so it never replaces it.
`config.json` can be a symlink into a dotfiles repo. Spool saves to the file the link points to, so the link stays,
and edits to that file load too. If that file is read-only (for example managed by Nix), a change in Settings shows
"Could not save config.json" and stays in use until Spool quits. Spool does not make the folder a link points to:
if that folder does not exist yet (the dotfiles repo is not cloned), the message names the folder, and "Open File"
shows the link in Finder. When the file comes, or the folder is replaced (for example by a new clone), Spool
loads it within a few seconds.
If Spool cannot read the file (for example it was made with `sudo`), Spool uses the settings it has (at start,
from `config.json.lastgood`), does not write over the file, and shows "Could not save config.json". After you fix the
permissions (`chmod` or `chown`), Spool loads the file within a few seconds.
Spool never replaces the link with a plain file, also not a link in a loop.

When you quit Spool (from the menu, at logout, or with a plain `kill`), every window that is out of view comes back onto the screen.

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
| `make test-signing` | `SigningScriptTests` only. They run `make-signing-cert.sh` against fake tools with neutral names (`SPOOL_SECURITY`, `SPOOL_CODESIGN`), never a file named `security`. On a managed Mac the endpoint security tool can still report the keychain-like arguments. The suite runs only with `SPOOL_SIGNING_TESTS=1`, so a plain `swift test` skips it too. |
| `make bench` | The frame-write and layout benchmarks in release mode. |
| `make app` | Makes `dist/Spool.app` (universal, signed). |
| `make dmg` | Makes `dist/Spool-<version>.dmg`. |
| `make e2e` | Live end-to-end test on real windows of a test app ([docs/E2E.md](docs/E2E.md)). |

## Project layout

| Path | What |
|---|---|
| `Sources/SpoolCore` | Pure model: strip operations, layout, animation, config, rules, session, IPC types. No AppKit. |
| `Sources/SpoolEngine` | Talks to macOS: AX window control, hotkeys, trackpad, displays, Spaces, overlays, IPC server. |
| `Sources/SpoolApp` | Menu bar app, settings, guided start, shortcut recorder, updates. |
| `Sources/spool-cli` | The `spool` command. |
| `Sources/spool-e2e`, `Sources/spool-e2e-windows`, `Sources/SpoolE2EKit` | Live E2E test: runner, test window app, pure checks. See [docs/E2E.md](docs/E2E.md). |
| `Integrations/Raycast` | Raycast script commands. |
| `scripts`, `Packaging` | App bundle, signing, LaunchAgent, DMG, install. |

## Known limits

- Window focus uses private SkyLight calls, as other window managers on macOS do. A future macOS can change them; Spool then falls back to normal app activation.
- Trackpad swipes use the private MultitouchSupport framework.
- On a Mac that your employer manages, ask IT before you use Spool. See [Use on a managed work Mac](docs/INSTALL.md#use-on-a-managed-work-mac).
- Releases are signed with a personal certificate and are not notarized, so they are for the owner's own Macs. Updates come from [fskroes/spool-releases](https://github.com/fskroes/spool-releases). See [docs/RELEASING.md](docs/RELEASING.md).
