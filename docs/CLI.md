# Spool command-line tool

The `spool` tool controls the running Spool app from a terminal, a script, Raycast or any
other launcher. It sends one request to the app over a Unix socket and prints the answer.

## Install

- The app has the tool inside: `Spool.app/Contents/Helpers/spool`.
- `make install` links it to `~/.local/bin/spool`. Make sure that `~/.local/bin` is in your `PATH`.
- In a source checkout, `swift build` makes `.build/debug/spool`.

## Usage

```
spool <command> [<n>] [--json] [--socket <path>]
spool report [--days <n>] [--json]
spool license [<key>] [--json]
```

Examples:

```sh
spool focus-left
spool focus-index 3
spool command focus-left
spool state
spool stats --json
spool mark Safari jumped to the left
spool report --days 30
spool license
spool list
spool help focus-index
spool --version
```

| Command | What it does |
|---|---|
| `spool focus-left` | Focuses the column on the left. |
| `spool focus-index 3` | Focuses place 3. Same as `spool focus-index-3`. |
| `spool command focus-left` | Same as `spool focus-left`. |
| `spool state` | Shows the displays, columns and windows. |
| `spool stats --json` | Shows the performance counters as JSON. |
| `spool mark Safari jumped to the left` | Saves a mark with the note "Safari jumped to the left". |
| `spool report --days 30` | Shows the local metrics of the last 30 days. |
| `spool license` | Shows who the license is for: `Licensed to <email> (order <id>)`. |
| `spool list` | Shows all commands with a short description. |
| `spool help focus-index` | Shows the help for one command. |
| `spool --version` | Shows the version. |

A command prints nothing when it works. Errors go to stderr.

## Commands

`spool list` shows the same list. Names are not case sensitive, and `_` works as `-`.
For a command with a number, you can write the number as a separate word (`spool focus-index 3`)
or as part of the name (`spool focus-index-3`).

| Command | What it does | URL |
|---|---|---|
| `spool focus-left` | Focus left | `spool://focus-left` |
| `spool focus-right` | Focus right | `spool://focus-right` |
| `spool focus-up` | Focus up in stack | `spool://focus-up` |
| `spool focus-down` | Focus down in stack | `spool://focus-down` |
| `spool focus-first` | Focus first window | `spool://focus-first` |
| `spool focus-last` | Focus last window | `spool://focus-last` |
| `spool focus-index <1-9>` | Focus place &lt;n&gt; (9 is the last place) | `spool://focus-index/3` |
| `spool move-left` | Move column left | `spool://move-left` |
| `spool move-right` | Move column right | `spool://move-right` |
| `spool move-up` | Move window up in stack | `spool://move-up` |
| `spool move-down` | Move window down in stack | `spool://move-down` |
| `spool move-first` | Move column to first place | `spool://move-first` |
| `spool move-last` | Move column to last place | `spool://move-last` |
| `spool move-to-index <1-9>` | Move column to place &lt;n&gt; (9 is the last place) | `spool://move-to-index/3` |
| `spool cycle-width` | Cycle preset widths | `spool://cycle-width` |
| `spool toggle-full-width` | Full width | `spool://toggle-full-width` |
| `spool center-column` | Center column | `spool://center-column` |
| `spool wider` | Wider | `spool://wider` |
| `spool narrower` | Narrower | `spool://narrower` |
| `spool taller` | Taller (in a stack) | `spool://taller` |
| `spool shorter` | Shorter (in a stack) | `spool://shorter` |
| `spool equalize-heights` | Equalize heights | `spool://equalize-heights` |
| `spool stack-left` | Stack into left column | `spool://stack-left` |
| `spool stack-right` | Stack into right column | `spool://stack-right` |
| `spool pop-left` | Pop out of stack to the left | `spool://pop-left` |
| `spool pop-right` | Pop out of stack to the right | `spool://pop-right` |
| `spool toggle-tabbed` | Tabbed column | `spool://toggle-tabbed` |
| `spool toggle-float` | Float / unfloat | `spool://toggle-float` |
| `spool send-to-next-display` | Send window to next display | `spool://send-to-next-display` |
| `spool toggle-engine` | Start / stop the window manager | `spool://toggle-engine` |
| `spool focus-window <id>` | Focus the window with this ID (see spool state --json) | `spool://focus-window/1234` |
| `spool start` | Start | `spool://start` |
| `spool stop` | Stop | `spool://stop` |
| `spool restart` | Restart | `spool://restart` |
| `spool mark [<note>]` | Mark this moment: save the state, the stats and the last minute of the log, with a note | `spool://mark` |

`focus-index 9` and `move-to-index 9` mean the last place, also when there are more than 9 columns.

`spool mark` takes the words after `mark` as the note. Quotes are not necessary. Use a mark when something goes
wrong: Spool writes a new folder in `~/Library/Application Support/Spool/metrics/marks/`. It writes the folder
after it answers, so `spool mark` prints `Saving a mark (see engine.log for the folder)`. The engine log
(`~/Library/Logs/Spool/engine.log`) names the folder when the write ends. The note is the only text that you type that Spool keeps. Marks need metrics on (Settings > General).
See [METRICS.md](METRICS.md#marks).

## Queries

| Query | What it shows |
|---|---|
| `spool ping` | `Spool is running.` when the app answers. |
| `spool state` | Engine status, the focused window, and the columns of each display. |
| `spool stats` | Uptime, frame and window write counts, AX errors, timings, restarts and the slowest apps. |
| `spool report [--days <n>]` | The local metrics of the last &lt;n&gt; days (1 to 90, default 7). See "Metrics report". |
| `spool license [<key>]` | The license of this copy of Spool, or activates a key. See "License". |

Example output of `spool state`:

```
Engine: running. Accessibility: granted.
Focused: Terminal "zsh" (window 202)
Display: Built-in Retina Display (on, space 5)
  [1] Safari "Apple" | [2*] Terminal "zsh" + Notes
Display: LG UltraFine (off, space 9)
  (no windows)
Floating: calculator "Calculator"
```

- Columns are numbered from 1. `*` marks the focused column of the display.
- `+` joins the windows of a stacked column.
- The app name is the last part of the bundle ID. A title longer than 40 characters is cut.

Example output of `spool stats`:

```
Uptime:               1h 02m 03s
Frames written:       1200
Window writes:        3400
Skipped writes:       12
Coalesced writes:     40
AX errors:            1
Closed-window writes: 3 (the window closed first; not errors)
Frame write:          p50 1.20 ms, p95 3.46 ms
Spool's part:         p50 0.08 ms, p95 0.11 ms (frame write without the AX calls)
Command latency:      p50 4.00 ms, p95 9.50 ms
Restarts:             2
Slowest apps (AX write per window):
  teams2 (4173)  p50 12.00 ms, p95 40.50 ms, latency p95 80.00 ms, 340 writes
  Notes (1838)   p50 3.10 ms, p95 6.20 ms, latency p95 9.80 ms, 512 writes
```

- **AX errors**: AX frame writes that failed. `engine.log` names the window, the app, the AX call and the code of the
  first 3 per app and code.
- **Closed-window writes**: writes to a window that closed before Spool knew it. They are not errors and are not
  retried. A Spool that does not report it shows no line.
- **Frame write**: the time from a layout tick until every frame of that tick is on its window, or was
  replaced by a newer frame that is on its window. Apps are written in parallel, so this is the time of the
  slowest app in the tick.
- **Spool's part**: the frame write time without the AX calls of the slowest app in the tick: Spool's own
  code. The AX calls wait for the app and WindowServer. The live budget `frame-own-p95` is 1 ms. A Spool
  that does not report it shows no line.
- **Command latency**: the time from a command until its first frame that moves a window is on the windows. A command that moves
  no window (for example `focus-left` at the first column), a command during a swipe, and a swipe give no sample.
- **Slowest apps**: the 5 apps with the highest p95 AX time for one window write, from the newest 128
  writes of each app. **latency** is from the tick that queued the frame until it was written, so it
  includes the wait for the write before it. An app with a high AX time makes Spool feel slow; quit it or
  float its windows to check.

## Metrics report

`spool report` reads the metrics files in `~/Library/Application Support/Spool/metrics/` and prints a summary:
the live budgets (PASS, FAIL or no data), speed, cost, problems, the most used commands, friction per app and the
slowest apps. It also works when Spool is not running. When Spool runs, the tool first asks it to write the
numbers that are still in memory.

```sh
spool report
spool report --days 30
spool report --json
```

- `--days <n>`: the number of days, 1 to 90. The default is 7. Another value is a usage error (exit code 2).
- `--json`: the full report as JSON (pretty printed, keys sorted).

[METRICS.md](METRICS.md) tells what each number means, and how to turn the metrics off.

## License

Spool costs EUR 0.99, one time. The format of the key is in [LICENSE-KEYS.md](LICENSE-KEYS.md).

```sh
spool license
spool license "$KEY"
```

`$KEY` is the license key from your email.

- `spool license` prints `Licensed to <email> (order <id>)` and exits with 0. Without a valid key it prints
  `Not licensed.` and exits with 1.
- `spool license <key>` sends the key to the running app. The app checks it with its own public key, stores it
  in `license.key` in its data folder and starts the window manager. Use this on a Mac where you cannot click.
  A key that is not valid prints `This license key is not valid.` and exits with 1. White space in the key is
  ignored, so a key that your email client wrapped works.
- Both work while Spool is waiting for a license. Every window command then prints
  "Spool needs a license key. Open Spool, or run spool license <key>." and exits with 1.
- A build from `swift build` has no license check. `spool license` prints `This build of Spool needs no license.`
- `--json` prints the answer of the app with the fields `state`, `email` and `order`. It never holds the key.

## JSON output

Add `--json` to a command or a query to print the full response of the app as JSON
(pretty printed, keys sorted). Use it in scripts, for example to get the window IDs:

```sh
spool state --json | jq '.state.displays[].columns[][].id'
```

`spool list --json` prints all commands and queries with `name`, `usage`, `title` and `url`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK. |
| 1 | The command failed, or the app sent an error. The reason is on stderr. |
| 2 | Usage error: unknown command, wrong argument or unknown option. |
| 3 | Spool is not running. The message is `Spool is not running. Open Spool.app.` |

An unknown command gets a suggestion when it looks like a typo:

```
$ spool focus-lef
Unknown command 'focus-lef'. Did you mean 'focus-left'?
Run 'spool help' for usage.
```

## Socket

The app listens on `~/Library/Application Support/Spool/spool.sock`.
Only your user can connect: the file has mode 0600, and the app checks the user ID of each client.

To use a different socket (for tests or to debug), use `--socket <path>` or set `SPOOL_SOCKET`.
`--socket` has priority over `SPOOL_SOCKET`. The path must be 103 bytes or less.

Test only: when the app starts with `SPOOL_HOME` set, the socket, config, session and logs are in that folder
(logs in `$SPOOL_HOME/Logs`), and `SPOOL_MANAGE_ONLY` limits Spool to the windows of some apps. The live E2E
test uses them. See [E2E.md](E2E.md). Do not use them for normal work.

The tool waits a maximum of 2 seconds for an answer. `start`, `stop`, `toggle-engine` and `restart` wait a maximum of
10 seconds, because the app first moves every window back into view and waits for the apps to answer.

### Wire format

One JSON object per line (UTF-8, with a newline at the end). You can send many requests on one connection.
The app answers in the same order.

```
{"query":"ping"}                 ->  {"ok":true}
{"command":"focus-index-3"}      ->  {"ok":true}
{"command":"mark","note":"slow"} ->  {"ok":true}
{"query":"state"}                ->  {"ok":true,"state":{...}}
{"command":"fly"}                ->  {"error":"Bad request: Unknown command fly","ok":false}
```

The app closes a connection when a line is longer than 1 MB, or after 10 seconds without activity.
A maximum of 16 connections can be open at the same time.

## URL scheme

All commands also work as a `spool://` URL, for example from Shortcuts or a browser.
These forms do the same thing:

```sh
open -g "spool://focus-left"
open -g "spool://command?name=focus-left"
open -g "spool://focus-index/3"
```

The last URL is the same as `spool focus-index 3`.

A URL opens Spool if it is not running. Queries (`ping`, `state`, `stats`) and `report` are not available as URLs.

`spool://license?key=<key>` activates a license key, for example from the link in the email with the key. The key
has only URL-safe characters, so the link needs no encoding. A key that is not valid, or no key, opens the license
window with the error.

`spool://settings/<page>` opens a page of the settings window, for example `open "spool://settings/shortcuts"`.
The pages are `general`, `layout`, `appearance`, `trackpad` (Mouse & Trackpad), `displays`, `rules`, `shortcuts`,
`mac-setup` and `help`. `spool://settings` and `spool://open` open the page that was open last (General after Spool starts).

## Raycast

The folder `Integrations/Raycast` has Raycast Script Commands for the main commands, and a "Spool State" command.
Setup is in [Integrations/Raycast/README.md](../Integrations/Raycast/README.md).
