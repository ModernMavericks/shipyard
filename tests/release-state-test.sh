#!/bin/sh
# release-state.sh: the canonical rendering and its digest.
#
# The rendering is a WIRE FORMAT -- every published release records a digest computed from it, so a
# change here invalidates all of them and reads as "nothing has ever been released". The golden
# values below are the guard. If you are changing them deliberately, the spec's failure-modes section
# says a format bump means recompute, never republish.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/release-state.sh"
_tmp="${TMPDIR:-/tmp}"
w="$(mktemp -d "${_tmp%/}/release-state-test.XXXXXX")"; trap 'rm -rf "$w"' EXIT
GOLD='v1:sha256:8c5fc85c689b60ccc9a3ed0120fa949e2bd9c0f9a121ac572fa11ba148312be7'

mk() {   # $1 = dir; a minimal product: upstream 1.2.3, one ingredient pin at 4.4.3
  mkdir -p "$1"
  printf '1.2.3\n' > "$1/UPSTREAM_VERSION"
  printf 'CMAKE_VERSION=4.4.3\nOTHER=ignored\n' > "$1/pins.env"
  printf '%s\n' '# Build ingredients' '' '## Declared state' '' \
    '- upstream: UPSTREAM_VERSION' '- cmake: pins.env:CMAKE_VERSION' > "$1/INGREDIENTS.md"
}

# 1. The golden digest: sha256 of "cmake=4.4.3\nupstream=1.2.3\n" -- sorted by NAME, not by
#    declaration order and not by path.
mk "$w/a"
got="$(sh "$S" --root "$w/a")"
[ "$got" = "$GOLD" ] || { echo "FAIL golden: got '$got', want '$GOLD'"; exit 1; }

# 2. --render shows the rendering, which is what makes a digest mismatch debuggable at all.
got="$(sh "$S" --root "$w/a" --render)"
want="$(printf 'cmake=4.4.3\nupstream=1.2.3')"
[ "$got" = "$want" ] || { echo "FAIL render: got '$got'"; exit 1; }

# 3. A SOURCE change does not move the digest. This is the doctrine's first clause as a property of
#    the design: a push that only changes code has nothing to realise.
echo 'int main(void){return 0;}' > "$w/a/main.c"
got="$(sh "$S" --root "$w/a")"
[ "$got" = "$GOLD" ] || { echo "FAIL a source change moved the digest: $got"; exit 1; }

# 4. An INGREDIENT change does move it.
mk "$w/b"; printf 'CMAKE_VERSION=4.4.4\nOTHER=ignored\n' > "$w/b/pins.env"
got="$(sh "$S" --root "$w/b")"
want='v1:sha256:405b7fdda86a03f4ef636aceb3c7c819fe5d93208118cd365a0b962cb37c8004'
[ "$got" = "$want" ] || { echo "FAIL ingredient change: got '$got', want '$want'"; exit 1; }

# 5. Declaration ORDER does not matter; the canonical name is the key.
mk "$w/c"
printf '%s\n' '# Build ingredients' '' '## Declared state' '' \
  '- cmake: pins.env:CMAKE_VERSION' '- upstream: UPSTREAM_VERSION' > "$w/c/INGREDIENTS.md"
got="$(sh "$S" --root "$w/c")"
[ "$got" = "$GOLD" ] || { echo "FAIL declaration order changed the digest: $got"; exit 1; }

# 6. Renaming the pin FILE does not change the digest -- that is why the name is the key.
mk "$w/d"; mv "$w/d/pins.env" "$w/d/versions.env"
printf '%s\n' '# Build ingredients' '' '## Declared state' '' \
  '- upstream: UPSTREAM_VERSION' '- cmake: versions.env:CMAKE_VERSION' > "$w/d/INGREDIENTS.md"
got="$(sh "$S" --root "$w/d")"
[ "$got" = "$GOLD" ] || { echo "FAIL renaming the pin file changed the digest: $got"; exit 1; }

# 7. Surrounding whitespace in a pin file is not part of the value.
mk "$w/k"; printf '  1.2.3  \n\n' > "$w/k/UPSTREAM_VERSION"
got="$(sh "$S" --root "$w/k")"
[ "$got" = "$GOLD" ] || { echo "FAIL whitespace in a pin file changed the digest: $got"; exit 1; }

# 8. A missing pin file is a HARD error, never a silently different digest: an unrenderable state
#    must not look like a new one and publish.
mk "$w/e"; rm "$w/e/pins.env"
if sh "$S" --root "$w/e" >"$w/e.out" 2>&1; then echo "FAIL missing pin file was accepted"; exit 1; fi
grep -q 'pins.env' "$w/e.out" || { echo "FAIL missing-file error does not name the file"; exit 1; }

# 9. A missing KEY inside an existing file is the same kind of error.
mk "$w/f"; printf 'OTHER=only\n' > "$w/f/pins.env"
if sh "$S" --root "$w/f" >"$w/f.out" 2>&1; then echo "FAIL missing key was accepted"; exit 1; fi
grep -q 'CMAKE_VERSION' "$w/f.out" || { echo "FAIL missing-key error does not name the key"; exit 1; }

# 10. An empty pin file is an error too, not an empty value silently folded into the digest.
mk "$w/l"; : > "$w/l/UPSTREAM_VERSION"
if sh "$S" --root "$w/l" >"$w/l.out" 2>&1; then echo "FAIL empty pin file was accepted"; exit 1; fi

# 11. No declared state at all -> exit 2 naming the section, never a digest. A repo that has not
#     migrated must get a usage error; the parser's silence is not a green light here.
mkdir -p "$w/g"; printf '%s\n' '# Build ingredients' '' 'prose only' > "$w/g/INGREDIENTS.md"
rc=0; sh "$S" --root "$w/g" >"$w/g.out" 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL no declared state should exit 2, got $rc"; exit 1; }
grep -q 'Declared state' "$w/g.out" || { echo "FAIL error does not name the section"; exit 1; }

# 12. A malformed declaration propagates as a failure, not as a partial digest -- and, like every
#     other usage-or-declaration error this script detects, that failure is exit 2, not whatever
#     declared-state.sh itself uses (1).
mk "$w/h"
printf '%s\n' '# Build ingredients' '' '## Declared state' '' '- upstream:' > "$w/h/INGREDIENTS.md"
rc=0; sh "$S" --root "$w/h" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL malformed declaration should exit 2, got $rc"; exit 1; }

# 13. Whitespace around a KEYED pin's value is not part of the value either -- the whole-file path
#     already trims, and a cosmetic reformat of a pins.env line must not move the digest.
mk "$w/m"; printf 'CMAKE_VERSION= 4.4.3 \nOTHER=ignored\n' > "$w/m/pins.env"
got="$(sh "$S" --root "$w/m")"
[ "$got" = "$GOLD" ] || { echo "FAIL whitespace around a keyed pin changed the digest: $got"; exit 1; }

echo "PASS: release-state"
