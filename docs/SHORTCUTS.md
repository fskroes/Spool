# Spool shortcuts

All default shortcuts use Control-Option (`⌃⌥`), so plain Option stays free for typing accented characters.
Shift adds "move" to a "focus" shortcut. Command adds "to the end".

You can change every shortcut in **Settings > Shortcuts**. Click `+` next to an action and press the new keys.
The page shows the actions in groups (Focus, Move, Width and height, and more). The nine "place" shortcuts of a group
are in one row, for example "Focus place 1 to 9". Click the row to open it. The row opens by itself when you search,
record one of its shortcuts, or when one of its shortcuts has a problem.
A shortcut needs `⌃`, or `⌥` and `⌘` together, or a function key (F1 to F20). The recorder refuses `⌘` alone
(apps use it, for example `⌘W`) and `⌥` alone (it types characters, for example `⌥2` is € and `⌥L` is @ on a German layout).
The page shows a warning when two actions use the same keys, or when macOS or another app already owns a combination.
The key names below are for a US layout. The Settings page shows the names for your active keyboard layout.

## Default shortcuts

<!-- shortcuts:begin (generated from DefaultBindings, checked by ShortcutsDocTests) -->
| Action | Default shortcut | CLI |
|---|---|---|
| Focus left | `⌃⌥H` or `⌃⌥←` | `spool focus-left` |
| Focus right | `⌃⌥L` or `⌃⌥→` | `spool focus-right` |
| Focus up in stack | `⌃⌥K` or `⌃⌥↑` | `spool focus-up` |
| Focus down in stack | `⌃⌥J` or `⌃⌥↓` | `spool focus-down` |
| Focus first window | `⌃⌥⌘←` | `spool focus-first` |
| Focus last window | `⌃⌥⌘→` | `spool focus-last` |
| Focus place 1 | `⌃⌥1` | `spool focus-index-1` |
| Focus place 2 | `⌃⌥2` | `spool focus-index-2` |
| Focus place 3 | `⌃⌥3` | `spool focus-index-3` |
| Focus place 4 | `⌃⌥4` | `spool focus-index-4` |
| Focus place 5 | `⌃⌥5` | `spool focus-index-5` |
| Focus place 6 | `⌃⌥6` | `spool focus-index-6` |
| Focus place 7 | `⌃⌥7` | `spool focus-index-7` |
| Focus place 8 | `⌃⌥8` | `spool focus-index-8` |
| Focus last place | `⌃⌥9` | `spool focus-index-9` |
| Move column left | `⌃⌥⇧H` | `spool move-left` |
| Move column right | `⌃⌥⇧L` | `spool move-right` |
| Move window up in stack | `⌃⌥⇧K` | `spool move-up` |
| Move window down in stack | `⌃⌥⇧J` | `spool move-down` |
| Move column to first place | `⌃⌥⇧⌘←` | `spool move-first` |
| Move column to last place | `⌃⌥⇧⌘→` | `spool move-last` |
| Move column to place 1 | `⌃⌥⇧1` | `spool move-to-index-1` |
| Move column to place 2 | `⌃⌥⇧2` | `spool move-to-index-2` |
| Move column to place 3 | `⌃⌥⇧3` | `spool move-to-index-3` |
| Move column to place 4 | `⌃⌥⇧4` | `spool move-to-index-4` |
| Move column to place 5 | `⌃⌥⇧5` | `spool move-to-index-5` |
| Move column to place 6 | `⌃⌥⇧6` | `spool move-to-index-6` |
| Move column to place 7 | `⌃⌥⇧7` | `spool move-to-index-7` |
| Move column to place 8 | `⌃⌥⇧8` | `spool move-to-index-8` |
| Move column to last place | `⌃⌥⇧9` | `spool move-to-index-9` |
| Cycle preset widths | `⌃⌥R` | `spool cycle-width` |
| Full width | `⌃⌥F` | `spool toggle-full-width` |
| Center column | `⌃⌥C` | `spool center-column` |
| Wider | `⌃⌥=` | `spool wider` |
| Narrower | `⌃⌥-` | `spool narrower` |
| Taller (in a stack) | `⌃⌥⇧=` | `spool taller` |
| Shorter (in a stack) | `⌃⌥⇧-` | `spool shorter` |
| Equalize heights | `⌃⌥0` | `spool equalize-heights` |
| Stack into left column | `⌃⌥[` | `spool stack-left` |
| Stack into right column | `⌃⌥]` | `spool stack-right` |
| Pop out of stack to the left | `⌃⌥⇧[` | `spool pop-left` |
| Pop out of stack to the right | `⌃⌥⇧]` | `spool pop-right` |
| Tabbed column | `⌃⌥⇧T` | `spool toggle-tabbed` |
| Float / unfloat | `⌃⌥T` | `spool toggle-float` |
| Send window to next display | `⌃⌥N` | `spool send-to-next-display` |
| Start / stop the window manager | `⌃⌥Q` | `spool toggle-engine` |
| Mark this moment | `⌃⌥⇧M` | `spool mark` |
<!-- shortcuts:end -->

### Shortcuts that macOS uses

macOS 15 and later use these arrow combinations for window tiling and Spaces (macOS 26, read with
`CGSGetSymbolicHotKeyValue`): `⌃` + arrow, `⌃⇧` + arrow and `⌃⌥⇧` + arrow. Apple writes the tiling ones
with Fn (for example Fn-Control-Option-Shift-Left Arrow, see
[Mac window tiling icons and keyboard shortcuts](https://support.apple.com/guide/mac-help/mchl9674d0b0/mac)),
but arrow keys always send the Fn flag. So Spool has no defaults on these combinations, and
**Settings > Shortcuts** shows a warning if you record one. To use `⌃⌥⇧` + arrow for "move", first turn off
the macOS shortcut in **System Settings > Keyboard > Keyboard Shortcuts > Windows**.

A `config.json` from an earlier version of Spool (version 1) can still have `⌃⌥⇧` + arrow on the move commands.
On macOS 15 and later, Spool removes those four combinations when it reads the file. On macOS 13 and 14 it keeps
them, because macOS does not use them there, and the file stays version 1. A command that is not in your file
(because it is newer than the file) gets its default shortcut, unless your file uses that combination for another
command. On macOS 15 and later, Spool then saves the file once as version 2, so a combination that you add again
later is kept. If you upgrade from macOS 14 to macOS 15, the removal runs once at the first start after the upgrade.

## Trackpad

| Gesture | Action |
|---|---|
| Swipe left or right with 3 or 4 fingers (Settings > Mouse & Trackpad) | Scroll the strip. Lift with speed to fling; the strip stops on a column edge. |

When Spool uses a finger count, turn off the macOS gesture that uses the same fingers
(Settings > Mac Setup shows which one and opens the right System Settings page).

## Mouse

| Action | Result |
|---|---|
| Drag a tiled window and drop it | The window moves to the gap where you drop it. On another display it joins that display's strip. Only the window you pressed the mouse on can be dragged; windows that move because Spool scrolls the strip are never taken for a drag. |
| Resize a tiled window from its edge | The column takes the new width. |
| Move the pointer over a window (Focus follows mouse, off by default) | That window gets focus. |

## Differences from ChainYourMac

Spool is a clean-room app. Its default shortcuts are its own:

- `⌃⌥[` and `⌃⌥]` put the focused window into the stack of the column on the left or right.
- `⌃⌥⇧[` and `⌃⌥⇧]` take the focused window out of its stack, to a new column on the left or right.
- `⌃⌥1` to `⌃⌥9` focus a place in the strip; `9` is always the last column.
