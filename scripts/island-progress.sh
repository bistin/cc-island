#!/bin/bash
# island-progress.sh — stream progress to Dynamic Island
#
# Modes:
#   1. Direct:  island-progress.sh <title> <current> <total>
#               e.g. island-progress.sh "Upload" 45 100
#
#   2. Pipe:    <cmd> 2>&1 | island-progress.sh <title>
#               Parses "[N/M]" patterns from stdin (works with swift build,
#               cargo build, xcodebuild, etc.). Forwards all output unchanged.
#               e.g. swift build 2>&1 | island-progress.sh "Build"
#
# Send the same <title> across updates — the island swaps progress in place
# without re-animating the ear. When progress hits 100%, the event shows
# briefly with success style then auto-dismisses.

set -u

TITLE="${1:-Task}"
PORT="${DYNAMIC_ISLAND_PORT:-9423}"
URL="http://127.0.0.1:$PORT/event"

post() {
    local cur="$1" tot="$2"
    local prog style
    prog=$(awk "BEGIN{printf \"%.3f\", $cur/$tot}")
    if [ "$cur" -ge "$tot" ]; then
        style="success"
    else
        style="claude"
    fi
    curl -s -X POST "$URL" \
        -H "Content-Type: application/json" \
        -d "{\"title\":\"$TITLE\",\"subtitle\":\"$cur/$tot\",\"progress\":$prog,\"style\":\"$style\"}" \
        > /dev/null 2>&1 &
}

# Direct mode
if [ $# -ge 3 ]; then
    post "$2" "$3"
    exit 0
fi

# Pipe mode: forward stdin, sniff "[N/M]" lines for progress
while IFS= read -r line; do
    printf '%s\n' "$line"
    if [[ "$line" =~ \[([0-9]+)/([0-9]+)\] ]]; then
        post "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    fi
done
