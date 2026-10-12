# Helpers for build-app.sh and release.sh. Source it; it defines functions only.
# No network, no keychain: Tests/StripleCoreTests/ReleaseScriptTests.swift calls each function.
# shellcheck shell=bash

# Prints the value of KEY from a KEY=VALUE file (Packaging/updates.env). Prints nothing when the
# file or the key is missing. Comment lines start with "#". Quotes around the value are removed.
striple_updates_value() {
    local file=$1 key=$2
    [[ -f "$file" ]] || return 0
    awk -v k="$key" '
        /^[[:space:]]*#/ { next }
        index($0, k "=") == 1 {
            v = substr($0, length(k) + 2)
            sub(/[[:space:]]+$/, "", v)
            if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
            print v
            exit
        }' "$file"
}

# Status 0 when $1 is a version like 1.2.3.
striple_version_valid() { [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }

# Status 0 when version $1 is higher than version $2 (both like 1.2.3).
striple_version_gt() {
    striple_version_valid "$1" && striple_version_valid "$2" || return 2
    local -a a b
    IFS=. read -r -a a <<<"$1"
    IFS=. read -r -a b <<<"$2"
    local i
    for i in 0 1 2; do
        (( 10#${a[i]} > 10#${b[i]} )) && return 0
        (( 10#${a[i]} < 10#${b[i]} )) && return 1
    done
    return 1
}

# Prints the body of the "## <version>" section of a changelog, without the heading and without
# blank lines at the start and the end. Status 1 when the section is missing or empty.
# The heading can have more text after the version: "## 0.1.0 (2026-10-10)".
striple_changelog_section() {
    local file=$1 version=$2 body
    [[ -f "$file" ]] || return 1
    body=$(awk -v v="$version" '
        /^## / {
            if (found) exit
            rest = substr($0, 4)
            if (rest == v || index(rest, v " ") == 1) { found = 1; next }
        }
        found {
            line[++n] = $0
            if ($0 ~ /[^[:space:]]/) { if (!first) first = n; last = n }
        }
        END { for (i = first; first && i <= last; i++) print line[i] }' "$file")
    [[ -n "${body//[[:space:]]/}" ]] || return 1
    printf '%s\n' "$body"
}

# The appcast URL for a GitHub releases repository "owner/name".
striple_feed_url_for_repo() { printf 'https://github.com/%s/releases/latest/download/appcast.xml\n' "$1"; }

# The download prefix for the files of one release.
striple_download_prefix() { printf 'https://github.com/%s/releases/download/v%s/\n' "$1" "$2"; }

# Prints "<shortVersionString> <version>" of the item with the highest build number (sparkle:version).
# Status 1 when the appcast has no item with both values.
striple_appcast_latest() {
    local file=$1 n i short build best_short="" best_build=-1
    n=$(xmllint --xpath 'count(//item)' "$file" 2>/dev/null) || return 1
    for (( i = 1; i <= n; i++ )); do
        short=$(xmllint --xpath "string(//item[$i]/*[local-name()='shortVersionString'])" "$file" 2>/dev/null)
        build=$(xmllint --xpath "string(//item[$i]/*[local-name()='version'])" "$file" 2>/dev/null)
        [[ -n "$short" && "$build" =~ ^[0-9]+$ ]] || continue
        if (( build > best_build )); then best_build=$build; best_short=$short; fi
    done
    [[ -n "$best_short" ]] || return 1
    printf '%s %s\n' "$best_short" "$best_build"
}

# Checks an appcast made by generate_appcast for one release. Prints the EdDSA signature.
# Arguments: appcast, version, build, archive URL, archive length in bytes.
# Status 1 with a message on stderr when a value is wrong.
striple_appcast_check() {
    local file=$1 version=$2 build=$3 url=$4 length=$5 got
    local item="//item[1]" enc="//item[1]/enclosure"
    _striple_appcast_fail() { printf 'appcast: %s\n' "$*" >&2; return 1; }
    got=$(xmllint --xpath 'count(//item)' "$file" 2>/dev/null) || { _striple_appcast_fail "not valid XML"; return 1; }
    [[ "$got" == 1 ]] || { _striple_appcast_fail "expected 1 item, found $got"; return 1; }
    got=$(xmllint --xpath "string($item/*[local-name()='shortVersionString'])" "$file")
    [[ "$got" == "$version" ]] || { _striple_appcast_fail "shortVersionString is '$got', expected '$version'"; return 1; }
    got=$(xmllint --xpath "string($item/*[local-name()='version'])" "$file")
    [[ "$got" == "$build" ]] || { _striple_appcast_fail "version (build) is '$got', expected '$build'"; return 1; }
    got=$(xmllint --xpath "string($enc/@url)" "$file")
    [[ "$got" == "$url" ]] || { _striple_appcast_fail "enclosure url is '$got', expected '$url'"; return 1; }
    got=$(xmllint --xpath "string($enc/@length)" "$file")
    [[ "$got" == "$length" ]] || { _striple_appcast_fail "enclosure length is '$got', expected '$length'"; return 1; }
    got=$(xmllint --xpath "string($enc/@*[local-name()='edSignature'])" "$file")
    [[ -n "$got" ]] || { _striple_appcast_fail "the enclosure has no EdDSA signature"; return 1; }
    printf '%s\n' "$got"
}

# Status 0 when a designated requirement (the output of `codesign -d -r -`) pins the bundle ID
# and the certificate with SHA-1 $3. An ad hoc DR (cdhash) fails.
striple_dr_is_local() {
    local dr=$1 bundle=$2 hash
    hash=$(tr 'A-F' 'a-f' <<<"$3")
    [[ -n "$hash" && "$dr" == *"identifier \"$bundle\" and certificate leaf = H\"$hash\""* ]]
}
