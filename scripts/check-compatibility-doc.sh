#!/bin/bash
# Fail when docs/compatibility.md disagrees with the table it is generated from.
#
# The page lists what this app assumes about Claude Code, tmux and macOS — none of which is an
# API. A page like that maintained by hand is wrong by the second release: somebody adds a
# dependency in code, nobody remembers the page, and it quietly starts describing an older build
# while looking authoritative. So the table lives in Swift and the page is printed from it.
#
# Run with --write to regenerate after changing the table.
set -uo pipefail
cd "$(dirname "$0")/.."

DOC="docs/compatibility.md"
generated=$(swift run --quiet DynamicIsland --compat-table 2>/dev/null)
if [ -z "$generated" ]; then
  echo "  ✗ could not generate the table — 'swift run DynamicIsland --compat-table' produced nothing"
  echo "::error::compatibility table could not be generated"
  exit 1
fi

if [ "${1:-}" = "--write" ]; then
  printf '%s\n' "$generated" > "$DOC"
  echo "  ✓ wrote $DOC"
  exit 0
fi

if [ ! -f "$DOC" ]; then
  echo "  ✗ $DOC is missing — regenerate it with: scripts/check-compatibility-doc.sh --write"
  echo "::error::$DOC is missing"
  exit 1
fi

status=0

# Every file the table points at must exist. A table that names a file nobody renamed it away
# from is the failure mode this whole page exists to avoid: authoritative-looking and wrong.
missing=""
for path in $(printf '%s\n' "$generated" \
              | grep -oE '[A-Za-z][A-Za-z-]*/[A-Za-z+]+\.swift' | sort -u); do
  [ -f "Sources/$path" ] || missing="$missing $path"
done
if [ -n "$missing" ]; then
  echo "  ✗ the table names files that do not exist under Sources/:$missing"
  echo "::error::compatibility table points at missing files:$missing"
  status=1
fi

if diff -q <(printf '%s\n' "$generated") "$DOC" >/dev/null; then
  [ $status -eq 0 ] && echo "  ✓ $DOC matches Compat.dependencies, and every file it names exists"
  exit $status
fi

echo "  ✗ $DOC no longer matches Compat.dependencies:"
diff <(printf '%s\n' "$generated") "$DOC" | head -20
echo
echo "  regenerate with: scripts/check-compatibility-doc.sh --write"
echo "::error::$DOC is out of date"
exit 1
