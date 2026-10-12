#!/usr/bin/env bash
# Installs dist/Striple.app and links the striple CLI. Used by `make install`.
#
# Usage: scripts/install.sh [--prefix DIR] [--app PATH] [--dry-run] [--uninstall]
#   --prefix DIR   install into DIR. Default: /Applications if writable, else ~/Applications.
#   --app PATH     the app to install. Default: dist/Striple.app.
#   --dry-run      print the actions, change nothing.
#   --uninstall    remove the app and the CLI link. Keeps settings and logs.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly BUNDLE_ID="com.fskroes.Striple"
readonly BIN_DIR="$HOME/.local/bin"
readonly LINK="$BIN_DIR/striple"
# The system Applications folder. Tests point it at a temporary folder.
readonly SYSTEM_APPS=${STRIPLE_SYSTEM_APPS:-/Applications}
# The settings with the pinned signing identity. Tests point it at another file.
readonly UPDATES_ENV=${STRIPLE_UPDATES_ENV:-$ROOT/Packaging/updates.env}
# shellcheck source=release-lib.sh
source "$ROOT/scripts/release-lib.sh"

PREFIX=""
PREFIX_GIVEN=0
SOURCE_APP="$ROOT/dist/Striple.app"
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
readonly DEST="$PREFIX/Striple.app"

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

# Deletes an installed Striple.app, with checks so a bad path can never be removed.
remove_app() {
    local app=$1
    [[ -n "$app" ]] || die "refusing to remove an empty path"
    [[ "$app" == */Striple.app ]] || die "refusing to remove '$app': it does not end in /Striple.app"
    [[ -d "$app" ]] || return 0
    [[ "$(bundle_id_of "$app")" == "$BUNDLE_ID" ]] || die "refusing to remove '$app': it is not $BUNDLE_ID"
    run rm -rf "$app"
}

is_running() {
    [[ "$(osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null || true)" == "true" ]]
}

# Quits Striple the normal way. Exit status 0 means launchd does not restart it.
quit_striple() {
    is_running || return 0
    say "Quitting the running Striple"
    run osascript -e "quit app id \"$BUNDLE_ID\""
    [[ $DRY_RUN -eq 1 ]] && return 0
    local tries=0
    while is_running; do
        tries=$((tries + 1))
        [[ $tries -le 20 ]] || die "Striple did not quit in 10 seconds. Quit it from its menu, then try again."
        sleep 0.5
    done
}

link_points_into_striple() {
    [[ -L "$LINK" ]] && [[ "$(readlink "$LINK")" == */Striple.app/Contents/Helpers/striple ]]
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
    if link_points_into_striple; then
        linked=$(readlink "$LINK")
        linked=${linked%/Contents/Helpers/striple}
    fi
    printf '%s\n' "$linked" "$SYSTEM_APPS/Striple.app" "$HOME/Applications/Striple.app" | awk 'NF && !seen[$0]++'
}

if [[ $UNINSTALL -eq 1 ]]; then
    [[ $DRY_RUN -eq 1 ]] && say "Dry run. Nothing is changed."
    quit_striple
    found=0
    removed=""
    while IFS= read -r app; do
        [[ -d "$app" ]] || continue
        if [[ "$(bundle_id_of "$app")" != "$BUNDLE_ID" ]]; then
            warn "$app is not $BUNDLE_ID. Not removed."
            continue
        fi
        found=1
        if [[ -x "$app/Contents/MacOS/Striple" ]]; then
            # Removes the LaunchAgent and the login item, so macOS does not keep an entry for a deleted app.
            say "Turning off Launch at login ($app)"
            run "$app/Contents/MacOS/Striple" --unregister-login </dev/null
        fi
        say "Removing $app"
        removed+="$(physical "$app")"$'\n'
        remove_app "$app"
    done < <(uninstall_targets)
    [[ $found -eq 1 ]] || say "No Striple.app found"
    if link_points_into_striple; then
        linked_app=$(readlink "$LINK")
        linked_app=${linked_app%/Contents/Helpers/striple}
        # Only the link of the app that is removed now, or a link to an app that is gone. A link to another
        # install still works, so it stays.
        if [[ ! -d "$linked_app" ]] || grep -qxF "$(physical "$linked_app")" <<<"$removed"; then
            say "Removing $LINK"
            run rm -f "$LINK"
        else
            say "Keeping $LINK: it points to $linked_app, which is not removed."
        fi
    elif [[ -e "$LINK" || -L "$LINK" ]]; then
        warn "$LINK is not a Striple link. Not removed."
    fi
    cat <<EOF

Striple is removed (unless this was a dry run). These are kept. Remove them yourself if you want:
  Settings: rm -r "$HOME/Library/Application Support/Striple"
  Logs:     rm -r "$HOME/Library/Logs/Striple"
  Accessibility permission: tccutil reset Accessibility $BUNDLE_ID
EOF
    exit 0
fi

[[ -d "$SOURCE_APP" ]] || die "$SOURCE_APP not found. Run 'make app' first."
# Installing an app onto itself would delete it before the copy.
if same_file "$SOURCE_APP" "$DEST"; then
    die "$SOURCE_APP is already at $DEST. Install from another place, for example dist/Striple.app."
fi
[[ "$(bundle_id_of "$SOURCE_APP")" == "$BUNDLE_ID" ]] || die "$SOURCE_APP is not $BUNDLE_ID"
codesign --verify --deep --strict "$SOURCE_APP" || die "$SOURCE_APP has a bad code signature. Run 'make app' again."
# Another signature than the pinned one: macOS asks for the Accessibility permission again now,
# and again after the next update (releases have the pinned signature).
striple_updates_env_usable "$UPDATES_ENV" || die "$UPDATES_ENV not found. Set STRIPLE_UPDATES_ENV to the settings file."
PIN=$(striple_updates_value "$UPDATES_ENV" STRIPLE_SIGNING_CERT_SHA1)
if [[ "$(striple_install_signature "$PIN" "$(codesign -d -r - "$SOURCE_APP" 2>&1)" "$BUNDLE_ID")" == other ]]; then
    warn "$SOURCE_APP is not signed with the pinned identity $PIN.
After the install, macOS asks for the Accessibility permission again, and again after the next update.
Build with the pinned identity: docs/INSTALL.md, \"Keep the Accessibility permission after a rebuild\"."
fi

[[ $DRY_RUN -eq 1 ]] && say "Dry run. Nothing is changed."
say "Installing $SOURCE_APP to $DEST"
[[ -d "$PREFIX" ]] || run mkdir -p "$PREFIX"
quit_striple
remove_app "$DEST"
run ditto "$SOURCE_APP" "$DEST"

say "Linking $LINK"
run mkdir -p "$BIN_DIR"
if [[ -e "$LINK" && ! -L "$LINK" ]]; then
    die "$LINK exists and is not a link. Move it away, then try again."
fi
run ln -sfn "$DEST/Contents/Helpers/striple" "$LINK"
on_path || warn "$BIN_DIR is not on your PATH. Add this line to ~/.zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\""

cat <<EOF

Done. Next steps:
  1. Open Striple:  open "$DEST"
  2. Give Accessibility permission when Striple asks:
     System Settings > Privacy & Security > Accessibility > Striple (on).
  3. Check the CLI: striple --version
EOF
