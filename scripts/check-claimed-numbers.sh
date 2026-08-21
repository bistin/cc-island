#!/bin/bash
# Fail when a number quoted in the docs disagrees with the code it describes.
#
# A number in prose is a claim like any other, and it is the kind that goes stale
# silently: nothing breaks, nothing warns, and a reader who finds "68 tests" next to a
# run of 143 learns that the docs are not maintained before they learn anything else.
# This ran red the first time it was written — see the commit that added it.
#
# **A claim that cannot be found is a failure, not a skip.** That is the whole design.
# The obvious way to write this is "if the pattern matched, compare it", which turns
# every reworded sentence into a check that quietly stops checking while still reporting
# green. So `claim` fails loudly when its pattern finds nothing: either put the sentence
# back, or come here and say what it looks like now.
#
# Truth always comes from the code, never from a second copy of the number kept here.
set -uo pipefail
cd "$(dirname "$0")/.."

status=0
fail() { echo "  ✗ $*"; echo "::error::$*"; status=1; }
ok()   { echo "  ✓ $*"; }

# claim <label> <file> <sed-script> — sets $CLAIM, or fails and returns 1.
claim() {
  CLAIM=$(sed -n "$3" "$2" | head -1)
  [ -n "$CLAIM" ] && return 0
  fail "$1: $2 carries no such claim — it was either reworded, or it is new and undocumented. Write it down, or teach this script the new shape."
  return 1
}

compare() {  # compare <label> <actual> <claimed>
  if [ "$2" = "$3" ]; then ok "$1: $2"; else fail "$1: the docs say $3, the code says $2"; fi
}

echo "→ test counts"
# `swift test --list-tests` rather than counting `func test` with grep: it is the list
# SwiftPM will actually run, so a test that is defined but not collected cannot inflate it.
listing=$(swift test --list-tests 2>/dev/null)
if [ -z "$listing" ]; then
  fail "could not list tests — 'swift test --list-tests' produced nothing"
else
  total=$(printf '%s\n' "$listing" | wc -l | tr -d ' ')
  claim "total test count" README.md 's|^# Run unit tests (\([0-9][0-9]*\) tests.*|\1|p' \
    && compare "total" "$total" "$CLAIM"

  # Per target, derived from what is on disk rather than from a list kept here, so a new
  # test target has to be documented before CI will go green with it.
  for dir in Tests/*/; do
    target=$(basename "$dir")
    actual=$(printf '%s\n' "$listing" | grep -c "^${target}\.")
    claim "$target" README.md "s|^.*${target}/[^#]*#[[:space:]]*\([0-9][0-9]*\) tests.*|\1|p" \
      && compare "$target" "$actual" "$CLAIM"
  done
fi

echo "→ the port the app listens on"
port=$(grep -oE 'port: UInt16 = [0-9]+' Sources/DynamicIsland/LocalServer.swift | grep -oE '[0-9]+$' | head -1)
if [ -z "$port" ]; then
  fail "could not read the default port out of Sources/DynamicIsland/LocalServer.swift"
else
  # Every port the docs name, from either shape it is written in. A doc that has stopped
  # naming it at all is also a failure: this check would otherwise pass by covering nothing.
  # README.zh-TW.md is in the list because a translation is a second place for the
  # number to be wrong, and the one nobody rereads.
  docs_with_port="README.md CLAUDE.md"
  [ -f README.zh-TW.md ] && docs_with_port="$docs_with_port README.zh-TW.md"
  # shellcheck disable=SC2086
  mentioned=$(grep -ohE '127\.0\.0\.1:[0-9]{4,5}|port [0-9]{4,5}' $docs_with_port \
              | grep -oE '[0-9]{4,5}' | sort -u)
  if [ -z "$mentioned" ]; then
    fail "port: none of the READMEs or CLAUDE.md names it any more — this check is covering nothing"
  else
    wrong=$(printf '%s\n' "$mentioned" | grep -v "^${port}$")
    if [ -n "$wrong" ]; then
      fail "port: the docs name $(printf '%s' "$wrong" | tr '\n' ' '), the code defaults to $port"
    else
      ok "port: $port"
    fi
  fi
fi

echo "→ the permission long-poll horizon"
timeout=$(grep -oE 'PermissionTimeoutSeconds: TimeInterval = [0-9]+' Sources/IslandHookCore/StopReply.swift \
          | grep -oE '[0-9]+$' | head -1)
if [ -z "$timeout" ]; then
  fail "could not read PermissionTimeoutSeconds out of Sources/IslandHookCore/StopReply.swift"
else
  claim "permission timeout" CLAUDE.md 's|.*PermissionTimeoutSeconds` = \([0-9][0-9]*\).*|\1|p' \
    && compare "permission timeout" "$timeout" "$CLAIM"
fi

echo
if [ $status -eq 0 ]; then
  echo "✓ every number the docs claim matches the code"
else
  echo "!! a number in the docs no longer matches the code — fix the docs, not this script,"
  echo "   unless the code is what moved."
fi
exit $status
