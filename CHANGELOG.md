# Changelog

Each release has a section here. `scripts/release.sh` copies the section into the update window and into the GitHub release, so write for the person who uses Striple.

## Unreleased

- The settings window looks like System Settings. The sidebar goes to the top of the window, each page has a coloured icon, and the page name shows above the page.
- The General page is now four pages: General, Layout, Appearance, and Mouse & Trackpad. Each page fits on the screen with less scrolling.
- Shortcuts are in groups: Focus, Move, Width and height, Stacks and tabs, Windows and displays, and Striple. The nine "place" shortcuts of a group are folded into one row, for example "Focus place 1 to 9 ⌃⌥1 to ⌃⌥9". The row opens when you click it, search, record one of them, or when one of them has a conflict or macOS refuses it.
- While a Striple window is open (Settings, the guide, About or an update window), Striple has a Dock icon, a place in ⌘Tab, and a menu bar with About, Check for Updates, Settings, Hide, Quit, the Edit and Window menus, and a Help menu. A click on the Dock icon brings the open window to the front, also when it is minimized. When you close the last window, Striple is a menu bar app again. Hide Striple does not hide the focus border, the dimming or the tab bars.
- Settings and Mac Setup come to the front when you open them from the Striple menu in the menu bar. When Striple comes to the front, the dimming stays below the window that had the focus. With the dimming on, all open Striple windows come along, also when you click only one of them, so none of them stays dimmed.
- New `striple://settings/` pages: `layout`, `appearance` and `trackpad`.

## 0.1.0

The first release of Striple.

- An endless horizontal strip of windows per display and per Space. A new window never makes the other windows smaller.
- Stacks, tabbed columns, preset widths, full width, and gaps that respect the Dock and the menu bar.
- Spring animations, a focus border, dimming, and a minimap when the view moves. Windows start to move in the same moment as the shortcut, and keep one size while they move, so apps redraw less. The first frame fits the refresh rate of the display, also on 120 Hz ProMotion displays.
- The minimap shows the app icon of each window when its block is large enough. During a swipe it highlights the window that gets focus if you stop and lift your fingers there.
- Trackpad swipes with 3 or 4 fingers. Drag a window to move it in the strip. After you let go, the window moves from where you dropped it and does not flash back to its old place.
- One strip per display. The strips come back after a restart of the app.
- Per-app rules, smart floating for dialogs, and no focus stealing.
- A `striple` CLI, a URL scheme and Raycast scripts. `striple stats` shows writes to a window that closed during a move apart from AX errors, and the engine log names the window, app and error code of a failed write.
- Updates with Sparkle. The app is signed with a stable local identity, so macOS keeps the Accessibility permission after an update.
- If System Settings shows Striple on but Striple still asks for the Accessibility permission, click Settings > Mac Setup > Reset Permission. Striple removes its own old entry and asks again.
