# Shared by make-signing-cert.sh and build-app.sh. Source it; it defines names and functions only.
# shellcheck shell=bash

# The identity, its keychain and the password item keep the old name of Spool, Striple: the name is in the
# certificate that Packaging/updates.env pins. A new name needs a new identity (docs/RELEASING.md).
SPOOL_SIGNING_NAME="Striple Local Signing"
# Tests point this at a temporary path.
SPOOL_SIGNING_KEYCHAIN="${SPOOL_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/striple-signing.keychain-db}"
SPOOL_SIGNING_PASSWORD_ITEM="${SPOOL_SIGNING_PASSWORD_ITEM:-Striple Local Signing keychain}"
SPOOL_LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# The keychain tool, and the signing tool of make-signing-cert.sh. Tests set them to fakes with
# neutral names: endpoint security reports a new file named `security` as a credential-dumping tool.
SPOOL_SECURITY="${SPOOL_SECURITY:-security}"
SPOOL_CODESIGN="${SPOOL_CODESIGN:-codesign}"

# `security -i` reads its input in blocks of 4096 bytes: the rest of a longer line runs as a second
# command. Lines stay below this limit.
SPOOL_SECURITY_LINE_MAX=4000

# Runs one `security` command that has a secret in it. The command goes to `security -i` on stdin,
# so the secret is not in the argument list of any process (ps, process accounting, EDR).
# Put every value through spool_security_quote. The status is the status of the command.
# A line with a line break, or of SPOOL_SECURITY_LINE_MAX bytes or more, would split into two
# commands: it is refused with status 2 and not run.
spool_security_secret() {
    local LC_ALL=C
    case "$1" in
        *$'\n'*|*$'\r'*) echo "spool: a security command must be one line" >&2; return 2 ;;
    esac
    if (( ${#1} >= SPOOL_SECURITY_LINE_MAX )); then
        echo "spool: a security command must be shorter than $SPOOL_SECURITY_LINE_MAX bytes" >&2
        return 2
    fi
    printf '%s\n' "$1" | "$SPOOL_SECURITY" -i
}

# One argument for a `security -i` line: in double quotes, with \ and " escaped. `security -i` treats a
# backslash as an escape also inside quotes, so "a\b" would arrive as "ab". A line break cannot be
# escaped: such a value is refused with status 2. (Bash strings cannot hold a NUL byte.)
spool_security_quote() {
    local v=$1
    case "$v" in
        *$'\n'*|*$'\r'*) echo "spool: a value for security cannot have a line break" >&2; return 2 ;;
    esac
    v=${v//\\/\\\\}
    v=${v//\"/\\\"}
    printf '"%s"' "$v"
}

# The user keychain search list, one path per line, without quotes.
spool_signing_search_list() { "$SPOOL_SECURITY" list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//'; }

# The keychain path with symlinks resolved (/tmp is /private/tmp): `security` lists that form.
spool_signing_keychain_resolved() {
    local dir
    dir=$(cd "$(dirname "$SPOOL_SIGNING_KEYCHAIN")" 2>/dev/null && pwd -P) || dir=$(dirname "$SPOOL_SIGNING_KEYCHAIN")
    printf '%s/%s\n' "$dir" "$(basename "$SPOOL_SIGNING_KEYCHAIN")"
}

# Status 0 when the search list entry $1 is the Spool keychain.
spool_signing_is_ours() { [[ "$1" == "$SPOOL_SIGNING_KEYCHAIN" || "$1" == "$(spool_signing_keychain_resolved)" ]]; }

# codesign finds an identity only in a keychain on the search list.
spool_signing_add_to_search_list() {
    local list p
    list=$(spool_signing_search_list)
    while IFS= read -r p; do spool_signing_is_ours "$p" && return 0; done <<<"$list"
    local paths=()
    while IFS= read -r p; do [[ -n "$p" ]] && paths+=("$p"); done <<<"$list"
    # An empty list: keep the login keychain on it (and bash 3.2 cannot expand an empty array under set -u).
    [[ ${#paths[@]} -gt 0 ]] || paths=("$SPOOL_LOGIN_KEYCHAIN")
    "$SPOOL_SECURITY" list-keychains -d user -s "${paths[@]}" "$SPOOL_SIGNING_KEYCHAIN"
}

spool_signing_remove_from_search_list() {
    local paths=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && ! spool_signing_is_ours "$p" && paths+=("$p")
    done <<<"$(spool_signing_search_list)"
    # An empty list would hide the login keychain from every app.
    [[ ${#paths[@]} -gt 0 ]] || paths=("$SPOOL_LOGIN_KEYCHAIN")
    "$SPOOL_SECURITY" list-keychains -d user -s "${paths[@]}"
}

# Prints the SHA-1 of the identity and leaves its keychain unlocked and on the search list.
# Fails (status 1, no output) when the keychain, its password item or the identity is missing.
spool_signing_identity() {
    [[ -f "$SPOOL_SIGNING_KEYCHAIN" ]] || return 1
    local pass kc
    pass=$("$SPOOL_SECURITY" find-generic-password -s "$SPOOL_SIGNING_PASSWORD_ITEM" -a "$USER" -w 2>/dev/null) || return 1
    [[ "$pass" =~ ^[0-9a-f]+$ ]] || return 1
    kc=$(spool_security_quote "$SPOOL_SIGNING_KEYCHAIN") || return 1
    spool_security_secret "unlock-keychain -p $pass $kc" >/dev/null 2>&1 || return 1
    spool_signing_add_to_search_list || return 1
    # Not "-v": the certificate is self-signed and not trusted, which codesign does not need.
    "$SPOOL_SECURITY" find-identity -p codesigning "$SPOOL_SIGNING_KEYCHAIN" 2>/dev/null \
        | awk -v name="\"$SPOOL_SIGNING_NAME\"" 'index($0, name) && $1 ~ /\)$/ { print $2; found=1; exit } END { exit !found }'
}
