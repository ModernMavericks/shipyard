#!/bin/sh
# Record a state digest onto an ALREADY PUBLISHED release, so the fast path works for releases that
# predate this design (spec 2026-09-12, failure modes).
#
# --tag is the ONE-TIME MIGRATION TOOL a human (or a migration workflow) runs when a repo first
# declares its state -- not something the nightly backstop does. It is paired with
# `release-state.sh --ref <tag>`, which renders what that tag's tree actually contained, so the
# digest recorded on a release is the digest OF that release. The earlier design had reconcile.yml
# backfill a digest inferred from a version match; version.sh's `auto` mode maps every declared state
# of one upstream to one version, so that inference could write an unreleased state's digest onto a
# release that did not contain it -- and, once written, the fast path matched and nothing looked
# again. Marking each existing release once, with what it really holds, is exact where that was a
# guess (ruling 16).
#
# The only writer of a release body outside the publish path, and deliberately narrow:
#   - APPENDS one line and preserves every other byte (those notes are what users read);
#   - idempotent -- the same digest again is a no-op, so the nightly backstop can run forever;
#   - a DIFFERENT digest already recorded stops it with exit 3 and no write. Two declared states
#     claiming one release is not resolved by overwriting; a human must look.
#
# TWO TARGETS, ONE APPEND RULE:
#   --notes-file F   the NORMAL path: a notes file, in place, BEFORE packaging. The appcast's
#                    <description> and the Release body both come from that one file, so writing the
#                    marker before packaging keeps them in agreement -- a conformance check that
#                    asserts this equality is in flight in the release-notes work, not enforced today.
#                    The reason stands regardless: a 10.9 user's Sparkle update dialog should show the
#                    same notes the Release page shows, and a marker added later (at publish time)
#                    would leave it one line short of that. No --tag: the notes are not a release yet,
#                    and inventing a tag argument would invite passing the wrong one.
#   --tag T          the MIGRATION path: an already-published release, marked once with the digest
#                    computed from its OWN tree (`release-state.sh --ref T`).
#
# ...AND ONE ESCAPE, --replace-unreadable: replace a marker that state_digest_readable REJECTS
# instead of exiting 3. release-needed.sh answers SKIP=unreadable-marker/<tag> and tells you to
# recompute and re-record; without this flag that instruction could not be followed. A marker BEING
# PRESENT is the very condition that blocked publishing, so the plain append refused because of it,
# and --digest accepts only v1:sha256:<hex> so a new-format digest could not be offered either --
# leaving hand-editing a release body as the only real recovery, which all three of those messages
# implicitly denied. Narrow on purpose: a READABLE digest that merely differs STILL exits 3. Two
# declared states claiming one release is a question for a human, and "replace whatever is there"
# would make every recorded digest overwritable by any caller.
#
#   usage: release-state-record.sh --notes-file F --digest v1:sha256:<hex>
#          release-state-record.sh --tag T --digest v1:sha256:<hex> [--repo OWNER/NAME]
#          release-state-record.sh --tag T --digest D [--replace-unreadable]
#          release-state-record.sh --tag T --digest D --body-file F --out F   (offline; tests)
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$SELF/lib.sh"                    # state_marker(): the family's ONE reader of a recorded marker

TAG=""; DIGEST=""; REPO=""; BODY_FILE=""; OUT=""; NOTES_FILE=""; REPLACE_UNREADABLE=no
REPLACED=no
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2;;
    --digest) DIGEST="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --notes-file) NOTES_FILE="$2"; shift 2;;
    --body-file) BODY_FILE="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --replace-unreadable) REPLACE_UNREADABLE=yes; shift;;
    *) echo "release-state-record: unknown option $1" >&2; exit 2;;
  esac
done
# Exactly one target. Both, or neither, is a caller bug -- and guessing which was meant would either
# skip the marker or write it somewhere nobody reads.
if [ -n "$NOTES_FILE" ] && [ -n "$TAG" ]; then
  echo "release-state-record: --notes-file and --tag are different targets; pass one" >&2
  exit 2
fi
[ -n "$NOTES_FILE" ] || [ -n "$TAG" ] || {
  echo "release-state-record: name a target -- --notes-file F (before packaging) or --tag T (an" >&2
  echo "    already-published release)" >&2
  exit 2
}
[ -n "$DIGEST" ] || { echo "release-state-record: --digest required" >&2; exit 2; }
case "$DIGEST" in
  v1:sha256:*) rest="${DIGEST#v1:sha256:}"
    case "$rest" in
      ''|*[!0-9a-f]*) echo "release-state-record: --digest is not v1:sha256:<lowercase hex>" >&2; exit 2;;
    esac ;;
  *) echo "release-state-record: --digest must start with v1:sha256:" >&2; exit 2;;
esac
if [ -n "$BODY_FILE" ] && [ -z "$OUT" ]; then
  echo "release-state-record: --body-file needs --out (offline mode writes a file, never a release)" >&2
  exit 2
fi

_tmp="${TMPDIR:-/tmp}"
work="$(mktemp -d "${_tmp%/}/state-record.XXXXXX")"; trap 'rm -rf "$work"' EXIT
body="$work/body"

# WHAT is being marked, and what it is CALLED in messages. One append rule below serves both.
if [ -n "$NOTES_FILE" ]; then
  [ -f "$NOTES_FILE" ] || {
    echo "release-state-record: no such notes file: $NOTES_FILE" >&2
    echo "    the notes are a build product; a missing one means this ran before they were" >&2
    echo "    generated. This script never creates them." >&2
    exit 2
  }
  cp "$NOTES_FILE" "$body"
  what="$NOTES_FILE"
elif [ -n "$BODY_FILE" ]; then
  cp "$BODY_FILE" "$body"
  what="$TAG"
else
  set -- release view "$TAG" --json body --jq .body
  [ -z "$REPO" ] || set -- "$@" --repo "$REPO"
  gh "$@" > "$body" 2>"$work/err" || {
    echo "release-state-record: cannot read release $TAG: $(cat "$work/err")" >&2
    exit 1
  }
  what="$TAG"
fi

# What counts as a recorded marker is lib.sh's business, not this script's: release-needed.sh reads
# the same bodies, and when the two rules differed a marker in an older format was "nothing recorded"
# to that script and "a CONFLICTING record" to this one -- exit 3, nightly, forever.
existing="$(state_marker < "$body")"
if [ -n "$existing" ]; then
  if [ "$existing" = "$DIGEST" ]; then
    # Nothing to write, so nothing is written -- not even a byte-identical rewrite of the target.
    [ -z "$OUT" ] || cp "$body" "$OUT"
    printf 'UNCHANGED=%s\n' "$what"
    exit 0
  fi
  if [ "$REPLACE_UNREADABLE" = yes ] && ! state_digest_readable "$existing"; then
    # The escape release-needed.sh's SKIP=unreadable-marker/<tag> tells you to take. Rewrite the
    # marker LINE where it stands rather than stripping and re-appending, so a body whose marker is
    # not at the end keeps its shape; every other byte is preserved as always. One marker per body is
    # the invariant, and a stale unreadable line is litter in notes users read, so any others go.
    awk -v new="ModernMavericks-State: $DIGEST" '
      /^ModernMavericks-State:/ { if (!seen) { print new; seen = 1 } ; next }
      { print }
    ' "$body" > "$work/replaced"
    mv "$work/replaced" "$body"
    REPLACED=yes
  else
    echo "release-state-record: $what already records a DIFFERENT state" >&2
    echo "    recorded: $existing" >&2
    echo "    offered:  $DIGEST" >&2
    echo "    two declared states cannot claim one release; nothing was written" >&2
    if state_digest_readable "$existing"; then
      echo "    (both are readable digests, so this is a real disagreement -- not something" >&2
      echo "    --replace-unreadable will resolve for you)" >&2
    else
      echo "    the recorded marker is not a digest this shipyard can read; to replace exactly that," >&2
      echo "    pass --replace-unreadable" >&2
    fi
    exit 3
  fi
fi

# The marker must be its own PARAGRAPH, not a line welded to the footer. Markdown joins consecutive
# lines, so a marker appended directly after the footer's last line renders -- in the Sparkle update
# dialog a 10.9 user actually reads -- as one run-on paragraph ending in a raw 64-character hash:
#   "Requires Mac OS X 10.9.5 or later. All changes since 9.9p2-mavericks.5 ModernMavericks-State: v1:sha256:3f78..."
# Verified by the openssh session rendering a real body through `gen_appcast.sh --render-notes`.
#
# So: guarantee a final newline FIRST, then leave a blank line. The guarantee matters because
# `gh release view --json body --jq .body` does not promise a trailing newline and neither does a
# hand-edited notes file -- and without it the `printf '\n'` below merely terminates the footer's
# last line, leaving the marker fused to it exactly as above. `$(tail -c 1 …)` is empty precisely
# when that byte IS a newline, because command substitution strips trailing newlines.
#
# A target with no content at all gets neither, so it does not begin with an empty line.
# Skipped entirely when --replace-unreadable already rewrote the marker in place: appending there
# would leave the old line AND a new one, which is two markers where the whole point was one.
if [ "$REPLACED" = no ]; then
  if [ -s "$body" ]; then
    [ -z "$(tail -c 1 "$body")" ] || printf '\n' >> "$body"
    printf '\n' >> "$body"
  fi
  printf 'ModernMavericks-State: %s\n' "$DIGEST" >> "$body"
fi

if [ -n "$NOTES_FILE" ]; then
  # In place, and only after the append succeeded: a half-written notes file would publish.
  cat "$body" > "$NOTES_FILE"
  if [ "$REPLACED" = yes ]; then printf 'REPLACED=%s\n' "$NOTES_FILE"
  else printf 'RECORDED=%s\n' "$NOTES_FILE"; fi
  exit 0
fi

if [ -n "$OUT" ]; then
  cp "$body" "$OUT"
else
  set -- release edit "$TAG" --notes-file "$body"
  [ -z "$REPO" ] || set -- "$@" --repo "$REPO"
  gh "$@" >/dev/null
fi
if [ "$REPLACED" = yes ]; then printf 'REPLACED=%s\n' "$TAG"
else printf 'BACKFILLED=%s\n' "$TAG"; fi
