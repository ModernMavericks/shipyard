#!/bin/sh
# shipyard-version.sh: the LINE is committed (UPSTREAM_VERSION); the PATCH is the commit count, so a
# new commit is necessarily a new version. This is what UPSTREAM_VERSION alone could not do: it sat at
# 1.0.5 across 13 commits that each shipped to fifteen repos through the moving @v1 tag.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/shipyard-version.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/shipyard-version.XXXXXX")"; trap 'rm -rf "$work"' EXIT

mkrepo() {  # $1 = dir, $2 = line, $3 = number of commits
  mkdir -p "$1"; cd "$1"
  git init -q -b main .
  git config user.email t@example.com; git config user.name tester
  printf '%s\n' "$2" > UPSTREAM_VERSION
  mkdir -p scripts; cp "$S" scripts/
  i=0; while [ "$i" -lt "$3" ]; do echo "$i" > f; git add -A; git commit -qm "c$i"; i=$((i + 1)); done
}

mkrepo "$work/a" 1.0 3
out="$(sh scripts/shipyard-version.sh)"
[ "$(printf '%s\n' "$out" | sed -n 's/^FULL=//p')" = "1.0.3" ] \
  || { echo "FAIL: 3 commits on line 1.0 should be 1.0.3; got: $out"; exit 1; }
[ "$(printf '%s\n' "$out" | sed -n 's/^TAG=//p')" = "v1.0.3" ] \
  || { echo "FAIL: TAG should be v1.0.3; got: $out"; exit 1; }

# One more commit is one more version. This is the whole point.
echo more > f; git add -A; git commit -qm c3
[ "$(sh scripts/shipyard-version.sh | sed -n 's/^FULL=//p')" = "1.0.4" ] \
  || { echo "FAIL: a new commit must produce a new version"; exit 1; }

# A deliberate line bump keeps the count climbing, so versions stay monotonic across lines.
printf '2.0\n' > UPSTREAM_VERSION; git add -A; git commit -qm 'line 2.0'
[ "$(sh scripts/shipyard-version.sh | sed -n 's/^FULL=//p')" = "2.0.5" ] \
  || { echo "FAIL: a line bump must not restart the patch"; exit 1; }

# A full version left in UPSTREAM_VERSION is the mistake this replaces -- refuse it loudly rather
# than silently emitting 1.0.5.7.
mkrepo "$work/b" 1.0.5 2
if sh scripts/shipyard-version.sh >/dev/null 2>&1; then
  echo "FAIL: UPSTREAM_VERSION with a patch component should be refused"; exit 1
fi
sh scripts/shipyard-version.sh 2>&1 | grep -qi 'line' \
  || { echo "FAIL: the refusal should say UPSTREAM_VERSION holds the LINE"; exit 1; }

echo "PASS: shipyard-version"
