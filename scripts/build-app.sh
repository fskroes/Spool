#!/usr/bin/env bash
# Builds and signs dist/Striple.app. Used by `make app`.
#
# Environment (all optional):
#   SIGN_IDENTITY          codesign identity. Default: "Striple Local Signing" when
#                          scripts/make-signing-cert.sh made it, else "-" (ad hoc).
#   STRIPLE_ARCHS          architectures to build. Default: "arm64 x86_64" (universal).
#   STRIPLE_FEED_URL       Sparkle appcast URL (https). Default: from Packaging/updates.env.
#   STRIPLE_ED_PUBLIC_KEY  Sparkle EdDSA public key. Default: from Packaging/updates.env.
#   STRIPLE_UPDATES        "off" builds without Sparkle updates (no feed, no key).
#
# The script does not install, open or register anything.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

readonly BUNDLE_ID="com.fskroes.Striple"
# shellcheck source=signing-env.sh
source "$ROOT/scripts/signing-env.sh"
# shellcheck source=release-lib.sh
source "$ROOT/scripts/release-lib.sh"
readonly AGENT_PLIST="com.fskroes.Striple.agent.plist"
readonly DIST="$ROOT/dist"
readonly APP="$DIST/Striple.app"
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
case "${STRIPLE_UPDATES:-on}" in
    off) FEED_URL=""; ED_KEY="" ;;
    on)
        FEED_URL=${STRIPLE_FEED_URL:-$(striple_updates_value "$UPDATES_ENV" STRIPLE_FEED_URL)}
        ED_KEY=${STRIPLE_ED_PUBLIC_KEY:-$(striple_updates_value "$UPDATES_ENV" STRIPLE_ED_PUBLIC_KEY)}
        ;;
    *) die "STRIPLE_UPDATES must be on or off" ;;
esac
if [[ -n "$FEED_URL" || -n "$ED_KEY" ]]; then
    [[ -n "$FEED_URL" && -n "$ED_KEY" ]] || die "set both STRIPLE_FEED_URL and STRIPLE_ED_PUBLIC_KEY, or neither"
    [[ "$FEED_URL" == https://* ]] || die "STRIPLE_FEED_URL must use https"
fi

# Signing identity. LOCAL: the self-signed identity of make-signing-cert.sh (by its SHA-1, so a
# certificate with the same name in another keychain is never used).
LOCAL=0
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    IDENTITY=$SIGN_IDENTITY
elif IDENTITY=$(striple_signing_identity); then
    LOCAL=1
else
    IDENTITY="-"
fi
# Hardened runtime and secure timestamps need an Apple-issued identity (Developer ID or
# Apple Development). With ad hoc or the self-signed local identity there is no Team ID,
# so library validation under the hardened runtime would refuse to load Sparkle.
SIGN_FLAGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" && $LOCAL -eq 0 && "$IDENTITY" != "$STRIPLE_SIGNING_NAME" ]]; then
    SIGN_FLAGS+=(--options runtime --timestamp)
fi

# Build. Both products in one configuration so they share one build directory.
read -r -a ARCHS <<< "${STRIPLE_ARCHS:-arm64 x86_64}"
ARCH_FLAGS=()
for arch in "${ARCHS[@]}"; do ARCH_FLAGS+=(--arch "$arch"); done
log "Building Striple $VERSION ($BUILD) for ${ARCHS[*]}"
swift build -c release "${ARCH_FLAGS[@]}" --product StripleApp
swift build -c release "${ARCH_FLAGS[@]}" --product striple
BIN=$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)
[[ -x "$BIN/StripleApp" && -x "$BIN/striple" ]] || die "build products not found in $BIN"

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
    */dist/Striple.app) rm -rf "$APP" ;;
    *) die "refusing to delete unexpected path: $APP" ;;
esac
CONTENTS="$APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/Resources" \
    "$CONTENTS/Frameworks" "$CONTENTS/Library/LaunchAgents"

ditto "$BIN/StripleApp" "$CONTENTS/MacOS/Striple"
ditto "$BIN/striple" "$CONTENTS/Helpers/striple"
# Remove the debug map (STABS). It holds absolute paths of this Mac, with the user name, and the
# app does not need it. Symbols for crash reports stay. The binaries are signed again below.
strip -S -no_code_signature_warning "$CONTENTS/MacOS/Striple" "$CONTENTS/Helpers/striple"
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
    log "Sparkle updates off (STRIPLE_UPDATES=off, or no feed in Packaging/updates.env)"
fi
plutil -convert xml1 "$PLIST"
if grep -q '__STRIPLE_' "$PLIST"; then die "unreplaced placeholder in Info.plist"; fi

# rpath: the app loads @rpath/Sparkle.framework from Contents/Frameworks.
MAIN="$CONTENTS/MacOS/Striple"
rpaths() { otool -l "$1" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' | sort -u; }
if [[ $'\n'"$(rpaths "$MAIN")"$'\n' != *$'\n@executable_path/../Frameworks\n'* ]]; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$MAIN"
fi
# Drop rpaths that point into the build machine's toolchain; nothing in the bundle needs them.
for binary in "$MAIN" "$CONTENTS/Helpers/striple"; do
    for path in $(rpaths "$binary"); do
        case "$path" in
            /Library/Developer/*|/Applications/Xcode*) install_name_tool -delete_rpath "$path" "$binary" ;;
        esac
    done
done
[[ "$(otool -L "$MAIN")" == *"@rpath/Sparkle.framework/"* ]] || die "app binary does not link @rpath/Sparkle.framework"

# Sign inside-out. No --deep (Sparkle and Apple both advise against it for signing).
if [[ "$IDENTITY" == "-" ]]; then
    warn "signing ad hoc. macOS forgets the Accessibility grant after each rebuild."
    warn "run scripts/make-signing-cert.sh once to get a stable local identity (see docs/INSTALL.md)."
fi
if [[ $LOCAL -eq 1 ]]; then
    log "Signing with identity: $STRIPLE_SIGNING_NAME ($IDENTITY)"
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
sign --identifier "$BUNDLE_ID.cli" "$CONTENTS/Helpers/striple"
sign "$APP"

# Verify.
log "Verifying"
plutil -lint "$PLIST" "$CONTENTS/Library/LaunchAgents/$AGENT_PLIST"
codesign --verify --deep --strict "$APP"
if [[ $LOCAL -eq 1 ]]; then
    # The Accessibility permission stays only while the requirement names the certificate, not a cdhash.
    [[ "$(codesign -d -r - "$APP" 2>&1)" == *"identifier \"$BUNDLE_ID\" and certificate leaf = H\""* ]] \
        || die "the designated requirement does not name the local certificate"
fi
[[ -e "$SPARKLE/Versions/B/Sparkle" ]] || die "Sparkle binary missing in the bundle"

SIZE=$(du -sh "$APP" | cut -f1)
log "Built $APP ($SIZE, version $VERSION build $BUILD, ${ARCHS[*]})"
