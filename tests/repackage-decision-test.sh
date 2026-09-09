#!/bin/sh
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/repackage-decision.sh"

# own-upstream changed -> SKIP (that's the N=1 path's job)
out="$(CHANGED='UPSTREAM_VERSION' OWN_UPSTREAM_PATHS='UPSTREAM_VERSION' sh "$S")"
[ "$out" = "SKIP=own-upstream-changed" ] || { echo "FAIL own-upstream: $out"; exit 1; }

# an own-upstream path present among several changed paths -> SKIP
out="$(CHANGED="$(printf 'components/golang/version\ncomponents/tailscale/version')" OWN_UPSTREAM_PATHS='components/tailscale/version' sh "$S")"
[ "$out" = "SKIP=own-upstream-changed" ] || { echo "FAIL own-upstream-multi: $out"; exit 1; }

# ingredient only, own-upstream declared but unchanged -> DISPATCH
out="$(CHANGED='components/golang/version' OWN_UPSTREAM_PATHS='components/tailscale/version' sh "$S")"
[ "$out" = "DISPATCH" ] || { echo "FAIL ingredient/dispatch: $out"; exit 1; }

# ingredient, empty own-upstream (e.g. container-tools) -> DISPATCH
out="$(CHANGED='components/golang/version' OWN_UPSTREAM_PATHS='' sh "$S")"
[ "$out" = "DISPATCH" ] || { echo "FAIL ingredient/empty-own: $out"; exit 1; }

# --- own-upstream declared as a KEY inside a shared file -------------------------------------
# The swift repos keep every pin in ONE shell file (pins.env / build.sh): SWIFT_VERSION is their own
# upstream, the LLVM and toolchain pins are ingredients. Path-level ownership cannot tell those apart
# -- declaring the whole file own-upstream would skip every repackage, declaring it not-own would
# double-publish a Swift bump (auto-cut N=1 from the push AND a dispatched N+1). So an entry may name
# a key: "pins.env:SWIFT_VERSION".
work="$(mktemp -d "${TMPDIR:-/tmp}/repackage-decision-t.XXXXXX")"; trap 'rm -rf "$work"' EXIT
cd "$work"
git init -q . && git config user.email t@t && git config user.name t
cat > pins.env <<'EOF'
SWIFT_VERSION="6.3.3"
LLVM_SHA="aaaa"
EOF
git add -A && git commit -qm one
BASE="$(git rev-parse HEAD)"

# the ingredient key moved, the upstream key did not -> DISPATCH
sed -i.bak 's/LLVM_SHA="aaaa"/LLVM_SHA="bbbb"/' pins.env && rm -f pins.env.bak
git add -A && git commit -qm two
out="$(CHANGED='pins.env' OWN_UPSTREAM_PATHS='pins.env:SWIFT_VERSION' BEFORE="$BASE" sh "$S")"
[ "$out" = "DISPATCH" ] || { echo "FAIL key-level ingredient should dispatch: $out"; exit 1; }

# the upstream key itself moved -> SKIP (the repo's own new-upstream path owns it)
BASE2="$(git rev-parse HEAD)"
sed -i.bak 's/SWIFT_VERSION="6.3.3"/SWIFT_VERSION="6.4.0"/' pins.env && rm -f pins.env.bak
git add -A && git commit -qm three
out="$(CHANGED='pins.env' OWN_UPSTREAM_PATHS='pins.env:SWIFT_VERSION' BEFORE="$BASE2" sh "$S")"
[ "$out" = "SKIP=own-upstream-changed" ] || { echo "FAIL key-level upstream should skip: $out"; exit 1; }

# a key entry whose FILE did not change at all -> DISPATCH, without consulting git
out="$(CHANGED='components/x/version' OWN_UPSTREAM_PATHS='pins.env:SWIFT_VERSION' BEFORE="$BASE2" sh "$S")"
[ "$out" = "DISPATCH" ] || { echo "FAIL untouched key file should dispatch: $out"; exit 1; }

# A key entry with no BEFORE cannot answer the question. Fail loudly: guessing DISPATCH would
# double-publish an upstream bump, and guessing SKIP would silently stop every repackage.
if out="$(CHANGED='pins.env' OWN_UPSTREAM_PATHS='pins.env:SWIFT_VERSION' sh "$S" 2>&1)"; then
  echo "FAIL missing BEFORE should fail, got: $out"; exit 1
fi
printf '%s\n' "$out" | grep -qi 'BEFORE' || { echo "FAIL should name BEFORE: $out"; exit 1; }

cd /
echo "PASS: repackage-decision"
