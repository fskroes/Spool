#!/usr/bin/env bash
# Publishes a Striple release on GitHub, in the public repository from Packaging/updates.env.
# Used by `make publish` and `make publish-dry`. See docs/RELEASING.md.
#
#   1. Checks: a clean tree on main, a VERSION higher than the published one, a CHANGELOG.md
#      section for VERSION, the Sparkle private key matches Packaging/updates.env, and the local
#      signing identity exists (scripts/make-signing-cert.sh).
#   2. Builds dist/Striple.app (universal, updates on) and checks its Info.plist and signature.
#   3. Makes dist/release/<version>/: Striple-<version>.zip (the Sparkle archive), Striple.dmg,
#      appcast.xml (one item, EdDSA signed), SHA256SUMS.txt and notes.md.
#   4. Verifies the EdDSA signature of the archive.
#   5. Not with --dry-run: makes the releases repository if it is missing, uploads a draft
#      release, publishes it, downloads the feed and the archive again and compares them,
#      then tags HEAD v<version> in this repository (local tag, nothing is pushed).
#
# Usage: scripts/release.sh [--dry-run]
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
# shellcheck source=signing-env.sh
source "$ROOT/scripts/signing-env.sh"
# shellcheck source=release-lib.sh
source "$ROOT/scripts/release-lib.sh"

readonly BUNDLE_ID="com.fskroes.Striple"
readonly APP="$ROOT/dist/Striple.app"
readonly UPDATES_ENV="$ROOT/Packaging/updates.env"
readonly SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

DRY=0
case "${1:-}" in
    "") ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
esac

for tool in git curl ditto shasum plutil codesign xmllint lipo hdiutil; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done
if [[ $DRY -eq 0 ]]; then
    command -v gh >/dev/null || die "missing tool: gh (brew install gh, then gh auth login)"
    gh auth status >/dev/null 2>&1 || die "gh is not logged in (run: gh auth login)"
fi
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || swift package resolve >/dev/null
for tool in generate_keys generate_appcast sign_update; do
    [[ -x "$SPARKLE_BIN/$tool" ]] || die "missing Sparkle tool: $SPARKLE_BIN/$tool"
done

# --- 1. Checks -----------------------------------------------------------------------------
REPO=$(striple_updates_value "$UPDATES_ENV" STRIPLE_RELEASES_REPO)
FEED=$(striple_updates_value "$UPDATES_ENV" STRIPLE_FEED_URL)
KEY=$(striple_updates_value "$UPDATES_ENV" STRIPLE_ED_PUBLIC_KEY)
ACCOUNT=$(striple_updates_value "$UPDATES_ENV" STRIPLE_ED_KEY_ACCOUNT)
[[ -n "$REPO" && -n "$FEED" && -n "$KEY" && -n "$ACCOUNT" ]] \
    || die "Packaging/updates.env needs STRIPLE_RELEASES_REPO, STRIPLE_FEED_URL, STRIPLE_ED_PUBLIC_KEY and STRIPLE_ED_KEY_ACCOUNT"
[[ "$FEED" == "$(striple_feed_url_for_repo "$REPO")" ]] \
    || die "STRIPLE_FEED_URL must be $(striple_feed_url_for_repo "$REPO")"
[[ -z "${SIGN_IDENTITY:-}" ]] || die "unset SIGN_IDENTITY: releases are signed with the local identity only"
[[ "${STRIPLE_UPDATES:-on}" == on ]] || die "unset STRIPLE_UPDATES: a release must have updates on"

VERSION=$(tr -d '[:space:]' < VERSION)
striple_version_valid "$VERSION" || die "VERSION must look like 1.2.3, got '$VERSION'"
# A dry run can run on a task branch with changes; a real release cannot.
must() { if [[ $DRY -eq 1 ]]; then printf 'warning (dry run): %s\n' "$*" >&2; else die "$*"; fi; }
[[ -z "$(git status --porcelain)" ]] || must "the working tree has changes. Commit them first."
[[ "$(git branch --show-current)" == main ]] || must "release from main (now on '$(git branch --show-current)')"
BUILD=$(git rev-list --count HEAD)
TAG="v$VERSION"
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "the tag $TAG exists. Increase VERSION."

NOTES=$(striple_changelog_section CHANGELOG.md "$VERSION") \
    || die "CHANGELOG.md has no '## $VERSION' section with text. Write the release notes first."

ACTUAL_KEY=$("$SPARKLE_BIN/generate_keys" --account "$ACCOUNT" -p 2>/dev/null | tail -n 1) || ACTUAL_KEY=""
[[ "$ACTUAL_KEY" == "$KEY" ]] || die "the Sparkle key in your keychain (account $ACCOUNT) does not match STRIPLE_ED_PUBLIC_KEY.
Import your backup: $SPARKLE_BIN/generate_keys --account $ACCOUNT -f <private-key-file>"

HASH=$(striple_signing_identity) || die "no local signing identity. Run scripts/make-signing-cert.sh.
An update with another signature makes macOS ask for the Accessibility permission again."

TMP=$(mktemp -d "${TMPDIR:-/tmp}/striple-release.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# The published feed: the new release must be newer.
CODE=$(curl -sSL --max-time 30 -o "$TMP/published.xml" -w '%{http_code}' "$FEED") || die "cannot read $FEED"
case "$CODE" in
    200)
        read -r PREV_VERSION PREV_BUILD < <(striple_appcast_latest "$TMP/published.xml") \
            || die "the published feed has no release item: $FEED"
        striple_version_gt "$VERSION" "$PREV_VERSION" || die "VERSION $VERSION is not higher than the published $PREV_VERSION"
        (( BUILD > PREV_BUILD )) || die "build $BUILD is not higher than the published build $PREV_BUILD"
        log "Published now: $PREV_VERSION ($PREV_BUILD). New: $VERSION ($BUILD)"
        ;;
    404)
        if [[ $DRY -eq 0 ]] && gh release list --repo "$REPO" --limit 1 2>/dev/null | grep -q .; then
            die "$REPO has releases but no feed at $FEED. Fix the latest release first."
        fi
        log "No release published yet. New: $VERSION ($BUILD)"
        ;;
    *) die "unexpected HTTP $CODE from $FEED" ;;
esac

# --- 2. Build --------------------------------------------------------------------------------
log "Building the app"
env -u STRIPLE_FEED_URL -u STRIPLE_ED_PUBLIC_KEY -u STRIPLE_ARCHS -u STRIPLE_UPDATES \
    "$ROOT/scripts/build-app.sh"

PLIST="$APP/Contents/Info.plist"
plist() { plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null; }
[[ "$(plist CFBundleIdentifier)" == "$BUNDLE_ID" ]] || die "wrong bundle ID in $PLIST"
[[ "$(plist CFBundleShortVersionString)" == "$VERSION" ]] || die "the app version is not $VERSION"
[[ "$(plist CFBundleVersion)" == "$BUILD" ]] || die "the app build is not $BUILD"
[[ "$(plist SUFeedURL)" == "$FEED" ]] || die "the app has the wrong SUFeedURL"
[[ "$(plist SUPublicEDKey)" == "$KEY" ]] || die "the app has the wrong SUPublicEDKey"
codesign --verify --deep --strict "$APP" || die "the signature of the app is not valid"
striple_dr_is_local "$(codesign -d -r - "$APP" 2>&1)" "$BUNDLE_ID" "$HASH" \
    || die "the app is not signed with the local identity $HASH"
for arch in arm64 x86_64; do
    [[ " $(lipo -archs "$APP/Contents/MacOS/Striple") " == *" $arch "* ]] || die "the app has no $arch slice"
done

# --- 3. Files ---------------------------------------------------------------------------------
OUT="$ROOT/dist/release/$VERSION"
case "$OUT" in */dist/release/*) rm -rf "$OUT" ;; *) die "unexpected output path: $OUT" ;; esac
mkdir -p "$OUT"
ZIP_NAME="Striple-$VERSION.zip"
log "Making $ZIP_NAME and Striple.dmg"
# No extended attributes: macOS adds com.apple.provenance to built files, and the signature
# does not need it (a signed bundle keeps its signature in _CodeSignature).
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$OUT/$ZIP_NAME"
env -u SIGN_IDENTITY "$ROOT/scripts/make-dmg.sh" >/dev/null
mv "$ROOT/dist/Striple-$VERSION.dmg" "$OUT/Striple.dmg"
printf '%s\n' "$NOTES" > "$OUT/notes.md"

PREFIX=$(striple_download_prefix "$REPO" "$VERSION")
log "Making appcast.xml"
mkdir "$TMP/archives"
cp "$OUT/$ZIP_NAME" "$TMP/archives/"
cp "$OUT/notes.md" "$TMP/archives/Striple-$VERSION.md"
"$SPARKLE_BIN/generate_appcast" --account "$ACCOUNT" --download-url-prefix "$PREFIX" \
    --embed-release-notes --link "https://github.com/$REPO" -o "$OUT/appcast.xml" "$TMP/archives" >/dev/null

# --- 4. Verify --------------------------------------------------------------------------------
LENGTH=$(stat -f %z "$OUT/$ZIP_NAME")
SIG=$(striple_appcast_check "$OUT/appcast.xml" "$VERSION" "$BUILD" "$PREFIX$ZIP_NAME" "$LENGTH") \
    || die "the appcast is not correct"
"$SPARKLE_BIN/sign_update" --account "$ACCOUNT" --verify "$OUT/$ZIP_NAME" "$SIG" >/dev/null 2>&1 \
    || die "the EdDSA signature of $ZIP_NAME is not valid"
# Unpack the archive the way an update does, and check the app in it.
mkdir "$TMP/unpacked"
ditto -x -k "$OUT/$ZIP_NAME" "$TMP/unpacked"
[[ -z "$(find "$TMP/unpacked" -name __MACOSX -print -quit)" ]] || die "$ZIP_NAME has __MACOSX entries"
codesign --verify --deep --strict "$TMP/unpacked/Striple.app" || die "the app in $ZIP_NAME has no valid signature"
striple_dr_is_local "$(codesign -d -r - "$TMP/unpacked/Striple.app" 2>&1)" "$BUNDLE_ID" "$HASH" \
    || die "the app in $ZIP_NAME is not signed with the local identity"
(cd "$OUT" && shasum -a 256 "$ZIP_NAME" Striple.dmg appcast.xml > SHA256SUMS.txt)
log "Files in $OUT:"
(cd "$OUT" && ls -l "$ZIP_NAME" Striple.dmg appcast.xml SHA256SUMS.txt notes.md | awk '{ printf "    %10s  %s\n", $5, $9 }')

if [[ $DRY -eq 1 ]]; then
    log "Dry run: nothing was uploaded. Without --dry-run the release goes to https://github.com/$REPO"
    exit 0
fi

# --- 5. Publish -------------------------------------------------------------------------------
LOGIN=$(gh api user --jq .login)
[[ "${REPO%%/*}" == "$LOGIN" ]] || die "gh is logged in as $LOGIN, but the releases repository is $REPO"
NOREPLY="$LOGIN@users.noreply.github.com"
if ! gh repo view "$REPO" >/dev/null 2>&1; then
    log "Making the public repository $REPO"
    gh api -X POST user/repos -f name="${REPO#*/}" -F private=false -F has_issues=false \
        -F has_wiki=false -F has_projects=false \
        -f description="Striple builds and the update feed. Source is private." >/dev/null
    # The first commit through the API, with the noreply address: no local Git identity is used.
    gh api -X PUT "repos/$REPO/contents/README.md" -f message="Say what this repository holds" \
        -f content="$(base64 < "$ROOT/Packaging/releases-README.md")" \
        -f "committer[name]=$LOGIN" -f "committer[email]=$NOREPLY" \
        -f "author[name]=$LOGIN" -f "author[email]=$NOREPLY" >/dev/null
fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    die "the release $TAG exists in $REPO. If it is a failed draft, delete it: gh release delete $TAG --repo $REPO --yes"
fi

{
    printf '# Striple %s, build %s\n\n%s\n\n' "$VERSION" "$BUILD" "$NOTES"
    printf 'Striple updates itself: **Check for Updates…** in the menu bar menu.\n'
    printf 'Checksums: `SHA256SUMS.txt`.\n'
} > "$TMP/body.md"

log "Uploading the draft release $TAG"
gh release create "$TAG" --repo "$REPO" --draft --title "Striple $VERSION" --notes-file "$TMP/body.md" \
    "$OUT/$ZIP_NAME" "$OUT/Striple.dmg" "$OUT/SHA256SUMS.txt" "$OUT/appcast.xml" >/dev/null
log "Publishing $TAG"
gh release edit "$TAG" --repo "$REPO" --draft=false --latest >/dev/null

# GitHub can take some seconds before /latest/ points to the new release.
log "Checking the published files"
ok=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsSL --max-time 30 -o "$TMP/feed.xml" "$FEED" && cmp -s "$TMP/feed.xml" "$OUT/appcast.xml"; then
        ok=1; break
    fi
    sleep 3
done
[[ $ok -eq 1 ]] || die "$FEED does not return the new appcast. Check https://github.com/$REPO/releases/tag/$TAG"
curl -fsSL --max-time 300 -o "$TMP/$ZIP_NAME" "$PREFIX$ZIP_NAME" || die "cannot download $PREFIX$ZIP_NAME"
cmp -s "$TMP/$ZIP_NAME" "$OUT/$ZIP_NAME" || die "the downloaded $ZIP_NAME is not the same as the uploaded one"

git tag -a "$TAG" -m "Striple $VERSION (build $BUILD)"
log "Published Striple $VERSION ($BUILD): https://github.com/$REPO/releases/tag/$TAG"
log "Feed: $FEED"
