#!/bin/sh
# release-needed.sh: has this declared state already been released?
#
# The third case matters most. Every release published BEFORE this design carries no digest at all. A
# naive lookup finds none, says PUBLISH, and cuts a duplicate -- in 14 repos, unattended, on the
# first night the backstop runs. The version-equality fallback is what prevents that, and it is also
# what makes a digest format bump safe.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/release-needed.sh"
D1='v1:sha256:8c5fc85c689b60ccc9a3ed0120fa949e2bd9c0f9a121ac572fa11ba148312be7'
D2='v1:sha256:405b7fdda86a03f4ef636aceb3c7c819fe5d93208118cd365a0b962cb37c8004'
TAB="$(printf '\t')"

run() { MAVERICKS_RELEASES="$1" sh "$S" --digest "$2" --version "$3"; }

# 1. Nothing released yet -> publish.
got="$(run "" "$D1" 1.2.3-mavericks.1)"
[ "$got" = PUBLISH ] || { echo "FAIL empty: got '$got'"; exit 1; }

# 2. A release carries this digest -> skip, naming the tag that has it.
got="$(run "1.2.3-mavericks.1${TAB}${D1}" "$D1" 1.2.3-mavericks.1)"
[ "$got" = "SKIP=already-released/1.2.3-mavericks.1" ] || { echo "FAIL digest hit: got '$got'"; exit 1; }

# 3. THE MIGRATION CASE: a release exists for this version but carries no digest -> skip AND ask for
#    a backfill. Publishing here would duplicate a release that is already out.
got="$(run "1.2.3-mavericks.1${TAB}" "$D1" 1.2.3-mavericks.1)"
[ "$got" = "SKIP=already-released/1.2.3-mavericks.1 BACKFILL=1.2.3-mavericks.1" ] \
  || { echo "FAIL pre-migration fallback: got '$got'"; exit 1; }

# 4. An ordinary ingredient bump: a release exists with a different digest and a different version.
got="$(run "1.2.3-mavericks.1${TAB}${D1}" "$D2" 1.2.3-mavericks.2)"
[ "$got" = PUBLISH ] || { echo "FAIL bump: got '$got'"; exit 1; }

# 5. The digest wins over the version: the same state already out under another version must not be
#    published again (a hand-cut repackage, say).
got="$(run "9.9.9-mavericks.7${TAB}${D1}" "$D1" 1.2.3-mavericks.1)"
[ "$got" = "SKIP=already-released/9.9.9-mavericks.7" ] || { echo "FAIL digest over version: got '$got'"; exit 1; }

# 6. A digest recorded in an older FORMAT is not this digest: it must not match, and must not crash.
got="$(run "1.2.3-mavericks.1${TAB}v0:sha256:deadbeef" "$D1" 1.2.3-mavericks.2)"
[ "$got" = PUBLISH ] || { echo "FAIL old-format digest: got '$got'"; exit 1; }

# 7. Many releases, the match in the middle.
got="$(run "9.0.0-mavericks.1${TAB}
1.2.3-mavericks.1${TAB}${D1}
8.0.0-mavericks.3${TAB}v1:sha256:abc" "$D1" 1.2.3-mavericks.1)"
[ "$got" = "SKIP=already-released/1.2.3-mavericks.1" ] || { echo "FAIL middle match: got '$got'"; exit 1; }

# 8. Priority when a digest match and a version match land on TWO DIFFERENT tags: an old repackage
#    already carries this exact digest, while the current version was ALSO released before the
#    digest existed. Naming the version-tag here would lie about which release actually has this
#    state, and would wrongly ask for a backfill nothing needs.
got="$(run "9.9.9-mavericks.7${TAB}${D1}
1.2.3-mavericks.1${TAB}" "$D1" 1.2.3-mavericks.1)"
[ "$got" = "SKIP=already-released/9.9.9-mavericks.7" ] || { echo "FAIL priority, two tags: got '$got'"; exit 1; }

# 9. Usage errors are exit 2, distinct from a decision: a caller that forgot an argument must never
#    be told "publish".
rc=0; MAVERICKS_RELEASES="" sh "$S" --digest "$D1" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL missing --version should exit 2, got $rc"; exit 1; }
rc=0; MAVERICKS_RELEASES="" sh "$S" --version 1.2.3-mavericks.1 >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL missing --digest should exit 2, got $rc"; exit 1; }

# 10. A malformed digest is a usage error too: it can only come from a caller bug, and treating it as
#    "no match" would publish.
rc=0; MAVERICKS_RELEASES="" sh "$S" --digest sha256:nope --version 1.2.3-mavericks.1 >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL malformed digest should exit 2, got $rc"; exit 1; }

echo "PASS: release-needed"
