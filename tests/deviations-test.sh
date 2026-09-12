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
echo "PASS: deviations"
