#!/bin/sh
# May publish-release.yml create this release, or has the version's tag already been taken?
#
#   assert_tag_publishable.sh VERSION REPO_URL REF_TYPE REF_NAME SHA
#
# Exit 0 to publish, 1 to refuse. The caller's own remote is asked BY URL: publish-release.yml checks
# out shipyard, never the calling repo, so there is no `origin` here to ask -- and a guard that errors
# out is a guard that passes everything. Every family repo is public, so this needs no token.
#
# Refusing an existing tag: two runs can compute the same -mavericks.(N+1) from the same tag set and
# both build it. The loser must not publish, and must not relabel either -- VERSION is already baked
# into pkgbuild --version, the pkg filename and the appcast's <sparkle:version>, which
# assert_appcast_upgradeable.sh compares against the tag history. Rebuilding is the only correct
# recovery, and that is a re-dispatch.
#
# The exception: a run TRIGGERED BY a pushed tag always finds its own tag, because that tag is what
# started it. Blanket refusal therefore broke every repo that publishes from a pushed tag -- the model
# the conventions document, and clang's only path. So that case publishes, and only that case: the
# run's ref must BE this version's tag, and the tag must point at the commit being published (its
# commit for an annotated tag).
set -eu
[ "$#" -eq 5 ] || { echo "usage: assert_tag_publishable.sh VERSION REPO_URL REF_TYPE REF_NAME SHA" >&2; exit 2; }
VER="$1"; URL="$2"; REF_TYPE="$3"; REF_NAME="$4"; SHA="$5"

set +e
# Both spellings: an annotated tag's ref is the tag OBJECT, and its "^{}" entry is the commit. An
# exact pattern returns only the first, so ask for the peeled one by name too.
refs="$(git ls-remote --tags "$URL" "refs/tags/$VER" "refs/tags/$VER^{}" 2>/dev/null)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "::error::could not read tags from $URL (git ls-remote exit $rc) -- refusing to publish without knowing whether $VER is taken." >&2
  exit 1
fi
[ -n "$refs" ] || { echo "tag $VER is free"; exit 0; }

if [ "$REF_TYPE" != tag ] || [ "$REF_NAME" != "$VER" ]; then
  echo "::error::tag $VER already exists -- another run published it while this one was building." >&2
  echo "::error::Nothing was published. Re-dispatch this release: it will compute the next -mavericks.N and rebuild with that version baked in." >&2
  exit 1
fi

# This run's own tag. It must name the commit being published -- both spellings, since an annotated
# tag's ref is the tag object and its "^{}" entry is the commit.
for sha in $(printf '%s\n' "$refs" | awk '{print $1}'); do
  if [ "$sha" = "$SHA" ]; then
    echo "tag $VER is the tag that triggered this run, at $SHA"
    exit 0
  fi
done
echo "::error::tag $VER triggered this run but points at $(printf '%s\n' "$refs" | awk 'NR==1{print $1}'), not at the commit being published ($SHA)." >&2
echo "::error::Nothing was published. A tag must name the commit whose artifacts it labels." >&2
exit 1
