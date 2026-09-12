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

# --- --ref: the state a RELEASE actually contained, computed rather than inferred ----------------
#
# This is ruling 16 as a test. version.sh's `auto` mode returns the EXISTING tag's N whenever the
# upstream already has one, so it maps every declared state of one upstream to ONE version: at the
# tag below and on main today, `version.sh auto` says 1.2.3-mavericks.1 both times, while the states
# differ. An earlier design read that version match as "already released" and then backfilled the
# current digest onto that release -- cementing an unreleased ingredient bump as released, with no
# later reconcile ever looking again. --ref removes the guess: the digest of a released state comes
# from the tree that was released.
GIT="git -c user.name=T -c user.email=t@example.com -c commit.gpgsign=false -c init.defaultBranch=main"
r="$w/r"
$GIT init -q "$r"
printf '1.2.3\n' > "$r/UPSTREAM_VERSION"
printf 'CMAKE_VERSION=4.4.3\nOTHER=ignored\n' > "$r/pins.env"
# The pre-migration past, faithfully: at the tag there is no "## Declared state" section AT ALL.
printf '%s\n' '# Build ingredients' '' 'prose only' > "$r/INGREDIENTS.md"
$GIT -C "$r" add -A
$GIT -C "$r" commit -q -m 'the release that predates this design'
$GIT -C "$r" tag 1.2.3-mavericks.1
# ...then the repo declares its state, and an ingredient bump lands.
printf 'CMAKE_VERSION=4.4.4\nOTHER=ignored\n' > "$r/pins.env"
printf '%s\n' '# Build ingredients' '' '## Declared state' '' \
  '- upstream: UPSTREAM_VERSION' '- cmake: pins.env:CMAKE_VERSION' > "$r/INGREDIENTS.md"
$GIT -C "$r" add -A
$GIT -C "$r" commit -q -m 'declare state, and bump cmake'

# 14. The working tree renders the CURRENT state...
got="$(sh "$S" --root "$r")"
want='v1:sha256:405b7fdda86a03f4ef636aceb3c7c819fe5d93208118cd365a0b962cb37c8004'
[ "$got" = "$want" ] || { echo "FAIL ref fixture, working tree: got '$got'"; exit 1; }

# 15. ...and --ref renders what the TAG contained: same rendering, same wire format, same golden
#     digest, only the source of the values changes. The two must DIFFER -- that difference is the
#     unreleased bump the version match could not see.
got="$(sh "$S" --root "$r" --ref 1.2.3-mavericks.1)"
[ "$got" = "$GOLD" ] || { echo "FAIL --ref did not render the tag's own tree: got '$got'"; exit 1; }

# 16. The DECLARATION comes from the working tree on purpose: the tag's tree has no "## Declared
#     state" section, because every pre-migration release predates it. The question --ref answers is
#     "what were TODAY's declared inputs worth at that revision?".
got="$(sh "$S" --root "$r" --ref 1.2.3-mavericks.1 --render)"
want="$(printf 'cmake=4.4.3\nupstream=1.2.3')"
[ "$got" = "$want" ] || { echo "FAIL --ref --render: got '$got'"; exit 1; }

# 17. A revision that does not exist is exit 2, never a digest. A shallow clone is the realistic way
#     to get here, and a wrong digest recorded onto a release cannot be un-recorded (exit 3 forever).
rc=0; sh "$S" --root "$r" --ref no-such-tag >"$w/r17" 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL a bogus --ref should exit 2, got $rc"; exit 1; }
grep -q 'no-such-tag' "$w/r17" || { echo "FAIL the bogus-ref error does not name it"; exit 1; }
#     And it must say the REVISION is the problem, not blame the first declared file: "UPSTREAM_VERSION
#     is not in no-such-tag's tree" sends the reader to the wrong question entirely.
grep -q 'not a revision' "$w/r17" \
  || { echo "FAIL a bogus --ref is not reported as a bad revision: $(cat "$w/r17")"; exit 1; }

# 18. A declared path the revision's tree does not have is exit 2 too, naming the ref: at an older
#     tag a pin file may simply not exist yet, and "absent" must not render as a new state.
printf '%s\n' '# Build ingredients' '' '## Declared state' '' \
  '- upstream: UPSTREAM_VERSION' '- cmake: pins.env:CMAKE_VERSION' '- later: later.pin' \
  > "$r/INGREDIENTS.md"
printf '7\n' > "$r/later.pin"
rc=0; sh "$S" --root "$r" --ref 1.2.3-mavericks.1 >"$w/r18" 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL a path absent at the ref should exit 2, got $rc"; exit 1; }
grep -q 'later.pin' "$w/r18" || { echo "FAIL the absent-at-ref error does not name the file"; exit 1; }
grep -q '1.2.3-mavericks.1' "$w/r18" || { echo "FAIL the absent-at-ref error does not name the ref"; exit 1; }
# ...and that same declaration renders fine from the working tree, so the failure is about the ref.
sh "$S" --root "$r" >/dev/null || { echo "FAIL the working tree stopped rendering"; exit 1; }

# 19. BYTE order, pinned by names that DISAGREE about it. Both names in the golden fixture are plain
#     alphabetic, so an edit dropping LC_ALL=C from the sort passed every assertion above -- while
#     glibc collation treats `-` and `_` as ignorable at the primary level and orders `ab`, `a-b`,
#     `a_b` differently from byte order (think macports-legacy-support). This digest is computed on
#     macOS at build time and on ubuntu in the nightly reconcile, and two hosts disagreeing about one
#     state is a nightly dispatch loop: one says the state is unreleased, the other publishes it.
#     Asserted through --render, because the bytes are the wire format and a hash only says "differs".
mk "$w/n"
printf '%s\n' '# Build ingredients' '' '## Declared state' '' '- upstream: UPSTREAM_VERSION' \
  '- ab: pins.env:AB' '- a_b: pins.env:A_UNDER_B' '- a-b: pins.env:A_DASH_B' > "$w/n/INGREDIENTS.md"
printf 'AB=3\nA_UNDER_B=2\nA_DASH_B=1\n' > "$w/n/pins.env"
got="$(sh "$S" --root "$w/n" --render)"
want="$(printf 'a-b=1\na_b=2\nab=3\nupstream=1.2.3')"
[ "$got" = "$want" ] || { echo "FAIL the rendering is not in byte order: got '$got'"; exit 1; }

# 20. The declared `upstream` must name the very file version.sh reads. Nothing else ties them
#     together: declared-state.sh accepts any path, and lib.sh reads
#     ${MAVERICKS_UPSTREAM_FILE:-UPSTREAM_VERSION}. A product tracking one file for its digest while
#     the version came from another would publish N+1 of the PREVIOUS upstream carrying the NEW
#     upstream's contents, and nothing anywhere would say so.
mk "$w/p"; mkdir -p "$w/p/components/foo"; printf '1.2.3\n' > "$w/p/components/foo/version"
printf '%s\n' '# Build ingredients' '' '## Declared state' '' \
  '- upstream: components/foo/version' '- cmake: pins.env:CMAKE_VERSION' > "$w/p/INGREDIENTS.md"
rc=0; sh "$S" --root "$w/p" >"$w/p.out" 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL an upstream version.sh does not read should exit 2, got $rc"; exit 1; }
grep -q 'components/foo/version' "$w/p.out" || { echo "FAIL the error does not name the declared path"; exit 1; }
grep -q 'UPSTREAM_VERSION' "$w/p.out" || { echo "FAIL the error does not name the path version.sh reads"; exit 1; }

# ...and it is the same coupling version.sh has, so the same override satisfies both. (The digest is
# the golden one: which FILE the upstream lives in is not part of the rendering -- the NAME is.)
got="$(MAVERICKS_UPSTREAM_FILE=components/foo/version sh "$S" --root "$w/p")"
[ "$got" = "$GOLD" ] || { echo "FAIL MAVERICKS_UPSTREAM_FILE did not reconcile the two: got '$got'"; exit 1; }
# An absolute override rooted at the repo is the same path, and must be accepted as one.
got="$(MAVERICKS_UPSTREAM_FILE="$w/p/components/foo/version" sh "$S" --root "$w/p")"
[ "$got" = "$GOLD" ] || { echo "FAIL a root-prefixed override was read as a different file: got '$got'"; exit 1; }

echo "PASS: release-state"
