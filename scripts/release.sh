#!/usr/bin/env bash
# Publishes a Spool release on GitHub, in the public repository from Packaging/updates.env.
# Used by `make publish` and `make publish-dry`. See docs/RELEASING.md.
#
#   1. Checks: a clean tree on main, a VERSION higher than the published one, no release
#      v<version> in the releases repository (also no draft), a CHANGELOG.md section for
#      VERSION, the Sparkle private key matches Packaging/updates.env, this Mac has a
#      "Developer ID Application" identity of the team in Packaging/updates.env (SPOOL_TEAM_ID),
#      and the notarytool profile SPOOL_NOTARY_PROFILE works. A real run also needs the commit
#      on main of the source repository (SPOOL_SOURCE_REPO) on GitHub, and no tag v<version> in the
#      releases repository yet.
#      The published archive must have the same signing team and update key.
#   2. Builds dist/Spool.app (universal, updates on, hardened runtime) and checks its Info.plist
#      and signature.
#   3. Notarizes the app with Apple, staples the ticket to it, and asks Gatekeeper.
#   4. Makes dist/release/<version>/ (a dry run: dist/release/dry-run/<version>/):
#      Spool-<version>.zip (the Sparkle archive), Spool.dmg (signed, notarized and stapled),
#      appcast.xml (one item, EdDSA signed), SHA256SUMS.txt, notes.md and commit.txt (the
#      commit of the build).
#   5. Verifies the EdDSA signature of the archive, the ticket of the app in it, and that no file
#      in the zip or the DMG has your home path, user name or Git email in it.
#   6. Not with --dry-run: makes the public releases repository when it does not exist, uploads a
#      draft release, publishes it, downloads the feed, the archive and the DMG again and compares
#      them, checks the tag in the releases repository, then tags the commit of the build v<version>
#      in this repository (a local tag, nothing is pushed).
#
# A dry run sends the app and the DMG to Apple's notary service too (not public), so it checks the
# whole chain. Notarization takes some minutes. Run it in the foreground: notarytool reads its
# profile from the login keychain.
#
# Usage: scripts/release.sh [--dry-run] [--new-identity] | --finish
#   --finish        only step 6 after the publish: when a run published the release but stopped
#                   before the tag. It uses the files in dist/release/<version>/ of that run.
#   --new-identity  the published release is signed by another team, and this is on purpose.
#                   Installed copies lose the Accessibility permission after this update, while the
#                   switch still shows on. Tell the users to click Settings > Mac Setup > Reset Permission.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
# shellcheck source=signing-env.sh
source "$ROOT/scripts/signing-env.sh"
# shellcheck source=release-lib.sh
source "$ROOT/scripts/release-lib.sh"

readonly BUNDLE_ID="com.fskroes.Spool"
readonly APP="$ROOT/dist/Spool.app"
readonly UPDATES_ENV="$ROOT/Packaging/updates.env"
readonly SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

warn() { printf 'warning: %s\n' "$*" >&2; }

DRY=0
FINISH=0
NEW_IDENTITY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --finish) FINISH=1 ;;
        --new-identity) NEW_IDENTITY=1 ;;
        -h|--help) sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done
[[ $FINISH -eq 0 || ( $DRY -eq 0 && $NEW_IDENTITY -eq 0 ) ]] || die "--finish takes no other option"

for tool in git curl ditto shasum plutil codesign xmllint lipo hdiutil xcrun spctl; do
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
REPO=$(spool_updates_value "$UPDATES_ENV" SPOOL_RELEASES_REPO)
SOURCE=$(spool_updates_value "$UPDATES_ENV" SPOOL_SOURCE_REPO)
FEED=$(spool_updates_value "$UPDATES_ENV" SPOOL_FEED_URL)
KEY=$(spool_updates_value "$UPDATES_ENV" SPOOL_ED_PUBLIC_KEY)
ACCOUNT=$(spool_updates_value "$UPDATES_ENV" SPOOL_ED_KEY_ACCOUNT)
TEAM=$(spool_updates_value "$UPDATES_ENV" SPOOL_TEAM_ID)
PROFILE=$(spool_updates_value "$UPDATES_ENV" SPOOL_NOTARY_PROFILE)
[[ -n "$REPO" && -n "$SOURCE" && -n "$FEED" && -n "$KEY" && -n "$ACCOUNT" && -n "$TEAM" && -n "$PROFILE" ]] \
    || die "Packaging/updates.env needs SPOOL_RELEASES_REPO, SPOOL_SOURCE_REPO, SPOOL_FEED_URL, SPOOL_ED_PUBLIC_KEY, SPOOL_ED_KEY_ACCOUNT, SPOOL_TEAM_ID and SPOOL_NOTARY_PROFILE"
# The source is private, the releases repository is public: a release must never go to the source.
[[ "$REPO" != "$SOURCE" ]] || die "SPOOL_RELEASES_REPO must not be the source repository $SOURCE"
[[ "$FEED" == "$(spool_feed_url_for_repo "$REPO")" ]] \
    || die "SPOOL_FEED_URL must be $(spool_feed_url_for_repo "$REPO")"
spool_team_id_valid "$TEAM" || die "SPOOL_TEAM_ID must be a Team ID of 10 capital letters and digits, got '$TEAM'"
[[ -z "${SIGN_IDENTITY:-}" ]] || die "unset SIGN_IDENTITY: releases are signed with the Developer ID of team $TEAM only"
[[ "${SPOOL_UPDATES:-on}" == on ]] || die "unset SPOOL_UPDATES: a release must have updates on"

VERSION=$(tr -d '[:space:]' < VERSION)
spool_version_valid "$VERSION" || die "VERSION must look like 1.2.3, got '$VERSION'"
# A dry run can run on a task branch with changes; a real release cannot.
must() { if [[ $DRY -eq 1 ]]; then printf 'warning (dry run): %s\n' "$*" >&2; else die "$*"; fi; }
[[ -z "$(git status --porcelain)" ]] || must "the working tree has changes. Commit them first."
[[ "$(git branch --show-current)" == main ]] || must "release from main (now on '$(git branch --show-current)')"
BUILD=$(git rev-list --count HEAD)
# The release is this commit. The build, commit.txt and the tag all use it.
COMMIT=$(git rev-parse HEAD)
TAG="v$VERSION"
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "the tag $TAG exists. Increase VERSION."

NOTES=$(spool_changelog_section CHANGELOG.md "$VERSION") \
    || die "CHANGELOG.md has no '## $VERSION' section with text. Write the release notes first."

ACTUAL_KEY=$("$SPARKLE_BIN/generate_keys" --account "$ACCOUNT" -p 2>/dev/null | tail -n 1) || ACTUAL_KEY=""
[[ "$ACTUAL_KEY" == "$KEY" ]] || die "the Sparkle key in your keychain (account $ACCOUNT) does not match SPOOL_ED_PUBLIC_KEY.
Import your backup: $SPARKLE_BIN/generate_keys --account $ACCOUNT -f <private-key-file>"

DEVID=$(spool_developer_id "$TEAM") || die "this Mac has no \"Developer ID Application\" identity of team $TEAM.
Install it: Xcode > Settings > Accounts > Manage Certificates, or import its .p12 backup into the login keychain.
Check with: security find-identity -v -p codesigning"

# notarytool reads the profile from the login keychain. It fails here, before the build, and not
# after some minutes of building.
xcrun notarytool history --keychain-profile "$PROFILE" --output-format json >/dev/null 2>&1 \
    || die "the notarytool profile $PROFILE does not work. Make it once, in your own terminal:
xcrun notarytool store-credentials $PROFILE --apple-id <your Apple ID> --team-id $TEAM
The password it asks for is an app-specific password from https://account.apple.com, not your Apple ID password.
If the profile exists: run this script in the foreground, with the login keychain unlocked."

TMP=$(mktemp -d "${TMPDIR:-/tmp}/spool-release.XXXXXX")
trap 'spool_release_cleanup "$TMP"' EXIT
# A dry run never replaces the files of a real run: --finish needs them.
if [[ $DRY -eq 1 ]]; then OUT="$ROOT/dist/release/dry-run/$VERSION"; else OUT="$ROOT/dist/release/$VERSION"; fi
ZIP_NAME="Spool-$VERSION.zip"
PREFIX=$(spool_download_prefix "$REPO" "$VERSION")

# Step 5 after the publish: the feed serves the new appcast and the archive is the uploaded one.
verify_published_and_tag() {
    # GitHub can take some seconds before /latest/ points to the new release.
    log "Checking the published files"
    local ok=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if curl -fsSL --max-time 30 -o "$TMP/feed.xml" "$FEED" && cmp -s "$TMP/feed.xml" "$OUT/appcast.xml"; then
            ok=1; break
        fi
        sleep 3
    done
    [[ $ok -eq 1 ]] || die "$FEED does not return the new appcast. Check https://github.com/$REPO/releases/tag/$TAG,
then run: scripts/release.sh --finish"
    curl -fsSL --max-time 300 -o "$TMP/$ZIP_NAME" "$PREFIX$ZIP_NAME" || die "cannot download $PREFIX$ZIP_NAME"
    cmp -s "$TMP/$ZIP_NAME" "$OUT/$ZIP_NAME" || die "the downloaded $ZIP_NAME is not the same as the uploaded one"
    # The download link of the website and the README points to the DMG of the latest release.
    curl -fsSL --max-time 300 -o "$TMP/Spool.dmg" "$(spool_latest_download "$REPO")Spool.dmg" \
        || die "cannot download $(spool_latest_download "$REPO")Spool.dmg"
    cmp -s "$TMP/Spool.dmg" "$OUT/Spool.dmg" || die "the downloaded Spool.dmg is not the same as the uploaded one"
    # GitHub made the release tag in the releases repository when it published. The tag of the source
    # is the local one below: the releases repository holds no source, so its tag cannot name the commit.
    local remote
    remote=$(spool_release_remote_tag "$REPO" "$TAG") || die "$remote"
    [[ -n "$remote" ]] || die "the tag $TAG does not exist in $REPO. Check https://github.com/$REPO/releases/tag/$TAG"
    spool_release_tag "$TAG" "$COMMIT" || die "cannot tag $COMMIT as $TAG"
    log "Published Spool $VERSION: https://github.com/$REPO/releases/tag/$TAG"
    log "Feed: $FEED"
}

if [[ $FINISH -eq 1 ]]; then
    for f in "$ZIP_NAME" Spool.dmg appcast.xml SHA256SUMS.txt commit.txt; do
        [[ -f "$OUT/$f" ]] || die "$OUT/$f is missing. --finish needs the files of the run that published $TAG."
    done
    (cd "$OUT" && shasum -a 256 -c SHA256SUMS.txt >/dev/null) || die "the files in $OUT do not match SHA256SUMS.txt"
    # The tag must go on the commit the release was built from.
    spool_release_commit_check "$OUT" || die "--finish must run on the commit of the release."
    read -r _ RUN_BUILD < <(spool_appcast_latest "$OUT/appcast.xml") || die "$OUT/appcast.xml has no release item"
    [[ "$RUN_BUILD" == "$BUILD" ]] || die "$OUT was built at build $RUN_BUILD, HEAD is build $BUILD. Check out that commit first."
    [[ "$(gh release view "$TAG" --repo "$REPO" --json isDraft --jq .isDraft 2>/dev/null)" == false ]] \
        || die "$TAG is not a published release in $REPO. Run scripts/release.sh (without --finish)."
    verify_published_and_tag
    exit 0
fi

# The published feed: the new release must be newer.
CODE=$(curl -sSL --max-time 30 -o "$TMP/published.xml" -w '%{http_code}' "$FEED") || die "cannot read $FEED"
case "$CODE" in
    200)
        read -r PREV_VERSION PREV_BUILD < <(spool_appcast_latest "$TMP/published.xml") \
            || die "the published feed has no release item: $FEED"
        [[ "$VERSION" != "$PREV_VERSION" ]] || die "$VERSION is published already. If its run stopped before the tag,
run: scripts/release.sh --finish. Else increase VERSION."
        spool_version_gt "$VERSION" "$PREV_VERSION" || die "VERSION $VERSION is not higher than the published $PREV_VERSION"
        (( BUILD > PREV_BUILD )) || die "build $BUILD is not higher than the published build $PREV_BUILD"
        log "Published now: $PREV_VERSION ($PREV_BUILD). New: $VERSION ($BUILD)"
        # Installed copies accept the update only with the same update key, and keep their
        # Accessibility permission only with the same signing identity.
        PREV_URL=$(spool_appcast_latest_url "$TMP/published.xml") || die "the published feed has no enclosure URL"
        curl -fsSL --max-time 300 -o "$TMP/published.zip" "$PREV_URL" || die "cannot download $PREV_URL"
        mkdir "$TMP/published"
        ditto -x -k "$TMP/published.zip" "$TMP/published" || die "cannot unpack $PREV_URL"
        PREV_APP="$TMP/published/Spool.app"
        if spool_dr_is_team "$(codesign -d -r - "$PREV_APP" 2>&1)" "$BUNDLE_ID" "$TEAM"; then
            [[ $NEW_IDENTITY -eq 0 ]] || die "the published $PREV_VERSION is signed by team $TEAM already. Run without --new-identity."
        elif [[ $NEW_IDENTITY -eq 1 ]]; then
            warn "the published $PREV_VERSION is not signed by team $TEAM (--new-identity).
After this update, every installed copy loses the Accessibility permission while the switch still shows on.
Tell the users in the release notes: click Settings > Mac Setup > Reset Permission in Spool, then turn Spool on."
        else
            die "the published $PREV_VERSION is not signed by team $TEAM. A release with another signature makes
every installed copy lose its Accessibility permission. If the change is on purpose: docs/RELEASING.md,
\"Change the signing team\"."
        fi
        [[ "$(plutil -extract SUPublicEDKey raw -o - "$PREV_APP/Contents/Info.plist" 2>/dev/null)" == "$KEY" ]] \
            || die "the published $PREV_VERSION has another SUPublicEDKey than Packaging/updates.env.
Installed copies would refuse this update. Use the key of the published release."
        if [[ $NEW_IDENTITY -eq 1 ]]; then
            log "The published $PREV_VERSION has the same update key, and another signing team (--new-identity)"
        else
            log "The published $PREV_VERSION has the same signing team and update key"
        fi
        ;;
    404)
        # Drafts are not public; a failed draft of this version is handled before the upload.
        # When gh cannot tell (network, login), the run stops: "no releases" would skip the checks of
        # the published identity and key.
        if [[ $DRY -eq 0 ]]; then
            PUBLISHED=$(spool_release_none_published "$REPO" "$FEED") || die "$PUBLISHED"
        fi
        log "No release published yet. New: $VERSION ($BUILD)"
        ;;
    *) die "unexpected HTTP $CODE from $FEED" ;;
esac
# Before the build: a second run must not delete the files that --finish needs.
if [[ $DRY -eq 0 ]]; then
    EXISTING=$(spool_release_existing "$TAG" "$REPO") || die "$EXISTING"
    # A release is built from reviewed code: the commit must be on main of the source repository.
    # The releases repository must not have the tag yet (a release on an existing tag keeps that tag).
    ONMAIN=$(spool_release_commit_on_main "$SOURCE" "$COMMIT") || die "$ONMAIN"
    REMOTE_TAG=$(spool_release_remote_tag "$REPO" "$TAG") || die "$REMOTE_TAG"
    [[ -z "$REMOTE_TAG" ]] || die "the tag $TAG exists in $REPO (on $REMOTE_TAG). Increase VERSION."
fi

# --- 2. Build --------------------------------------------------------------------------------
log "Building the app"
env -u SPOOL_FEED_URL -u SPOOL_ED_PUBLIC_KEY -u SPOOL_ARCHS -u SPOOL_UPDATES \
    "$ROOT/scripts/build-app.sh"

PLIST="$APP/Contents/Info.plist"
plist() { plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null; }
[[ "$(plist CFBundleIdentifier)" == "$BUNDLE_ID" ]] || die "wrong bundle ID in $PLIST"
[[ "$(plist CFBundleShortVersionString)" == "$VERSION" ]] || die "the app version is not $VERSION"
[[ "$(plist CFBundleVersion)" == "$BUILD" ]] || die "the app build is not $BUILD"
[[ "$(plist SUFeedURL)" == "$FEED" ]] || die "the app has the wrong SUFeedURL"
[[ "$(plist SUPublicEDKey)" == "$KEY" ]] || die "the app has the wrong SUPublicEDKey"
codesign --verify --deep --strict "$APP" || die "the signature of the app is not valid"
spool_dr_is_team "$(codesign -d -r - "$APP" 2>&1)" "$BUNDLE_ID" "$TEAM" \
    || die "the app is not signed with the Developer ID of team $TEAM"
# Notarization refuses an app without the hardened runtime.
[[ "$(codesign -d --verbose=2 "$APP" 2>&1)" == *"(runtime)"* ]] || die "the app does not have the hardened runtime"
for arch in arm64 x86_64; do
    [[ " $(lipo -archs "$APP/Contents/MacOS/Spool") " == *" $arch "* ]] || die "the app has no $arch slice"
done
spool_release_head_is "$COMMIT" || die "the app is not a build of $COMMIT. Run again."
if [[ $DRY -eq 0 ]]; then
    spool_release_head_is "$COMMIT" clean || die "the app is not a build of $COMMIT. Run again."
fi

# --- 3. Notarize the app ----------------------------------------------------------------------
# Sends FILE to Apple's notary service and waits for the answer. LABEL names it in the messages.
notarize() {
    local file=$1 label=$2 json status id
    log "Notarizing $label (this takes some minutes)"
    json=$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json 2>"$TMP/notary.err") || true
    status=$(spool_notary_status "$json") || status=""
    if [[ "$status" != Accepted ]]; then
        id=$(spool_notary_id "$json") || id=""
        [[ -z "$id" ]] || xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
        die "Apple did not notarize $label: ${status:-no answer}. $(tr '\n' ' ' < "$TMP/notary.err")
${id:+Read why: xcrun notarytool log $id --keychain-profile $PROFILE}"
    fi
    log "Apple notarized $label"
}
# Staples the ticket to FILE and checks it. Gatekeeper then accepts FILE also without a network.
staple() {
    xcrun stapler staple "$1" >/dev/null 2>&1 || die "cannot staple the ticket to $2"
    xcrun stapler validate "$1" >/dev/null 2>&1 || die "the ticket on $2 is not valid"
}
# Asks Gatekeeper, as on the Mac of a user. KIND: execute (an app) or open (a DMG).
gatekeeper() {
    local file=$1 label=$2 kind=$3 out
    if [[ "$kind" == execute ]]; then
        out=$(spctl --assess --type execute -vv "$file" 2>&1) || true
    else
        out=$(spctl --assess --type open --context context:primary-signature -vv "$file" 2>&1) || true
    fi
    spool_gatekeeper_notarized "$out" || die "Gatekeeper does not accept $label as notarized:
$out"
}
mkdir "$TMP/notarize"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$TMP/notarize/Spool.zip"
notarize "$TMP/notarize/Spool.zip" Spool.app
staple "$APP" Spool.app
gatekeeper "$APP" Spool.app execute

# --- 4. Files ---------------------------------------------------------------------------------
case "$OUT" in */dist/release/*) rm -rf "$OUT" ;; *) die "unexpected output path: $OUT" ;; esac
mkdir -p "$OUT"
log "Making $ZIP_NAME and Spool.dmg"
# The archive is made after the staple, so the app in it has its ticket.
# No extended attributes: macOS adds com.apple.provenance to built files, and the signature
# does not need it (a signed bundle keeps its signature in _CodeSignature).
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$OUT/$ZIP_NAME"
SIGN_IDENTITY="$DEVID" "$ROOT/scripts/make-dmg.sh" >/dev/null
mv "$ROOT/dist/Spool-$VERSION.dmg" "$OUT/Spool.dmg"
# A DMG is its own file for Gatekeeper: a notarized app in a DMG without a ticket still warns.
notarize "$OUT/Spool.dmg" Spool.dmg
staple "$OUT/Spool.dmg" Spool.dmg
gatekeeper "$OUT/Spool.dmg" Spool.dmg open
printf '%s\n' "$NOTES" > "$OUT/notes.md"

log "Making appcast.xml"
mkdir "$TMP/archives"
cp "$OUT/$ZIP_NAME" "$TMP/archives/"
cp "$OUT/notes.md" "$TMP/archives/Spool-$VERSION.md"
"$SPARKLE_BIN/generate_appcast" --account "$ACCOUNT" --download-url-prefix "$PREFIX" \
    --embed-release-notes --link "https://github.com/$REPO" -o "$OUT/appcast.xml" "$TMP/archives" >/dev/null

# --- 5. Verify --------------------------------------------------------------------------------
LENGTH=$(stat -f %z "$OUT/$ZIP_NAME")
SIG=$(spool_appcast_check "$OUT/appcast.xml" "$VERSION" "$BUILD" "$PREFIX$ZIP_NAME" "$LENGTH") \
    || die "the appcast is not correct"
"$SPARKLE_BIN/sign_update" --account "$ACCOUNT" --verify "$OUT/$ZIP_NAME" "$SIG" >/dev/null 2>&1 \
    || die "the EdDSA signature of $ZIP_NAME is not valid"
# Unpack the archive the way an update does, and check the app in it.
mkdir "$TMP/unpacked"
ditto -x -k "$OUT/$ZIP_NAME" "$TMP/unpacked"
[[ -z "$(find "$TMP/unpacked" -name __MACOSX -print -quit)" ]] || die "$ZIP_NAME has __MACOSX entries"
codesign --verify --deep --strict "$TMP/unpacked/Spool.app" || die "the app in $ZIP_NAME has no valid signature"
spool_dr_is_team "$(codesign -d -r - "$TMP/unpacked/Spool.app" 2>&1)" "$BUNDLE_ID" "$TEAM" \
    || die "the app in $ZIP_NAME is not signed with the Developer ID of team $TEAM"
xcrun stapler validate "$TMP/unpacked/Spool.app" >/dev/null 2>&1 || die "the app in $ZIP_NAME has no notarization ticket"
# The files are public: nothing may name this Mac's user.
log "Checking the zip and the DMG for your home path, user name and Git email"
# The user name only as a folder of a path: alone it is also the GitHub owner, and the bundle ID and the
# feed URL have it (com.fskroes.Spool, github.com/fskroes/Spool), so every release would stop.
PRIVATE=("$HOME" "/Users/$USER/" "$(git config user.email || true)")
check_private() {
    local msg
    msg=$(spool_release_private_check "$1" "$2" "${PRIVATE[@]}") || die "$msg"
}
check_private "$TMP/unpacked" "$ZIP_NAME"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$TMP/dmg" "$OUT/Spool.dmg" >/dev/null \
    || die "cannot open Spool.dmg"
# A die from here on leaves the DMG mounted; the EXIT trap detaches it.
check_private "$TMP/dmg" Spool.dmg
[[ -d "$TMP/dmg/Spool.app" ]] || die "Spool.dmg has no Spool.app"
# The app in the DMG is what a user drags to Applications: it needs its own ticket, also when the DMG has one.
xcrun stapler validate "$TMP/dmg/Spool.app" >/dev/null 2>&1 || die "the app in Spool.dmg has no notarization ticket"
spool_dr_is_team "$(codesign -d -r - "$TMP/dmg/Spool.app" 2>&1)" "$BUNDLE_ID" "$TEAM" \
    || die "the app in Spool.dmg is not signed with the Developer ID of team $TEAM"
hdiutil detach "$TMP/dmg" -quiet
(cd "$OUT" && shasum -a 256 "$ZIP_NAME" Spool.dmg appcast.xml > SHA256SUMS.txt)
# Not uploaded. --finish uses it to put the tag on this commit.
printf '%s\n' "$COMMIT" > "$OUT/commit.txt"
log "Files in $OUT:"
(cd "$OUT" && ls -l "$ZIP_NAME" Spool.dmg appcast.xml SHA256SUMS.txt notes.md | awk '{ printf "    %10s  %s\n", $5, $9 }')

if [[ $DRY -eq 1 ]]; then
    log "Dry run: nothing was uploaded. Without --dry-run the release goes to https://github.com/$REPO"
    exit 0
fi

# --- 6. Publish -------------------------------------------------------------------------------
LOGIN=$(gh api user --jq .login)
[[ "${REPO%%/*}" == "$LOGIN" ]] || die "gh is logged in as $LOGIN, but the releases repository is $REPO"
NOREPLY="$LOGIN@users.noreply.github.com"
if ! gh repo view "$REPO" >/dev/null 2>&1; then
    log "Making the public repository $REPO"
    gh api -X POST user/repos -f name="${REPO#*/}" -F private=false -F has_issues=false \
        -F has_wiki=false -F has_projects=false \
        -f description="Spool release files and the update feed. Source is private." >/dev/null
    # The first commit through the API, with the noreply address: no local Git identity is used.
    gh api -X PUT "repos/$REPO/contents/README.md" -f message="Say what this repository holds" \
        -f content="$(base64 < "$ROOT/Packaging/releases-README.md")" \
        -f "committer[name]=$LOGIN" -f "committer[email]=$NOREPLY" \
        -f "author[name]=$LOGIN" -f "author[email]=$NOREPLY" >/dev/null
fi
# Spool downloads its updates from this repository, with no login.
[[ "$(gh repo view "$REPO" --json visibility --jq .visibility 2>/dev/null)" == PUBLIC ]] \
    || die "the releases repository $REPO is not public. Spool cannot download its updates from it."
# Checked in step 1 too. Again here: the build and the notarization take minutes, and in that time
# another run can make the release or push the tag.
EXISTING=$(spool_release_existing "$TAG" "$REPO") || die "$EXISTING"
REMOTE_TAG=$(spool_release_remote_tag "$REPO" "$TAG") || die "$REMOTE_TAG"
[[ -z "$REMOTE_TAG" ]] || die "the tag $TAG exists in $REPO (on $REMOTE_TAG). Increase VERSION."

{
    printf '# Spool %s, build %s\n\n%s\n\n' "$VERSION" "$BUILD" "$NOTES"
    printf '**Install:** download `Spool.dmg`, open it, and drag Spool to Applications. '
    printf 'The app is signed with a Developer ID and notarized by Apple.\n\n'
    printf 'Spool updates itself: **Check for Updates…** in the menu bar menu.\n'
    printf 'Checksums: `SHA256SUMS.txt`. Source commit: `%s`.\n' "$COMMIT"
} > "$TMP/body.md"

log "Uploading the draft release $TAG"
gh release create "$TAG" --repo "$REPO" --draft --title "Spool $VERSION" --notes-file "$TMP/body.md" \
    "$OUT/$ZIP_NAME" "$OUT/Spool.dmg" "$OUT/SHA256SUMS.txt" "$OUT/appcast.xml" >/dev/null
log "Publishing $TAG"
gh release edit "$TAG" --repo "$REPO" --draft=false --latest >/dev/null

verify_published_and_tag
