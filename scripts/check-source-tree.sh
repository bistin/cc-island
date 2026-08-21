#!/bin/bash
# Fail when the README's Sources/ tree and the files on disk disagree.
#
# The tree is what somebody reads to find their way around before they know the names of
# anything, which makes being wrong about it expensive in a way most stale docs are not: a
# missing file is a whole area of the app that a newcomer never learns exists, and a file that
# was renamed away sends them looking for something that is not there.
#
# It listed 19 of 44 files when this was written — not by decision, just by nobody going back.
# A curated "the important ones" cannot be checked by anything; "all of them" can, which is the
# whole reason the tree is now complete.
set -uo pipefail
cd "$(dirname "$0")/.."

status=0
fail() { echo "  ✗ $*"; echo "::error::$*"; status=1; }

block=$(awk '/^Sources\/$/{on=1} on{print} /^Tests\/$/{on=0}' README.md)
if [ -z "$block" ]; then
  fail "README.md has no Sources/ tree any more — restore it, or delete this check on purpose"
  exit 1
fi

listed=$(printf '%s\n' "$block" | grep -oE '[A-Za-z+]+\.swift' | sort -u)
actual=$(find Sources -name '*.swift' -exec basename {} \; | sort -u)

missing=$(comm -13 <(printf '%s\n' "$listed") <(printf '%s\n' "$actual"))
extra=$(comm -23 <(printf '%s\n' "$listed") <(printf '%s\n' "$actual"))

if [ -n "$missing" ]; then
  fail "these files exist but the README tree does not list them:$(printf ' %s' $missing)"
fi
if [ -n "$extra" ]; then
  fail "the README tree names files that no longer exist:$(printf ' %s' $extra)"
fi

[ $status -eq 0 ] && echo "  ✓ the README tree lists every file under Sources/, and no others"
exit $status
