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

# Prints each file under DIR that contains one of the other arguments as bytes (for example $HOME
# and $USER). Empty arguments are ignored. Status 0: no file has one. Status 1: a file has one.
# Status 2: the check failed (for example a file that cannot be read); grep tells why on stderr.
striple_private_strings() {
    local dir=$1 needle status=0
    shift
    local -a args=()
    for needle in "$@"; do [[ -n "$needle" ]] && args+=(-e "$needle"); done
    [[ ${#args[@]} -gt 0 ]] || return 0
    [[ -d "$dir" ]] || { echo "striple_private_strings: no such folder: $dir" >&2; return 2; }
    LC_ALL=C grep -rlF "${args[@]}" "$dir" || status=$?
    case $status in
        0) return 1 ;;
        1) return 0 ;;
        *) return 2 ;;
    esac
}

# The verdict of striple_private_strings for release.sh: status 0 when DIR is clean. Else status 1 and
# a message for LABEL on stdout. A check that could not run is a failure, never "clean".
striple_release_private_check() {
    local dir=$1 label=$2 leaks status=0
    shift 2
    leaks=$(striple_private_strings "$dir" "$@") || status=$?
    case $status in
        0) return 0 ;;
        1) printf 'files in %s contain your home path, user name or Git email:\n%s\n' "$label" "$leaks" ;;
        *) printf 'cannot check %s for your home path, user name or Git email (see the error above)\n' "$label" ;;
    esac
    return 1
}

# Status 0 when the releases repository REPO has no release TAG (also when REPO does not exist).
# Status 1 with advice on stdout for a draft or a published release; status 2 when gh cannot tell.
striple_release_existing() {
    local tag=$1 repo=$2 out err status=0
    err=$(mktemp "${TMPDIR:-/tmp}/striple-gh.XXXXXX") || return 2
    out=$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft 2>"$err") || status=$?
    local msg
    msg=$(<"$err")
    rm -f "$err"
    if [[ $status -ne 0 ]]; then
        [[ "$msg" == *"release not found"* ]] && return 0
        printf 'cannot check for the release %s in %s: %s\n' "$tag" "$repo" "$msg"
        return 2
    fi
    case "$out" in
        true)
            printf 'a draft release %s exists in %s, from a run that stopped before the publish. Delete it, then run again:\n' "$tag" "$repo"
            printf 'gh release delete %s --repo %s --yes\n' "$tag" "$repo" ;;
        false)
            printf '%s is published in %s. Do not delete it. If its run stopped before the tag, run on the commit\n' "$tag" "$repo"
            printf 'of that run: make publish-finish. If the tag exists, increase VERSION.\n' ;;
        *)
            printf 'unexpected answer from gh release view %s: %s\n' "$tag" "$out"
            return 2 ;;
    esac
    return 1
}

# Status 0 when HEAD is COMMIT. With "clean" as the second argument, the working tree must also have
# no changes. release.sh checks this after the build: the files must come from COMMIT.
striple_release_head_is() {
    local commit=$1 head
    head=$(git rev-parse HEAD) || return 1
    [[ "$head" == "$commit" ]] || { echo "HEAD moved from $commit to $head during the release" >&2; return 1; }
    if [[ "${2:-}" == clean && -n "$(git status --porcelain)" ]]; then
        echo "the working tree changed during the release" >&2
        return 1
    fi
}

# Tags COMMIT (not HEAD) with an annotated tag TAG and MESSAGE.
striple_release_tag() { git tag -a "$1" -m "$3" "$2"; }

# Status 0 when the files in DIR were built from the commit HEAD. The release writes
# DIR/commit.txt; the build number alone does not identify a commit (two branches can have the same count).
striple_release_commit_check() {
    local dir=$1 built head
    [[ -f "$dir/commit.txt" ]] || { echo "$dir/commit.txt is missing" >&2; return 1; }
    built=$(<"$dir/commit.txt")
    head=$(git rev-parse HEAD) || return 1
    [[ "$built" == "$head" ]] || { echo "$dir was built from commit $built, HEAD is $head. Check out $built first." >&2; return 1; }
}

# The EXIT trap of release.sh: detach the DMG if it is still mounted at DIR/dmg, then delete DIR.
# If the DMG does not detach, DIR is kept: rm -rf must not run into a mounted volume.
striple_release_cleanup() {
    local dir=$1 real
    [[ -n "$dir" && -d "$dir" ]] || return 0
    real=$(cd "$dir" && pwd -P)
    if mount | grep -qF " on $real/dmg ("; then
        hdiutil detach -force "$dir/dmg" -quiet || {
            echo "cannot detach $dir/dmg. Detach it, then delete $dir" >&2
            return 1
        }
    fi
    rm -rf "$dir"
}

# Prints the url attribute of the enclosure of the item with the highest build number.
striple_appcast_latest_url() {
    local file=$1 n i build url best_build=-1 best_url=""
    n=$(xmllint --xpath 'count(//item)' "$file" 2>/dev/null) || return 1
    for (( i = 1; i <= n; i++ )); do
        build=$(xmllint --xpath "string(//item[$i]/*[local-name()='version'])" "$file" 2>/dev/null)
        url=$(xmllint --xpath "string(//item[$i]/enclosure/@url)" "$file" 2>/dev/null)
        [[ -n "$url" && "$build" =~ ^[0-9]+$ ]] || continue
        if (( build > best_build )); then best_build=$build; best_url=$url; fi
    done
    [[ -n "$best_url" ]] || return 1
    printf '%s\n' "$best_url"
}

# Status 0 when two certificate SHA-1 values are the same (any case, spaces and colons ignored).
striple_sha1_equal() {
    local a b
    a=$(tr -d ' :' <<<"$1" | tr 'a-f' 'A-F')
    b=$(tr -d ' :' <<<"$2" | tr 'a-f' 'A-F')
    [[ "$a" =~ ^[0-9A-F]{40}$ && "$a" == "$b" ]]
}
