#!/bin/sh
# ingredient-pins.sh: the SINGLE source of ingredient pin paths, read from the repackage caller.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/ingredient-pins.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/ingredient-pins-test.XXXXXX")"; trap 'rm -rf "$work"' EXIT
cd "$work"
git init -q -b main .
git config user.email t@example.com; git config user.name tester
mkdir -p .github/workflows components/golang components/tailscale
printf '1.26.5-mavericks.1\n' > components/golang/version
printf 'REF=v1.102.0\n'       > components/tailscale/version
printf '1.26.5\n'             > UPSTREAM_VERSION
printf 'MLS_VERSION=1.5.2\n'  > versions.sh
git add -A; git commit -qm base

# no caller workflow -> empty, exit 0 (a repo with no ingredients)
out="$(sh "$S")"
[ -z "$out" ] || { echo "FAIL no-caller: got '$out'"; exit 1; }

# inline form + own-upstream exclusion (tailscale/container-tools shape)
cat > .github/workflows/repackage-on-ingredient-bump.yml <<'YML'
on:
  push:
    branches: [main]
    paths: ['components/**']
jobs:
  repackage:
    uses: ModernMavericks/shipyard/.github/workflows/repackage-on-ingredient-bump.yml@v1
    with:
      own-upstream-paths: components/tailscale/version
YML
out="$(sh "$S")"
[ "$out" = components/golang/version ] || { echo "FAIL inline: got '$out'"; exit 1; }

# block form with trailing comments (golang shape); own upstream excluded even when watched
cat > .github/workflows/repackage-on-ingredient-bump.yml <<'YML'
on:
  push:
    branches: [main]
    paths:
      - versions.sh        # the shim pin, the CA hash pin
      - UPSTREAM_VERSION   # deliberately listed to prove exclusion works
jobs:
  repackage:
    uses: ModernMavericks/shipyard/.github/workflows/repackage-on-ingredient-bump.yml@v1
    with:
      own-upstream-paths: UPSTREAM_VERSION
YML
out="$(sh "$S")"
[ "$out" = versions.sh ] || { echo "FAIL block: got '$out'"; exit 1; }

# a glob matching nothing -> empty (the guard, not this script, is what complains)
cat > .github/workflows/repackage-on-ingredient-bump.yml <<'YML'
on:
  push:
    paths: ['nosuchdir/**']
jobs:
  repackage:
    with:
      own-upstream-paths: ""
YML
out="$(sh "$S")"
[ -z "$out" ] || { echo "FAIL empty-glob: got '$out'"; exit 1; }

# --- G2: own-upstream-paths' "path:KEY" form must be honoured here too --------------------------
# repackage-decision.sh already understands "pins.env:SWIFT_VERSION" (a KEY inside a shared pin
# file is the repo's own upstream, not an ingredient). This script only compared whole paths
# ([ "$f" = "$o" ]), so "pins.env:SWIFT_VERSION" never matched the bare path "pins.env" and the file
# was never excluded at all -- on the swift repos' next Swift bump, the notes would list SWIFT_VERSION
# as a moved ingredient while repackage-decision.sh simultaneously says SKIP=own-upstream-changed.
cat > .github/workflows/repackage-on-ingredient-bump.yml <<'YML'
on:
  push:
    branches: [main]
    paths: ['pins.env']
jobs:
  repackage:
    uses: ModernMavericks/shipyard/.github/workflows/repackage-on-ingredient-bump.yml@v1
    with:
      own-upstream-paths: pins.env:SWIFT_VERSION
YML
printf 'SWIFT_VERSION="6.3.3"\nLLVM_SHA="aaaa"\n' > pins.env
git add -A; git commit -qm "add swift-shaped pins.env"
out="$(sh "$S")"
[ "$out" = "pins.env:SWIFT_VERSION" ] \
  || { echo "FAIL path:KEY: expected the key-annotated path, got '$out'"; exit 1; }

# a whole-path own-upstream entry must still exclude the file entirely (no regression)
cat > .github/workflows/repackage-on-ingredient-bump.yml <<'YML'
on:
  push:
    branches: [main]
    paths: ['pins.env']
jobs:
  repackage:
    uses: ModernMavericks/shipyard/.github/workflows/repackage-on-ingredient-bump.yml@v1
    with:
      own-upstream-paths: pins.env
YML
out="$(sh "$S")"
[ -z "$out" ] || { echo "FAIL whole-path still own-upstream: got '$out'"; exit 1; }

# --- IMPORTANT 3: own-upstream-paths as a YAML block scalar must parse like the inline form --------
# repackage-decision.sh never parses this YAML itself -- GitHub Actions' own engine resolves `with:`
# before that script sees a plain env var -- so this hand-rolled reader is the only place a block
# scalar ("own-upstream-paths: |") needs handling, and it must resolve to the same tokens a real YAML
# parser would. Unused by any family repo today (pre-existing, latent), but the brief asked for
# parsing that genuinely matches, not a lookalike that silently excludes nothing.
cat > .github/workflows/repackage-on-ingredient-bump.yml <<'YML'
on:
  push:
    branches: [main]
    paths: ['pins.env', 'other.txt']
jobs:
  repackage:
    uses: ModernMavericks/shipyard/.github/workflows/repackage-on-ingredient-bump.yml@v1
    with:
      own-upstream-paths: |
        pins.env:SWIFT_VERSION
        other.txt
YML
printf 'x\n' > other.txt
git add -A; git commit -qm "add other.txt, block-scalar own-upstream-paths"
out="$(sh "$S")"
printf '%s\n' "$out" | grep -qx 'pins.env:SWIFT_VERSION' \
  || { echo "FAIL block-scalar: pins.env:SWIFT_VERSION not derived, got '$out'"; exit 1; }
printf '%s\n' "$out" | grep -qx 'other.txt' \
  && { echo "FAIL block-scalar: other.txt should be excluded whole, got '$out'"; exit 1; }

# --- FINDING 2 (round 3): the block scalar must end at a SIBLING KEY, not just at column 0 ---------
# The reader terminated inblock only on a column-0 line, but every sibling key under the same `with:`
# (dispatch-workflow:, dispatch-field:, ...) is itself indented -- so it (and its VALUE) got swallowed
# into the own-upstream token list. That is only cosmetic when the leaked tokens don't coincide with a
# real watched path -- but here the sibling's value ("other.txt") IS a real watched path, so the old
# reader wrongly excludes it entirely, purely because of an unrelated sibling key three lines below
# the block. A real YAML parser ends the block at the first line no MORE indented than
# "own-upstream-paths:" itself; this reader must match that exactly.
cat > .github/workflows/repackage-on-ingredient-bump.yml <<'YML'
on:
  push:
    branches: [main]
    paths: ['pins.env', 'other.txt']
jobs:
  repackage:
    uses: ModernMavericks/shipyard/.github/workflows/repackage-on-ingredient-bump.yml@v1
    with:
      own-upstream-paths: |
        pins.env:SWIFT_VERSION
      dispatch-field: other.txt
YML
git add -A; git commit -qm "block-scalar own-upstream-paths with a colliding sibling value"
out="$(sh "$S")"
printf '%s\n' "$out" | grep -qx 'pins.env:SWIFT_VERSION' \
  || { echo "FAIL block-scalar sibling keys: pins.env:SWIFT_VERSION missing, got '$out'"; exit 1; }
printf '%s\n' "$out" | grep -qx 'other.txt' \
  || { echo "FAIL block-scalar sibling keys: other.txt wrongly excluded by a sibling key's value, got '$out'"; exit 1; }

echo "PASS: ingredient-pins"
