#!/bin/sh
# Link upstream's own release notes, as a markdown section for the release notes (Sparkle appcast
# <description> + GitHub Release body), when this release ships an upstream version that no earlier
# release shipped. A -mavericks.1 exists to deliver someone else's changes, and until now its notes
# named the new version without saying where to read what changed.
#
# WHERE upstream publishes notes is per-repo, so the repo answers it: build/upstream-release-notes-url.sh
# <upstream-version> prints ONE URL. Usually a printf; tailscale's finds a date anchor in a changelog.
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

ver="${1:?upstream-notes: version required}"
up="${ver%%-mavericks.*}"

hook="$MAVERICKS_ROOT/build/upstream-release-notes-url.sh"
[ -f "$hook" ] || exit 0

for t in $(cd "$MAVERICKS_ROOT" && git tag --list "$up-mavericks.*"); do
  [ "$t" = "$ver" ] || exit 0
done

if ! url="$(cd "$MAVERICKS_ROOT" && sh "$hook" "$up")"; then
  echo "upstream-notes: $hook failed for $up; omitting the upstream section" >&2
  exit 0
fi
case "$url" in
  http://*|https://*) ;;
  *) echo "upstream-notes: $hook printed no URL for $up; omitting the upstream section" >&2; exit 0 ;;
esac
# One URL, nothing else: a second line or a space would render as a broken link, not as a warning.
case "$url" in
  *[[:space:]]*|*")"*)
    echo "upstream-notes: $hook printed more than one URL for $up; omitting the upstream section" >&2
    exit 0 ;;
esac

printf '### Upstream\n\n- [Upstream release notes for %s](%s)\n' "$up" "$url"
