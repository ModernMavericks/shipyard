#!/bin/sh
# The generator: one shape for every product, and a fatal error for every gap it cannot fill.
#
# Before this, notes were best-effort prose: every generated section was appended with `|| true` and
# 2>/dev/null, so a broken hook, an unfindable baseline or a shallow clone all produced a SHORTER body
# and a green run. openssh never listed an ingredient; signal-desktop shipped a new upstream with no
# link; swift-runtime's repackage failed at signing instead, for want of a committed file.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/release-notes.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/release-notes.XXXXXX")"; trap 'rm -rf "$work"' EXIT

# A product repo fixture: a git repo with a hook, a pin, and a repackage caller naming that pin.
mkrepo() {  # $1 = dir
  mkdir -p "$1/build" "$1/components/libressl" "$1/.github/workflows" "$1/release-notes"
  ( cd "$1" && git init -q -b main . && git config user.email t@example.com && git config user.name tester )
  printf '3.8.2\n' > "$1/components/libressl/version"
  cat > "$1/.github/workflows/repackage-on-ingredient-bump.yml" <<'YML'
on:
  push:
    branches: [main]
    paths:
      - components/libressl/version
jobs:
  repackage:
    uses: ModernMavericks/shipyard/.github/workflows/repackage-on-ingredient-bump.yml@v1
    with:
      own-upstream-paths: UPSTREAM_VERSION
YML
  printf '#!/bin/sh\nprintf "https://example.com/notes/%%s\\n" "$1"\n' > "$1/build/upstream-release-notes-url.sh"
  printf '9.9p2\n' > "$1/UPSTREAM_VERSION"
  ( cd "$1" && git add -A && git commit -qm base )
}

gen() {  # $1 = repo, $2 = tag/version, rest = extra args
  r="$1"; v="$2"; shift 2
  ( cd "$r" && MAVERICKS_ROOT="$r" sh "$S" --tag "$v" --version "$v" \
      --product OpenSSH --min-os 10.9.5 --out "$r/OUT.md" "$@" )
}

# --- new upstream: names the upstream, links its notes, and says what it replaced ------------------
r="$work/new"; mkrepo "$r"
( cd "$r" && git tag 9.9p2-mavericks.1 )
gen "$r" 9.9p2-mavericks.1 >/dev/null
grep -q '^## OpenSSH 9.9p2 for Mavericks (9.9p2-mavericks.1)$' "$r/OUT.md" \
  || { echo "FAIL new: title"; cat "$r/OUT.md"; exit 1; }
grep -q 'First release of OpenSSH 9.9p2' "$r/OUT.md" || { echo "FAIL new: first-release wording"; exit 1; }
grep -q 'https://example.com/notes/9.9p2' "$r/OUT.md" || { echo "FAIL new: upstream link"; exit 1; }
grep -q 'Requires Mac OS X 10.9.5 or later' "$r/OUT.md" || { echo "FAIL new: floor"; exit 1; }
sh "$here/../scripts/check-release-notes.sh" "$r/OUT.md" 9.9p2-mavericks.1 >/dev/null \
  || { echo "FAIL new: own output fails the shape check"; exit 1; }

# --- ingredient repackage: names the pin that moved, and the baseline it moved from ----------------
r="$work/ing"; mkrepo "$r"
( cd "$r" && git tag 9.9p2-mavericks.1 )
printf '3.9.2\n' > "$r/components/libressl/version"
( cd "$r" && git commit -qam "bump libressl" && git tag 9.9p2-mavericks.2 )
gen "$r" 9.9p2-mavericks.2 >/dev/null
grep -q 'rebuilt because build ingredients moved' "$r/OUT.md" || { echo "FAIL ing: kind"; cat "$r/OUT.md"; exit 1; }
grep -q '3.8.2 -> 3.9.2' "$r/OUT.md" || { echo "FAIL ing: pin diff (the openssh pN bug)"; cat "$r/OUT.md"; exit 1; }
grep -q '9.9p2-mavericks.1\.\{0,\}9.9p2-mavericks.2' "$r/OUT.md" \
  || grep -q 'compare/9.9p2-mavericks.1' "$r/OUT.md" || { echo "FAIL ing: compare link"; exit 1; }
grep -q 'Upstream release notes' "$r/OUT.md" && { echo "FAIL ing: a repackage must not claim a new upstream"; exit 1; }

# --- packaging-only: no upstream change, no pin moved ----------------------------------------------
r="$work/pkgonly"; mkrepo "$r"
( cd "$r" && git tag 9.9p2-mavericks.1 && echo x >> build/upstream-release-notes-url.sh \
    && git commit -qam "ci: unrelated" && git tag 9.9p2-mavericks.2 )
gen "$r" 9.9p2-mavericks.2 >/dev/null
grep -q 'packaging changes only' "$r/OUT.md" || { echo "FAIL pkgonly: kind"; cat "$r/OUT.md"; exit 1; }
grep -q '### Build ingredients' "$r/OUT.md" && { echo "FAIL pkgonly: no pin moved, no section"; exit 1; }

# --- committed prose is slotted in verbatim, never rewritten ---------------------------------------
r="$work/prose"; mkrepo "$r"
printf 'Hand-written paragraph.\n\n- a bullet a human wrote\n' > "$r/release-notes/9.9p2-mavericks.1.md"
( cd "$r" && git add -A && git commit -qm notes && git tag 9.9p2-mavericks.1 )
gen "$r" 9.9p2-mavericks.1 >/dev/null
grep -q 'Hand-written paragraph.' "$r/OUT.md" || { echo "FAIL prose: not included"; exit 1; }
grep -q '^- a bullet a human wrote$' "$r/OUT.md" || { echo "FAIL prose: mangled"; exit 1; }
grep -q '^### What changed$' "$r/OUT.md" || { echo "FAIL prose: generated sections dropped"; exit 1; }

# --- self-upstream: no -mavericks axis, so no upstream claim and a plain title ---------------------
r="$work/self"; mkrepo "$r"; rm "$r/build/upstream-release-notes-url.sh"
printf 'No upstream release notes: this repo is its own upstream.\n' > "$r/INGREDIENTS.md"
( cd "$r" && git add -A && git commit -qm self && git tag 20260802.5 )
( cd "$r" && MAVERICKS_ROOT="$r" sh "$S" --tag 20260802.6 --version 20260802.6 \
    --product Porthole --out "$r/OUT.md" ) >/dev/null
grep -q '^## Porthole 20260802.6$' "$r/OUT.md" || { echo "FAIL self: title"; cat "$r/OUT.md"; exit 1; }
grep -q 'for Mavericks (' "$r/OUT.md" && { echo "FAIL self: port-shaped title"; exit 1; }

# --- FATAL: a new upstream whose hook is broken ----------------------------------------------------
r="$work/badhook"; mkrepo "$r"
printf '#!/bin/sh\nexit 1\n' > "$r/build/upstream-release-notes-url.sh"
( cd "$r" && git commit -qam badhook && git tag 9.9p2-mavericks.1 )
if gen "$r" 9.9p2-mavericks.1 >/dev/null 2>&1; then echo "FAIL badhook: should be fatal"; exit 1; fi
out="$(gen "$r" 9.9p2-mavericks.1 2>&1 || true)"
printf '%s\n' "$out" | grep -qi 'upstream' || { echo "FAIL badhook: cause not named: $out"; exit 1; }

# --- FATAL: a new upstream with no hook and no declared reason -------------------------------------
r="$work/nohook"; mkrepo "$r"; rm "$r/build/upstream-release-notes-url.sh"
( cd "$r" && git add -A && git commit -qm nohook && git tag 9.9p2-mavericks.1 )
if gen "$r" 9.9p2-mavericks.1 >/dev/null 2>&1; then echo "FAIL nohook: should be fatal"; exit 1; fi

# ...but a DECLARED reason in INGREDIENTS.md is the sanctioned way to have none
printf 'No upstream release notes: upstream publishes none.\n' > "$r/INGREDIENTS.md"
( cd "$r" && git add -A && git commit -qm declare )
gen "$r" 9.9p2-mavericks.1 >/dev/null || { echo "FAIL nohook+declared: should pass"; exit 1; }

# --- FATAL: a shallow clone hides the tags, so the kind cannot be decided --------------------------
r="$work/shallow"; mkrepo "$r"
( cd "$r" && git tag 9.9p2-mavericks.1 )
sr="$work/shallow-clone"
git clone -q --depth 1 "file://$r" "$sr" 2>/dev/null || git clone -q --depth 1 "$r" "$sr"
if ( cd "$sr" && MAVERICKS_ROOT="$sr" sh "$S" --tag 9.9p2-mavericks.2 --version 9.9p2-mavericks.2 \
       --product OpenSSH --out "$sr/OUT.md" ) >/dev/null 2>&1; then
  echo "FAIL shallow: should be fatal (this is signal-desktop's silent-drop shape)"; exit 1
fi

# --- FATAL: missing required arguments -------------------------------------------------------------
r="$work/args"; mkrepo "$r"; ( cd "$r" && git tag 9.9p2-mavericks.1 )
if ( cd "$r" && MAVERICKS_ROOT="$r" sh "$S" --tag 9.9p2-mavericks.1 --version 9.9p2-mavericks.1 \
       --out "$r/OUT.md" ) >/dev/null 2>&1; then echo "FAIL args: --product must be required"; exit 1; fi

echo "PASS: release-notes"
