#!/bin/sh
# Print a path to a GUARANTEED non-empty release-notes file, ending with a generated section naming
# which build ingredients changed since the previous release.
#
# Both consumers reject an empty file -- sign_and_appcast.sh for the Sparkle <description>, and
# publish-release.yml for the Release body -- so this must never hand back nothing. A committed
# release-notes/<TAG>.md supplies the prose; otherwise a minimal default does. Either way the result
# is a TEMP file: appending the ingredient section must never edit a tracked note in place.
#   usage: release-notes-file.sh <TAG> <FULL_VERSION> [PRODUCT_NAME]
#
# One implementation for the family. The per-repo copies differed only in their default wording and
# in whether they bothered with the ingredient section at all.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$SELF/lib.sh"          # sets MAVERICKS_ROOT if unset

TAG="${1:?release-notes-file: TAG required}"
FULL="${2:?release-notes-file: FULL version required}"
PRODUCT="${3:-ModernMavericks}"

notes="$MAVERICKS_ROOT/release-notes/${TAG}.md"
up="${FULL%%-mavericks.*}"
tmp="$(mktemp -t mav-notes-XXXXXX)"

if [ -f "$notes" ] && [ -s "$notes" ]; then
  cat "$notes" > "$tmp"
else
  printf '## %s %s (%s)\n\nAutomated release for Mac OS X 10.9 (Mavericks).\n' \
    "$PRODUCT" "$up" "$TAG" > "$tmp"
fi

# Append which ingredients moved. Its siblings ship alongside this script, so unlike the per-repo
# copies there is no "the installed shipyard is stale" path to warn about. Still tolerant:
# prose must never fail a release.
PREV="$(cd "$MAVERICKS_ROOT" && sh "$SELF/previous-release-tag.sh" "$TAG" 2>/dev/null || true)"
PINS="$(cd "$MAVERICKS_ROOT" && sh "$SELF/ingredient-pins.sh" 2>/dev/null || true)"
if [ -n "$PREV" ] && [ -n "$PINS" ]; then
  SECTION="$(cd "$MAVERICKS_ROOT" && sh "$SELF/ingredient-notes.sh" "$PREV" $PINS 2>/dev/null || true)"
  [ -z "$SECTION" ] || printf '\n%s\n' "$SECTION" >> "$tmp"
fi

printf '%s\n' "$tmp"
