#!/bin/sh
# Has this declared state already been released? One line out; decides nothing about HOW to publish
# (spec 2026-09-12).
#
#   PUBLISH                                        no release carries this digest, none for this version
#   SKIP=already-released/<tag>                    a release carries this digest
#   SKIP=already-released/<tag> BACKFILL=<tag>     no digest anywhere, but <tag> already released this
#                                                  VERSION -- the pre-migration past; record it
#
# Why the fallback exists: every release published before this design carries no digest. A lookup
# that only asked "does any release carry my digest?" would answer PUBLISH for all of them and cut a
# duplicate in every repo, unattended, the first night the backstop ran. It also makes a digest
# FORMAT bump safe: recompute, never republish.
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

match_tag=""; version_tag=""
while IFS= read -r rec || [ -n "$rec" ]; do
  [ -n "$rec" ] || continue
  tag="${rec%%$TAB*}"
  dg="${rec#*$TAB}"
  [ "$dg" != "$rec" ] || dg=""            # no TAB in the record at all
  [ -n "$tag" ] || continue
  if [ -n "$dg" ] && [ "$dg" = "$DIGEST" ] && [ -z "$match_tag" ]; then match_tag="$tag"; fi
  if [ "$tag" = "$VERSION" ] && [ -z "$dg" ] && [ -z "$version_tag" ]; then version_tag="$tag"; fi
done < "$work/records"

if [ -n "$match_tag" ]; then
  printf 'SKIP=already-released/%s\n' "$match_tag"
elif [ -n "$version_tag" ]; then
  # The pre-migration past, or a digest format bump: this version is already out there. Do not
  # publish it again; record the digest so the fast path works from now on.
  printf 'SKIP=already-released/%s BACKFILL=%s\n' "$version_tag" "$version_tag"
else
  printf 'PUBLISH\n'
fi
