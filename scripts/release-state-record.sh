#!/bin/sh
# Record a state digest onto an ALREADY PUBLISHED release, so the fast path works for releases that
# predate this design (spec 2026-09-12, failure modes).
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
#   --tag T          the BACKFILL path: an already-published release, for releases that predate this
#                    design (spec 2026-09-12, failure modes).
#
#   usage: release-state-record.sh --notes-file F --digest v1:sha256:<hex>
#          release-state-record.sh --tag T --digest v1:sha256:<hex> [--repo OWNER/NAME]
#          release-state-record.sh --tag T --digest D --body-file F --out F   (offline; tests)
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$SELF/lib.sh"                    # state_marker(): the family's ONE reader of a recorded marker

TAG=""; DIGEST=""; REPO=""; BODY_FILE=""; OUT=""; NOTES_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2;;
    --digest) DIGEST="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --notes-file) NOTES_FILE="$2"; shift 2;;
    --body-file) BODY_FILE="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
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
  echo "release-state-record: $what already records a DIFFERENT state" >&2
  echo "    recorded: $existing" >&2
  echo "    offered:  $DIGEST" >&2
  echo "    two declared states cannot claim one release; nothing was written" >&2
  exit 3
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
if [ -s "$body" ]; then
  [ -z "$(tail -c 1 "$body")" ] || printf '\n' >> "$body"
  printf '\n' >> "$body"
fi
printf 'ModernMavericks-State: %s\n' "$DIGEST" >> "$body"

if [ -n "$NOTES_FILE" ]; then
  # In place, and only after the append succeeded: a half-written notes file would publish.
  cat "$body" > "$NOTES_FILE"
  printf 'RECORDED=%s\n' "$NOTES_FILE"
  exit 0
fi

if [ -n "$OUT" ]; then
  cp "$body" "$OUT"
else
  set -- release edit "$TAG" --notes-file "$body"
  [ -z "$REPO" ] || set -- "$@" --repo "$REPO"
  gh "$@" >/dev/null
fi
printf 'BACKFILLED=%s\n' "$TAG"
