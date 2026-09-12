#!/bin/sh
# Is this file the family's release body for this exact version?
#
# The shape is small on purpose -- it has to pass for every product, from a Go toolchain to a kext --
# so it asserts only what a reader is entitled to: the release says which version it is, and says what
# changed. Six products published "Automated release for Mac OS X 10.9 (Mavericks)." as their entire
# notes, for every release including Renovate-driven repackages whose only reason to exist was an
# ingredient bump; that body passes no check here.
#
# Used twice: release-notes.sh self-checks what it just generated, and publish-release.yml checks what
# it is about to publish -- so a repo that regresses to a hand-rolled body still cannot ship one.
#   usage: check-release-notes.sh <file> <version>
set -eu
f="${1:?check-release-notes: notes file required}"
ver="${2:?check-release-notes: version required}"

fail() { echo "check-release-notes: $1" >&2; exit 1; }

[ -f "$f" ] || fail "no such file: $f"
[ -s "$f" ] || fail "$f is empty; a release body must say something"
[ -n "$(tr -d '[:space:]' < "$f")" ] || fail "$f is empty apart from whitespace"

first="$(sed -n '1p' "$f")"
case "$first" in
  '## '*) ;;
  *) fail "the first line of $f is not a '## ' title: $first" ;;
esac

# The title must name THIS version. A copied file under a new tag is otherwise invisible: every other
# check passes, and the release announces its predecessor.
case "$first" in
  *"$ver"*) ;;
  *) fail "the title does not name $ver: $first" ;;
esac

grep -q '^### What changed[[:space:]]*$' "$f" \
  || fail "$f has no '### What changed' section; every release says what changed, even a repackage"

# A heading with nothing under it is worse than no heading: it promises a section and delivers none.
# The '## ' title line is not itself a section requiring a body -- it is validated separately above --
# so it only resets tracking; '### ' subsections are what must have non-blank content before the next
# heading, a '---' rule, or end of file.
t="$(mktemp "${TMPDIR:-/tmp}/crn.XXXXXX")"
trap 'rm -f "$t"' EXIT
awk '
  /^### / {
    if (head != "" && body == 0) { print head; exit 1 }
    head = $0; body = 0; next
  }
  /^##[^#]/ { if (head != "" && body == 0) { print head; exit 1 } head = ""; body = 0; next }
  /^---[[:space:]]*$/ { if (head != "" && body == 0) { print head; exit 1 } head = ""; body = 0; next }
  /[^[:space:]]/ { body = 1 }
  END { if (head != "" && body == 0) { print head; exit 1 } }
' "$f" > "$t" 2>/dev/null || {
  empty="$(cat "$t" 2>/dev/null || true)"
  fail "section is empty: ${empty:-<unknown>}"
}

echo "check-release-notes: ok — $f is the family shape for $ver"
