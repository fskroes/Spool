# Shared by make-signing-cert.sh and build-app.sh. Source it; it defines names and functions only.
# shellcheck shell=bash

STRIPLE_SIGNING_NAME="Striple Local Signing"
# Tests point this at a temporary path.
STRIPLE_SIGNING_KEYCHAIN="${STRIPLE_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/striple-signing.keychain-db}"
STRIPLE_SIGNING_PASSWORD_ITEM="Striple Local Signing keychain"

# The user keychain search list, one path per line, without quotes.
striple_signing_search_list() { security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//'; }

# codesign finds an identity only in a keychain on the search list.
striple_signing_add_to_search_list() {
    local list
    list=$(striple_signing_search_list)
    grep -qxF "$STRIPLE_SIGNING_KEYCHAIN" <<<"$list" && return 0
    local paths=()
    while IFS= read -r p; do [[ -n "$p" ]] && paths+=("$p"); done <<<"$list"
    security list-keychains -d user -s "${paths[@]}" "$STRIPLE_SIGNING_KEYCHAIN"
}

striple_signing_remove_from_search_list() {
    local paths=()
    while IFS= read -r p; do
        [[ -n "$p" && "$p" != "$STRIPLE_SIGNING_KEYCHAIN" ]] && paths+=("$p")
    done <<<"$(striple_signing_search_list)"
    # An empty list would hide the login keychain from every app.
    [[ ${#paths[@]} -gt 0 ]] || paths=("$HOME/Library/Keychains/login.keychain-db")
    security list-keychains -d user -s "${paths[@]}"
}

# Prints the SHA-1 of the identity and leaves its keychain unlocked and on the search list.
# Fails (status 1, no output) when the keychain, its password item or the identity is missing.
striple_signing_identity() {
    [[ -f "$STRIPLE_SIGNING_KEYCHAIN" ]] || return 1
    local pass
    pass=$(security find-generic-password -s "$STRIPLE_SIGNING_PASSWORD_ITEM" -a "$USER" -w 2>/dev/null) || return 1
    security unlock-keychain -p "$pass" "$STRIPLE_SIGNING_KEYCHAIN" 2>/dev/null || return 1
    striple_signing_add_to_search_list || return 1
    # Not "-v": the certificate is self-signed and not trusted, which codesign does not need.
    security find-identity -p codesigning "$STRIPLE_SIGNING_KEYCHAIN" 2>/dev/null \
        | awk -v name="\"$STRIPLE_SIGNING_NAME\"" 'index($0, name) && $1 ~ /\)$/ { print $2; found=1; exit } END { exit !found }'
}
