#!/usr/bin/env bash
# The quiet test lane: runs only the test suites that start no process and make no executable file.
#
# Why: on a managed Mac the endpoint security tool watches what the test helper (swiftpm-testing-helper) does.
# Tests that write fake tools (for example a script named `security`) and run them raised an alert. A quiet
# suite only computes in memory and reads or writes plain data files.
#
# A test file is quiet when it has none of these:
#   - a process start: Process(, executableURL, posix_spawn, NSTask, popen(, system(
#   - a permission with an execute bit (posixPermissions: 0o755 and so on). A line that only gives a folder back
#     its permissions can stay quiet: put the comment `quiet-lane: folder` on that line.
# Every type at the start of a line in a quiet file is a suite of the lane. A quiet file with a top-level @Test
# function stops the script: such a test has no suite name to select.
#
# Usage:
#   scripts/quiet-tests.sh            run the quiet suites
#   scripts/quiet-tests.sh --list     print the quiet and the loud files, run nothing
#   scripts/quiet-tests.sh --filter X run only the quiet suites whose name matches the extended regex X
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

LIST=0
ONLY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list) LIST=1; shift ;;
        --filter) [[ $# -ge 2 ]] || { echo "quiet-tests: --filter needs a regex" >&2; exit 2; }; ONLY=$2; shift 2 ;;
        *) echo "quiet-tests: unknown option $1" >&2; exit 2 ;;
    esac
done

readonly SPAWN='Process\(|executableURL|posix_spawn|NSTask|popen\(|(^|[^A-Za-z_.])system\('
readonly EXEC_BITS='posixPermissions:[[:space:]]*0o[0-7]*[1357][0-7]*'

# Prints why a file is loud, or nothing when it is quiet.
loud_reason() {
    local f=$1 hit
    hit=$(grep -nE "$SPAWN" "$f" | head -1 || true)
    [[ -z "$hit" ]] || { echo "starts a process (line ${hit%%:*})"; return; }
    hit=$(grep -nE "$EXEC_BITS" "$f" | grep -v 'quiet-lane: folder' | head -1 || true)
    [[ -z "$hit" ]] || echo "sets an execute bit (line ${hit%%:*})"
}

FILTERS=()
for dir in Tests/*/; do
    target=$(basename "$dir")
    suites=()
    for f in "$dir"*.swift; do
        [[ -e "$f" ]] || continue
        why=$(loud_reason "$f")
        if [[ -n "$why" ]]; then
            [[ $LIST -eq 1 ]] && echo "loud   $f: $why"
            continue
        fi
        if grep -nE '^@Test' "$f" >/dev/null; then
            echo "quiet-tests: $f has a top-level @Test function. Put it in a suite type." >&2
            exit 1
        fi
        names=$(grep -oE '^(@Suite[^{]*[[:space:]])?(final[[:space:]]+)?(struct|class|enum)[[:space:]]+[A-Za-z0-9_]+' "$f" \
            | awk '{ print $NF }' || true)
        while IFS= read -r n; do
            [[ -n "$n" ]] || continue
            [[ -z "$ONLY" || "$n" =~ $ONLY ]] || continue
            suites+=("$n")
        done <<<"$names"
        [[ $LIST -eq 1 ]] && echo "quiet  $f: $(tr '\n' ' ' <<<"$names")"
    done
    if [[ ${#suites[@]} -gt 0 ]]; then
        FILTERS+=(--filter "$target\\.($(IFS='|'; echo "${suites[*]}"))/")
    fi
done

[[ $LIST -eq 0 ]] || exit 0
[[ ${#FILTERS[@]} -gt 0 ]] || { echo "quiet-tests: no quiet suite matches" >&2; exit 1; }

PLUGINS="$(xcode-select -p 2>/dev/null)/usr/lib/swift/host/plugins/testing"
FLAGS=()
[[ -d "$PLUGINS" ]] && FLAGS=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
# Never the opt-in signing suite, also when the caller has the variable set.
exec env -u STRIPLE_SIGNING_TESTS swift test ${FLAGS[@]+"${FLAGS[@]}"} "${FILTERS[@]}"
