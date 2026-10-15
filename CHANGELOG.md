# Changelog

Each release has a section here. `scripts/release.sh` copies the section into the update window and into the GitHub release, so write for the person who uses Spool.

## Unreleased

- Striple is now Spool. The app, the `spool` CLI, the `spool://` URL scheme and the Raycast scripts have the new name. `make install` removes Striple, and Spool moves your settings, layout and logs from the Striple folders at its first start. If Launch at login was on, it stays on. Give Spool the Accessibility permission once. See "Upgrade from Striple" in docs/INSTALL.md.
- The settings window looks like System Settings. The sidebar goes to the top of the window, each page has a coloured icon, and the page name shows above the page.
- The General page is now four pages: General, Layout, Appearance, and Mouse & Trackpad. Each page fits on the screen with less scrolling.
- Shortcuts are in groups: Focus, Move, Width and height, Stacks and tabs, Windows and displays, and Spool. The nine "place" shortcuts of a group are folded into one row, for example "Focus place 1 to 9 ⌃⌥1 to ⌃⌥9". The row opens when you click it, search, record one of them, or when one of them has a conflict or macOS refuses it.
- While a Spool window is open (Settings, the guide, About or an update window), Spool has a Dock icon, a place in ⌘Tab, and a menu bar with About, Check for Updates, Settings, Hide, Quit, the Edit and Window menus, and a Help menu. A click on the Dock icon brings the open window to the front, also when it is minimized. When you close the last window, Spool is a menu bar app again. Hide Spool does not hide the focus border, the dimming or the tab bars.
- Settings and Mac Setup come to the front when you open them from the Spool menu in the menu bar. When Spool comes to the front, the dimming stays below the window that had the focus. With the dimming on, all open Spool windows come along, also when you click only one of them, so none of them stays dimmed.
- New `spool://settings/` pages: `layout`, `appearance` and `trackpad`.

## 0.1.0

The first release of Spool.

- An endless horizontal strip of windows per display and per Space. A new window never makes the other windows smaller.
- Stacks, tabbed columns, preset widths, full width, and gaps that respect the Dock and the menu bar.
- Spring animations, a focus border, dimming, and a minimap when the view moves. Windows start to move in the same moment as the shortcut, and keep one size while they move, so apps redraw less. The first frame fits the refresh rate of the display, also on 120 Hz ProMotion displays.
- The minimap shows the app icon of each window when its block is large enough. During a swipe it highlights the window that gets focus if you stop and lift your fingers there.
- Trackpad swipes with 3 or 4 fingers. Drag a window to move it in the strip. After you let go, the window moves from where you dropped it and does not flash back to its old place.
- One strip per display. The strips come back after a restart of the app.
- Per-app rules, smart floating for dialogs, and no focus stealing.
- A `spool` CLI, a URL scheme and Raycast scripts. `spool stats` shows writes to a window that closed during a move apart from AX errors, and the engine log names the window, app and error code of a failed write.
- Updates with Sparkle. The app is signed with a stable local identity, so macOS keeps the Accessibility permission after an update.
- If System Settings shows Spool on but Spool still asks for the Accessibility permission, click Settings > Mac Setup > Reset Permission. Spool removes its own old entry and asks again.
