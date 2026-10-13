# Striple command-line tool

The `striple` tool controls the running Striple app from a terminal, a script, Raycast or any
other launcher. It sends one request to the app over a Unix socket and prints the answer.

## Install

- The app has the tool inside: `Striple.app/Contents/Helpers/striple`.
- `make install` links it to `~/.local/bin/striple`. Make sure that `~/.local/bin` is in your `PATH`.
- In a source checkout, `swift build` makes `.build/debug/striple`.

## Usage

```
striple <command> [<n>] [--json] [--socket <path>]
striple report [--days <n>] [--json]
```

Examples:

```sh
striple focus-left
striple focus-index 3
striple command focus-left
striple state
striple stats --json
striple mark Safari jumped to the left
striple report --days 30
striple list
striple help focus-index
striple --version
```

| Command | What it does |
|---|---|
| `striple focus-left` | Focuses the column on the left. |
| `striple focus-index 3` | Focuses place 3. Same as `striple focus-index-3`. |
| `striple command focus-left` | Same as `striple focus-left`. |
| `striple state` | Shows the displays, columns and windows. |
| `striple stats --json` | Shows the performance counters as JSON. |
| `striple mark Safari jumped to the left` | Saves a mark with the note "Safari jumped to the left". |
| `striple report --days 30` | Shows the local metrics of the last 30 days. |
| `striple list` | Shows all commands with a short description. |
| `striple help focus-index` | Shows the help for one command. |
| `striple --version` | Shows the version. |

A command prints nothing when it works. Errors go to stderr.

## Commands

`striple list` shows the same list. Names are not case sensitive, and `_` works as `-`.
For a command with a number, you can write the number as a separate word (`striple focus-index 3`)
or as part of the name (`striple focus-index-3`).

| Command | What it does | URL |
|---|---|---|
| `striple focus-left` | Focus left | `striple://focus-left` |
| `striple focus-right` | Focus right | `striple://focus-right` |
| `striple focus-up` | Focus up in stack | `striple://focus-up` |
| `striple focus-down` | Focus down in stack | `striple://focus-down` |
| `striple focus-first` | Focus first window | `striple://focus-first` |
| `striple focus-last` | Focus last window | `striple://focus-last` |
| `striple focus-index <1-9>` | Focus place &lt;n&gt; (9 is the last place) | `striple://focus-index/3` |
| `striple move-left` | Move column left | `striple://move-left` |
| `striple move-right` | Move column right | `striple://move-right` |
| `striple move-up` | Move window up in stack | `striple://move-up` |
| `striple move-down` | Move window down in stack | `striple://move-down` |
| `striple move-first` | Move column to first place | `striple://move-first` |
| `striple move-last` | Move column to last place | `striple://move-last` |
| `striple move-to-index <1-9>` | Move column to place &lt;n&gt; (9 is the last place) | `striple://move-to-index/3` |
| `striple cycle-width` | Cycle preset widths | `striple://cycle-width` |
| `striple toggle-full-width` | Full width | `striple://toggle-full-width` |
| `striple center-column` | Center column | `striple://center-column` |
| `striple wider` | Wider | `striple://wider` |
| `striple narrower` | Narrower | `striple://narrower` |
| `striple taller` | Taller (in a stack) | `striple://taller` |
| `striple shorter` | Shorter (in a stack) | `striple://shorter` |
| `striple equalize-heights` | Equalize heights | `striple://equalize-heights` |
| `striple stack-left` | Stack into left column | `striple://stack-left` |
| `striple stack-right` | Stack into right column | `striple://stack-right` |
| `striple pop-left` | Pop out of stack to the left | `striple://pop-left` |
| `striple pop-right` | Pop out of stack to the right | `striple://pop-right` |
| `striple toggle-tabbed` | Tabbed column | `striple://toggle-tabbed` |
| `striple toggle-float` | Float / unfloat | `striple://toggle-float` |
| `striple send-to-next-display` | Send window to next display | `striple://send-to-next-display` |
| `striple toggle-engine` | Start / stop the window manager | `striple://toggle-engine` |
| `striple focus-window <id>` | Focus the window with this ID (see striple state --json) | `striple://focus-window/1234` |
| `striple start` | Start | `striple://start` |
| `striple stop` | Stop | `striple://stop` |
| `striple restart` | Restart | `striple://restart` |
| `striple mark [<note>]` | Mark this moment: save the state, the stats and the last minute of the log, with a note | `striple://mark` |

`focus-index 9` and `move-to-index 9` mean the last place, also when there are more than 9 columns.

`striple mark` takes the words after `mark` as the note. Quotes are not necessary. Use a mark when something goes
wrong: Striple writes a new folder in `~/Library/Application Support/Striple/metrics/marks/` and prints its parent
folder. The note is the only text that you type that Striple keeps. Marks need metrics on (Settings > General).
See [METRICS.md](METRICS.md#marks).

## Queries

| Query | What it shows |
|---|---|
| `striple ping` | `Striple is running.` when the app answers. |
| `striple state` | Engine status, the focused window, and the columns of each display. |
| `striple stats` | Uptime, frame and window write counts, AX errors, timings, restarts and the slowest apps. |
| `striple report [--days <n>]` | The local metrics of the last &lt;n&gt; days (1 to 90, default 7). See "Metrics report". |

Example output of `striple state`:

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

Example output of `striple stats`:

```
Uptime:           1h 02m 03s
Frames written:   1200
Window writes:    3400
Skipped writes:   12
Coalesced writes: 40
AX errors:        1
Frame write:      p50 1.20 ms, p95 3.46 ms
Command latency:  p50 4.00 ms, p95 9.50 ms
Restarts:         2
Slowest apps (AX write per window):
  teams2 (4173)  p50 12.00 ms, p95 40.50 ms, latency p95 80.00 ms, 340 writes
  Notes (1838)   p50 3.10 ms, p95 6.20 ms, latency p95 9.80 ms, 512 writes
```

- **Frame write**: the time from a layout tick until every frame of that tick is on its window, or was
  replaced by a newer frame that is on its window. Apps are written in parallel, so this is the time of the
  slowest app in the tick.
- **Slowest apps**: the 5 apps with the highest p95 AX time for one window write, from the newest 128
  writes of each app. **latency** is from the tick that queued the frame until it was written, so it
  includes the wait for the write before it. An app with a high AX time makes Striple feel slow; quit it or
  float its windows to check.

## Metrics report

`striple report` reads the metrics files in `~/Library/Application Support/Striple/metrics/` and prints a summary:
the live budgets (PASS, FAIL or no data), speed, cost, problems, the most used commands, friction per app and the
slowest apps. It also works when Striple is not running. When Striple runs, the tool first asks it to write the
numbers that are still in memory.

```sh
striple report
striple report --days 30
striple report --json
```

- `--days <n>`: the number of days, 1 to 90. The default is 7. Another value is a usage error (exit code 2).
- `--json`: the full report as JSON (pretty printed, keys sorted).

[METRICS.md](METRICS.md) tells what each number means, and how to turn the metrics off.

## JSON output

Add `--json` to a command or a query to print the full response of the app as JSON
(pretty printed, keys sorted). Use it in scripts, for example to get the window IDs:

```sh
striple state --json | jq '.state.displays[].columns[][].id'
```

`striple list --json` prints all commands and queries with `name`, `usage`, `title` and `url`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK. |
| 1 | The command failed, or the app sent an error. The reason is on stderr. |
| 2 | Usage error: unknown command, wrong argument or unknown option. |
| 3 | Striple is not running. The message is `Striple is not running. Open Striple.app.` |

An unknown command gets a suggestion when it looks like a typo:

```
$ striple focus-lef
Unknown command 'focus-lef'. Did you mean 'focus-left'?
Run 'striple help' for usage.
```

## Socket

The app listens on `~/Library/Application Support/Striple/striple.sock`.
Only your user can connect: the file has mode 0600, and the app checks the user ID of each client.

To use a different socket (for tests or to debug), use `--socket <path>` or set `STRIPLE_SOCKET`.
`--socket` has priority over `STRIPLE_SOCKET`. The path must be 103 bytes or less.

Test only: when the app starts with `STRIPLE_HOME` set, the socket, config, session and logs are in that folder
(logs in `$STRIPLE_HOME/Logs`), and `STRIPLE_MANAGE_ONLY` limits Striple to the windows of some apps. The live E2E
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

All commands also work as a `striple://` URL, for example from Shortcuts or a browser.
These forms do the same thing:

```sh
open -g "striple://focus-left"
open -g "striple://command?name=focus-left"
open -g "striple://focus-index/3"
```

The last URL is the same as `striple focus-index 3`.

A URL opens Striple if it is not running. Queries (`ping`, `state`, `stats`) and `report` are not available as URLs.

## Raycast

The folder `Integrations/Raycast` has Raycast Script Commands for the main commands, and a "Striple State" command.
Setup is in [Integrations/Raycast/README.md](../Integrations/Raycast/README.md).
