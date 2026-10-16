# Helpers for build-app.sh and release.sh. Source it; it defines functions only.
# No network, no keychain: Tests/SpoolCoreTests/ReleaseScriptTests.swift calls each function.
# shellcheck shell=bash

# Prints the value of KEY from a KEY=VALUE file (Packaging/updates.env). Prints nothing when the
# file or the key is missing. Comment lines start with "#". Quotes around the value are removed.
spool_updates_value() {
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
spool_version_valid() { [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }

# Status 0 when version $1 is higher than version $2 (both like 1.2.3).
spool_version_gt() {
    spool_version_valid "$1" && spool_version_valid "$2" || return 2
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
spool_changelog_section() {
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
spool_feed_url_for_repo() { printf 'https://github.com/%s/releases/latest/download/appcast.xml\n' "$1"; }

# The download prefix for the files of the latest release. README.md and the website link Spool.dmg there.
spool_latest_download() { printf 'https://github.com/%s/releases/latest/download/\n' "$1"; }

# The download prefix for the files of one release.
spool_download_prefix() { printf 'https://github.com/%s/releases/download/v%s/\n' "$1" "$2"; }

# Prints "<shortVersionString> <version>" of the item with the highest build number (sparkle:version).
# Status 1 when the appcast has no item with both values.
spool_appcast_latest() {
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
spool_appcast_check() {
    local file=$1 version=$2 build=$3 url=$4 length=$5 got
    local item="//item[1]" enc="//item[1]/enclosure"
    _spool_appcast_fail() { printf 'appcast: %s\n' "$*" >&2; return 1; }
    got=$(xmllint --xpath 'count(//item)' "$file" 2>/dev/null) || { _spool_appcast_fail "not valid XML"; return 1; }
    [[ "$got" == 1 ]] || { _spool_appcast_fail "expected 1 item, found $got"; return 1; }
    got=$(xmllint --xpath "string($item/*[local-name()='shortVersionString'])" "$file")
    [[ "$got" == "$version" ]] || { _spool_appcast_fail "shortVersionString is '$got', expected '$version'"; return 1; }
    got=$(xmllint --xpath "string($item/*[local-name()='version'])" "$file")
    [[ "$got" == "$build" ]] || { _spool_appcast_fail "version (build) is '$got', expected '$build'"; return 1; }
    got=$(xmllint --xpath "string($enc/@url)" "$file")
    [[ "$got" == "$url" ]] || { _spool_appcast_fail "enclosure url is '$got', expected '$url'"; return 1; }
    got=$(xmllint --xpath "string($enc/@length)" "$file")
    [[ "$got" == "$length" ]] || { _spool_appcast_fail "enclosure length is '$got', expected '$length'"; return 1; }
    got=$(xmllint --xpath "string($enc/@*[local-name()='edSignature'])" "$file")
    [[ -n "$got" ]] || { _spool_appcast_fail "the enclosure has no EdDSA signature"; return 1; }
    printf '%s\n' "$got"
}

# Status 0 when a designated requirement (the output of `codesign -d -r -`) pins the bundle ID
# and the certificate with SHA-1 $3. An ad hoc DR (cdhash) fails.
spool_dr_is_local() {
    local dr=$1 bundle=$2 hash
    hash=$(tr 'A-F' 'a-f' <<<"$3")
    [[ -n "$hash" && "$dr" == *"identifier \"$bundle\" and certificate leaf = H\"$hash\""* ]]
}

# Status 0 when $1 looks like an Apple Team ID: 10 capital letters and digits.
spool_team_id_valid() { [[ "$1" =~ ^[A-Z0-9]{10}$ ]]; }

# Status 0 when $1 is an Ed25519 public key as `spool-license keygen` prints it: 32 bytes in standard base64
# (44 characters, one "="), in the one canonical spelling. The value is public.
spool_license_key_valid() {
    local key=$1
    [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
    [[ "$(printf '%s' "$key" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" == 32 ]] || return 1
    [[ "$(printf '%s' "$key" | base64 -D 2>/dev/null | base64)" == "$key" ]]
}

# Prints every public key of the license test vectors file $1 (docs/license-test-vectors.json), one per
# line: publicKeyA, publicKeyB, and any later publicKey<X>. Their seeds are public, so a build with one of
# them accepts keys that anyone can make. Status 1 when the file has none.
spool_license_test_keys() {
    [[ -f "$1" ]] || return 1
    local name key found=0
    for name in $(plutil -convert json -o - "$1" 2>/dev/null | grep -o '"publicKey[A-Z]"' | tr -d '"'); do
        key=$(plutil -extract "$name" raw -o - "$1" 2>/dev/null) || continue
        [[ -n "$key" ]] || continue
        printf '%s\n' "$key"
        found=1
    done
    [[ $found -eq 1 ]]
}

# The code requirement that the app checks on its own bundle before it trusts its license public key
# (LicenseKeeper.trustRequirement in Swift; a test keeps the two equal). $1: the Team ID.
spool_license_trust_requirement() { printf 'anchor apple generic and certificate leaf[subject.OU] = "%s"\n' "$1"; }

# Status 0 when the app $1 has a public test key of the vectors file $2 as SpoolLicensePublicKey: a build
# of `make e2e`. Anyone can make license keys for it, so it must not be installed or put in a DMG.
spool_app_has_test_license_key() {
    local key keys
    key=$(plutil -extract SpoolLicensePublicKey raw -o - "$1/Contents/Info.plist" 2>/dev/null) || return 1
    keys=$(spool_license_test_keys "$2") || return 1
    grep -qxF -- "$key" <<< "$keys"
}

# Status 0 when a designated requirement (the output of `codesign -d -r -`) is the one of a Developer ID
# signature of team $3 for the bundle ID $2. macOS stores the Accessibility permission with this requirement.
# It names the team, not one certificate, so it stays the same when the certificate is renewed.
# The real form (codesign on macOS 26):
#   designated => identifier "B" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6]
#   /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and
#   certificate leaf[subject.OU] = "TEAMID"
# The two OIDs are the Developer ID intermediate and the Developer ID Application leaf. An Apple
# Development signature has other OIDs, so it fails here.
spool_dr_is_team() {
    local dr=$1 bundle=$2 team=$3
    spool_team_id_valid "$team" || return 1
    [[ "$dr" == *"designated => identifier \"$bundle\" and anchor apple generic and "* ]] || return 1
    [[ "$dr" == *"certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */"* ]] || return 1
    [[ "$dr" == *"certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */"* ]] || return 1
    [[ "$dr" == *"certificate leaf[subject.OU] = \"$team\""* || "$dr" == *"certificate leaf[subject.OU] = $team"* ]]
}

# Prints the SHA-1 of the first "Developer ID Application" identity of team $2 in $1, the output of
# `security find-identity -v -p codesigning`. Status 1 when there is none.
spool_developer_id_in() {
    local list=$1 team=$2
    spool_team_id_valid "$team" || return 1
    awk -v team="($team)\"" '
        $2 ~ /^[0-9A-F]{40}$/ && index($0, "\"Developer ID Application: ") && index($0, team) { print $2; found = 1; exit }
        END { exit !found }' <<<"$list"
}

# The status of a notarization from the JSON of `xcrun notarytool submit --output-format json`, for
# example "Accepted" or "Invalid". Status 1 when the JSON has no status.
spool_notary_status() { printf '%s' "$1" | plutil -extract status raw -o - - 2>/dev/null; }

# The submission ID from the same JSON, for `xcrun notarytool log <id>`. Status 1 when it has none.
spool_notary_id() { printf '%s' "$1" | plutil -extract id raw -o - - 2>/dev/null; }

# Status 0 when $1, the output of `spctl --assess -vv` (stdout and stderr), says Gatekeeper accepts the
# file as notarized. "Unnotarized Developer ID" means the ticket is not on the file: macOS on another
# Mac does not open it.
spool_gatekeeper_notarized() {
    [[ "$1" == *": accepted"* && $'\n'"$1"$'\n' == *$'\n'"source=Notarized Developer ID"$'\n'* ]]
}

# Prints each file under DIR that contains one of the other arguments as bytes (for example $HOME
# and $USER). Empty arguments are ignored. Status 0: no file has one. Status 1: a file has one.
# Status 2: the check failed (for example a file that cannot be read); grep tells why on stderr.
spool_private_strings() {
    local dir=$1 needle status=0
    shift
    local -a args=()
    for needle in "$@"; do [[ -n "$needle" ]] && args+=(-e "$needle"); done
    [[ ${#args[@]} -gt 0 ]] || return 0
    [[ -d "$dir" ]] || { echo "spool_private_strings: no such folder: $dir" >&2; return 2; }
    LC_ALL=C grep -rlF "${args[@]}" "$dir" || status=$?
    case $status in
        0) return 1 ;;
        1) return 0 ;;
        *) return 2 ;;
    esac
}

# The verdict of spool_private_strings for release.sh: status 0 when DIR is clean. Else status 1 and
# a message for LABEL on stdout. A check that could not run is a failure, never "clean".
spool_release_private_check() {
    local dir=$1 label=$2 leaks status=0
    shift 2
    leaks=$(spool_private_strings "$dir" "$@") || status=$?
    case $status in
        0) return 0 ;;
        1) printf 'files in %s contain your home path, user name or Git email:\n%s\n' "$label" "$leaks" ;;
        *) printf 'cannot check %s for your home path, user name or Git email (see the error above)\n' "$label" ;;
    esac
    return 1
}

# Status 0 when the releases repository REPO has no release TAG (also when REPO does not exist).
# Status 1 with advice on stdout for a draft or a published release; status 2 when gh cannot tell.
spool_release_existing() {
    local tag=$1 repo=$2 out err status=0
    err=$(mktemp "${TMPDIR:-/tmp}/spool-gh.XXXXXX") || return 2
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

# release.sh asks this when the feed FEED of the releases repository REPO returns 404.
# Status 0 when REPO has no published release, or does not exist yet (the first release makes it).
# Status 1 with a message on stdout when REPO has a published release: then the feed must exist.
# Status 2 with a message on stdout when gh cannot tell (network, rate limit, login): never "none".
spool_release_none_published() {
    local repo=$1 feed=$2 out err status=0 msg
    err=$(mktemp "${TMPDIR:-/tmp}/spool-gh.XXXXXX") || return 2
    out=$(gh release list --repo "$repo" --exclude-drafts --limit 1 --json tagName --jq length 2>"$err") || status=$?
    msg=$(<"$err")
    rm -f "$err"
    if [[ $status -ne 0 ]]; then
        [[ "$msg" == *"Could not resolve to a Repository"* ]] && return 0
        printf 'cannot list the releases of %s: %s\n' "$repo" "$msg"
        return 2
    fi
    case "$out" in
        0) return 0 ;;
        [1-9]*)
            printf '%s has published releases but no feed at %s. Fix the latest release first.\n' "$repo" "$feed"
            return 1 ;;
        *)
            printf 'unexpected answer from gh release list --repo %s: %s\n' "$repo" "$out"
            return 2 ;;
    esac
}

# Status 0 when HEAD is COMMIT. With "clean" as the second argument, the working tree must also have
# no changes. release.sh checks this after the build: the files must come from COMMIT.
spool_release_head_is() {
    local commit=$1 head
    head=$(git rev-parse HEAD) || return 1
    [[ "$head" == "$commit" ]] || { echo "HEAD moved from $commit to $head during the release" >&2; return 1; }
    if [[ "${2:-}" == clean && -n "$(git status --porcelain)" ]]; then
        echo "the working tree changed during the release" >&2
        return 1
    fi
}

# Tags COMMIT (not HEAD) with TAG in this repository: the source of the release. Nothing is pushed.
spool_release_tag() { git tag "$1" "$2"; }

# Status 0 when COMMIT is on the branch main of REPO (the source repository) on GitHub: a release is
# built from reviewed, pushed code. Status 1 with advice on stdout when it is not on main;
# status 2 with a message on stdout when gh cannot tell.
spool_release_commit_on_main() {
    local repo=$1 commit=$2 out err status=0 msg
    err=$(mktemp "${TMPDIR:-/tmp}/spool-gh.XXXXXX") || return 2
    # base...head: "identical" or "ahead" means main has COMMIT.
    out=$(gh api "repos/$repo/compare/$commit...main" --jq .status 2>"$err") || status=$?
    msg=$(<"$err")
    rm -f "$err"
    if [[ $status -ne 0 ]]; then
        if [[ "$msg" == *"HTTP 404"* ]]; then
            printf 'the commit %s is not on GitHub. Push main first: git push origin main\n' "$commit"
            return 1
        fi
        printf 'cannot compare %s with main of %s: %s\n' "$commit" "$repo" "$msg"
        return 2
    fi
    case "$out" in
        identical|ahead) return 0 ;;
        behind|diverged)
            printf 'the commit %s is not on main of %s (%s). Push main first: git push origin main\n' "$commit" "$repo" "$out"
            return 1 ;;
        *)
            printf 'unexpected answer from gh api compare for %s: %s\n' "$repo" "$out"
            return 2 ;;
    esac
}

# Prints the commit of the tag TAG in REPO on GitHub. Prints nothing (status 0) when the tag does not
# exist. Status 2 with a message on stdout when gh cannot tell.
spool_release_remote_tag() {
    local repo=$1 tag=$2 out err status=0 msg
    err=$(mktemp "${TMPDIR:-/tmp}/spool-gh.XXXXXX") || return 2
    out=$(gh api "repos/$repo/commits/refs/tags/$tag" --jq .sha 2>"$err") || status=$?
    msg=$(<"$err")
    rm -f "$err"
    if [[ $status -ne 0 ]]; then
        [[ "$msg" == *"HTTP 404"* || "$msg" == *"HTTP 422"* ]] && return 0
        printf 'cannot read the tag %s of %s: %s\n' "$tag" "$repo" "$msg"
        return 2
    fi
    [[ "$out" =~ ^[0-9a-f]{40}$ ]] || { printf 'unexpected answer from gh api for the tag %s: %s\n' "$tag" "$out"; return 2; }
    printf '%s\n' "$out"
}

# Status 0 when the files in DIR were built from the commit HEAD. The release writes
# DIR/commit.txt; the build number alone does not identify a commit (two branches can have the same count).
spool_release_commit_check() {
    local dir=$1 built head
    [[ -f "$dir/commit.txt" ]] || { echo "$dir/commit.txt is missing" >&2; return 1; }
    built=$(<"$dir/commit.txt")
    head=$(git rev-parse HEAD) || return 1
    [[ "$built" == "$head" ]] || { echo "$dir was built from commit $built, HEAD is $head. Check out $built first." >&2; return 1; }
}

# The EXIT trap of release.sh: detach the DMG if it is still mounted at DIR/dmg, then delete DIR.
# If the DMG does not detach, DIR is kept: rm -rf must not run into a mounted volume.
spool_release_cleanup() {
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
spool_appcast_latest_url() {
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
spool_sha1_equal() {
    local a b
    a=$(tr -d ' :' <<<"$1" | tr 'a-f' 'A-F')
    b=$(tr -d ' :' <<<"$2" | tr 'a-f' 'A-F')
    [[ "$a" =~ ^[0-9A-F]{40}$ && "$a" == "$b" ]]
}

# Status 0 when $1 can be the settings file: a file, or /dev/null (no settings, so no pin).
# A path to a missing file must stop the caller: reading it gives no pin, and the pin then is off
# without a word.
spool_updates_env_usable() { [[ -f "$1" || "$1" == /dev/null ]]; }

# Which identity a build signs with. $1: the Team ID of the releases (SPOOL_TEAM_ID, empty: none).
# $2: the SHA-1 of a Developer ID Application identity of that team in the keychain (empty: none).
# $3: the SHA-1 of the self-signed identity of make-signing-cert.sh (empty: none).
# $4: SIGN_IDENTITY (empty: not set). Prints one word:
#   explicit  SIGN_IDENTITY is set: sign with it.
#   release   sign with the Developer ID of the team: the identity of the releases. The Accessibility
#             permission stays after every update.
#   local     sign with the self-signed identity. The permission stays after a rebuild, but not after
#             an update to a release (another signature).
#   missing   a team is set, but this Mac has neither identity. An ad hoc build here is a trap: a grant
#             given to it stores cdhashes, and turning the switch off and on keeps them, so no later
#             build matches.
#   adhoc     no team and no identity: sign ad hoc.
spool_build_identity() {
    local team=$1 devid=$2 hash=$3 explicit=$4
    if [[ -n "$explicit" ]]; then echo explicit
    elif [[ -n "$team" && -n "$devid" ]]; then echo release
    elif [[ -n "$hash" ]]; then echo local
    elif [[ -n "$team" ]]; then echo missing
    else echo adhoc
    fi
}

# How to get a signature that keeps the Accessibility permission after a rebuild. $1: the Team ID of the
# releases (empty: none).
spool_stable_identity_hint() {
    local text="To keep the permission after a rebuild: run scripts/make-signing-cert.sh once, or sign with
your own Apple Development or Developer ID identity: SIGN_IDENTITY=\"<name or SHA-1>\" make install."
    [[ -z "$1" ]] || text+="
To use Spool without a build: install the notarized release."
    echo "$text See docs/INSTALL.md."
}

# The message when Packaging/updates.env names the team of the releases and build-app.sh finds no
# identity to sign with. $1: the Team ID. An ad hoc build is not the default here: a grant for it stops
# working after the next build.
spool_missing_identity_message() {
    echo "No signing identity. Packaging/updates.env names the team $1 of the releases, but this Mac has no
\"Developer ID Application\" identity of that team, and no identity from scripts/make-signing-cert.sh.
To use Spool: install the notarized release. It updates itself (docs/INSTALL.md).
To build Spool yourself, make a free identity once: scripts/make-signing-cert.sh, then make install.
Or sign with your own Apple identity: SIGN_IDENTITY=\"<name or SHA-1>\" make install.
The maintainer: install the Developer ID certificate of team $1 (Xcode > Settings > Accounts > Manage Certificates).
Do not use an ad hoc build as your normal build: when you give it the Accessibility permission, macOS
stores its cdhash, and no later build matches, even when the switch shows on. See docs/INSTALL.md.
For a test build or the E2E test only: SIGN_IDENTITY=- make app (or make e2e)."
}

# How an app to install is signed, against the team of the releases. $1: the Team ID (empty: none).
# $2: the designated requirement of the app (the output of `codesign -d -r -`). $3: the bundle ID.
# Prints one word:
#   nopin   no team is set.
#   pinned  the app has the Developer ID signature of the team, like the releases.
#   adhoc   the app is signed ad hoc (its requirement is only cdhashes): an Accessibility entry for it
#           stops working after the next build, while the switch still shows on.
#   other   the app is signed with another identity: an Accessibility entry for it stops working after
#           an update (releases are signed by the team), while the switch still shows on.
spool_install_signature() {
    local dr
    # codesign prints an ad hoc requirement as a comment: "# designated => cdhash H\"...\"".
    dr=$(sed -n 's/^#* *designated => //p' <<<"$2")
    if [[ -z "$1" ]]; then echo nopin
    elif spool_dr_is_team "$2" "$3" "$1"; then echo pinned
    elif [[ "$dr" == "cdhash "* ]]; then echo adhoc
    else echo other
    fi
}
