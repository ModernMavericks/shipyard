#!/bin/sh
# Print the newest existing release tag (<upstream>-mavericks.N), or nothing when there is none.
# Generated release notes use it as the "changed since" baseline.
#   usage: previous-release-tag.sh [--glob PATTERN] [tag-to-exclude] [upstream-glob]
# The glob scopes the search to one upstream line ('1.26.*'), which a repo shipping parallel lines
# needs: 1.26.7's notes must diff against 1.26.5, not against a 1.27.0 that shipped in between.
# Pass the tag being published so a tag-triggered build compares against its PREDECESSOR, not itself
# (a dispatch-cut repackage has no tag yet, so excluding it is harmless there).
# Ordering is version-aware: 1.102.0 sorts after 1.98.8, and N=10 after N=9, both of which a lexical
# sort gets wrong. It uses lib.sh's ver_cmp rather than `sort -V`, which the 10.9 box's BSD sort does
# not have -- with -V this script worked in CI and failed on the platform the family targets.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$SELF/lib.sh"          # numeric(), ver_cmp(), comparison_key()

# --glob takes the pattern VERBATIM, for a product whose releases are not <upstream>-mavericks.N:
# shipyard and magic-trackpad2 tag vX.Y.Z, porthole tags YYYYMMDD.N. The positional upstream-glob is
# a PREFIX ("1.26") that gets "-mavericks.*" appended, so it cannot express either shape -- which is
# why all three shipped every release with no baseline, and therefore no compare link and no
# ingredient section, at exit 0.
pattern=""
while [ $# -gt 0 ]; do
  case "$1" in
    --glob) pattern="${2:?previous-release-tag: --glob needs a pattern}"; shift 2 ;;
    *) break ;;
  esac
done

exclude="${1:-}"
if [ -z "$pattern" ]; then
  pattern="*-mavericks.*"
  [ -z "${2:-}" ] || pattern="${2}-mavericks.*"
else
  # Silently ignoring one of two conflicting patterns is how a caller gets a baseline from a tag set
  # it did not ask about.
  [ -z "${2:-}" ] || {
    echo "previous-release-tag: --glob and a positional upstream-glob are mutually exclusive" >&2
    exit 2
  }
fi

# The comparison key drops the "-mavericks." separator to a dot, exactly as gen_appcast.sh derives the
# appcast's, so N orders as a final numeric component. A tag whose key is not purely dotted-numeric is
# outside the comparator's domain and is skipped rather than silently mis-ordered.
best_tag=""; best_key=""
for t in $(git tag --list "$pattern"); do
  [ "$t" = "$exclude" ] && continue
  # A leading "v" is not part of the version. Without stripping it, numeric() rejects every vX.Y.Z
  # tag and a v-shaped repo has no baseline however it is globbed. Harmless for -mavericks. tags,
  # which carry no "v", and it leaves shipyard's moving "v1" tag comparing as 1 -- below every real
  # v1.0.N, so it can never be chosen as a baseline.
  k="$(comparison_key "${t#v}")"
  numeric "$k" || continue
  if [ -z "$best_key" ] || [ "$(ver_cmp "$k" "$best_key")" = 1 ]; then best_key="$k"; best_tag="$t"; fi
done

[ -z "$best_tag" ] || printf '%s\n' "$best_tag"
