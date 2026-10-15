# Spool for Raycast

Raycast Script Commands for the main Spool commands. Each script runs one `spool` command.

## Add the scripts to Raycast

1. Open Raycast Settings (`⌘ ,`), then **Extensions**.
2. Click **+** and select **Add Script Directory**.
3. Select this folder (`Integrations/Raycast`).

The commands show in Raycast with the package name "Spool". You can give each one a hotkey or an alias
in the Extensions settings.

Spool had the name Striple before. If you used the `striple-*.sh` scripts, give the hotkeys and aliases again:
they belong to a script, and the scripts have new names.

## How a script finds Spool

1. It uses the `spool` tool. It looks in your `PATH`, then `~/.local/bin/spool` (from `make install`),
   then `/Applications/Spool.app/Contents/Helpers/spool`. Raycast does not read your shell profile,
   so a `PATH` change in `~/.zshrc` has no effect here.
2. If there is no `spool` tool, the script opens the URL `spool://<command>` in the background.
3. If Spool is not running, the script opens the URL. This starts Spool and runs the command.
   "Stop Window Manager" does not start Spool; it only shows "Spool is not running.".

"Spool State" shows the output of `spool state` (displays, columns and windows).

## Scripts

| Script | Command |
|---|---|
| Focus Left / Right | `focus-left`, `focus-right` |
| Focus Up / Down in Stack | `focus-up`, `focus-down` |
| Move Column Left / Right | `move-left`, `move-right` |
| Cycle Column Width | `cycle-width` |
| Full Width Column | `toggle-full-width` |
| Center Column | `center-column` |
| Tabbed Column | `toggle-tabbed` |
| Stack Into Left / Right Column | `stack-left`, `stack-right` |
| Pop Out of Stack to the Left / Right | `pop-left`, `pop-right` |
| Float or Unfloat Window | `toggle-float` |
| Send Window to Next Display | `send-to-next-display` |
| Start / Stop / Restart Window Manager | `start`, `stop`, `restart` |
| Start or Stop Window Manager | `toggle-engine` |
| Spool State | `state` |

## Change the scripts

Do not edit the `spool-*.sh` files. Edit the list in `generate.sh`, then run:

```sh
bash Integrations/Raycast/generate.sh
```

The script removes old generated files and writes them again. All other commands are in `docs/CLI.md`
(or run `spool list`).
