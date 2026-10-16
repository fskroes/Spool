# Spool

**A scrolling window manager for macOS.** Your windows sit side by side on one endless strip. The screen shows a part of the strip. A new window opens next to the window you work in, and no other window gets smaller.

[Website](https://spool.1yc.dev) · [Install](#install) · [Shortcuts](docs/SHORTCUTS.md) · [CLI](docs/CLI.md) · [Spec](docs/SPEC.md)

<p align="center"><img src="site/strip.svg" width="720" alt="Five windows on a strip. The view moves right along the strip, a new window opens to the right, and the other windows keep their width."></p>

Spool costs EUR 0.99, one time, VAT included ([1yc.dev/spool](https://1yc.dev/spool)). It is for people who keep many windows open on one screen and want to move between them with the keyboard or the trackpad, as niri and PaperWM do on Linux.

## Why a strip

Most tiling window managers cut the screen into a grid. Each new window takes space from the windows you already have, so after three or four windows every window is too small to use. Stage Manager hides the windows you do not use at that moment, so you look for them again.

Spool does not divide the screen. It adds a column to the strip:

```
A grid: a new window makes every window smaller.

 ┌───────────┬───────────┐               ┌───────┬───────┬───────┐
 │  Editor   │ Terminal  │   open Docs   │Editor │Termin…│ Docs  │
 │           │           │  ──────────▶  │       │       │       │
 └───────────┴───────────┘               └───────┴───────┴───────┘

Spool: Docs opens to the right. Editor and Terminal keep their width.

          the display
 ┌─────────────────────────┐
 │┌───────────┐┌──────────┐│┌───────┐
 ││  Editor   ││ Terminal │││ Docs  │   ← the strip goes on
 │└───────────┘└──────────┘│└───────┘
 └─────────────────────────┘
```

Then you move the view along the strip, and the windows keep their size and their order.

## What you can do

These examples use the default shortcuts. All of them use `⌃⌥` (Control-Option), so plain Option stays free for typing. You can change every shortcut in Settings > Shortcuts.

**Move along the strip.** `⌃⌥L` or `⌃⌥→` focuses the next window to the right, `⌃⌥H` or `⌃⌥←` the one to the left. `⌃⌥1` to `⌃⌥9` jump to a place. A swipe with 4 fingers (or 3, in Settings) scrolls the strip; lift with speed and it flings and stops on a window edge. A minimap shows where you are while the view moves.

**Give a window the width it needs.** `⌃⌥R` cycles the width of the focused column through 1/3, 1/2 and 2/3 of the screen. `⌃⌥F` makes it full width and back. `⌃⌥=` and `⌃⌥-` make it wider or narrower. `⌃⌥C` puts it in the middle.

**Put windows in order.** `⌃⌥⇧H` and `⌃⌥⇧L` move the column left and right. `⌃⌥[` puts the focused window in the column on its left, so two windows share one column, one above the other. `⌃⌥⇧T` shows the windows of a column as tabs.

**Keep some windows out.** Per-app rules float an app, keep it tiled, or give it a fixed place on the strip. Dialogs float by themselves. `⌃⌥T` floats or tiles one window.

**Script it.** The `spool` command controls the running app and shows its state:

```sh
spool focus-right
spool state
```

```
Engine: running. Accessibility: granted.
Focused: VSCode "Layout.swift" (window 102)
Display: Built-in Retina Display (on, space 3)
  [1] mail "Inbox" | [2*] VSCode "Layout.swift" | [3] Terminal "make test" + Notes "Ideas" | [4] Safari "niri docs"
```

`[2*]` is the focused column. `+` joins the windows of a stack. Add `--json` for scripts, for example to list the apps on the strip in order:

```sh
spool state --json | jq -r '.state.displays[].columns[][].bundleID'
```

The same commands work as URLs (`open -g spool://focus-right`) and as Raycast script commands ([Integrations/Raycast](Integrations/Raycast)).

**See when it is slow.** `spool stats` shows the live frame-write time and the apps that answer slowest. When something goes wrong, press `⌃⌥⇧M` or run `spool mark Safari jumped to the left`, and Spool saves the state of that moment. Nothing leaves the Mac ([docs/METRICS.md](docs/METRICS.md)).

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
| F25 | License key: Spool costs EUR 0.99, one time, with no trial. The key comes by email and works with no network | the window at the first start, `spool license`, [docs/LICENSE-KEYS.md](docs/LICENSE-KEYS.md) |

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

Requirements: macOS 13 or later.

1. Buy Spool on [1yc.dev/spool](https://1yc.dev/spool): EUR 0.99, one time, VAT included. The email has your license key and the download link.
2. Download [Spool.dmg](https://github.com/fskroes/spool-releases/releases/latest/download/Spool.dmg), open it and drag Spool to Applications.
3. Open Spool. Paste the license key and click **Activate**, or click the activation link in the email. The key is checked on your Mac, with no network connection. Lost your key? [1yc.dev/spool/restore](https://1yc.dev/spool/restore) sends it again.
4. The guide then asks for the **Accessibility** permission (System Settings > Privacy & Security > Accessibility). That is the only permission Spool needs.

The app is signed with a Developer ID and notarized by Apple, so macOS opens it with no extra step. Spool updates itself: **Check for Updates…** in the menu bar menu, or automatically every 24 hours. The Accessibility permission stays after each update, because every release is signed by the same Apple team. To link the `spool` CLI, see [docs/INSTALL.md](docs/INSTALL.md#install-the-release).

### Build from source

The source is private. This is for the maintainer. Requirements: the Xcode Command Line Tools (`xcode-select --install`).

```sh
scripts/make-signing-cert.sh
make install
open /Applications/Spool.app
```

`scripts/make-signing-cert.sh` makes a free, self-signed signing identity one time. With it, every build has the same signature, so the Accessibility permission stays after a rebuild. `make install` builds `dist/Spool.app`, copies it to `/Applications` and links `spool` to `~/.local/bin`. On the maintainer's Mac, `make install` signs with the Developer ID of the releases instead. Without either identity, `make install` stops and lists the ways on. See [docs/INSTALL.md](docs/INSTALL.md#keep-the-accessibility-permission-after-a-rebuild). A bundled build needs a license key too, and only a build signed with the Developer ID of the releases can accept one: make the key with `spool-license issue` (see [docs/RELEASING.md](docs/RELEASING.md#license-keys)). A build with the self-signed identity, or ad hoc, stays unlicensed.

A build from source is not signed like a release. When Sparkle updates it to a release, the Accessibility entry no longer matches: click Settings > Mac Setup > **Reset Permission** once. To keep your own build, build it with `SPOOL_UPDATES=off make install`.

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
| `make test` | All unit tests (core, engine, IPC, E2E kit), except `SigningScriptTests` and the timing benchmarks `MetricsBenchmarkTests` and `FrameApplierBenchmarkTests` (`make bench` runs those). |
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

## Work on Spool

[AGENTS.md](AGENTS.md) is the guide for people and coding agents: how a change is made (spec, test, docs), what to run before a PR, and what never to touch. Before a PR, run:

```sh
make test
scripts/verify smoke
```

`scripts/verify smoke` builds every product, starts an isolated copy of the app (its own settings folder, no shortcuts, no managed windows), talks to it with the `spool` command and checks the website. It ends with one JSON summary line. See [.claude/skills/verify-spool/SKILL.md](.claude/skills/verify-spool/SKILL.md) for what a pass proves.

To hand a bug to an agent, open an issue with the **Agent task** template. It adds the label `agent`, and the agent queue picks it up, reproduces it on `main` and opens a PR.

The website in [site/](site/) is published to https://spool.1yc.dev by GitHub Pages when `site/` changes on `main`. `scripts/site-domain status` checks the domain, the DNS and the certificate (see [AGENTS.md](AGENTS.md#the-website)).

## Known limits

- Window focus uses private SkyLight calls, as other window managers on macOS do. A future macOS can change them; Spool then falls back to normal app activation.
- Trackpad swipes use the private MultitouchSupport framework.
- On a Mac that your employer manages, ask IT before you use Spool. See [Use on a managed work Mac](docs/INSTALL.md#use-on-a-managed-work-mac).
- Releases are signed with a Developer ID and notarized by Apple. Downloads and updates come from the [releases of fskroes/spool-releases](https://github.com/fskroes/spool-releases/releases). See [docs/RELEASING.md](docs/RELEASING.md).
- Spool is a paid app with a private source. A license key unlocks it (F25, [docs/LICENSE-KEYS.md](docs/LICENSE-KEYS.md)).

## Related projects

- [niri](https://github.com/YaLTeR/niri): a scrolling tiling compositor for Wayland on Linux. The model Spool follows.
- [PaperWM](https://github.com/paperwm/PaperWM): scrolling tiling for GNOME, where the idea started.
- [PaperWM.spoon](https://github.com/mogenson/PaperWM.spoon): the same idea on macOS as a Hammerspoon spoon.
- [AeroSpace](https://github.com/nikitabobko/AeroSpace): an i3-like tiling window manager for macOS, with a grid instead of a strip.
