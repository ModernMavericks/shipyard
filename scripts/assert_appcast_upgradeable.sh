#!/bin/sh
# Prove a release's Sparkle appcast will be SEEN AS AN UPGRADE by a client running the previous
# release -- the property that actually failed when "-mavericks.N" made SUStandardVersionComparator
# return EQUAL for consecutive repackages and clients reported "you're up to date". This verifies the
# ORDERING behavior, not merely the format (which gen_appcast.sh already guards at generation):
#
#   - <sparkle:version> is purely dotted-numeric X.Y.Z.N -- the comparator's total-order domain.
#   - it is STRICTLY GREATER than the previous published release's <sparkle:version>, by the same
#     component-wise numeric comparison SUStandardVersionComparator applies on that domain.
#
# Runs where the release tags live (the CI release job's checkout). The previous release is the
# numerically-highest existing <upstream>-mavericks.N tag; its numeric key is derived exactly as
# gen_appcast.sh derives the appcast's ("-mavericks." -> "."). With NO previous tag (the first release)
# the ordering check is SKIPPED -- and SAID to be, never silently passed. If tags can't be listed at
# all (not a git checkout) the gate FAILS rather than skip: a silent no-op is how these bugs shipped.
#
# The "which tag is highest" decision uses the same lib.sh ver_cmp that previous-release-tag.sh now
# uses -- neither relies on `sort -V`, which the 10.9 box's BSD sort lacks. This gate still walks the
# tags itself because it needs the numeric KEY it compares, not just the tag name, and comparing with
# the shared comparator is what keeps it consistent with the ordering assertion it feeds.
#
# Usage:
#   assert_appcast_upgradeable.sh --appcast FILE --version V [--upstream-glob G]
#     --version        the release being published; excluded from the tag search so a tag build
#                      compares against its PREDECESSOR, not itself.
#     --upstream-glob  scope for a repo shipping parallel upstream lines (golang: '1.26.*'), so N is
#                      compared within its own line.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$SELF/lib.sh"          # numeric(), ver_cmp() -- shared so this gate and
                          # previous-release-tag.sh cannot disagree on which tag is highest

APPCAST=""; VER=""; GLOB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --appcast) APPCAST="$2"; shift 2;;
    --version) VER="$2"; shift 2;;
    --upstream-glob) GLOB="$2"; shift 2;;
    *) echo "assert_appcast_upgradeable: unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$APPCAST" ] && [ -n "$VER" ] || { echo "assert_appcast_upgradeable: need --appcast --version" >&2; exit 2; }
[ -f "$APPCAST" ] || { echo "assert_appcast_upgradeable: no appcast: $APPCAST" >&2; exit 1; }

NEW="$(sed -n 's|.*<sparkle:version>\([^<]*\)</sparkle:version>.*|\1|p' "$APPCAST" | head -1)"
[ -n "$NEW" ] || { echo "assert_appcast_upgradeable: no <sparkle:version> in $APPCAST" >&2; exit 1; }
if ! numeric "$NEW"; then
  echo "assert_appcast_upgradeable: <sparkle:version> '$NEW' is not purely dotted-numeric -- outside SUStandardVersionComparator's orderable domain" >&2
  exit 1
fi

pattern="*-mavericks.*"; [ -z "$GLOB" ] || pattern="${GLOB}-mavericks.*"
if ! tags="$(git tag --list "$pattern" 2>/dev/null)"; then
  echo "assert_appcast_upgradeable: cannot list git tags (not a checkout?) -- run where the release tags live; refusing to skip silently" >&2
  exit 1
fi

# Highest existing tag in this line, by our own numeric compare (no sort -V), excluding the one we publish.
PREV_TAG=""; PREV=""
for t in $tags; do
  [ "$t" = "$VER" ] && continue
  k="$(printf '%s' "$t" | sed 's/-mavericks\./\./')"
  numeric "$k" || continue
  if [ -z "$PREV" ] || [ "$(ver_cmp "$k" "$PREV")" = 1 ]; then PREV="$k"; PREV_TAG="$t"; fi
done

if [ -z "$PREV" ]; then
  echo "assert_appcast_upgradeable: ok — sparkle:version $NEW is numeric; no previous release${GLOB:+ in line $GLOB} to order against (first release)"
  exit 0
fi

case "$(ver_cmp "$NEW" "$PREV")" in
  1) echo "assert_appcast_upgradeable: ok — sparkle:version $NEW > previous $PREV (tag $PREV_TAG); a client on the previous release will see an update" ;;
  *) echo "assert_appcast_upgradeable: sparkle:version $NEW does NOT order after previous $PREV (from tag $PREV_TAG) -- a client on $PREV_TAG would NOT see this as an upgrade" >&2
     exit 1 ;;
esac
