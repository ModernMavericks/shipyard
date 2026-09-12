#!/bin/sh
# Print the newest existing release tag (<upstream>-mavericks.N), or nothing when there is none.
# Generated release notes use it as the "changed since" baseline.
#   usage: previous-release-tag.sh [tag-to-exclude] [upstream-glob]
# The glob scopes the search to one upstream line ('1.26.*'), which a repo shipping parallel lines
# needs: 1.26.7's notes must diff against 1.26.5, not against a 1.27.0 that shipped in between.
# Pass the tag being published so a tag-triggered build compares against its PREDECESSOR, not itself
# (a dispatch-cut repackage has no tag yet, so excluding it is harmless there).
# Ordering is version-aware: 1.102.0 sorts after 1.98.8, and N=10 after N=9, both of which a lexical
# sort gets wrong. It uses lib.sh's ver_cmp rather than `sort -V`, which the 10.9 box's BSD sort does
# not have -- with -V this script worked in CI and failed on the platform the family targets.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$SELF/lib.sh"          # numeric(), ver_cmp()

exclude="${1:-}"
pattern="*-mavericks.*"
[ -z "${2:-}" ] || pattern="${2}-mavericks.*"

# The comparison key drops the "-mavericks." separator to a dot, exactly as gen_appcast.sh derives the
# appcast's, so N orders as a final numeric component. A tag whose key is not purely dotted-numeric is
# outside the comparator's domain and is skipped rather than silently mis-ordered.
best_tag=""; best_key=""
for t in $(git tag --list "$pattern"); do
  [ "$t" = "$exclude" ] && continue
  k="$(comparison_key "$t")"
  numeric "$k" || continue
  if [ -z "$best_key" ] || [ "$(ver_cmp "$k" "$best_key")" = 1 ]; then best_key="$k"; best_tag="$t"; fi
done

[ -z "$best_tag" ] || printf '%s\n' "$best_tag"
