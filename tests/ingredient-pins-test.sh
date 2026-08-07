#!/bin/sh
# ingredient-pins.sh: the SINGLE source of ingredient pin paths, read from the repackage caller.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/ingredient-pins.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
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

echo "PASS: ingredient-pins"
