---
name: verify-spool
description: Run Spool and check it works, with the build log, an isolated app boot over the CLI, the engine log and the website as evidence. Use after any change, before saying done, before a merge, and when a bug report arrives (reproduce on main first).
---

# verify-spool

`scripts/verify` builds Spool, starts an isolated copy of the app, uses it
through the `spool` CLI, checks the website, and returns pass or fail with
evidence. It is one command. Do not write a new verification script.

## Rule

Never say a change is done without a passing `scripts/verify smoke` run.
Paste the last line of its output (the `"event": "summary"` line) in your
report and in the PR body. Paste the line of a full run, without `--only`:
its `"layers"` must be `["build", "cli", "app", "site"]`.

**What a PASS means today: every product builds, the CLI parses and answers,
the app starts with an empty settings folder, answers `ping`, `state`,
`stats` and a window command over its socket, loads its config, stops on
SIGTERM and logs no fatal line, and every page in `site/` has a title, working
local links and only allowed scripts.** It does not mean that windows move
correctly. A PASS alone does not verify a change to tiling, animation, focus,
gestures, overlays or Spaces. For those, run `scripts/verify e2e` (below), and
the unit tests that cover the code you changed.

## When

- After any change, before you say done.
- Before a merge. `bash ~/.claude/scripts/self-merge.sh` runs it for you on
  the rebased head.
- A bug report arrives: run it on `main` first and keep the failing summary.
  Then fix, then run it again. When smoke cannot show the bug (most window
  bugs), write the failing unit test first; that is your reproduction.

## Commands

Run from the repo root (or your worktree).

```sh
scripts/verify smoke
scripts/verify smoke --only cli,app
scripts/verify site
scripts/verify e2e
```

- `smoke`: the layers build, cli, app and site. About 3 s with a warm
  build, 40 s cold.
- `smoke --only cli,app`: only some layers. The build runs first when cli
  or app is asked.
- `site`: only the website checks, no Swift build. Under 1 s.
- `e2e`: the live E2E test, `make e2e` with ad hoc signing. About 3 min.

Needs the Xcode Command Line Tools (`xcode-select --install`) and
`/usr/bin/python3`. Nothing else: a fresh worktree works as is.

Flags: `--out DIR` (evidence folder, must be outside the repo; default
`$TMPDIR/spool-verify/<time>`), `--only LAYERS` (smoke only).

## Read the output

- stdout is JSON lines. One `"event": "check"` line per check, then one
  `"event": "summary"` line. Exit 0 pass, 1 a check failed, 2 bad usage,
  3 could not run (only `e2e`: see below).
- A failed check has `problems`: the exit code and the last lines of the log.
- `artifacts` in the summary is the evidence folder: `build.log`,
  `app-stdout.log`, `engine.log`, `state.json`, `summary.json`, and for `e2e`
  the folder `e2e/` with `report.md` (docs/E2E.md, "The report").

## The isolated boot

The `app` layer starts `.build/debug/SpoolApp` with:

- `SPOOL_HOME` set to a new temporary folder: no read or write of the
  user's settings, session, logs or socket.
- `SPOOL_MANAGE_ONLY` set and empty: Spool manages no app, also when the
  terminal has the Accessibility permission (`Policy.manageOnlyBundleIDs`).
- a `config.json` with `"bindings": {}`: no global hotkey is registered, so
  it cannot take ⌃⌥ keys from the user's own Spool.

So it is safe next to a running Spool and on a Mac where someone works. It
stops the app and deletes the folder at the end, also on SIGINT, SIGTERM and
SIGHUP.

## e2e

`scripts/verify e2e` runs `make e2e` with `SIGN_IDENTITY=-`. It moves the
windows of a test app on the real display and needs: the Accessibility
permission for the process that runs it, an unlocked screen, and no other
Spool running. When one of these is missing, the runner refuses (docs/E2E.md,
exit 2) and verify reports the check as `skipped` with the reason and exits 3.
A skipped e2e is not a pass. Say so in the report and name what was not
checked.

## What it checks, and what it does not

It checks: `swift build` of every product; `spool --help`, `list --json`,
an unknown command (exit 2) and `ping` with no server (exit 3); the app boot
above; every `*.html` under `site/` (found from the files, not a list) for a
`<title>`, local links and `#` anchors that resolve, no plain `http://`, and
scripts only from cdnjs, jsdelivr or unpkg; `site/CNAME` is `spool.1yc.dev`.

It does not check:

- Window placement, animation, focus, swipes, overlays, Spaces or displays.
  The unit tests (`make test`) and `scripts/verify e2e` cover those.
- Performance. Run `make bench` after a change in `Sources/SpoolCore` or
  the frame path of `Sources/SpoolEngine`, and compare with the table in
  README.md.
- The signed release app (`make app`, `make dmg`). Signing needs the
  maintainer's identity.
- The website's look. Open `site/index.html` in a browser and look at it at
  desktop and 375 px width, in light and dark.

Verify reads no secret. Everything it starts gets only `PATH`, `HOME`,
`USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `TERM`, `LANG`, `LC_*`,
`DEVELOPER_DIR`, `SDKROOT`, `TOOLCHAINS` and `__CF_USER_TEXT_ENCODING` from
your environment, plus the `SPOOL_*` values that verify sets itself. Keys,
tokens, `SSH_AUTH_SOCK` and every other variable stay out.

Limits of the cleanup: verify stops the app and removes the temporary home
on Ctrl-C, `SIGTERM` and `SIGHUP`. A `kill -9` of verify cannot run the
cleanup, and the app runs in its own process group. After a `kill -9`, run
`pkill -f '/\.build/.*/SpoolApp$'` to stop a left-over app. It matches only
an app started from a `.build` folder, never `/Applications/Spool.app`. The evidence folder
(`--out`, default `$TMPDIR/spool-verify/<time>`) stays after the run, so
you can read it. Verify never removes it.

`make test` still runs the unit tests. Verify does not replace it.
