# Changelog

Each release has a section here. `scripts/release.sh` copies the section into the update window and into the GitHub release, so write for the person who uses Striple.

## 0.1.0

The first release of Striple.

- An endless horizontal strip of windows per display and per Space. A new window never makes the other windows smaller.
- Stacks, tabbed columns, preset widths, full width, and gaps that respect the Dock and the menu bar.
- Spring animations, a focus border, dimming, and a minimap when the view moves. Windows start to move in the same moment as the shortcut, and keep one size while they move, so apps redraw less. The first frame fits the refresh rate of the display, also on 120 Hz ProMotion displays.
- Trackpad swipes with 3 or 4 fingers. Drag a window to move it in the strip. After you let go, the window moves from where you dropped it and does not flash back to its old place.
- One strip per display. The strips come back after a restart of the app.
- Per-app rules, smart floating for dialogs, and no focus stealing.
- A `striple` CLI, a URL scheme and Raycast scripts. `striple stats` shows writes to a window that closed during a move apart from AX errors, and the engine log names the window, app and error code of a failed write.
- Updates with Sparkle. The app is signed with a stable local identity, so macOS keeps the Accessibility permission after an update.
- If System Settings shows Striple on but Striple still asks for the Accessibility permission, click Settings > Mac Setup > Reset Permission. Striple removes its own old entry and asks again.
