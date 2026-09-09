#!/bin/sh
# The guard: a pin nothing describes is the failure mode a single source can't prevent.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/check-ingredient-pins.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/check-ingredient-pin.XXXXXX")"; trap 'rm -rf "$work"' EXIT
cd "$work"
git init -q -b main .
git config user.email t@example.com; git config user.name tester
mkdir -p .github/workflows components/golang components/tailscale
printf '1.26.5-mavericks.1\n' > components/golang/version
printf 'REF=v1.102.0\n'       > components/tailscale/version
git add -A; git commit -qm base

# no caller -> passes trivially (legacysupport has no ingredients)
sh "$S" >/dev/null || { echo "FAIL no-caller should pass"; exit 1; }

# sound declaration -> passes
cat > .github/workflows/repackage-on-ingredient-bump.yml <<'YML'
on:
  push:
    paths: ['components/**']
jobs:
  repackage:
    with:
      own-upstream-paths: components/tailscale/version
YML
sh "$S" >/dev/null || { echo "FAIL sound declaration should pass"; exit 1; }

# a glob matching nothing -> fails loudly (a typo would otherwise thin the notes silently)
cat > .github/workflows/repackage-on-ingredient-bump.yml <<'YML'
on:
  push:
    paths: ['componentz/**']
jobs:
  repackage:
    with:
      own-upstream-paths: ""
YML
if sh "$S" >/dev/null 2>&1; then echo "FAIL empty expansion should fail"; exit 1; fi

# every watched path being own-upstream -> nothing left to describe; fails
cat > .github/workflows/repackage-on-ingredient-bump.yml <<'YML'
on:
  push:
    paths: ['components/tailscale/version']
jobs:
  repackage:
    with:
      own-upstream-paths: components/tailscale/version
YML
if sh "$S" >/dev/null 2>&1; then echo "FAIL all-excluded should fail"; exit 1; fi

# an untracked file never enters the list (expansion is over tracked files), so this still passes --
# documenting the behaviour rather than demanding a failure.
cat > .github/workflows/repackage-on-ingredient-bump.yml <<'YML'
on:
  push:
    paths: ['components/**', 'untracked.txt']
jobs:
  repackage:
    with:
      own-upstream-paths: ""
YML
printf 'x\n' > untracked.txt
sh "$S" >/dev/null || { echo "FAIL untracked-but-unmatched should still pass"; exit 1; }

echo "PASS: check-ingredient-pins"
