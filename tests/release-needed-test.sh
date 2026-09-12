#!/bin/sh
# release-needed.sh: has this declared state already been released?
#
# The four version/digest QUADRANTS are the cases that matter, and writing them down is what would
# have caught ruling 16's defect. The answer must depend on the digest and never on the version:
# version.sh's `auto` mode maps every declared state of a given upstream to ONE version, so "a
# release exists for this version" does not mean "a release exists for this state". An earlier cut
# inferred exactly that, and then backfilled the digest onto the release it had guessed -- losing an
# unreleased ingredient bump silently and permanently.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/release-needed.sh"
_tmp="${TMPDIR:-/tmp}"                    # macOS sets TMPDIR with a trailing slash
w="$(mktemp -d "${_tmp%/}/release-needed-test.XXXXXX")"; trap 'rm -rf "$w"' EXIT
D1='v1:sha256:8c5fc85c689b60ccc9a3ed0120fa949e2bd9c0f9a121ac572fa11ba148312be7'
D2='v1:sha256:405b7fdda86a03f4ef636aceb3c7c819fe5d93208118cd365a0b962cb37c8004'
TAB="$(printf '\t')"

# Two injection points, deliberately. $MAVERICKS_RELEASES is the finished records: it exercises the
# DECISION. $MAVERICKS_RELEASES_RAW is the API's own shape -- "<tag><TAB><draft><TAB><body>", the body
# escaped the way jq's @tsv escapes it -- so the code that PARSES the outside world is code these
# cases run. It was not, and the two bugs that hid behind the higher injection point were both
# reproduced: an invalid --json field made every night answer PUBLISH in all 14 repos, and any gh
# failure answered PUBLISH too.
run() { MAVERICKS_RELEASES="$1" sh "$S" --digest "$2" --version "$3"; }
raw() { MAVERICKS_RELEASES_RAW="$1" sh "$S" --digest "$2" --version "$3"; }

# 1. Nothing released yet -> publish.
got="$(run "" "$D1" 1.2.3-mavericks.1)"
[ "$got" = PUBLISH ] || { echo "FAIL empty: got '$got'"; exit 1; }

# 2. A release carries this digest -> skip, naming the tag that has it.
got="$(run "1.2.3-mavericks.1${TAB}${D1}" "$D1" 1.2.3-mavericks.1)"
[ "$got" = "SKIP=already-released/1.2.3-mavericks.1" ] || { echo "FAIL digest hit: got '$got'"; exit 1; }

# 3. THE QUADRANT THAT PROVES THE RULING: a release exists for this very VERSION but carries no
#    digest -> PUBLISH. Inferring "already released" here is what lost a release. An unreleased
#    ingredient bump gets `version.sh auto`'s existing tag, so this shape is not the pre-migration
#    past OR a released state -- it is both, indistinguishably, which is why the version cannot
#    decide. A repo whose existing release really is this state is marked once, at migration, with
#    the digest computed from that tag's own tree (release-state.sh --ref).
got="$(run "1.2.3-mavericks.1${TAB}" "$D1" 1.2.3-mavericks.1)"
[ "$got" = PUBLISH ] || { echo "FAIL a digest-less release for this version decided: got '$got'"; exit 1; }

# 3b. The same version with a DIFFERENT, readable digest is an earlier state of it, and blocks
#     nothing: the state changed, the version did not, and the state is what a release realises.
got="$(run "1.2.3-mavericks.1${TAB}${D2}" "$D1" 1.2.3-mavericks.1)"
[ "$got" = PUBLISH ] || { echo "FAIL same version, different digest: got '$got'"; exit 1; }

# 3c. ...and the fourth quadrant: a different version carrying THIS digest is already released.
#     (Case 5 below is the same property stated the other way round.)
got="$(run "1.2.3-mavericks.4${TAB}${D1}" "$D1" 1.2.3-mavericks.1)"
[ "$got" = "SKIP=already-released/1.2.3-mavericks.4" ] \
  || { echo "FAIL different version, this digest: got '$got'"; exit 1; }

# 4. An ordinary ingredient bump: a release exists with a different digest and a different version.
got="$(run "1.2.3-mavericks.1${TAB}${D1}" "$D2" 1.2.3-mavericks.2)"
[ "$got" = PUBLISH ] || { echo "FAIL bump: got '$got'"; exit 1; }

# 5. The digest wins over the version: the same state already out under another version must not be
#    published again (a hand-cut repackage, say).
got="$(run "9.9.9-mavericks.7${TAB}${D1}" "$D1" 1.2.3-mavericks.1)"
[ "$got" = "SKIP=already-released/9.9.9-mavericks.7" ] || { echo "FAIL digest over version: got '$got'"; exit 1; }

# 6. A marker in an older FORMAT is not this digest -- and is not "no marker" either. Somebody
#    recorded a state on that release in a way this shipyard cannot compare, so publishing would be
#    exactly how a bump to v2 republishes all 14 products ("recompute, never republish"). It gets its
#    own answer, naming the tag that needs recomputing, and it must not crash.
got="$(run "1.2.3-mavericks.1${TAB}v0:sha256:deadbeef" "$D1" 1.2.3-mavericks.2)"
[ "$got" = "SKIP=unreadable-marker/1.2.3-mavericks.1" ] \
  || { echo "FAIL old-format marker: got '$got'"; exit 1; }

# 6b. But a READABLE digest that merely differs is an ordinary earlier state: it blocks nothing.
got="$(run "1.2.3-mavericks.1${TAB}${D2}" "$D1" 9.9.9-mavericks.9)"
[ "$got" = PUBLISH ] || { echo "FAIL a different readable digest blocked publishing: got '$got'"; exit 1; }

# 6c. A digest match WINS over an unreadable marker elsewhere: the state demonstrably is released, so
#     there is nothing for a human to recompute before anything can proceed.
got="$(run "8.0.0-mavericks.1${TAB}v0:sha256:deadbeef
1.2.3-mavericks.1${TAB}${D1}" "$D1" 1.2.3-mavericks.1)"
[ "$got" = "SKIP=already-released/1.2.3-mavericks.1" ] \
  || { echo "FAIL an unreadable marker outranked a real match: got '$got'"; exit 1; }

# 7. Many releases, the match in the middle.
got="$(run "9.0.0-mavericks.1${TAB}
1.2.3-mavericks.1${TAB}${D1}
8.0.0-mavericks.3${TAB}v1:sha256:abc" "$D1" 1.2.3-mavericks.1)"
[ "$got" = "SKIP=already-released/1.2.3-mavericks.1" ] || { echo "FAIL middle match: got '$got'"; exit 1; }

# 8. A digest match and a same-version release land on TWO DIFFERENT tags: an old repackage carries
#    this exact digest, while the current version was also released, digest-less. The answer must
#    name the tag that actually HAS this state; naming the version-tag would lie about which release
#    realises it.
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

# --- the API boundary: everything below injects the RAW shape, so the transform actually runs -----

# 11. A well-formed multi-release payload. Bodies are real notes: multi-line, with the marker its own
#     paragraph, exactly as release-state-record.sh writes it. The digest must be attributed to the
#     tag whose body carries it, and to no other.
P11="$(printf '%s\n' \
  "9.0.0-mavericks.1${TAB}false${TAB}## 9.0.0-mavericks.1\n\n- old news\n" \
  "1.2.3-mavericks.1${TAB}false${TAB}## 1.2.3-mavericks.1\n\n- a thing\n\nModernMavericks-State: ${D1}\n" \
  "8.0.0-mavericks.3${TAB}false${TAB}## 8.0.0-mavericks.3\n\n- nothing recorded here\n")"
got="$(raw "$P11" "$D1" 7.7.7-mavericks.1)"
[ "$got" = "SKIP=already-released/1.2.3-mavericks.1" ] || { echo "FAIL raw payload: got '$got'"; exit 1; }

# 12. A body with NO marker is digest-less, not a match. (Searched for D2, which nothing carries.)
got="$(raw "$P11" "$D2" 7.7.7-mavericks.1)"
[ "$got" = PUBLISH ] || { echo "FAIL raw payload, no marker for this digest: got '$got'"; exit 1; }

# 13. A DRAFT is not a release. publish-release.yml creates a draft per attempt and
#     delete-draft-release.sh cleans them up, so a leftover draft carrying the current digest is a
#     real shape -- and counting it would answer already-released forever while the real release
#     silently never happened.
got="$(raw "1.2.3-mavericks.9${TAB}true${TAB}ModernMavericks-State: ${D1}" "$D1" 7.7.7-mavericks.1)"
[ "$got" = PUBLISH ] || { echo "FAIL a draft counted as released: got '$got'"; exit 1; }

# ...and the filter drops ONLY drafts: a published release alongside one still counts.
got="$(raw "$(printf '%s\n' \
  "2.0.0-mavericks.1${TAB}true${TAB}ModernMavericks-State: ${D1}" \
  "3.0.0-mavericks.1${TAB}false${TAB}ModernMavericks-State: ${D2}")" "$D2" 7.7.7-mavericks.1)"
[ "$got" = "SKIP=already-released/3.0.0-mavericks.1" ] \
  || { echo "FAIL the draft filter dropped a published release: got '$got'"; exit 1; }

# 14. A TAB inside a body must not invent a record. The old transform started a new record at any
#     "^[^\t]+\t", so a body containing a tab attributed the digest to prose and left the real tag
#     reading as digest-less. @tsv escapes it, and the split takes exactly the first two tabs.
got="$(raw "$(printf '%s\n' \
  "1.2.3-mavericks.1${TAB}false${TAB}| ingredient\tpinned |\n\nModernMavericks-State: ${D1}" \
  "4.0.0-mavericks.1${TAB}false${TAB}plain notes")" "$D1" 7.7.7-mavericks.1)"
[ "$got" = "SKIP=already-released/1.2.3-mavericks.1" ] \
  || { echo "FAIL a tab inside a body moved the digest: got '$got'"; exit 1; }

# 15. The one clause the offline cases cannot reach is the fetch's own request, so pin it directly.
#     `gh release list --json tagName,body` FAILS -- `body` is a `gh release view` field -- and a
#     failed list read as "no releases", which answers PUBLISH: every night, in every repo. @tsv is
#     what makes a record exactly one line, which cases 11-14 rely on being true of the real API.
#     Full-line comments are stripped first: the script explains the trap it avoids, and the prose
#     naming it must not read as the trap itself.
code="$(sed 's/^[[:space:]]*#.*//' "$S")"
case "$code" in
  *"release list"*) echo "FAIL the fetch is back on gh release list, which has no body field"; exit 1 ;;
esac
case "$code" in
  *@tsv*) : ;;
  *) echo "FAIL the fetch no longer asks jq for @tsv, so a body can span records"; exit 1 ;;
esac

# 16. A gh FAILURE IS A FAILURE, never a decision. Auth expiry, a rate limit, a 5xx, a network blip
#     and a renamed repo all produce empty output -- and empty output means PUBLISH. The seam is
#     $MAVERICKS_GH, an explicit path, not a stub on PATH: a stub on PATH is invisible at the call
#     site and would shadow gh for anything else the script ran.
printf '%s\n' '#!/bin/sh' 'echo "gh: HTTP 401: Bad credentials" >&2' 'exit 4' > "$w/gh-fails"
chmod +x "$w/gh-fails"
rc=0
out="$(MAVERICKS_GH="$w/gh-fails" sh "$S" --digest "$D1" --version 1.2.3-mavericks.1 2>"$w/e16")" || rc=$?
[ "$rc" != 0 ] || { echo "FAIL a failing gh exited 0"; exit 1; }
case "$out" in
  *PUBLISH*) echo "FAIL a failing gh answered PUBLISH: '$out'"; exit 1 ;;
  *SKIP*)    echo "FAIL a failing gh answered a SKIP: '$out'"; exit 1 ;;
esac
grep -q 'Bad credentials' "$w/e16" || { echo "FAIL gh's own error was swallowed"; exit 1; }

# 17. A fetch that SUCCEEDS with no output is a real answer, though: a repo with no releases yet.
printf '%s\n' '#!/bin/sh' 'exit 0' > "$w/gh-empty"; chmod +x "$w/gh-empty"
got="$(MAVERICKS_GH="$w/gh-empty" sh "$S" --digest "$D1" --version 1.2.3-mavericks.1)"
[ "$got" = PUBLISH ] || { echo "FAIL a repo with no releases: got '$got'"; exit 1; }

# 18. A raw record whose draft flag is neither true nor false means the API shape moved under us.
#     Guessing would either count a draft or drop a release, so it refuses to decide.
rc=0
out="$(MAVERICKS_RELEASES_RAW="1.2.3-mavericks.1${TAB}maybe${TAB}notes" \
  sh "$S" --digest "$D1" --version 1.2.3-mavericks.1 2>"$w/e18")" || rc=$?
[ "$rc" != 0 ] || { echo "FAIL a malformed draft flag exited 0"; exit 1; }
case "$out" in *PUBLISH*) echo "FAIL a malformed draft flag answered PUBLISH"; exit 1;; esac

echo "PASS: release-needed"
