#!/usr/bin/env bash
# Builds and signs dist/Spool.app. Used by `make app`.
#
# Environment (all optional):
#   SIGN_IDENTITY          codesign identity. Default: the "Developer ID Application" identity of
#                          the team in Packaging/updates.env (SPOOL_TEAM_ID), the identity of the
#                          releases. Else "Striple Local Signing" when scripts/make-signing-cert.sh
#                          made it. When a team is set and neither is found, the build stops.
#                          Without a team: "-" (ad hoc).
#                          SIGN_IDENTITY=- makes an ad hoc test build on purpose.
#   SPOOL_ARCHS            architectures to build. Default: "arm64 x86_64" (universal).
#   SPOOL_FEED_URL         Sparkle appcast URL (https). Default: from Packaging/updates.env.
#   SPOOL_ED_PUBLIC_KEY    Sparkle EdDSA public key. Default: from Packaging/updates.env.
#   SPOOL_UPDATES          "off" builds without Sparkle updates (no feed, no key).
#   SPOOL_LICENSE_PUBLIC_KEY  the public key that checks license keys (32 bytes, base64), written to
#                          SpoolLicensePublicKey in Info.plist. Default: from Packaging/updates.env.
#                          make e2e sets the public test key of docs/license-test-vectors.json.
#                          Without a key the app asks for a license that it cannot accept.
#   SPOOL_E2E_BUILD        "1" only for make e2e: compiles with SPOOL_E2E, so the ad hoc E2E app trusts its
#                          Info.plist key without the signature of the release team. Never for a release.
#
# The script does not install, open or register anything.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

readonly BUNDLE_ID="com.fskroes.Spool"
# shellcheck source=signing-env.sh
source "$ROOT/scripts/signing-env.sh"
# shellcheck source=release-lib.sh
source "$ROOT/scripts/release-lib.sh"
readonly AGENT_PLIST="com.fskroes.Spool.agent.plist"
readonly DIST="$ROOT/dist"
readonly APP="$DIST/Spool.app"
readonly ICON_DIR="$ROOT/.build/icon"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for tool in swift codesign plutil ditto otool install_name_tool iconutil git; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done

# Version and build number.
[[ -f VERSION ]] || die "VERSION file not found"
VERSION=$(tr -d '[:space:]' < VERSION)
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "VERSION must look like 1.2.3, got '$VERSION'"
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
YEAR=$(git log -1 --format=%cd --date=format:%Y 2>/dev/null || date +%Y)

# Sparkle feed: both values or neither.
# The environment overrides Packaging/updates.env.
UPDATES_ENV="$ROOT/Packaging/updates.env"
case "${SPOOL_UPDATES:-on}" in
    off) FEED_URL=""; ED_KEY="" ;;
    on)
        FEED_URL=${SPOOL_FEED_URL:-$(spool_updates_value "$UPDATES_ENV" SPOOL_FEED_URL)}
        ED_KEY=${SPOOL_ED_PUBLIC_KEY:-$(spool_updates_value "$UPDATES_ENV" SPOOL_ED_PUBLIC_KEY)}
        ;;
    *) die "SPOOL_UPDATES must be on or off" ;;
esac
if [[ -n "$FEED_URL" || -n "$ED_KEY" ]]; then
    [[ -n "$FEED_URL" && -n "$ED_KEY" ]] || die "set both SPOOL_FEED_URL and SPOOL_ED_PUBLIC_KEY, or neither"
    [[ "$FEED_URL" == https://* ]] || die "SPOOL_FEED_URL must use https"
fi

# License key: the public key that checks the license keys. It is independent of the update feed. The
# environment overrides Packaging/updates.env, like the feed values. Empty is allowed (a build for tests of the
# build), but the app then asks for a license that no key can open.
LICENSE_KEY=${SPOOL_LICENSE_PUBLIC_KEY:-$(spool_updates_value "$UPDATES_ENV" SPOOL_LICENSE_PUBLIC_KEY)}
if [[ -n "$LICENSE_KEY" ]]; then
    spool_license_key_valid "$LICENSE_KEY" \
        || die "SPOOL_LICENSE_PUBLIC_KEY is not a 32-byte public key in base64: $LICENSE_KEY"
else
    warn "no SPOOL_LICENSE_PUBLIC_KEY (environment or Packaging/updates.env). This app will ask for a license"
    warn "that it cannot accept. Fix: make the key pair once with spool-license keygen, then put the public key in"
    warn "Packaging/updates.env (docs/RELEASING.md, \"License keys\")."
fi
# An E2E app trusts its Info.plist key without the signature of the team. With the real key it would be a
# team-signed app that any edited Info.plist unlocks. Checked before any keychain call.
if [[ "${SPOOL_E2E_BUILD:-}" == 1 ]]; then
    TEST_KEYS=$(spool_license_test_keys "$ROOT/docs/license-test-vectors.json") \
        || die "cannot read the test keys of docs/license-test-vectors.json"
    [[ -n "$LICENSE_KEY" ]] && grep -qxF -- "$LICENSE_KEY" <<< "$TEST_KEYS" \
        || die "SPOOL_E2E_BUILD=1 needs a public test key of docs/license-test-vectors.json as SPOOL_LICENSE_PUBLIC_KEY (make e2e sets it)"
fi

# Signing identity. Packaging/updates.env names the team of the releases (SPOOL_TEAM_ID). A
# "Developer ID Application" identity of that team signs like a release: the Accessibility permission
# stays after a rebuild and after every update. Else LOCAL: the self-signed identity of
# make-signing-cert.sh (by its SHA-1, so a certificate with the same name in another keychain is never
# used).
LOCAL=0
RELEASE=0
TEAM=$(spool_updates_value "$UPDATES_ENV" SPOOL_TEAM_ID)
[[ -z "$TEAM" ]] || spool_team_id_valid "$TEAM" || die "SPOOL_TEAM_ID in Packaging/updates.env is not a Team ID: $TEAM"
DEVID=""
LOCAL_HASH=""
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    [[ -z "$TEAM" ]] || DEVID=$(spool_developer_id "$TEAM") || DEVID=""
    [[ -n "$DEVID" ]] || LOCAL_HASH=$(spool_signing_identity) || LOCAL_HASH=""
fi
case "$(spool_build_identity "$TEAM" "$DEVID" "$LOCAL_HASH" "${SIGN_IDENTITY:-}")" in
    explicit) IDENTITY=$SIGN_IDENTITY ;;
    release) IDENTITY=$DEVID; RELEASE=1 ;;
    local) IDENTITY=$LOCAL_HASH; LOCAL=1 ;;
    missing) die "$(spool_missing_identity_message "$TEAM")" ;;
    *) IDENTITY="-" ;;
esac
# Hardened runtime and secure timestamps need an Apple-issued identity (Developer ID or
# Apple Development). With ad hoc or the self-signed local identity there is no Team ID,
# so library validation under the hardened runtime would refuse to load Sparkle.
# Notarization needs both.
SIGN_FLAGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" && $LOCAL -eq 0 && "$IDENTITY" != "$SPOOL_SIGNING_NAME" ]]; then
    SIGN_FLAGS+=(--options runtime --timestamp)
fi

# A release build trusts its license public key only with a signature of the team of the releases
# (LicenseKeeper.trustRequirement). Signed another way, it asks for a license that no key can open.
if [[ $RELEASE -eq 0 && "${SPOOL_E2E_BUILD:-}" != 1 ]]; then
    warn "this app is not signed with the Developer ID of team ${TEAM:-?}: it cannot be licensed and its window"
    warn "manager does not start. Only a build signed by the team of the releases accepts a license key."
fi

# Build. Both products in one configuration so they share one build directory.
read -r -a ARCHS <<< "${SPOOL_ARCHS:-arm64 x86_64}"
ARCH_FLAGS=()
for arch in "${ARCHS[@]}"; do ARCH_FLAGS+=(--arch "$arch"); done
if [[ "${SPOOL_E2E_BUILD:-}" == 1 ]]; then
    ARCH_FLAGS+=(-Xswiftc -DSPOOL_E2E)
    warn "E2E build (SPOOL_E2E_BUILD=1): the app trusts its license key without the signature of the team"
fi
log "Building Spool $VERSION ($BUILD) for ${ARCHS[*]}"
swift build -c release "${ARCH_FLAGS[@]}" --product SpoolApp
swift build -c release "${ARCH_FLAGS[@]}" --product spool
BIN=$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)
[[ -x "$BIN/SpoolApp" && -x "$BIN/spool" ]] || die "build products not found in $BIN"

# Sparkle.framework from the SwiftPM binary artifact.
SPARKLE_SRC=$(find "$ROOT/.build/artifacts" -path '*Sparkle.xcframework/macos-*/Sparkle.framework' -type d -print -quit 2>/dev/null || true)
[[ -n "$SPARKLE_SRC" ]] || die "Sparkle.framework not found in .build/artifacts (run: swift package resolve)"

# App icon, regenerated when missing or older than its script.
if [[ ! -f "$ICON_DIR/AppIcon.icns" || "$ROOT/scripts/make-icon.swift" -nt "$ICON_DIR/AppIcon.icns" ]]; then
    log "Generating AppIcon.icns"
    mkdir -p "$ICON_DIR"
    swift "$ROOT/scripts/make-icon.swift" "$ICON_DIR" >/dev/null
fi

# Assemble a fresh bundle.
log "Assembling $APP"
case "$APP" in
    */dist/Spool.app) rm -rf "$APP" ;;
    *) die "refusing to delete unexpected path: $APP" ;;
esac
CONTENTS="$APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/Resources" \
    "$CONTENTS/Frameworks" "$CONTENTS/Library/LaunchAgents"

ditto "$BIN/SpoolApp" "$CONTENTS/MacOS/Spool"
ditto "$BIN/spool" "$CONTENTS/Helpers/spool"
# Remove the debug map (STABS). It holds absolute paths of this Mac, with the user name, and the
# app does not need it. Symbols for crash reports stay. The binaries are signed again below.
strip -S -no_code_signature_warning "$CONTENTS/MacOS/Spool" "$CONTENTS/Helpers/spool"
ditto "$ICON_DIR/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
ditto "$SPARKLE_SRC" "$CONTENTS/Frameworks/Sparkle.framework"
ditto "$ROOT/Packaging/LaunchAgents/$AGENT_PLIST" "$CONTENTS/Library/LaunchAgents/$AGENT_PLIST"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# Info.plist from the template.
PLIST="$CONTENTS/Info.plist"
ditto "$ROOT/Packaging/Info.plist" "$PLIST"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$BUILD" "$PLIST"
plutil -replace NSHumanReadableCopyright -string "Copyright © $YEAR fskroes. All rights reserved." "$PLIST"
if [[ -n "$FEED_URL" ]]; then
    plutil -replace SUFeedURL -string "$FEED_URL" "$PLIST"
    plutil -replace SUPublicEDKey -string "$ED_KEY" "$PLIST"
    plutil -replace SUEnableAutomaticChecks -bool YES "$PLIST"
    log "Sparkle updates on: $FEED_URL"
else
    log "Sparkle updates off (SPOOL_UPDATES=off, or no feed in Packaging/updates.env)"
fi
if [[ -n "$LICENSE_KEY" ]]; then
    plutil -replace SpoolLicensePublicKey -string "$LICENSE_KEY" "$PLIST"
    log "License public key: $LICENSE_KEY"
else
    log "No license public key: the app is unlicensed"
fi
plutil -convert xml1 "$PLIST"
if grep -q '__SPOOL_' "$PLIST"; then die "unreplaced placeholder in Info.plist"; fi

# rpath: the app loads @rpath/Sparkle.framework from Contents/Frameworks.
MAIN="$CONTENTS/MacOS/Spool"
rpaths() { otool -l "$1" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' | sort -u; }
if [[ $'\n'"$(rpaths "$MAIN")"$'\n' != *$'\n@executable_path/../Frameworks\n'* ]]; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$MAIN"
fi
# Drop rpaths that point into the build machine's toolchain; nothing in the bundle needs them.
for binary in "$MAIN" "$CONTENTS/Helpers/spool"; do
    for path in $(rpaths "$binary"); do
        case "$path" in
            /Library/Developer/*|/Applications/Xcode*) install_name_tool -delete_rpath "$path" "$binary" ;;
        esac
    done
done
[[ "$(otool -L "$MAIN")" == *"@rpath/Sparkle.framework/"* ]] || die "app binary does not link @rpath/Sparkle.framework"

# Sign inside-out. No --deep (Sparkle and Apple both advise against it for signing).
if [[ "$IDENTITY" == "-" ]]; then
    warn "signing ad hoc. An Accessibility grant for this build stops working after the next build,"
    warn "and the switch in System Settings still shows on. Then use Settings > Mac Setup > Reset Permission."
    warn "$(spool_stable_identity_hint "$TEAM")"
fi
if [[ $RELEASE -eq 1 ]]; then
    log "Signing with the Developer ID of team $TEAM ($IDENTITY)"
elif [[ $LOCAL -eq 1 ]]; then
    log "Signing with identity: $SPOOL_SIGNING_NAME ($IDENTITY)"
else
    log "Signing with identity: $IDENTITY"
fi
SPARKLE="$CONTENTS/Frameworks/Sparkle.framework"
sign() { codesign "${SIGN_FLAGS[@]}" "$@"; }
for xpc in "$SPARKLE"/Versions/B/XPCServices/*.xpc; do
    [[ -e "$xpc" ]] || continue
    if [[ "$(basename "$xpc")" == "Downloader.xpc" ]]; then
        sign --preserve-metadata=entitlements "$xpc"
    else
        sign "$xpc"
    fi
done
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --identifier "$BUNDLE_ID.cli" "$CONTENTS/Helpers/spool"
sign "$APP"

# Verify.
log "Verifying"
plutil -lint "$PLIST" "$CONTENTS/Library/LaunchAgents/$AGENT_PLIST"
codesign --verify --deep --strict "$APP"
DR=$(codesign -d -r - "$APP" 2>&1)
if [[ $RELEASE -eq 1 ]]; then
    # The Accessibility permission of a release stays while the requirement names the team.
    spool_dr_is_team "$DR" "$BUNDLE_ID" "$TEAM" || die "the designated requirement does not name the team $TEAM"
elif [[ $LOCAL -eq 1 ]]; then
    # The Accessibility permission stays only while the requirement names the certificate, not a cdhash.
    [[ "$DR" == *"identifier \"$BUNDLE_ID\" and certificate leaf = H\""* ]] \
        || die "the designated requirement does not name the local certificate"
fi
if [[ -n "$TEAM" && "$IDENTITY" != "-" ]] && ! spool_dr_is_team "$DR" "$BUNDLE_ID" "$TEAM"; then
    warn "this build is not signed by the team $TEAM of the releases (signed with: $IDENTITY).
Releases are signed by that team. After an update to a release, the Accessibility entry of this copy
stops working, while the switch still shows on. Then click Settings > Mac Setup > Reset Permission.
See docs/INSTALL.md."
fi
[[ -e "$SPARKLE/Versions/B/Sparkle" ]] || die "Sparkle binary missing in the bundle"

SIZE=$(du -sh "$APP" | cut -f1)
log "Built $APP ($SIZE, version $VERSION build $BUILD, ${ARCHS[*]})"
