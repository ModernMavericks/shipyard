#!/bin/sh
# Back-compat wrapper: the generator is release-notes.sh. Kept because six repos still call this
# signature from their release.yml, and @v1 reaches them all within minutes of a shipyard push -- so
# this must keep working until each has migrated. Delegating (rather than duplicating) means those
# repos get the standard body before anyone edits their workflows.
#
# The PRODUCT argument here is the family's older prose phrase ("Mavericks OpenSSH"); the generator
# wants the bare noun, so strip a leading "Mavericks " / trailing " for Mavericks" when present.
#   usage: release-notes-file.sh <TAG> <FULL_VERSION> [PRODUCT_NAME]
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$SELF/lib.sh"          # MAVERICKS_ROOT

TAG="${1:?release-notes-file: TAG required}"
FULL="${2:?release-notes-file: FULL version required}"
PRODUCT="${3:-ModernMavericks}"
PRODUCT="${PRODUCT#Mavericks }"
PRODUCT="${PRODUCT% for Mavericks}"

out="$(mktemp "${TMPDIR:-/tmp}/release-notes-file.XXXXXX")"
sh "$SELF/release-notes.sh" --tag "$TAG" --version "$FULL" --product "$PRODUCT" \
   --min-os 10.9.5 --out "$out" >&2
printf '%s\n' "$out"
