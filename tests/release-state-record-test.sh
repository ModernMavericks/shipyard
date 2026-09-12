#!/bin/sh
# release-state-record.sh: record a digest onto an ALREADY PUBLISHED release.
#
# The only writer of a release body outside the publish path, so it is deliberately narrow: it
# appends one line and touches nothing else, it is idempotent so the nightly backstop can run
# forever, and a conflicting digest stops it rather than overwriting -- two declared states claiming
# one release is a question for a human.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/release-state-record.sh"
_tmp="${TMPDIR:-/tmp}"
w="$(mktemp -d "${_tmp%/}/record-test.XXXXXX")"; trap 'rm -rf "$w"' EXIT
D1='v1:sha256:8c5fc85c689b60ccc9a3ed0120fa949e2bd9c0f9a121ac572fa11ba148312be7'
D2='v1:sha256:405b7fdda86a03f4ef636aceb3c7c819fe5d93208118cd365a0b962cb37c8004'

# 1. Appends the line, preserving every existing byte of the notes users read.
printf '## What changed\n\n- a thing\n' > "$w/body1"
out="$(sh "$S" --tag 1.2.3-mavericks.1 --digest "$D1" --body-file "$w/body1" --out "$w/new1")"
[ "$out" = "BACKFILLED=1.2.3-mavericks.1" ] || { echo "FAIL append: got '$out'"; exit 1; }
grep -q '^## What changed$' "$w/new1" || { echo "FAIL append lost the heading"; exit 1; }
grep -q '^- a thing$' "$w/new1" || { echo "FAIL append lost a bullet"; exit 1; }
grep -q "^ModernMavericks-State: $D1\$" "$w/new1" || { echo "FAIL append did not add the line"; exit 1; }

# 2. Idempotent: the same digest again changes nothing, and says so.
out="$(sh "$S" --tag 1.2.3-mavericks.1 --digest "$D1" --body-file "$w/new1" --out "$w/new2")"
[ "$out" = "UNCHANGED=1.2.3-mavericks.1" ] || { echo "FAIL idempotent: got '$out'"; exit 1; }
cmp -s "$w/new1" "$w/new2" || { echo "FAIL idempotent run rewrote the body"; exit 1; }

# 3. A DIFFERENT digest already recorded is exit 3 and no write.
rc=0
sh "$S" --tag 1.2.3-mavericks.1 --digest "$D2" --body-file "$w/new1" --out "$w/new3" >"$w/o3" 2>&1 || rc=$?
[ "$rc" = 3 ] || { echo "FAIL conflict should exit 3, got $rc"; exit 1; }
[ ! -f "$w/new3" ] || { echo "FAIL conflict still wrote an output"; exit 1; }
grep -q "$D1" "$w/o3" || { echo "FAIL conflict message does not show the digest already recorded"; exit 1; }

# 4. An empty body is fine -- a release with no notes still gets its marker, and no leading blank.
: > "$w/body4"
out="$(sh "$S" --tag 9.9.9-mavericks.1 --digest "$D1" --body-file "$w/body4" --out "$w/new4")"
[ "$out" = "BACKFILLED=9.9.9-mavericks.1" ] || { echo "FAIL empty body: got '$out'"; exit 1; }
[ "$(head -1 "$w/new4")" = "ModernMavericks-State: $D1" ] \
  || { echo "FAIL empty body got a leading blank line: $(head -2 "$w/new4")"; exit 1; }

# 5. Usage errors are exit 2.
rc=0; sh "$S" --tag t --body-file "$w/body4" --out "$w/x" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL missing --digest should exit 2, got $rc"; exit 1; }
rc=0; sh "$S" --digest "$D1" --body-file "$w/body4" --out "$w/x" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL missing --tag should exit 2, got $rc"; exit 1; }
rc=0; sh "$S" --tag t --digest nope --body-file "$w/body4" --out "$w/x" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL malformed digest should exit 2, got $rc"; exit 1; }
# A valid prefix with a non-hex (or empty) tail must also be rejected -- "nope" above never reaches
# this branch, since it fails the prefix check first.
rc=0; sh "$S" --tag t --digest v1:sha256:ZZ --body-file "$w/body4" --out "$w/x" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL non-hex digest tail should exit 2, got $rc"; exit 1; }
rc=0; sh "$S" --tag t --digest v1:sha256: --body-file "$w/body4" --out "$w/x" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL empty digest tail should exit 2, got $rc"; exit 1; }
# --body-file without --out would mean "read a file, write a RELEASE", which no caller wants.
rc=0; sh "$S" --tag t --digest "$D1" --body-file "$w/body4" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL --body-file without --out should exit 2, got $rc"; exit 1; }

# --- the NORMAL path: mark a notes file IN PLACE, before packaging ------------------------------
#
# This is what a product's release.yml calls before sign_and_appcast.sh. The appcast's
# <description> and the Release body are both produced from this one notes file, so marking it
# before packaging is what keeps them in agreement; a marker added later would leave the appcast's
# copy one line short of the Release page's. It takes no --tag: the notes file is not a release yet,
# and inventing a tag argument for it would invite passing the wrong one.

# 6. Appends in place, preserving the notes.
printf '## 1.2.3-mavericks.1\n\n### What changed\n\n- a thing\n' > "$w/notes"
out="$(sh "$S" --notes-file "$w/notes" --digest "$D1")"
[ "$out" = "RECORDED=$w/notes" ] || { echo "FAIL notes-file: got '$out'"; exit 1; }
grep -q '^### What changed$' "$w/notes" || { echo "FAIL notes-file lost a section"; exit 1; }
[ "$(tail -1 "$w/notes")" = "ModernMavericks-State: $D1" ] \
  || { echo "FAIL marker is not the last line: $(tail -1 "$w/notes")"; exit 1; }

# 7. Idempotent in place: running twice leaves one marker and reports UNCHANGED.
cp "$w/notes" "$w/notes.first"
out="$(sh "$S" --notes-file "$w/notes" --digest "$D1")"
[ "$out" = "UNCHANGED=$w/notes" ] || { echo "FAIL notes-file idempotent: got '$out'"; exit 1; }
cmp -s "$w/notes" "$w/notes.first" || { echo "FAIL second run rewrote the notes"; exit 1; }
[ "$(grep -c 'ModernMavericks-State:' "$w/notes")" = 1 ] || { echo "FAIL two markers"; exit 1; }

# 8. A different digest in place is exit 3 and NO write -- the file must be left exactly as it was.
cp "$w/notes" "$w/notes.before"
rc=0; sh "$S" --notes-file "$w/notes" --digest "$D2" >"$w/o8" 2>&1 || rc=$?
[ "$rc" = 3 ] || { echo "FAIL notes-file conflict should exit 3, got $rc"; exit 1; }
cmp -s "$w/notes" "$w/notes.before" || { echo "FAIL conflict modified the notes file"; exit 1; }

# 9. --notes-file and --tag are different targets; asking for both is a usage error, not a guess.
rc=0; sh "$S" --notes-file "$w/notes" --tag t --digest "$D1" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL --notes-file with --tag should exit 2, got $rc"; exit 1; }

# 10. Neither target named is a usage error too.
rc=0; sh "$S" --digest "$D1" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL no target should exit 2, got $rc"; exit 1; }

# 11. A missing notes file is an error, never a file this script creates: the notes are a build
#     product, and a missing one means the caller ran this before generating them.
rc=0; sh "$S" --notes-file "$w/nope.md" --digest "$D1" >"$w/o11" 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL missing notes file should exit 2, got $rc"; exit 1; }
grep -q 'nope.md' "$w/o11" || { echo "FAIL missing-notes error does not name the file"; exit 1; }

# 12. THE MARKER IS ITS OWN PARAGRAPH. Markdown joins consecutive lines, so a marker welded to the
#     footer renders in a 10.9 user's Sparkle dialog as one run-on paragraph ending in a raw hash.
#     Assert the blank line, not just the marker's presence.
printf '## 1.2.3-mavericks.1\n\n### What changed\n\n- a thing\n\n---\n\nRequires Mac OS X 10.9.5 or later.\n' > "$w/n12"
sh "$S" --notes-file "$w/n12" --digest "$D1" >/dev/null
[ "$(tail -1 "$w/n12")" = "ModernMavericks-State: $D1" ] || { echo "FAIL marker not last"; exit 1; }
[ -z "$(tail -2 "$w/n12" | head -1)" ] \
  || { echo "FAIL no blank line before the marker: '$(tail -2 "$w/n12" | head -1)'"; exit 1; }
grep -q '^Requires Mac OS X 10.9.5 or later.$' "$w/n12" \
  || { echo "FAIL the footer line was altered"; exit 1; }

# 13. ...even when the notes file does NOT end with a newline. Without a guaranteed final newline
#     first, the separator merely terminates the footer's last line and the marker fuses to it --
#     which is the rendering bug above, reintroduced silently. `gh --jq .body` promises no trailing
#     newline either, so this is the shape a backfill can hand us too.
printf 'Requires Mac OS X 10.9.5 or later.' > "$w/n13"      # deliberately no trailing newline
sh "$S" --notes-file "$w/n13" --digest "$D1" >/dev/null
[ "$(tail -1 "$w/n13")" = "ModernMavericks-State: $D1" ] || { echo "FAIL marker not last (no-EOL)"; exit 1; }
[ -z "$(tail -2 "$w/n13" | head -1)" ] \
  || { echo "FAIL no blank line before the marker when the file lacked a final newline"; exit 1; }
[ "$(head -1 "$w/n13")" = 'Requires Mac OS X 10.9.5 or later.' ] \
  || { echo "FAIL the footer line lost its content: '$(head -1 "$w/n13")'"; exit 1; }

# 14. And the paragraph break does not accumulate: a second run adds nothing at all.
cp "$w/n13" "$w/n13.first"
sh "$S" --notes-file "$w/n13" --digest "$D1" >/dev/null
cmp -s "$w/n13" "$w/n13.first" || { echo "FAIL a second run changed the file"; exit 1; }

echo "PASS: release-state-record"
