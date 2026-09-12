#!/bin/sh
# release-notes-file.sh is a back-compat DELEGATING wrapper around release-notes.sh (the generator).
# Its own job is narrow, and this file tests only that job:
#   - forward the unchanged TAG/FULL/PRODUCT signature
#   - translate the family's older "Mavericks X" / "X for Mavericks" product phrasing to the
#     generator's bare noun
#   - keep the generator's own stdout progress line ("release-notes: wrote ...") off the WRAPPER's
#     stdout, since callers capture that stdout as a PATH (NOTES="$(sh ... )")
#   - hand back a TEMP file, never editing a committed release-notes/<TAG>.md in place
# What a generated body actually CONTAINS -- titles, upstream links, ingredient sections, footers -- is
# release-notes.sh's contract, tested exhaustively in tests/release-notes-test.sh. Duplicating that here
# would only let the two drift.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/release-notes-file.sh"
w="$(mktemp -d "${TMPDIR:-/tmp}/release-notes-file-t.XXXXXX")"; trap 'rm -rf "$w"' EXIT
cd "$w"
git init -q -b main .
git config user.email t@example.com; git config user.name tester
mkdir -p release-notes
printf 'x\n' > UPSTREAM_VERSION
git add -A; git commit -qm base
export MAVERICKS_ROOT="$w"

# All the calls below use a SELF-upstream tag (TAG == FULL, no "-mavericks." axis): that sidesteps the
# generator's hook/tag/ingredient machinery entirely (no build/upstream-release-notes-url.sh or
# repackage-on-ingredient-bump.yml needed), which is exactly right for a test of the WRAPPER's own
# plumbing rather than the generator's.

# --- the stdout contract: exactly one line, a path to a non-empty file. The generator's own progress
# line must land on the wrapper's STDERR, never mixed into what a caller captures as $NOTES.
sh "$S" 20260911.1 20260911.1 Porthole >"$w/out.log" 2>"$w/err.log"
[ "$(wc -l < "$w/out.log" | tr -d ' ')" = 1 ] \
  || { echo "FAIL stdout: expected exactly one line"; cat -A "$w/out.log"; exit 1; }
p="$(cat "$w/out.log")"
[ -s "$p" ] || { echo "FAIL stdout: '$p' is not a non-empty file"; exit 1; }
grep -q 'release-notes: wrote' "$w/err.log" \
  || { echo "FAIL stdout: generator's progress line never appeared (on stderr or anywhere)"; exit 1; }
grep -q 'release-notes: wrote' "$w/out.log" \
  && { echo "FAIL stdout: generator's progress line leaked onto the wrapper's stdout"; exit 1; }
rm -f "$p"

# --- a committed note supplies the prose, is returned as a TEMP copy, and is never edited in place
printf '## Hand-written\n\nProse that must survive.\n' > release-notes/20260911.2.md
git add -A; git commit -qm notes
before="$(git hash-object release-notes/20260911.2.md)"
p="$(sh "$S" 20260911.2 20260911.2 Porthole 2>/dev/null)"
case "$p" in */release-notes/*) echo "FAIL committed should be temp: $p"; exit 1;; esac
grep -q 'Hand-written' "$p" || { echo "FAIL prose not preserved"; cat "$p"; exit 1; }
grep -q 'Prose that must survive' "$p" || { echo "FAIL prose not preserved"; cat "$p"; exit 1; }
[ "$before" = "$(git hash-object release-notes/20260911.2.md)" ] \
  || { echo "FAIL committed note edited in place"; exit 1; }
rm -f "$p"

# --- PRODUCT translation: the family's older prose phrasing reduces to the generator's bare noun
p="$(sh "$S" 20260911.3 20260911.3 'Mavericks Go' 2>/dev/null)"
grep -q '^## Go 20260911.3$' "$p" || { echo "FAIL 'Mavericks Go' should strip to 'Go'"; cat "$p"; exit 1; }
rm -f "$p"
p="$(sh "$S" 20260911.4 20260911.4 'OpenSSH for Mavericks' 2>/dev/null)"
grep -q '^## OpenSSH 20260911.4$' "$p" \
  || { echo "FAIL 'OpenSSH for Mavericks' should strip to 'OpenSSH'"; cat "$p"; exit 1; }
rm -f "$p"

# --- omitted PRODUCT keeps the documented default
p="$(sh "$S" 20260911.5 20260911.5 2>/dev/null)"
grep -q '^## ModernMavericks 20260911.5$' "$p" || { echo "FAIL default product missing"; cat "$p"; exit 1; }
rm -f "$p"

echo "PASS: release-notes-file (shared)"

# The wrapper now delegates to release-notes.sh, so a repo that has not migrated still gets the family
# shape: its output must pass check-release-notes.sh.
w2="$(mktemp -d "${TMPDIR:-/tmp}/rnf-delegate.XXXXXX")"
mkdir -p "$w2/build"
( cd "$w2" && git init -q -b main . && git config user.email t@example.com && git config user.name tester \
   && printf '9.9p2\n' > UPSTREAM_VERSION \
   && printf '#!/bin/sh\nprintf "https://example.com/%%s\\n" "$1"\n' > build/upstream-release-notes-url.sh \
   && git add -A && git commit -qm base && git tag 9.9p2-mavericks.1 )
p="$(cd "$w2" && MAVERICKS_ROOT="$w2" sh "$here/../scripts/release-notes-file.sh" 9.9p2-mavericks.1 9.9p2-mavericks.1 OpenSSH)"
[ -s "$p" ] || { echo "FAIL delegate: empty file at '$p'"; exit 1; }
sh "$here/../scripts/check-release-notes.sh" "$p" 9.9p2-mavericks.1 >/dev/null \
  || { echo "FAIL delegate: wrapper output is not the family shape"; cat "$p"; exit 1; }
rm -rf "$w2"
