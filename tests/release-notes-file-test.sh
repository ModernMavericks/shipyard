#!/bin/sh
# The promoted notes builder: one implementation, product name as an argument. Guarantees a non-empty
# file (the appcast signer and publish-release.yml both reject an empty one) and never edits a
# committed note in place.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/release-notes-file.sh"
w="$(mktemp -d "${TMPDIR:-/tmp}/release-notes-file-t.XXXXXX")"; trap 'rm -rf "$w"' EXIT
cd "$w"
git init -q -b main .
git config user.email t@example.com; git config user.name tester
mkdir -p release-notes components/golang .github/workflows
printf '1.26.4-mavericks.3\n' > components/golang/version
cat > .github/workflows/repackage-on-ingredient-bump.yml <<'YML'
on:
  push:
    paths: ['components/**']
jobs:
  repackage:
    with:
      own-upstream-paths: ""
YML
printf 'x\n' > UPSTREAM_VERSION
git add -A; git commit -qm base; git tag 1.0.0-mavericks.1
export MAVERICKS_ROOT="$w"

# absent note -> a non-empty default naming the product and the version, in a TEMP file
p="$(sh "$S" 2.0.0-mavericks.1 2.0.0-mavericks.1 'Mavericks Go')"
case "$p" in */release-notes/*) echo "FAIL absent should be temp: $p"; exit 1;; esac
[ -s "$p" ] || { echo "FAIL generated empty"; exit 1; }
grep -q '2.0.0' "$p" || { echo "FAIL missing version"; cat "$p"; exit 1; }
grep -q 'Mavericks Go' "$p" || { echo "FAIL missing product name"; cat "$p"; exit 1; }
rm -f "$p"

# a committed note supplies the prose, is returned as a TEMP copy, and is never edited in place
printf '## Hand-written\n\nProse that must survive.\n' > release-notes/1.0.0-mavericks.2.md
git add -A; git commit -qm notes
before="$(git hash-object release-notes/1.0.0-mavericks.2.md)"
p="$(sh "$S" 1.0.0-mavericks.2 1.0.0-mavericks.2 'Product')"
case "$p" in */release-notes/*) echo "FAIL committed should be temp: $p"; exit 1;; esac
head -1 "$p" | grep -q 'Hand-written' || { echo "FAIL prose not preserved"; cat "$p"; exit 1; }
[ "$before" = "$(git hash-object release-notes/1.0.0-mavericks.2.md)" ] \
  || { echo "FAIL committed note edited in place"; exit 1; }

# the ingredient section is appended when a pin moved since the previous release
printf '1.26.5-mavericks.1\n' > components/golang/version
p2="$(sh "$S" 1.0.0-mavericks.2 1.0.0-mavericks.2 'Product')"
grep -q '### Build ingredients' "$p2" || { echo "FAIL no ingredient section"; cat "$p2"; exit 1; }
grep -q '1.26.4-mavericks.3 -> 1.26.5-mavericks.1' "$p2" || { echo "FAIL pin delta missing"; cat "$p2"; exit 1; }
head -1 "$p2" | grep -q 'Hand-written' || { echo "FAIL prose lost when appending"; exit 1; }
rm -f "$p" "$p2"

# with the repo's hook, a NEW upstream links upstream's notes -- ahead of the ingredient facts
mkdir -p build
printf '#!/bin/sh\nprintf "https://example.com/v%%s\\n" "$1"\n' > build/upstream-release-notes-url.sh
p="$(sh "$S" 2.0.0-mavericks.1 2.0.0-mavericks.1 'Product')"
grep -qF '(https://example.com/v2.0.0)' "$p" || { echo "FAIL no upstream link"; cat "$p"; exit 1; }
u="$(grep -n '### Upstream' "$p" | cut -d: -f1)"; i="$(grep -n '### Build ingredients' "$p" | cut -d: -f1)"
[ "$u" -lt "$i" ] || { echo "FAIL upstream section should precede ingredients"; cat "$p"; exit 1; }
# ...and a repackage of an upstream already shipped does not
p2="$(sh "$S" 1.0.0-mavericks.2 1.0.0-mavericks.2 'Product')"
! grep -q '### Upstream' "$p2" || { echo "FAIL repackage linked upstream notes"; cat "$p2"; exit 1; }
rm -f "$p" "$p2"

echo "PASS: release-notes-file (shared)"
