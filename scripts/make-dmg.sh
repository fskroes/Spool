#!/usr/bin/env bash
# Makes dist/Spool-<version>.dmg from dist/Spool.app. Used by `make dmg`.
# The disk image holds Spool.app and a link to /Applications for drag-to-install.
# SIGN_IDENTITY: when set to a real identity (not "-"), the DMG is signed too.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
# shellcheck source=release-lib.sh
source "$ROOT/scripts/release-lib.sh"

readonly APP="$ROOT/dist/Spool.app"
[[ -d "$APP" ]] || die "$APP not found. Run 'make app' first."
! spool_app_has_test_license_key "$APP" "$ROOT/docs/license-test-vectors.json" \
    || die "$APP has the public test license key of the E2E test (make e2e): anyone can make keys for it. Run 'make dmg', which builds it again."
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")
readonly DMG="$ROOT/dist/Spool-$VERSION.dmg"
readonly STAGE="$ROOT/dist/dmg-stage"

case "$STAGE" in */dist/dmg-stage) rm -rf "$STAGE" ;; *) die "unexpected stage path: $STAGE" ;; esac
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Spool.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "Spool $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"

if [[ -n "${SIGN_IDENTITY:-}" && "${SIGN_IDENTITY}" != "-" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
hdiutil verify -quiet "$DMG"
printf '==> Built %s (%s)\n' "$DMG" "$(du -h "$DMG" | cut -f1)"
