#!/bin/sh
# One parser for INGREDIENTS.md's "## Conformance deviations": the artifact checker and the conventions
# gate must read a declared exception identically. A deviation without a reason is not a declaration.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; S="$here/../scripts/deviations.sh"
w="$(mktemp -d "${TMPDIR:-/tmp}/dev-test.XXXXXX")"; trap 'rm -rf "$w"' EXIT
cat > "$w/INGREDIENTS.md" <<'EOF'
# x
## Conformance deviations
- scheme: shipyard ports nothing
- enclosure-url:appcast.xml: the tag carries a v
- shipyard-cmake-only:build/legacy.sh: runs under the host cmake to bootstrap
## Next
- not-a-deviation: ignored
EOF
out="$(sh "$S" "$w")"
printf '%s\n' "$out" | grep -qx 'scheme \* shipyard ports nothing' || { echo "FAIL: unscoped entry; got:"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -qx 'enclosure-url appcast.xml the tag carries a v' || { echo "FAIL: scoped entry; got:"; echo "$out"; exit 1; }
printf '%s\n' "$out" | grep -qx 'shipyard-cmake-only build/legacy.sh runs under the host cmake to bootstrap' || { echo "FAIL: path-scoped entry"; exit 1; }
printf '%s\n' "$out" | grep -q 'not-a-deviation' && { echo "FAIL: entries outside the section must be ignored"; exit 1; }
printf '## Conformance deviations\n- scheme:\n' > "$w/INGREDIENTS.md"
if sh "$S" "$w" >/dev/null 2>&1; then echo "FAIL: an entry without a reason must fail"; exit 1; fi

# "- check:reason" -- no space after the colon -- is the same declaration written wrong. The grammar
# reads the text up to the SECOND colon as a glob, so this yields an EMPTY glob and the reason's first
# word silently becomes the scope. It fails safe today (an empty glob matches nothing, so the
# deviation simply never applies) which is exactly what makes it worth rejecting: the author wrote an
# exception, the file looks like it has one, and nothing honours it. One grammar, one meaning.
printf '## Conformance deviations\n- scheme:shipyard ports nothing\n' > "$w/INGREDIENTS.md"
if out="$(sh "$S" "$w" 2>&1)"; then echo "FAIL: a missing space after the colon must fail; got: $out"; exit 1; fi
printf '%s\n' "$out" | grep -qi 'glob' || { echo "FAIL: should say what is wrong (an empty glob): $out"; exit 1; }

# ...and a glob that is genuinely present still works, space or no space around it.
printf '## Conformance deviations\n- scheme:a/b.pkg: a real scope\n' > "$w/INGREDIENTS.md"
sh "$S" "$w" | grep -qx 'scheme a/b.pkg a real scope' || { echo "FAIL: a scoped entry must still parse"; exit 1; }
echo "PASS: deviations"
