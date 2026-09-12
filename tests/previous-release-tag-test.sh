#!/bin/sh
# previous-release-tag.sh: newest release tag, version-ordered (1.102.0 > 1.98.8, N=10 > N=9).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/previous-release-tag.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/previous-release-tag.XXXXXX")"; trap 'rm -rf "$work"' EXIT
cd "$work"
git init -q -b main .
git config user.email t@example.com; git config user.name tester
echo hi > f; git add f; git commit -qm base

# no tags at all -> nothing
out="$(sh "$S")"
[ -z "$out" ] || { echo "FAIL no-tags: got '$out'"; exit 1; }

git tag 1.98.8-mavericks.1
git tag 1.98.8-mavericks.2
git tag 1.102.0-mavericks.1
git tag v1                 # not a release tag; must be ignored

# version ordering: 1.102.0 sorts after 1.98.8 (numeric minor, not lexical)
out="$(sh "$S")"
[ "$out" = 1.102.0-mavericks.1 ] || { echo "FAIL newest: got '$out'"; exit 1; }

# excluding the tag being published yields its predecessor
out="$(sh "$S" 1.102.0-mavericks.1)"
[ "$out" = 1.98.8-mavericks.2 ] || { echo "FAIL exclude: got '$out'"; exit 1; }

# N ordering is numeric: .10 beats .9
git tag 1.102.0-mavericks.9; git tag 1.102.0-mavericks.10
out="$(sh "$S")"
[ "$out" = 1.102.0-mavericks.10 ] || { echo "FAIL N-order: got '$out'"; exit 1; }

# A repo with parallel upstream lines needs the baseline from its OWN line: 1.26.7's notes must diff
# against 1.26.5, not against a 1.27.0 that shipped in between.
git tag 1.26.5-mavericks.1; git tag 1.26.7-mavericks.1; git tag 1.27.0-mavericks.1
out="$(sh "$S" '' '1.26.*')"
[ "$out" = 1.26.7-mavericks.1 ] || { echo "FAIL line filter: got '$out'"; exit 1; }
out="$(sh "$S" 1.26.7-mavericks.1 '1.26.*')"
[ "$out" = 1.26.5-mavericks.1 ] || { echo "FAIL line filter + exclude: got '$out'"; exit 1; }
# no filter still means "newest overall" across every line -- 1.102.0 outranks 1.27.0 (sort -V), which
# is exactly why a repo with parallel lines must pass the filter rather than trust the default.
out="$(sh "$S")"
[ "$out" = 1.102.0-mavericks.10 ] || { echo "FAIL unfiltered newest: got '$out'"; exit 1; }

# An openssh-shaped repo: the upstream carries a letter (9.9p2), so the comparison key must map pN
# before ordering. This repo found NO baseline for its whole life, so every release silently omitted
# its ingredient section.
git tag 9.9p2-mavericks.4; git tag 9.9p2-mavericks.5
out="$(sh "$S" 9.9p2-mavericks.5 '9.9p2')"
[ "$out" = 9.9p2-mavericks.4 ] || { echo "FAIL pN baseline: got '$out'"; exit 1; }

# --- self-upstream tag shapes ------------------------------------------------------------------
# shipyard/magic-trackpad2 are vX.Y.Z; porthole is YYYYMMDD.N. Neither matches *-mavericks.*, so
# without --glob every one of their releases reports "no baseline" and drops its compare link.
git tag v1.0.5; git tag v1.0.191; git tag v1.0.192
out="$(sh "$S" --glob 'v[0-9]*' v1.0.192)"
[ "$out" = v1.0.191 ] || { echo "FAIL v-shaped newest below excluded: got '$out'"; exit 1; }

# The moving major tag v1 (tagged earlier in this file, so it's already in the repo) is a real tag
# in shipyard and must never be chosen as a baseline: a compare link against it says "everything
# since whenever v1 last moved," which is not a release. Stripping the leading "v" before keying
# makes v1 compare as bare "1", which orders below every real v1.0.N, so it can never win here.
out="$(sh "$S" --glob 'v[0-9]*' v1.0.192)"
[ "$out" = v1.0.191 ] || { echo "FAIL v-shaped v1 never wins: got '$out'"; exit 1; }

git tag 20260802.4; git tag 20260802.5
git tag feed-porthole            # not a release tag; must be ignored
git tag backup/pre-rewrite       # not a release tag; must be ignored
out="$(sh "$S" --glob '[0-9]*' 20260802.5)"
[ "$out" = 20260802.4 ] || { echo "FAIL date-shaped newest: got '$out'"; exit 1; }

# --glob and a positional upstream-glob fight over the same slot; silently picking one is how a
# caller gets a baseline from a tag set it did not ask about.
out="$(sh "$S" --glob 'v[0-9]*' v1.0.192 1.26 2>&1)" && rc=0 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL --glob/positional mutual exclusion: got exit $rc (output: $out)"; exit 1; }

# Unchanged: every existing positional call still means what it meant. Fresh tags here (not reused
# from above) so this cannot pass by accident against an already-tagged pair.
git tag 9.9p3-mavericks.1; git tag 9.9p3-mavericks.2
out="$(sh "$S" 9.9p3-mavericks.2)"
[ "$out" = 9.9p3-mavericks.1 ] || { echo "FAIL positional form untouched: got '$out'"; exit 1; }

echo "PASS: previous-release-tag"
