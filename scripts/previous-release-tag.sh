#!/bin/sh
# Print the newest existing release tag (<upstream>-mavericks.N), or nothing when there is none.
# Generated release notes use it as the "changed since" baseline.
#   usage: previous-release-tag.sh [--tag-glob PATTERN] [tag-to-exclude] [upstream-glob]
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

# --tag-glob (same spelling assert_appcast_upgradeable.sh already uses for this) takes the pattern
# VERBATIM, for a product whose releases are not <upstream>-mavericks.N: shipyard and magic-trackpad2
# tag vX.Y.Z, porthole tags YYYYMMDD.N. The positional upstream-glob is a PREFIX ("1.26") that gets
# "-mavericks.*" appended, so it cannot express either shape -- which is why all three shipped every
# release with no baseline, and therefore no compare link and no ingredient section, at exit 0.
pattern=""; tag_glob=no
while [ $# -gt 0 ]; do
  case "$1" in
    --tag-glob) pattern="${2:?previous-release-tag: --tag-glob needs a pattern}"; tag_glob=yes; shift 2 ;;
    # An unrecognised FLAG falling through to the positional slot is how a typo (--globb) silently
    # costs a release its compare link at exit 0 -- exactly the failure shape this generator exists
    # to stop. Only a "-"-leading argument is rejected; a bare tag/glob positional still falls through.
    -*) echo "previous-release-tag: unknown argument: $1" >&2; exit 2 ;;
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
    echo "previous-release-tag: --tag-glob and a positional upstream-glob are mutually exclusive" >&2
    exit 2
  }
fi

# The comparison key drops the "-mavericks." separator to a dot, exactly as gen_appcast.sh derives the
# appcast's, so N orders as a final numeric component. A tag whose key is not purely dotted-numeric is
# outside the comparator's domain and is skipped rather than silently mis-ordered.
best_tag=""; best_key=""
for t in $(git tag --list "$pattern"); do
  [ "$t" = "$exclude" ] && continue
  # A leading "v" is stripped ONLY under --tag-glob (vX.Y.Z tags), exactly as
  # assert_appcast_upgradeable.sh's --tag-glob mode does. Stripping it unconditionally is wrong: in the
  # default -mavericks.N scope, mavericks-legacysupport carries a stray v1.5.2-mavericks.1 tag beside
  # the real 1.5.2-mavericks.1, and stripping "v" there would let the two collide/compare as the same
  # release, and excluding the real tag would surface the stray one as a baseline instead of "none".
  if [ "$tag_glob" = yes ]; then k="$(comparison_key "${t#v}")"; else k="$(comparison_key "$t")"; fi
  numeric "$k" || continue
  if [ -z "$best_key" ] || [ "$(ver_cmp "$k" "$best_key")" = 1 ]; then best_key="$k"; best_tag="$t"; fi
done

[ -z "$best_tag" ] || printf '%s\n' "$best_tag"
