# Changelog

Each release has a section here. `scripts/release.sh` copies the section into the update window and into the GitHub release, so write for the person who uses Striple.

## 0.1.0

The first release of Striple.

- An endless horizontal strip of windows per display and per Space. A new window never makes the other windows smaller.
- Stacks, tabbed columns, preset widths, full width, and gaps that respect the Dock and the menu bar.
- Spring animations, a focus border, dimming, and a minimap when the view moves. Windows start to move in the same moment as the shortcut, and keep one size while they move, so apps redraw less.
- Trackpad swipes with 3 or 4 fingers. Drag a window to move it in the strip.
- One strip per display. The strips come back after a restart of the app.
- Per-app rules, smart floating for dialogs, and no focus stealing.
- A `striple` CLI, a URL scheme and Raycast scripts.
- Updates with Sparkle. The app is signed with a stable local identity, so macOS keeps the Accessibility permission after an update.
