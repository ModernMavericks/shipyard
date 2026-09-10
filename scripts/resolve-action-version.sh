#!/bin/sh
# What shipyard version is a consumer's `uses: ModernMavericks/shipyard/...@<ref>` actually getting?
#
# The runner unpacks a used action as a TARBALL with no .git, so shipyard-version.sh cannot count
# commits there and CMakeLists falls back to the bare line -- every consumer's installed shipyard
# reported "1.0", the anonymous install this line of work exists to end. The ref the consumer pinned
# is the one piece of identity that survives, so resolve from that.
#
# Two cases, and the common one costs nothing:
#   - an EXACT pin (v1.0.126) already IS the version. No network.
#   - a MOVING tag (v1) must be dereferenced against the remote: find the immutable v*.*.* tag that
#     points at the same commit.
# Anything else -- a raw SHA, a branch, an unreleased tag -- names no release, so this FAILS rather
# than invent a number. The caller falls back to the line and says why.
#
# A committed stamp is not an option: conventions check 7 fails a tracked VERSION ("VERSION is
# DERIVED, not committed"), which is the family's own rule.
#   usage: resolve-action-version.sh <ref> [repo-url]
set -eu
ref="${1:?resolve-action-version: ref required}"
url="${2:-https://github.com/ModernMavericks/shipyard}"

case "$ref" in
  v[0-9]*.[0-9]*.[0-9]*)
    printf '%s\n' "${ref#v}"
    exit 0
    ;;
esac

# Dereference the moving tag to a commit. `^{}` yields the commit for an annotated tag; a lightweight
# tag has no such line, so fall back to the ref's own object.
refs="$(git ls-remote --tags "$url" 2>/dev/null)" || {
  echo "resolve-action-version: cannot read tags from $url" >&2; exit 1; }

sha="$(printf '%s\n' "$refs" | awk -v r="refs/tags/$ref^{}" '$2==r {print $1}')"
[ -n "$sha" ] || sha="$(printf '%s\n' "$refs" | awk -v r="refs/tags/$ref" '$2==r {print $1}')"
[ -n "$sha" ] || { echo "resolve-action-version: $ref is not a tag in $url" >&2; exit 1; }

# Which immutable release tag points at that same commit? Check both the tag and its dereference, so
# this works whether the release tag is lightweight (action-gh-release) or annotated.
ver="$(printf '%s\n' "$refs" | awk -v s="$sha" '
  $1==s && $2 ~ /^refs\/tags\/v[0-9]+\.[0-9]+\.[0-9]+(\^\{\})?$/ {
    t=$2; sub(/^refs\/tags\/v/, "", t); sub(/\^\{\}$/, "", t); print t; exit
  }')"
[ -n "$ver" ] || { echo "resolve-action-version: no vX.Y.Z release points at $sha (ref $ref)" >&2; exit 1; }
printf '%s\n' "$ver"
