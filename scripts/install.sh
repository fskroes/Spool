#!/usr/bin/env bash
# Installs dist/Spool.app and links the spool CLI. Used by `make install`.
#
# Usage: scripts/install.sh [--prefix DIR] [--app PATH] [--dry-run] [--uninstall]
#   --prefix DIR   install into DIR. Default: /Applications if writable, else ~/Applications.
#   --app PATH     the app to install. Default: dist/Spool.app.
#   --dry-run      print the actions, change nothing.
#   --uninstall    remove the app and the CLI link. Keeps settings and logs.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly BUNDLE_ID="com.fskroes.Spool"
readonly BIN_DIR="$HOME/.local/bin"
readonly LINK="$BIN_DIR/spool"
# Striple is the old name of Spool. An install removes its app, login agent and CLI link.
readonly LEGACY_BUNDLE_ID="com.fskroes.Striple"
readonly LEGACY_LINK="$BIN_DIR/striple"
# The system Applications folder. Tests point it at a temporary folder.
readonly SYSTEM_APPS=${SPOOL_SYSTEM_APPS:-/Applications}
# Asks macOS which apps run. Tests set a fake, so the result does not depend on the apps that run on the Mac.
readonly OSASCRIPT=${SPOOL_OSASCRIPT:-osascript}
# The settings with the Team ID of the releases. Tests point it at another file.
readonly UPDATES_ENV=${SPOOL_UPDATES_ENV:-$ROOT/Packaging/updates.env}
# shellcheck source=release-lib.sh
source "$ROOT/scripts/release-lib.sh"

PREFIX=""
PREFIX_GIVEN=0
SOURCE_APP="$ROOT/dist/Spool.app"
DRY_RUN=0
UNINSTALL=0

usage() { sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
say() { printf '%s\n' "$*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) [[ $# -ge 2 ]] || die "--prefix needs a directory"; PREFIX=$2; PREFIX_GIVEN=1; shift 2 ;;
        --app) [[ $# -ge 2 ]] || die "--app needs a path"; SOURCE_APP=$2; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

if [[ -z "$PREFIX" ]]; then
    if [[ -w "$SYSTEM_APPS" ]]; then PREFIX=$SYSTEM_APPS; else PREFIX="$HOME/Applications"; fi
fi
PREFIX=${PREFIX%/}
[[ -n "$PREFIX" ]] || die "empty --prefix"
[[ "$PREFIX" == /* ]] || PREFIX="$PWD/$PREFIX"
[[ "$SOURCE_APP" == /* ]] || SOURCE_APP="$PWD/$SOURCE_APP"
readonly DEST="$PREFIX/Spool.app"

# Runs a command, or only prints it with --dry-run.
run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
    else
        "$@"
    fi
}

# The path with every symbolic link resolved, so two spellings of one folder compare equal.
physical() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }

# True when both paths are the same folder: the same device and inode. This also catches other letter case on
# a case-insensitive volume and links, where the path strings differ.
same_file() {
    [[ -e "$1" && -e "$2" ]] || return 1
    [[ "$(stat -L -f '%d:%i' "$1")" == "$(stat -L -f '%d:%i' "$2")" ]]
}

bundle_id_of() { plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || true; }

# Deletes an installed Spool.app, with checks so a bad path can never be removed.
remove_app() {
    local app=$1
    [[ -n "$app" ]] || die "refusing to remove an empty path"
    [[ "$app" == */Spool.app ]] || die "refusing to remove '$app': it does not end in /Spool.app"
    [[ -d "$app" ]] || return 0
    [[ "$(bundle_id_of "$app")" == "$BUNDLE_ID" ]] || die "refusing to remove '$app': it is not $BUNDLE_ID"
    run rm -rf "$app"
}

is_running() {
    [[ "$("$OSASCRIPT" -e "application id \"$1\" is running" 2>/dev/null || true)" == "true" ]]
}

# Quits the app with bundle ID $1 (name $2) the normal way. Exit status 0 means launchd does not restart it.
quit_app() {
    is_running "$1" || return 0
    say "Quitting the running $2"
    run "$OSASCRIPT" -e "quit app id \"$1\""
    [[ $DRY_RUN -eq 1 ]] && return 0
    local tries=0
    while is_running "$1"; do
        tries=$((tries + 1))
        [[ $tries -le 20 ]] || die "$2 did not quit in 10 seconds. Quit it from its menu, then try again."
        sleep 0.5
    done
}

quit_spool() { quit_app "$BUNDLE_ID" Spool; }

link_points_into_spool() {
    [[ -L "$LINK" ]] && [[ "$(readlink "$LINK")" == */Spool.app/Contents/Helpers/spool ]]
}

on_path() {
    case ":$PATH:" in *":$BIN_DIR:"*) return 0 ;; *) return 1 ;; esac
}

# The apps to remove. With --prefix only that one. Without it, every place `install` could have used:
# the app the CLI link points into, /Applications and ~/Applications. So an install with --prefix
# is found too, and its login agent does not start a deleted app at the next login.
uninstall_targets() {
    if [[ $PREFIX_GIVEN -eq 1 ]]; then
        printf '%s\n' "$DEST"
        return
    fi
    local linked=""
    if link_points_into_spool; then
        linked=$(readlink "$LINK")
        linked=${linked%/Contents/Helpers/spool}
    fi
    printf '%s\n' "$linked" "$SYSTEM_APPS/Spool.app" "$HOME/Applications/Spool.app" | awk 'NF && !seen[$0]++'
}

# Removes Striple, the old name of Spool: every place `install` of Striple could have used, and the app its CLI
# link points into. Its login agent goes first, so it does not start a deleted app at the next login.
# Spool moves the settings of Striple at its first start (docs/INSTALL.md, "Upgrade from Striple").
# Called after the copy of Spool: if the install stops before, Striple stays.
remove_legacy() {
    local linked="" app found=0 removed="" real
    if [[ -L "$LEGACY_LINK" && "$(readlink "$LEGACY_LINK")" == */Striple.app/Contents/Helpers/striple ]]; then
        linked=$(readlink "$LEGACY_LINK")
        linked=${linked%/Contents/Helpers/striple}
    fi
    while IFS= read -r app; do
        [[ -d "$app" ]] || continue
        if [[ "$app" != */Striple.app || "$(bundle_id_of "$app")" != "$LEGACY_BUNDLE_ID" ]]; then
            warn "$app is not $LEGACY_BUNDLE_ID. Not removed."
            continue
        fi
        found=1
        if [[ -x "$app/Contents/MacOS/Striple" ]]; then
            say "Turning off Launch at login of Striple ($app)"
            # Spool is installed already: a failure here is a warning, so the CLI link still comes.
            run "$app/Contents/MacOS/Striple" --unregister-login </dev/null \
                || warn "could not turn off Launch at login of $app. Spool turns it off at its first start."
        fi
        say "Removing $app: Striple is now Spool"
        real=$(physical "$app")
        if run rm -rf "$app"; then
            removed+="$real"$'\n'
        else
            warn "could not remove $app. Delete it by hand."
        fi
    done < <(printf '%s\n' "$linked" "$SYSTEM_APPS/Striple.app" "$HOME/Applications/Striple.app" "$PREFIX/Striple.app" \
        | awk 'NF && !seen[$0]++')
    # Only the link into a Striple that is removed now or is gone. A link into another app stays.
    if [[ -n "$linked" ]] && { [[ ! -d "$linked" ]] || grep -qxF "$(physical "$linked")" <<<"$removed"; }; then
        say "Removing $LEGACY_LINK: the CLI is now spool"
        run rm -f "$LEGACY_LINK"
    fi
    LEGACY_FOUND=$found
}

if [[ $UNINSTALL -eq 1 ]]; then
    [[ $DRY_RUN -eq 1 ]] && say "Dry run. Nothing is changed."
    quit_spool
    found=0
    removed=""
    while IFS= read -r app; do
        [[ -d "$app" ]] || continue
        if [[ "$(bundle_id_of "$app")" != "$BUNDLE_ID" ]]; then
            warn "$app is not $BUNDLE_ID. Not removed."
            continue
        fi
        found=1
        if [[ -x "$app/Contents/MacOS/Spool" ]]; then
            # Removes the LaunchAgent and the login item, so macOS does not keep an entry for a deleted app.
            say "Turning off Launch at login ($app)"
            run "$app/Contents/MacOS/Spool" --unregister-login </dev/null
        fi
        say "Removing $app"
        removed+="$(physical "$app")"$'\n'
        remove_app "$app"
    done < <(uninstall_targets)
    [[ $found -eq 1 ]] || say "No Spool.app found"
    if link_points_into_spool; then
        linked_app=$(readlink "$LINK")
        linked_app=${linked_app%/Contents/Helpers/spool}
        # Only the link of the app that is removed now, or a link to an app that is gone. A link to another
        # install still works, so it stays.
        if [[ ! -d "$linked_app" ]] || grep -qxF "$(physical "$linked_app")" <<<"$removed"; then
            say "Removing $LINK"
            run rm -f "$LINK"
        else
            say "Keeping $LINK: it points to $linked_app, which is not removed."
        fi
    elif [[ -e "$LINK" || -L "$LINK" ]]; then
        warn "$LINK is not a Spool link. Not removed."
    fi
    cat <<EOF

Spool is removed (unless this was a dry run). These are kept. Remove them yourself if you want:
  Settings: rm -r "$HOME/Library/Application Support/Spool"
  Logs:     rm -r "$HOME/Library/Logs/Spool"
  Accessibility permission: tccutil reset Accessibility $BUNDLE_ID
EOF
    exit 0
fi

[[ -d "$SOURCE_APP" ]] || die "$SOURCE_APP not found. Run 'make app' first."
# Installing an app onto itself would delete it before the copy.
if same_file "$SOURCE_APP" "$DEST"; then
    die "$SOURCE_APP is already at $DEST. Install from another place, for example dist/Spool.app."
fi
[[ "$(bundle_id_of "$SOURCE_APP")" == "$BUNDLE_ID" ]] || die "$SOURCE_APP is not $BUNDLE_ID"
codesign --verify --deep --strict "$SOURCE_APP" || die "$SOURCE_APP has a bad code signature. Run 'make app' again."
! spool_app_has_test_license_key "$SOURCE_APP" "$ROOT/docs/license-test-vectors.json" \
    || die "$SOURCE_APP has the public test license key of the E2E test (make e2e): anyone can make keys for it. Run 'make install', which builds it again."
# Another signature than the one of the releases: an Accessibility entry for it stops working, while the
# switch still shows on. For an ad hoc app after the next build, for another identity after an update
# (releases have the Developer ID signature of the team).
spool_updates_env_usable "$UPDATES_ENV" || die "$UPDATES_ENV not found. Set SPOOL_UPDATES_ENV to the settings file."
TEAM=$(spool_updates_value "$UPDATES_ENV" SPOOL_TEAM_ID)
case "$(spool_install_signature "$TEAM" "$(codesign -d -r - "$SOURCE_APP" 2>&1)" "$BUNDLE_ID")" in
    adhoc) warn "$SOURCE_APP is signed ad hoc, not by the team $TEAM of the releases.
If you give it the Accessibility permission, that entry stops working after the next build,
while the switch still shows on. Then click Settings > Mac Setup > Reset Permission again.
$(spool_stable_identity_hint "$TEAM")" ;;
    other) warn "$SOURCE_APP is not signed by the team $TEAM of the releases.
Updates are signed by that team. After an update, the Accessibility entry stops working,
while the switch still shows on. Then click Settings > Mac Setup > Reset Permission." ;;
esac

[[ $DRY_RUN -eq 1 ]] && say "Dry run. Nothing is changed."
say "Installing $SOURCE_APP to $DEST"
[[ -d "$PREFIX" ]] || run mkdir -p "$PREFIX"
# Before anything changes: remove_app stops for an app at $DEST that is not Spool.
[[ ! -d "$DEST" || "$(bundle_id_of "$DEST")" == "$BUNDLE_ID" ]] || die "refusing to replace '$DEST': it is not $BUNDLE_ID"
# Striple quits first, so two window managers never run. It is removed after the copy.
quit_app "$LEGACY_BUNDLE_ID" Striple
quit_spool
remove_app "$DEST"
run ditto "$SOURCE_APP" "$DEST"
LEGACY_FOUND=0
remove_legacy

say "Linking $LINK"
run mkdir -p "$BIN_DIR"
if [[ -e "$LINK" && ! -L "$LINK" ]]; then
    die "$LINK exists and is not a link. Move it away, then try again."
fi
run ln -sfn "$DEST/Contents/Helpers/spool" "$LINK"
on_path || warn "$BIN_DIR is not on your PATH. Add this line to ~/.zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\""

cat <<EOF

Done. Next steps:
  1. Open Spool:  open "$DEST"
  2. Give Accessibility permission when Spool asks:
     System Settings > Privacy & Security > Accessibility > Spool (on).
     If the switch is on already, but Spool says "Accessibility permission needed", click
     Settings > Mac Setup > Reset Permission in Spool, then turn Spool on.
  3. Check the CLI: spool --version
EOF
if [[ $LEGACY_FOUND -eq 1 ]]; then
    cat <<EOF

Striple is now Spool. At its first start, Spool moves your settings, layout and logs from the Striple folders.
macOS keeps the Accessibility entry of Striple. Remove it with: tccutil reset Accessibility $LEGACY_BUNDLE_ID
If Launch at login was on for Striple, Spool turns it on again at its first start.
EOF
fi
