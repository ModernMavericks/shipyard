#!/bin/sh
# Delete every DRAFT release of one tag -- never a published one. publish-release.yml calls it between
# publish attempts and after the last one fails, so a failed publish leaves nothing behind.
#
# Why a draft is left at all: action-gh-release creates the release as a draft, uploads the assets,
# and only then publishes it, which is when the tag is minted. A failed upload stops it in between:
# golang's 1.26.8-mavericks.3 lost its native .pkg to "other side closed" and sat as a draft with no
# tag -- invisible to Renovate, to the appcast, to every sibling, with its ingredient bump unshipped.
#
# The tag is matched exactly, and only releases GitHub reports as draft are touched: published
# releases, and drafts of any other tag, are never deleted. A listing that fails exits non-zero
# rather than reporting "no drafts" -- a cleanup that cannot look must not say it looked.
#   usage: delete-draft-release.sh OWNER/REPO TAG     (needs gh, authenticated via GH_TOKEN)
set -eu
repo="${1:?usage: delete-draft-release.sh OWNER/REPO TAG}"
tag="${2:?usage: delete-draft-release.sh OWNER/REPO TAG}"

# Listed on its own line, not in the pipe below: a pipeline's status is its LAST command's, so a
# failing gh would read as an empty list. --paginate prints one JSON array per page, back to back.
pages="$(gh api "repos/$repo/releases?per_page=100" --paginate)"
ids="$(printf '%s\n' "$pages" | python3 -c '
import json, sys
tag, text, dec, i = sys.argv[1], sys.stdin.read(), json.JSONDecoder(), 0
while True:
    while i < len(text) and text[i].isspace():
        i += 1
    if i >= len(text):
        break
    page, i = dec.raw_decode(text, i)
    for r in page:
        if r.get("draft") is True and r.get("tag_name") == tag:
            print(r["id"])
' "$tag")"

if [ -z "$ids" ]; then
  echo "delete-draft-release: no draft release of $tag in $repo"
  exit 0
fi
for id in $ids; do
  gh api -X DELETE "repos/$repo/releases/$id" >/dev/null
  echo "delete-draft-release: deleted draft release $id ($tag) in $repo"
done
