#!/bin/sh
# The promoted version scaffolding: one implementation for every repo that derives
# <upstream>-mavericks.N from tags. The three repo copies were byte-identical in logic and differed
# only in comment wording and the name of the root variable.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
V="$here/../scripts/version.sh"
L="$here/../scripts/lib.sh"
w="$(mktemp -d "${TMPDIR:-/tmp}/version-lib-test.XXXXXX")"; trap 'rm -rf "$w"' EXIT
printf '1.26.5\n' > "$w/UPSTREAM_VERSION"
export MAVERICKS_ROOT="$w"

# upstream_version() reads the committed file, whitespace stripped
got="$(. "$L"; upstream_version)"
[ "$got" = 1.26.5 ] || { echo "FAIL upstream_version: '$got'"; exit 1; }

# auto, no tags yet -> a new upstream is release number 1, and it releases
out="$(MAVERICKS_TAGS='' sh "$V" auto)"
printf '%s\n' "$out" | grep -qx 'FULL=1.26.5-mavericks.1' || { echo "FAIL auto/new FULL: $out"; exit 1; }
printf '%s\n' "$out" | grep -qx 'TAG=1.26.5-mavericks.1'  || { echo "FAIL auto/new TAG: $out"; exit 1; }
printf '%s\n' "$out" | grep -qx 'RELEASE=yes'             || { echo "FAIL auto/new REL: $out"; exit 1; }

# auto, already released -> the current N, and it does NOT release again
out="$(MAVERICKS_TAGS='1.26.5-mavericks.1
1.26.5-mavericks.3
1.26.5-mavericks.2' sh "$V" auto)"
printf '%s\n' "$out" | grep -qx 'FULL=1.26.5-mavericks.3' || { echo "FAIL auto/exist FULL: $out"; exit 1; }
printf '%s\n' "$out" | grep -qx 'RELEASE=no'              || { echo "FAIL auto/exist REL: $out"; exit 1; }

# local -> the next N, and it releases
out="$(MAVERICKS_TAGS='1.26.5-mavericks.3' sh "$V" local)"
printf '%s\n' "$out" | grep -qx 'FULL=1.26.5-mavericks.4' || { echo "FAIL local FULL: $out"; exit 1; }
printf '%s\n' "$out" | grep -qx 'RELEASE=yes'             || { echo "FAIL local REL: $out"; exit 1; }

# tags for OTHER upstreams are ignored (N resets to 1 when UPSTREAM_VERSION moves)
out="$(MAVERICKS_TAGS='1.26.4-mavericks.7' sh "$V" auto)"
printf '%s\n' "$out" | grep -qx 'FULL=1.26.5-mavericks.1' || { echo "FAIL other-upstream: $out"; exit 1; }

# a non-numeric suffix is not an N
out="$(MAVERICKS_TAGS='1.26.5-mavericks.rc1' sh "$V" auto)"
printf '%s\n' "$out" | grep -qx 'FULL=1.26.5-mavericks.1' || { echo "FAIL junk suffix: $out"; exit 1; }

# an unknown mode is an error, not a silent default
if sh "$V" sideways >/dev/null 2>&1; then echo "FAIL bad mode should exit non-zero"; exit 1; fi

# with no MAVERICKS_TAGS it reads the repo's tags
( cd "$w" && git init -q -b main . && git config user.email t@e.com && git config user.name t \
  && git add UPSTREAM_VERSION && git commit -qm base && git tag 1.26.5-mavericks.9 )
out="$(sh "$V" auto)"
printf '%s\n' "$out" | grep -qx 'FULL=1.26.5-mavericks.9' || { echo "FAIL git tags: $out"; exit 1; }

# A repo that ships parallel upstream lines keeps one UPSTREAM_VERSION per line, so the file is an
# input rather than a fixed path. (mavericks-golang: lines/126/UPSTREAM_VERSION.)
mkdir -p "$w/lines/127"
printf '1.27.0\n' > "$w/lines/127/UPSTREAM_VERSION"
out="$(MAVERICKS_UPSTREAM_FILE="$w/lines/127/UPSTREAM_VERSION" MAVERICKS_TAGS='' sh "$V" auto)"
printf '%s\n' "$out" | grep -qx 'FULL=1.27.0-mavericks.1' || { echo "FAIL upstream-file override: $out"; exit 1; }
# tags from the OTHER line must not affect this one's N
out="$(MAVERICKS_UPSTREAM_FILE="$w/lines/127/UPSTREAM_VERSION" MAVERICKS_TAGS='1.26.5-mavericks.9' sh "$V" auto)"
printf '%s\n' "$out" | grep -qx 'FULL=1.27.0-mavericks.1' || { echo "FAIL cross-line tag leak: $out"; exit 1; }

# comparison_key(): the ONE derivation of a Sparkle-comparable key. gen_appcast.sh and
# previous-release-tag.sh both used to carry their own, and they silently diverged when openssh's
# "pN" rule was added to one of them -- which is why no openssh release ever found its baseline.
. "$here/../scripts/lib.sh"
[ "$(comparison_key 1.102.0-mavericks.4)" = 1.102.0.4 ] || { echo "FAIL key: -mavericks.N"; exit 1; }
[ "$(comparison_key 9.9p2-mavericks.3)"   = 9.9.2.3 ]   || { echo "FAIL key: pN + N"; exit 1; }
[ "$(comparison_key 9.9p2)"               = 9.9.2 ]     || { echo "FAIL key: bare pN"; exit 1; }
[ "$(comparison_key 20260727-mavericks.2)" = 20260727.2 ] || { echo "FAIL key: date"; exit 1; }
[ "$(comparison_key 1.26.8)"              = 1.26.8 ]    || { echo "FAIL key: plain semver"; exit 1; }
numeric "$(comparison_key 9.9p2-mavericks.3)" || { echo "FAIL key: pN result must be orderable"; exit 1; }

# The CMake side is a deliberate mirror (a .cmake file cannot source lib.sh), and the family rule is
# that the two stay identical. Assert the mirror still carries both transforms, so a change here that
# forgets MavericksSparkle.cmake fails HERE rather than as "the updater thinks it is current".
grep -q 'string(REPLACE "-mavericks' "$here/../MavericksSparkle.cmake" \
  || { echo "FAIL MavericksSparkle.cmake lost its -mavericks derivation"; exit 1; }
grep -q '(\[0-9\])p(\[0-9\])' "$here/../MavericksSparkle.cmake" \
  || { echo "FAIL MavericksSparkle.cmake lost its pN derivation"; exit 1; }

# gen_appcast.sh must NOT carry its own derivation; it must call comparison_key().
# Regression test for the family's ONE-derivation rule that was violated when the
# pN rule was added to gen_appcast but not to previous-release-tag.
grep -q 's/-mavericks\\./\\./' "$here/../scripts/gen_appcast.sh" 2>/dev/null \
  && { echo "FAIL gen_appcast still derives its own key instead of calling comparison_key"; exit 1; }

echo "PASS: version-lib"
