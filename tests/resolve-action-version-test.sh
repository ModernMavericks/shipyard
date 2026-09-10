#!/bin/sh
# resolve-action-version.sh: what version is a consumer's `uses: ...@<ref>` actually getting?
#
# install@v1 configures shipyard from the ACTION's checkout, which the runner unpacks as a tarball
# with no .git -- so shipyard-version.sh cannot count commits and CMake falls back to the bare line.
# Every consumer's installed shipyard therefore reported "1.0", which is exactly the unidentifiable
# install this whole line of work exists to end. Resolve it from the ref the consumer pinned instead.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/resolve-action-version.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/resolve-action-version.XXXXXX")"; trap 'rm -rf "$work"' EXIT

# An exact pin answers itself -- no network, which is the common case for a repo escaping a bad @v1.
[ "$(sh "$S" v1.0.126)" = "1.0.126" ] || { echo "FAIL: an exact pin should resolve offline to 1.0.126"; exit 1; }
[ "$(sh "$S" v2.13.4)" = "2.13.4" ] || { echo "FAIL: exact pin v2.13.4"; exit 1; }

# A MOVING tag has to be dereferenced against the remote: which immutable tag shares its commit?
remote="$work/remote"
mkdir -p "$remote"; cd "$remote"
git init -q -b main .; git config user.email t@example.com; git config user.name tester
echo a > f; git add f; git commit -qm one
git tag v1.0.5
echo b > f; git add f; git commit -qm two
git tag v1.0.126          # lightweight, as action-gh-release mints them
git tag -f -a v1 -m 'v1 -> v1.0.126' >/dev/null   # annotated, as release.yml moves it

out="$(sh "$S" v1 "file://$remote")" || { echo "FAIL: a moving tag should resolve"; exit 1; }
[ "$out" = "1.0.126" ] || { echo "FAIL: v1 should resolve to the release sharing its commit; got '$out'"; exit 1; }

# The older release must NOT be picked just because it is also a v*.*.* tag.
[ "$out" != "1.0.5" ] || { echo "FAIL: resolved to the wrong release"; exit 1; }

# A ref that names no release (a raw SHA pin, or a tag we never released) must FAIL rather than
# invent a version -- the caller falls back to the line and says so.
if sh "$S" "$(git rev-parse HEAD)" "file://$remote" >/dev/null 2>&1; then
  echo "FAIL: a SHA pin names no release and must not resolve"; exit 1
fi
if sh "$S" nonexistent-ref "file://$remote" >/dev/null 2>&1; then
  echo "FAIL: an unknown ref must not resolve"; exit 1
fi

echo "PASS: resolve-action-version"
