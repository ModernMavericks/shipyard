#!/bin/sh
# declared-state.sh: the "## Declared state" grammar in INGREDIENTS.md.
#
# One machine-readable list, in the file that already documents what a product is made of -- and in
# the same shape as the "## Conformance deviations" section above it. A second declaration file would
# be a second list of the same pins, which is the drift this whole spec exists to remove.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/declared-state.sh"
_tmp="${TMPDIR:-/tmp}"                    # macOS sets TMPDIR with a trailing slash
w="$(mktemp -d "${_tmp%/}/declared-state-test.XXXXXX")"; trap 'rm -rf "$w"' EXIT
TAB="$(printf '\t')"

ing() {   # $1 = dir, rest = lines of the "## Declared state" section
  mkdir -p "$1"; d="$1"; shift
  { printf '%s\n' '# Build ingredients' '' '| Ingredient | Pinned in |' '|---|---|' \
      '| CMake 4.4.3 | `pins.env` |' '' '## Conformance deviations' '' \
      '- scheme: shipyard versions are not <upstream>-mavericks.N' '' '## Declared state' ''
    for l in "$@"; do printf '%s\n' "$l"; done
  } > "$d/INGREDIENTS.md"
}

# 1. Both entry shapes, in declaration order, tab-separated.
ing "$w/a" '- upstream: UPSTREAM_VERSION' '- cmake: pins.env:CMAKE_VERSION'
got="$(sh "$S" "$w/a")"
want="$(printf 'upstream%sUPSTREAM_VERSION\ncmake%spins.env:CMAKE_VERSION' "$TAB" "$TAB")"
[ "$got" = "$want" ] || { echo "FAIL basic: got '$got'"; exit 1; }

# 2. The OTHER section's entries are not ours. Both sections use "- x: y"; scoping is the whole job.
ing "$w/b" '- upstream: UPSTREAM_VERSION'
got="$(sh "$S" "$w/b")"
[ "$got" = "$(printf 'upstream%sUPSTREAM_VERSION' "$TAB")" ] \
  || { echo "FAIL section scoping leaked a deviation in: got '$got'"; exit 1; }

# 3. A section that ends at the next heading stops there.
ing "$w/c" '- upstream: UPSTREAM_VERSION' '' '## Something else' '' '- cmake: not-ours'
got="$(sh "$S" "$w/c")"
[ "$got" = "$(printf 'upstream%sUPSTREAM_VERSION' "$TAB")" ] \
  || { echo "FAIL section did not end at the next heading: got '$got'"; exit 1; }

# 4. No such section at all -> exit 0, no output. A repo that has not migrated is not an error.
mkdir -p "$w/d"; printf '%s\n' '# Build ingredients' '' 'prose only' > "$w/d/INGREDIENTS.md"
got="$(sh "$S" "$w/d")"; rc=$?
[ "$rc" = 0 ] || { echo "FAIL absent section should exit 0, got $rc"; exit 1; }
[ -z "$got" ] || { echo "FAIL absent section printed '$got'"; exit 1; }

# 5. No INGREDIENTS.md at all -> the same: exit 0, silent, like deviations.sh.
mkdir -p "$w/e"
got="$(sh "$S" "$w/e")"
[ -z "$got" ] || { echo "FAIL missing INGREDIENTS.md printed '$got'"; exit 1; }

# 6. An entry with no value is fatal and names itself -- exactly as a deviation with no reason is.
ing "$w/f" '- upstream:'
if sh "$S" "$w/f" >"$w/f.out" 2>&1; then echo "FAIL valueless entry was accepted"; exit 1; fi
grep -q upstream "$w/f.out" || { echo "FAIL valueless entry error does not name it"; exit 1; }

# 7. A name that is not canonical is fatal: the name is the digest key, so it cannot be freeform.
ing "$w/g" '- Upstream Version: UPSTREAM_VERSION'
if sh "$S" "$w/g" >"$w/g.out" 2>&1; then echo "FAIL non-canonical name was accepted"; exit 1; fi

# 8. The same name twice is fatal, not last-one-wins.
ing "$w/h" '- upstream: UPSTREAM_VERSION' '- cmake: pins.env:A' '- cmake: pins.env:B'
if sh "$S" "$w/h" >"$w/h.out" 2>&1; then echo "FAIL duplicate name was accepted"; exit 1; fi
grep -q cmake "$w/h.out" || { echo "FAIL duplicate-name error does not name it"; exit 1; }

# 9. A section with entries but no `upstream` is fatal: there would be no version to compare against.
ing "$w/i" '- cmake: pins.env:CMAKE_VERSION'
if sh "$S" "$w/i" >"$w/i.out" 2>&1; then echo "FAIL missing upstream entry was accepted"; exit 1; fi
grep -q upstream "$w/i.out" || { echo "FAIL missing-upstream error does not say so"; exit 1; }

# 10. Prose inside the section is ignored, so the section can explain itself.
ing "$w/j" 'What this product IS, for release purposes:' '' '- upstream: UPSTREAM_VERSION'
got="$(sh "$S" "$w/j")"
[ "$got" = "$(printf 'upstream%sUPSTREAM_VERSION' "$TAB")" ] \
  || { echo "FAIL prose in the section was not ignored: got '$got'"; exit 1; }

echo "PASS: declared-state"
