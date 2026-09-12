#!/bin/sh
# The family shape for a release body: a title naming THIS version, a What changed section, no empty
# sections, a non-empty body. Publishing something else is how "Automated release for Mac OS X 10.9
# (Mavericks)." became six products' entire release notes.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/check-release-notes.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-release-notes.XXXXXX")"; trap 'rm -rf "$work"' EXIT

ok() {  # $1 = file content, $2 = version, $3 = label
  printf '%s' "$1" > "$work/n.md"
  sh "$S" "$work/n.md" "$2" >/dev/null 2>&1 || { echo "FAIL should pass: $3"; exit 1; }
}
no() {  # $1 = content, $2 = version, $3 = label, $4 = expected substring of the complaint
  printf '%s' "$1" > "$work/n.md"
  if out="$(sh "$S" "$work/n.md" "$2" 2>&1)"; then echo "FAIL should fail: $3"; exit 1; fi
  printf '%s\n' "$out" | grep -q "$4" || { echo "FAIL $3: complaint lacked '$4': $out"; exit 1; }
}

GOOD='## OpenSSH 9.9p2 for Mavericks (9.9p2-mavericks.6)

### What changed
- Repackage of upstream OpenSSH 9.9p2; packaging changes only.

### Build ingredients
- **libressl**: 3.8.2 -> 3.9.2

---
Requires Mac OS X 10.9.5 or later.
'
ok "$GOOD" 9.9p2-mavericks.6 "the family shape"

# a self-upstream title carries the version without an upstream in parentheses
ok '## Porthole 20260802.6

### What changed
- Release of Porthole 20260802.6.
' 20260802.6 "self-upstream title"

no '' 9.9p2-mavericks.6 "empty file" "empty"
no '
   
' 9.9p2-mavericks.6 "whitespace only" "empty"

# the body must name THIS version -- a stale title is how a copied notes file ships under a new tag
no '## OpenSSH 9.9p2 for Mavericks (9.9p2-mavericks.5)

### What changed
- Repackage.
' 9.9p2-mavericks.6 "stale version in title" "9.9p2-mavericks.6"

# today's most common body: no What changed at all
no '## Mavericks OpenSSH 9.9p2 (9.9p2-mavericks.6)

Automated release for Mac OS X 10.9 (Mavericks).
' 9.9p2-mavericks.6 "no What changed" "What changed"

# a heading with nothing under it says less than no heading
no '## OpenSSH 9.9p2 for Mavericks (9.9p2-mavericks.6)

### What changed

### Build ingredients
- **libressl**: 3.8.2 -> 3.9.2
' 9.9p2-mavericks.6 "empty What changed" "empty"

# the first line must be the title, not prose
no 'Some prose first.

## OpenSSH 9.9p2 for Mavericks (9.9p2-mavericks.6)

### What changed
- Repackage.
' 9.9p2-mavericks.6 "title not first" "first line"

echo "PASS: check-release-notes"
