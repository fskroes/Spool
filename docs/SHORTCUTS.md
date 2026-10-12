# Striple shortcuts

All default shortcuts use Control-Option (`⌃⌥`), so plain Option stays free for typing accented characters.
Shift adds "move" to a "focus" shortcut. Command adds "to the end".

You can change every shortcut in **Settings > Shortcuts**. Click a shortcut and press the new keys.
The page shows a warning when two actions use the same keys, or when macOS or another app already owns a combination.
The key names below are for a US layout. The Settings page shows the names for your active keyboard layout.

## Default shortcuts

<!-- shortcuts:begin (generated from DefaultBindings, checked by ShortcutsDocTests) -->
| Action | Default shortcut | CLI |
|---|---|---|
| Focus left | `⌃⌥H` or `⌃⌥←` | `striple focus-left` |
| Focus right | `⌃⌥L` or `⌃⌥→` | `striple focus-right` |
| Focus up in stack | `⌃⌥K` or `⌃⌥↑` | `striple focus-up` |
| Focus down in stack | `⌃⌥J` or `⌃⌥↓` | `striple focus-down` |
| Focus first window | `⌃⌥⌘←` | `striple focus-first` |
| Focus last window | `⌃⌥⌘→` | `striple focus-last` |
| Focus place 1 | `⌃⌥1` | `striple focus-index-1` |
| Focus place 2 | `⌃⌥2` | `striple focus-index-2` |
| Focus place 3 | `⌃⌥3` | `striple focus-index-3` |
| Focus place 4 | `⌃⌥4` | `striple focus-index-4` |
| Focus place 5 | `⌃⌥5` | `striple focus-index-5` |
| Focus place 6 | `⌃⌥6` | `striple focus-index-6` |
| Focus place 7 | `⌃⌥7` | `striple focus-index-7` |
| Focus place 8 | `⌃⌥8` | `striple focus-index-8` |
| Focus last place | `⌃⌥9` | `striple focus-index-9` |
| Move column left | `⌃⌥⇧H` or `⌃⌥⇧←` | `striple move-left` |
| Move column right | `⌃⌥⇧L` or `⌃⌥⇧→` | `striple move-right` |
| Move window up in stack | `⌃⌥⇧K` or `⌃⌥⇧↑` | `striple move-up` |
| Move window down in stack | `⌃⌥⇧J` or `⌃⌥⇧↓` | `striple move-down` |
| Move column to first place | `⌃⌥⇧⌘←` | `striple move-first` |
| Move column to last place | `⌃⌥⇧⌘→` | `striple move-last` |
| Move column to place 1 | `⌃⌥⇧1` | `striple move-to-index-1` |
| Move column to place 2 | `⌃⌥⇧2` | `striple move-to-index-2` |
| Move column to place 3 | `⌃⌥⇧3` | `striple move-to-index-3` |
| Move column to place 4 | `⌃⌥⇧4` | `striple move-to-index-4` |
| Move column to place 5 | `⌃⌥⇧5` | `striple move-to-index-5` |
| Move column to place 6 | `⌃⌥⇧6` | `striple move-to-index-6` |
| Move column to place 7 | `⌃⌥⇧7` | `striple move-to-index-7` |
| Move column to place 8 | `⌃⌥⇧8` | `striple move-to-index-8` |
| Move column to last place | `⌃⌥⇧9` | `striple move-to-index-9` |
| Cycle preset widths | `⌃⌥R` | `striple cycle-width` |
| Full width | `⌃⌥F` | `striple toggle-full-width` |
| Center column | `⌃⌥C` | `striple center-column` |
| Wider | `⌃⌥=` | `striple wider` |
| Narrower | `⌃⌥-` | `striple narrower` |
| Taller (in a stack) | `⌃⌥⇧=` | `striple taller` |
| Shorter (in a stack) | `⌃⌥⇧-` | `striple shorter` |
| Equalize heights | `⌃⌥0` | `striple equalize-heights` |
| Stack into left column | `⌃⌥[` | `striple stack-left` |
| Stack into right column | `⌃⌥]` | `striple stack-right` |
| Pop out of stack to the left | `⌃⌥⇧[` | `striple pop-left` |
| Pop out of stack to the right | `⌃⌥⇧]` | `striple pop-right` |
| Tabbed column | `⌃⌥⇧T` | `striple toggle-tabbed` |
| Float / unfloat | `⌃⌥T` | `striple toggle-float` |
| Send window to next display | `⌃⌥N` | `striple send-to-next-display` |
| Start / stop the window manager | `⌃⌥Q` | `striple toggle-engine` |
<!-- shortcuts:end -->

## Trackpad

| Gesture | Action |
|---|---|
| Swipe left or right with 3 or 4 fingers (Settings > General) | Scroll the strip. Lift with speed to fling; the strip stops on a column edge. |

When Striple uses a finger count, turn off the macOS gesture that uses the same fingers
(Settings > Mac Setup shows which one and opens the right System Settings page).

## Mouse

| Action | Result |
|---|---|
| Drag a tiled window and drop it | The window moves to the gap where you drop it. On another display it joins that display's strip. |
| Resize a tiled window from its edge | The column takes the new width. |
| Move the pointer over a window (Focus follows mouse, off by default) | That window gets focus. |

## Differences from ChainYourMac

Striple is a clean-room app. Its default shortcuts are its own:

- `⌃⌥[` and `⌃⌥]` put the focused window into the stack of the column on the left or right.
- `⌃⌥⇧[` and `⌃⌥⇧]` take the focused window out of its stack, to a new column on the left or right.
- `⌃⌥1` to `⌃⌥9` focus a place in the strip; `9` is always the last column.
