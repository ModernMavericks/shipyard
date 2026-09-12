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
# Release records come from `gh release list` plus each release's body, or from $MAVERICKS_RELEASES
# when set (tests) -- newline-separated "<tag><TAB><digest-or-empty>", the same injection idiom
# version.sh uses for $MAVERICKS_TAGS.
#   usage: release-needed.sh --digest v1:sha256:<hex> --version <full> [--repo OWNER/NAME]
set -eu

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
  v1:sha256:*) rest="${DIGEST#v1:sha256:}"
    case "$rest" in
      ''|*[!0-9a-f]*) echo "release-needed: --digest is not v1:sha256:<lowercase hex>: $DIGEST" >&2; exit 2;;
    esac ;;
  *) echo "release-needed: --digest must start with v1:sha256: (got '$DIGEST')" >&2; exit 2;;
esac

# One "<tag><TAB><digest-or-empty>" per release. A body is multi-line, so the tag is emitted first
# and the state line is picked out of whatever follows it.
records() {
  if [ -n "${MAVERICKS_RELEASES+x}" ]; then printf '%s\n' "$MAVERICKS_RELEASES"; return 0; fi
  set -- release list --limit 200 --json tagName,body \
      --template '{{range .}}{{.tagName}}{{"\t"}}{{.body}}{{"\n"}}{{end}}'
  [ -z "$REPO" ] || set -- "$@" --repo "$REPO"
  gh "$@" 2>/dev/null | awk -F'\t' '
    /^[^\t]+\t/ { if (tag != "") print tag "\t" dg; tag = $1; dg = ""; $1 = "" }
    { if (match($0, /ModernMavericks-State:[ ]*v1:sha256:[0-9a-f]+/)) {
        s = substr($0, RSTART, RLENGTH); sub(/^ModernMavericks-State:[ ]*/, "", s)
        if (dg == "") dg = s } }
    END { if (tag != "") print tag "\t" dg }'
}

TAB="$(printf '\t')"
match_tag=""; version_tag=""
while IFS= read -r rec || [ -n "$rec" ]; do
  [ -n "$rec" ] || continue
  tag="${rec%%$TAB*}"
  dg="${rec#*$TAB}"
  [ "$dg" != "$rec" ] || dg=""            # no TAB in the record at all
  [ -n "$tag" ] || continue
  if [ -n "$dg" ] && [ "$dg" = "$DIGEST" ] && [ -z "$match_tag" ]; then match_tag="$tag"; fi
  if [ "$tag" = "$VERSION" ] && [ -z "$dg" ] && [ -z "$version_tag" ]; then version_tag="$tag"; fi
done <<EOF
$(records)
EOF

if [ -n "$match_tag" ]; then
  printf 'SKIP=already-released/%s\n' "$match_tag"
elif [ -n "$version_tag" ]; then
  # The pre-migration past, or a digest format bump: this version is already out there. Do not
  # publish it again; record the digest so the fast path works from now on.
  printf 'SKIP=already-released/%s BACKFILL=%s\n' "$version_tag" "$version_tag"
else
  printf 'PUBLISH\n'
fi
