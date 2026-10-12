# Striple for Raycast

Raycast Script Commands for the main Striple commands. Each script runs one `striple` command.

## Add the scripts to Raycast

1. Open Raycast Settings (`⌘ ,`), then **Extensions**.
2. Click **+** and select **Add Script Directory**.
3. Select this folder (`Integrations/Raycast`).

The commands show in Raycast with the package name "Striple". You can give each one a hotkey or an alias
in the Extensions settings.

## How a script finds Striple

1. It uses the `striple` tool. It looks in your `PATH`, then `~/.local/bin/striple` (from `make install`),
   then `/Applications/Striple.app/Contents/Helpers/striple`. Raycast does not read your shell profile,
   so a `PATH` change in `~/.zshrc` has no effect here.
2. If there is no `striple` tool, the script opens the URL `striple://<command>` in the background.
3. If Striple is not running, the script opens the URL. This starts Striple and runs the command.
   "Stop Window Manager" does not start Striple; it only shows "Striple is not running.".

"Striple State" shows the output of `striple state` (displays, columns and windows).

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
| Striple State | `state` |

## Change the scripts

Do not edit the `striple-*.sh` files. Edit the list in `generate.sh`, then run:

```sh
bash Integrations/Raycast/generate.sh
```

The script removes old generated files and writes them again. All other commands are in `docs/CLI.md`
(or run `striple list`).
