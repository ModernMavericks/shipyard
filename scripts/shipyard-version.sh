#!/bin/sh
# shipyard's own version. We are our own upstream, and we are consumed through a MOVING tag (@v1),
# so the version has to change whenever the content does -- otherwise there is nothing for a consumer
# to pin, name in a bug report, or compare an install against.
#
# UPSTREAM_VERSION holds the LINE (major.minor). The patch is the commit count, which makes a new
# commit necessarily a new version with no discipline to remember. That discipline is exactly what
# failed before: UPSTREAM_VERSION sat at 1.0.5 while 13 commits to scripts/ and *.cmake each shipped
# to fifteen repos through @v1, every one of them claiming to be 1.0.5.
#
# NOT resolve-version.sh: that hardcodes `-mavericks.N`, which is for repackaged upstreams, not for us.
#   usage: shipyard-version.sh          (prints FULL=<line>.<count> and TAG=v<line>.<count>)
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$root/UPSTREAM_VERSION" ] || { echo "shipyard-version: no $root/UPSTREAM_VERSION" >&2; exit 1; }
line="$(sed -n '1p' "$root/UPSTREAM_VERSION" | tr -d ' \t')"

# The line is major.minor and nothing else. A full version here is the old mistake creeping back, and
# it would silently produce a four-component version rather than fail.
case "$line" in
  [0-9]*.[0-9]*.*) echo "shipyard-version: UPSTREAM_VERSION holds the LINE (major.minor), not a full version: $line" >&2; exit 1 ;;
  [0-9]*.[0-9]*) : ;;
  *) echo "shipyard-version: UPSTREAM_VERSION is not a major.minor line: $line" >&2; exit 1 ;;
esac

# A shallow clone (`git clone --depth 1`) has HEAD but not the history behind it: `rev-list --count`
# would silently return 1, and FULL=$line.1 collides with the already-published v1.0.1. Refuse rather
# than mint a wrong, immutable tag. `--is-shallow-repository` needs git >= 2.15 (2017); that floor is
# safe for every runner and dev box in this family, so we use it rather than the more portable (but
# uglier) fallback of testing for a `shallow` file in the git dir.
if [ "$(git -C "$root" rev-parse --is-shallow-repository)" = "true" ]; then
  echo "shipyard-version: $root is a shallow clone; the commit count is meaningless there. Fetch full history (fetch-depth: 0 in CI, or 'git fetch --unshallow' locally) and retry." >&2
  exit 1
fi

count="$(git -C "$root" rev-list --count HEAD)"
echo "FULL=$line.$count"
echo "TAG=v$line.$count"
