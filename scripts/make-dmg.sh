#!/usr/bin/env bash
# Makes dist/Striple-<version>.dmg from dist/Striple.app. Used by `make dmg`.
# The disk image holds Striple.app and a link to /Applications for drag-to-install.
# SIGN_IDENTITY: when set to a real identity (not "-"), the DMG is signed too.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

readonly APP="$ROOT/dist/Striple.app"
[[ -d "$APP" ]] || die "$APP not found. Run 'make app' first."
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")
readonly DMG="$ROOT/dist/Striple-$VERSION.dmg"
readonly STAGE="$ROOT/dist/dmg-stage"

case "$STAGE" in */dist/dmg-stage) rm -rf "$STAGE" ;; *) die "unexpected stage path: $STAGE" ;; esac
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Striple.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "Striple $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"

if [[ -n "${SIGN_IDENTITY:-}" && "${SIGN_IDENTITY}" != "-" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
hdiutil verify -quiet "$DMG"
printf '==> Built %s (%s)\n' "$DMG" "$(du -h "$DMG" | cut -f1)"
