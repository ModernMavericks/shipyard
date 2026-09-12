#!/bin/sh
# Link upstream's own release notes, as a markdown section for the release notes (Sparkle appcast
# <description> + GitHub Release body), when this release ships an upstream version that no earlier
# release shipped. A -mavericks.1 exists to deliver someone else's changes, and until now its notes
# named the new version without saying where to read what changed.
#
# WHERE upstream publishes notes is per-repo, so the repo answers it: build/upstream-release-notes-url.sh
# (or scripts/…) <upstream-version> prints ONE URL. Usually a printf; tailscale's finds a date anchor.
# A script rather than a URL template because some upstreams cannot be addressed by version alone.
#
# Prints NOTHING for a repackage, for a repo without the hook (not adopted yet, or a self-upstream
# repo with no -mavericks axis), or when the hook fails -- so callers append unconditionally. Never
# fails a release: notes are prose. Runs only when notes are generated (CI, or a dev box).
#   usage: upstream-notes.sh <version>          (<upstream>-mavericks.N)
#
# "New upstream" is decided from the tags, not from the previous release: no OTHER
# <upstream>-mavericks.* tag may exist. Comparing against the previous release gets parallel lines
# wrong (golang's 1.26.7-mavericks.2 follows a 1.27.0 and is still a repackage), and excluding the
# version's own tag lets a tag-triggered build, whose tag already exists, still count as new.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$SELF/lib.sh"          # sets MAVERICKS_ROOT if unset

url_only=no
if [ "${1:-}" = "--url-only" ]; then url_only=yes; shift; fi
ver="${1:?upstream-notes: version required}"
up="${ver%%-mavericks.*}"

# Exit codes matter only in --url-only mode, where a caller decides whether a gap is fatal:
#   3 = no link is due (a repackage)   4 = this repo has no hook   5 = the hook is broken
# In the default section mode every one of these is still "print nothing, exit 0": appending a section
# unconditionally is the whole point of that mode.
bail() {  # $1 = --url-only exit code, $2 = message
  [ "$url_only" = yes ] || { echo "upstream-notes: $2" >&2; exit 0; }
  echo "upstream-notes: $2" >&2; exit "$1"
}

# build/ where a repo keeps its scripts there, scripts/ where it keeps them there (the swift repos) --
# the same two homes derive-upstream-version.sh already has.
hook=""
for d in build scripts; do
  if [ -f "$MAVERICKS_ROOT/$d/upstream-release-notes-url.sh" ]; then
    hook="$MAVERICKS_ROOT/$d/upstream-release-notes-url.sh"; break
  fi
done
[ -n "$hook" ] || bail 4 "no build/ or scripts/upstream-release-notes-url.sh in $MAVERICKS_ROOT"

# Tags we cannot see must not read as "no earlier release", or every repackage gets called new. A
# shallow clone has none (the family's release jobs use fetch-depth: 0 for exactly this), and a git
# that refuses the repo lists none. (A pre-2.15 git echoes the unknown flag back, which is not "true".)
if [ "$(cd "$MAVERICKS_ROOT" && git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
  bail 5 "$MAVERICKS_ROOT is a shallow clone, so its release tags are unknown (use fetch-depth: 0)"
fi
if ! tags="$(cd "$MAVERICKS_ROOT" && git tag --list "$up-mavericks.*")"; then
  bail 5 "cannot list release tags in $MAVERICKS_ROOT"
fi
for t in $tags; do
  [ "$t" = "$ver" ] || bail 3 "$ver is a repackage of $up; no upstream link is due"
done

if ! url="$(cd "$MAVERICKS_ROOT" && sh "$hook" "$up")"; then
  bail 5 "$hook failed for $up; omitting the upstream section"
fi
case "$url" in
  http://*|https://*) ;;
  *) bail 5 "$hook printed no URL for $up; omitting the upstream section" ;;
esac
# One URL, nothing else: a second line or a space would render as a broken link, not as a warning.
case "$url" in
  *[[:space:]]*|*")"*)
    bail 5 "$hook printed more than one URL for $up; omitting the upstream section" ;;
esac

if [ "$url_only" = yes ]; then
  printf '%s\n' "$url"
else
  printf '### Upstream\n\n- [Upstream release notes for %s](%s)\n' "$up" "$url"
fi
