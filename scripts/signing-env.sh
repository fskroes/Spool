# Shared by make-signing-cert.sh and build-app.sh. Source it; it defines names and functions only.
# shellcheck shell=bash

STRIPLE_SIGNING_NAME="Striple Local Signing"
# Tests point this at a temporary path.
STRIPLE_SIGNING_KEYCHAIN="${STRIPLE_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/striple-signing.keychain-db}"
STRIPLE_SIGNING_PASSWORD_ITEM="${STRIPLE_SIGNING_PASSWORD_ITEM:-Striple Local Signing keychain}"
STRIPLE_LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Runs one `security` command that has a secret in it. The command goes to `security -i` on stdin,
# so the secret is not in the argument list of any process (ps, process accounting, EDR).
# Values with spaces must be in double quotes; a value must not contain a double quote.
# The status is the status of the command.
striple_security_secret() { printf '%s\n' "$1" | security -i; }

# The user keychain search list, one path per line, without quotes.
striple_signing_search_list() { security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//'; }

# The keychain path with symlinks resolved (/tmp is /private/tmp): `security` lists that form.
striple_signing_keychain_resolved() {
    local dir
    dir=$(cd "$(dirname "$STRIPLE_SIGNING_KEYCHAIN")" 2>/dev/null && pwd -P) || dir=$(dirname "$STRIPLE_SIGNING_KEYCHAIN")
    printf '%s/%s\n' "$dir" "$(basename "$STRIPLE_SIGNING_KEYCHAIN")"
}

# Status 0 when the search list entry $1 is the Striple keychain.
striple_signing_is_ours() { [[ "$1" == "$STRIPLE_SIGNING_KEYCHAIN" || "$1" == "$(striple_signing_keychain_resolved)" ]]; }

# codesign finds an identity only in a keychain on the search list.
striple_signing_add_to_search_list() {
    local list p
    list=$(striple_signing_search_list)
    while IFS= read -r p; do striple_signing_is_ours "$p" && return 0; done <<<"$list"
    local paths=()
    while IFS= read -r p; do [[ -n "$p" ]] && paths+=("$p"); done <<<"$list"
    # An empty list: keep the login keychain on it (and bash 3.2 cannot expand an empty array under set -u).
    [[ ${#paths[@]} -gt 0 ]] || paths=("$STRIPLE_LOGIN_KEYCHAIN")
    security list-keychains -d user -s "${paths[@]}" "$STRIPLE_SIGNING_KEYCHAIN"
}

striple_signing_remove_from_search_list() {
    local paths=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && ! striple_signing_is_ours "$p" && paths+=("$p")
    done <<<"$(striple_signing_search_list)"
    # An empty list would hide the login keychain from every app.
    [[ ${#paths[@]} -gt 0 ]] || paths=("$STRIPLE_LOGIN_KEYCHAIN")
    security list-keychains -d user -s "${paths[@]}"
}

# Prints the SHA-1 of the identity and leaves its keychain unlocked and on the search list.
# Fails (status 1, no output) when the keychain, its password item or the identity is missing.
striple_signing_identity() {
    [[ -f "$STRIPLE_SIGNING_KEYCHAIN" ]] || return 1
    local pass
    pass=$(security find-generic-password -s "$STRIPLE_SIGNING_PASSWORD_ITEM" -a "$USER" -w 2>/dev/null) || return 1
    [[ "$STRIPLE_SIGNING_KEYCHAIN" != *'"'* && "$pass" =~ ^[0-9a-f]+$ ]] || return 1
    striple_security_secret "unlock-keychain -p $pass \"$STRIPLE_SIGNING_KEYCHAIN\"" >/dev/null 2>&1 || return 1
    striple_signing_add_to_search_list || return 1
    # Not "-v": the certificate is self-signed and not trusted, which codesign does not need.
    security find-identity -p codesigning "$STRIPLE_SIGNING_KEYCHAIN" 2>/dev/null \
        | awk -v name="\"$STRIPLE_SIGNING_NAME\"" 'index($0, name) && $1 ~ /\)$/ { print $2; found=1; exit } END { exit !found }'
}
