#!/bin/sh
# Has this declared state already been released? One line out; decides nothing about HOW to publish
# (spec 2026-09-12).
#
#   PUBLISH                            no published release carries this digest
#   SKIP=already-released/<tag>        a published release carries this digest
#   SKIP=unreadable-marker/<tag>       no match, and <tag> records a marker in a format this shipyard
#                                      cannot read. NOT "no marker": see below.
#
# THERE IS DELIBERATELY NO INFERENCE FROM THE VERSION (ruling 16). An earlier cut fell back to
# version equality -- "no digest anywhere, but a release exists for the version this state maps to,
# so it must already be released" -- and then backfilled the digest onto that release. version.sh's
# `auto` mode returns the EXISTING tag's N whenever the upstream already has one, so it maps every
# declared state of a given upstream to ONE version: an ingredient bump that had not been released
# was declared released, and the backfill cemented it by writing the unreleased state's digest onto a
# release that did not contain it. The fast path matched from then on and no later reconcile ever
# looked again -- a release lost silently and permanently, the golang incident reproduced by the
# machinery built to prevent it.
#
# The pre-migration hazard that fallback was protecting against is handled exactly instead, once, at
# migration: `release-state.sh --ref <tag>` renders what that tag's own tree contained, and
# `release-state-record.sh --tag <tag>` records it. Computed, not guessed.
#
# --version is still required and deliberately does NOT reach the answer. Keeping it lets the caller
# be told which version will not be published, and makes the quadrant that proves ruling 16
# expressible: same version, DIFFERENT digest -> PUBLISH. A version match is not a state match.
#
# An UNREADABLE marker is not an absent one. A release recording `v0:...`, or anything else this
# shipyard's format does not cover, is evidence that somebody recorded a state here in a way we
# cannot compare -- so treating it as "no marker" and publishing is precisely how a bump to v2 would
# republish all 14 products. The spec's promise is recompute, never republish, so this refuses to
# decide in the unsafe direction and says which tag needs recomputing. A release carrying a READABLE
# digest that simply differs from ours is an ordinary earlier state and blocks nothing.
#
# WHERE THE RECORDS COME FROM, and why it is split in two. The fetch is the only code in this design
# that touches the outside world, and it was the only code no test executed -- every case injected
# the finished records, which short-circuits above it. Both of the bugs that hid there were the exact
# failures this spec exists to prevent:
#
#   fetch_raw()          ONE `gh api` call, STATUS CHECKED. A gh failure is a failure (exit 1), never
#                        a decision: auth expiry, a rate limit, a 5xx, a network blip and a renamed
#                        repo all produce empty output, and empty output means PUBLISH. The previous
#                        `gh ... 2>/dev/null | awk` discarded stderr and took awk's exit status,
#                        because POSIX sh has no pipefail.
#   transform_records()  PURE: raw API lines in, "<tag><TAB><digest-or-empty>" out. Tests inject at
#                        THIS boundary ($MAVERICKS_RELEASES_RAW), so the code that parses the API's
#                        shape is code the tests run. It was not, which is how `gh release list
#                        --json tagName,body` shipped: `body` is a `gh release view` field, so the
#                        call failed outright, every release read as absent, and the nightly backstop
#                        would have answered PUBLISH in all 14 repos every night.
#   $MAVERICKS_RELEASES  the finished records, newline-separated "<tag><TAB><digest-or-empty>", for
#                        the decision-logic cases -- the same injection idiom version.sh uses for
#                        $MAVERICKS_TAGS.
#
#   usage: release-needed.sh --digest v1:sha256:<hex> --version <full> [--repo OWNER/NAME]
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$SELF/lib.sh"                    # state_marker(): the family's ONE reader of a recorded marker

DIGEST=""; VERSION=""; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --digest) DIGEST="$2"; shift 2;;
    --version) VERSION="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    *) echo "release-needed: unknown option $1" >&2; exit 2;;
  esac
done
[ -n "$DIGEST" ] || { echo "release-needed: --digest required" >&2; exit 2; }
[ -n "$VERSION" ] || { echo "release-needed: --version required" >&2; exit 2; }
# A malformed digest can only be a caller bug, and "no match" would publish. Refuse instead.
case "$DIGEST" in
  v1:sha256:*) state_digest_readable "$DIGEST" \
    || { echo "release-needed: --digest is not v1:sha256:<lowercase hex>: $DIGEST" >&2; exit 2; } ;;
  *) echo "release-needed: --digest must start with v1:sha256: (got '$DIGEST')" >&2; exit 2;;
esac

TAB="$(printf '\t')"
_tmp="${TMPDIR:-/tmp}"
work="$(mktemp -d "${_tmp%/}/release-needed.XXXXXX")"; trap 'rm -rf "$work"' EXIT

# The RAW API shape: one line per release, "<tag><TAB><draft><TAB><body>", with the body escaped by
# jq's @tsv -- every tab and newline inside it becomes a literal \t or \n, so a record is exactly one
# line. That is the whole reason for choosing this shape: the old transform started a new record at
# "^[^\t]+\t", so a body containing a tab invented a phantom record, attributed the digest to prose,
# and left the real tag reading as digest-less.
fetch_raw() {
  if [ -n "${MAVERICKS_RELEASES_RAW+x}" ]; then printf '%s\n' "$MAVERICKS_RELEASES_RAW"; return 0; fi
  # One paginated REST call returns tag, body and the draft flag together, which keeps the backstop's
  # "a quiet night is one API call" property. `gh release list --json` cannot: it has no body field.
  if [ -n "$REPO" ]; then p="repos/$REPO/releases"; else p="repos/{owner}/{repo}/releases"; fi
  # $MAVERICKS_GH is the seam a test uses to inject a FAILING fetch. Not a stub on PATH: a stub on
  # PATH is invisible at the call site and would shadow gh for anything else the script ran.
  "${MAVERICKS_GH:-gh}" api "$p?per_page=100" --paginate \
      --jq '.[] | [.tag_name, (.draft|tostring), (.body // "")] | @tsv' 2>"$work/gh-err" || {
    echo "release-needed: gh could not read $p -- refusing to decide" >&2
    [ ! -s "$work/gh-err" ] || sed 's/^/    /' "$work/gh-err" >&2
    echo "    an unreadable set of releases is not an EMPTY one: treating it as empty says PUBLISH," >&2
    echo "    which is how an expired token or a rate limit publishes a duplicate unattended" >&2
    return 1
  }
}

# A literal \t, \n, \r or \\ produced by jq's @tsv, put back. Deliberately NOT done in the `gh --jq`
# filter: the marker rule below must stay the family's one rule (lib.sh state_marker), not gain a
# second copy written in jq.
unescape_tsv() {
  awk '{
    out = ""; n = length($0)
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1)
      if (c == "\\" && i < n) {
        d = substr($0, i + 1, 1); i++
        if (d == "n") out = out "\n"
        else if (d == "t") out = out "\t"
        else if (d == "r") out = out "\r"
        else if (d == "\\") out = out "\\"
        else out = out c d
      } else out = out c
    }
    print out
  }'
}

# Raw lines in, one "<tag><TAB><digest-or-empty>" per release out. The pure half.
transform_records() {
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    tag="${line%%$TAB*}"
    [ -n "$tag" ] || continue
    rest="${line#*$TAB}"
    [ "$rest" != "$line" ] || continue          # no TAB at all: not a record
    draft="${rest%%$TAB*}"
    body="${rest#*$TAB}"
    [ "$body" != "$rest" ] || body=""
    # A DRAFT IS NOT A RELEASE. Drafts happen here -- publish-release.yml creates one per attempt and
    # delete-draft-release.sh cleans them up -- and a leftover draft whose body carries the current
    # digest would answer already-released forever while the real release silently never happened.
    # Filtered HERE, in the half the tests exercise, rather than in a jq filter they cannot reach.
    case "$draft" in
      true) continue ;;
      false) : ;;
      *) echo "release-needed: malformed release record for '$tag': draft flag is '$draft', not" >&2
         echo "    true/false. The raw API shape changed under us; refusing to decide." >&2
         return 1 ;;
    esac
    printf '%s\t%s\n' "$tag" "$(printf '%s\n' "$body" | unescape_tsv | state_marker)"
  done
}

if [ -n "${MAVERICKS_RELEASES+x}" ]; then
  printf '%s\n' "$MAVERICKS_RELEASES" > "$work/records"
else
  if ! fetch_raw > "$work/raw"; then exit 1; fi
  transform_records < "$work/raw" > "$work/records"
fi

match_tag=""; alien_tag=""; alien_value=""
while IFS= read -r rec || [ -n "$rec" ]; do
  [ -n "$rec" ] || continue
  tag="${rec%%$TAB*}"
  dg="${rec#*$TAB}"
  [ "$dg" != "$rec" ] || dg=""            # no TAB in the record at all
  [ -n "$tag" ] || continue
  [ -n "$dg" ] || continue                # no marker: this release says nothing about any state
  if [ "$dg" = "$DIGEST" ] && [ -z "$match_tag" ]; then match_tag="$tag"; fi
  if [ -z "$alien_tag" ] && ! state_digest_readable "$dg"; then alien_tag="$tag"; alien_value="$dg"; fi
done < "$work/records"

if [ -n "$match_tag" ]; then
  echo "release-needed: $match_tag already realises $DIGEST; $VERSION will not be published" >&2
  printf 'SKIP=already-released/%s\n' "$match_tag"
elif [ -n "$alien_tag" ]; then
  echo "release-needed: $alien_tag records a state marker this shipyard cannot read:" >&2
  echo "    $alien_value" >&2
  echo "    Nothing will publish until that is recomputed, because treating it as 'no marker' is how" >&2
  echo "    a digest format bump republishes every product. Recompute it from the tag's own tree:" >&2
  echo "        release-state.sh --ref $alien_tag" >&2
  echo "        release-state-record.sh --tag $alien_tag --digest <that>" >&2
  printf 'SKIP=unreadable-marker/%s\n' "$alien_tag"
else
  echo "release-needed: no published release realises $DIGEST; $VERSION would be published" >&2
  printf 'PUBLISH\n'
fi
