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

count="$(git -C "$root" rev-list --count HEAD)"
echo "FULL=$line.$count"
echo "TAG=v$line.$count"
