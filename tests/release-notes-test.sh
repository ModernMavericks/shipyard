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
  ( cd "$r" && MAVERICKS_ROOT="$r" \
      GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=ModernMavericks/mavericks-openssh \
      sh "$S" --tag "$v" --version "$v" \
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

# --- a repo with NO hook can still be publishing a repackage, and a repackage is due no link -------
# Whether this repo owns an upstream-notes hook and whether this RELEASE is even due an upstream link
# are independent questions, and the second is answerable from the tags alone. Resolving the hook
# first conflated them: every hookless repo reported "new upstream" regardless of its tags, so
# the fleet preview found 1password's -mavericks.2, swift-toolchain's -mavericks.4 and
# container-tools' -mavericks.23 -- all of them the Nth repackage of an upstream already shipped N-1
# times -- classified as brand-new upstreams. That surfaced two ways, and both fixtures below are
# needed because each is invisible from the other's side:
#
#   without a declared reason -> a FALSE REFUSAL. A legitimate repackage cannot be published at all,
#   and the error demands a hook for an upstream link this release was never owed. (1password,
#   swift-toolchain)
#
#   with a declared reason -> WORSE: a green run whose body asserts "New upstream: X" over a release
#   that changed no upstream at all. A false claim in the GitHub Release and in the Sparkle dialog a
#   10.9 user reads, at exit 0. (container-tools)
#
# The existing nohook cases above cannot catch either: both publish -mavericks.1, where "no other tag
# of this upstream exists" makes new-upstream the correct answer and the ordering unobservable.
r="$work/nohook-repack"; mkrepo "$r"; rm "$r/build/upstream-release-notes-url.sh"
( cd "$r" && git add -A && git commit -qm nohook && git tag 9.9p2-mavericks.1 \
    && echo x >> README.md && git add -A && git commit -qm "ci: unrelated" && git tag 9.9p2-mavericks.2 )
gen "$r" 9.9p2-mavericks.2 >/dev/null \
  || { echo "FAIL nohook-repack: a repackage is due no upstream link, so a missing hook must not block it"; exit 1; }
grep -q 'Repackage of upstream OpenSSH 9.9p2' "$r/OUT.md" \
  || { echo "FAIL nohook-repack: kind"; cat "$r/OUT.md"; exit 1; }
grep -q 'New upstream' "$r/OUT.md" \
  && { echo "FAIL nohook-repack: claims a new upstream over an upstream already shipped"; cat "$r/OUT.md"; exit 1; }

# ...and the declared-reason variant must not turn that false claim into a GREEN one.
printf 'No upstream release notes: upstream publishes none.\n' > "$r/INGREDIENTS.md"
( cd "$r" && git add -A && git commit -qm declare )
gen "$r" 9.9p2-mavericks.2 >/dev/null || { echo "FAIL nohook-repack+declared: should pass"; exit 1; }
grep -q 'Repackage of upstream OpenSSH 9.9p2' "$r/OUT.md" \
  || { echo "FAIL nohook-repack+declared: kind"; cat "$r/OUT.md"; exit 1; }
grep -q 'New upstream' "$r/OUT.md" \
  && { echo "FAIL nohook-repack+declared: a declared reason must not license a false new-upstream claim"; cat "$r/OUT.md"; exit 1; }

# --- FATAL: a shallow clone hides the tags, so the kind cannot be decided --------------------------
# The assertion checks the MESSAGE, not just a nonzero exit: with the shallow guard removed, this
# fixture still exits 1 (via upstream-notes.sh's own shallow-clone bail, mapped to the catch-all die),
# so "some die fired" is not enough to prove the shallow guard itself is doing anything.
r="$work/shallow"; mkrepo "$r"
( cd "$r" && git tag 9.9p2-mavericks.1 )
sr="$work/shallow-clone"
git clone -q --depth 1 "file://$r" "$sr" 2>/dev/null || git clone -q --depth 1 "$r" "$sr"
if ( cd "$sr" && MAVERICKS_ROOT="$sr" sh "$S" --tag 9.9p2-mavericks.2 --version 9.9p2-mavericks.2 \
       --product OpenSSH --out "$sr/OUT.md" ) >/dev/null 2>&1; then
  echo "FAIL shallow: should be fatal (this is signal-desktop's silent-drop shape)"; exit 1
fi
shallow_out="$(cd "$sr" && MAVERICKS_ROOT="$sr" sh "$S" --tag 9.9p2-mavericks.2 --version 9.9p2-mavericks.2 \
       --product OpenSSH --out "$sr/OUT.md" 2>&1 || true)"
printf '%s\n' "$shallow_out" | grep -qi shallow \
  || { echo "FAIL shallow: cause not named as shallow: $shallow_out"; exit 1; }

# --- FATAL: tags exist upstream but this checkout was not given them (git clone --no-tags) ----------
# A non-shallow checkout can still hide tags -- the shallow guard above does not fire here at all --
# so a repackage (-mavericks.2) must not be silently read as a first release with no baseline.
r="$work/notags"; mkrepo "$r"
( cd "$r" && git tag 9.9p2-mavericks.1 )
nr="$work/notags-clone"
git clone -q --no-tags "$r" "$nr" 2>/dev/null
if ( cd "$nr" && MAVERICKS_ROOT="$nr" sh "$S" --tag 9.9p2-mavericks.2 --version 9.9p2-mavericks.2 \
       --product OpenSSH --out "$nr/OUT.md" ) >/dev/null 2>&1; then
  echo "FAIL notags: -mavericks.2 with no visible upstream tags should be fatal"; exit 1
fi
# ...but -mavericks.1 with no visible tags stays a legitimate first release (or a not-yet-tagged
# dispatch-cut build): the plan accepts that false negative rather than block every real first release.
if ! ( cd "$nr" && MAVERICKS_ROOT="$nr" GITHUB_SERVER_URL=https://github.com \
       GITHUB_REPOSITORY=ModernMavericks/mavericks-openssh sh "$S" \
       --tag 9.9p2-mavericks.1 --version 9.9p2-mavericks.1 \
       --product OpenSSH --out "$nr/OUT.md" ) >/dev/null 2>&1; then
  echo "FAIL notags: -mavericks.1 with no visible upstream tags should still succeed"; exit 1
fi

# --- parallel lines: --line scopes the baseline to its own line, not the numerically-highest tag ----
# golang ships parallel lines; 1.26.7's baseline must be 1.26.5 (same line), not 1.27.0 (a newer line
# that shipped in between). Both spellings of --line must work: the human-friendly "1.26" (the
# original bug: previous-release-tag.sh takes a GLOB, so the bare prefix matched nothing) and the
# already-a-glob "1.26.*".
r="$work/golang"; mkrepo "$r"
( cd "$r" && git tag 1.26.5-mavericks.1 && git tag 1.27.0-mavericks.1 )
for line in "1.26" "1.26.*"; do
  ( cd "$r" && GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=ModernMavericks/mavericks-golang \
      MAVERICKS_ROOT="$r" sh "$S" --tag 1.26.7-mavericks.1 --version 1.26.7-mavericks.1 \
      --product Go --line "$line" --out "$r/OUT.md" ) >/dev/null \
    || { echo "FAIL golang ($line): should succeed"; exit 1; }
  grep -q 'was 1.26.5' "$r/OUT.md" \
    || { echo "FAIL golang ($line): baseline should be 1.26.5"; cat "$r/OUT.md"; exit 1; }
  grep -q '1.27.0' "$r/OUT.md" \
    && { echo "FAIL golang ($line): must not pick the newer 1.27.0 line as baseline"; cat "$r/OUT.md"; exit 1; }
done

# --- FATAL: an ingredient repackage caller whose pins cannot be derived must not ship as packaging-only
# The original openssh bug: a real ingredient bump (components/libressl/version) reported as
# "packaging changes only" because the caller was under a name ingredient-pins.sh did not look for, or
# its own crash was swallowed. Reproduce both against this script directly, not just ingredient-pins.sh.
r="$work/badcaller"; mkrepo "$r"
mv "$r/.github/workflows/repackage-on-ingredient-bump.yml" "$r/.github/workflows/renovate-repackage.yml"
( cd "$r" && git add -A && git commit -qm "rename caller" && git tag 9.9p2-mavericks.1 )
printf '3.9.2\n' > "$r/components/libressl/version"
( cd "$r" && git commit -qam "bump libressl" && git tag 9.9p2-mavericks.2 )
gen "$r" 9.9p2-mavericks.2 >/dev/null \
  || { echo "FAIL badcaller: should succeed once the caller is discovered by content, not by name"; exit 1; }
grep -q 'rebuilt because build ingredients moved' "$r/OUT.md" \
  || { echo "FAIL badcaller: a moved pin under a differently-named caller must not read as packaging-only"; cat "$r/OUT.md"; exit 1; }

r="$work/nopins"; mkrepo "$r"
cat > "$r/.github/workflows/repackage-on-ingredient-bump.yml" <<'YML'
on:
  push:
    branches: [main]
jobs:
  repackage:
    uses: ModernMavericks/shipyard/.github/workflows/repackage-on-ingredient-bump.yml@v1
YML
( cd "$r" && git add -A && git commit -qm "caller with no paths" && git tag 9.9p2-mavericks.1 )
if gen "$r" 9.9p2-mavericks.1 >/dev/null 2>&1; then
  echo "FAIL nopins: a wired-up caller deriving zero pins should be fatal"; exit 1
fi

# --- a scaffolded/half-wired file at the CONVENTIONAL path must not be trusted by name alone --------
# The path .github/workflows/repackage-on-ingredient-bump.yml is a convention, not a guarantee: a repo
# that scaffolded it as a placeholder (or disabled it) has NOT actually wired itself to repackage on
# ingredient bumps, even though the file exists there. Preferring it by existence alone reintroduces a
# false FATAL on an otherwise legitimate release -- a repo with a real libressl bump that this
# half-wired file was never watching must still ship as "packaging changes only", exactly as it did
# before the caller-discovery work started.
r="$work/unwired"; mkrepo "$r"
cat > "$r/.github/workflows/repackage-on-ingredient-bump.yml" <<'YML'
# placeholder -- not yet wired up
on:
  workflow_dispatch: {}
YML
( cd "$r" && git add -A && git commit -qm "scaffold placeholder caller" && git tag 9.9p2-mavericks.1 )
printf '3.9.2\n' > "$r/components/libressl/version"
( cd "$r" && git commit -qam "bump libressl" && git tag 9.9p2-mavericks.2 )
gen "$r" 9.9p2-mavericks.2 >/dev/null \
  || { echo "FAIL unwired: a half-wired placeholder at the conventional path must not be fatal"; exit 1; }
grep -q 'packaging changes only' "$r/OUT.md" \
  || { echo "FAIL unwired: an unwired placeholder must not claim ingredients moved"; cat "$r/OUT.md"; exit 1; }

# --- a decoy workflow that only MENTIONS the caller must not outrank the real caller ----------------
# release.yml sorts before repackage-on-ingredient-bump.yml in glob order, and a comment naming the
# caller (a plausible thing to write, e.g. documenting a dispatch trigger) must not be mistaken for a
# call to it. If it is, the real caller sitting right next to it is never consulted: either a
# legitimate release goes FATAL (decoy paths name an untracked file -> zero pins) or, worse, it ships
# with the WRONG ingredient section (decoy paths name a tracked file -> that file's own history is
# reported instead of the real moved pin).
r="$work/decoytrap"; mkrepo "$r"
cat > "$r/.github/workflows/release.yml" <<'YML'
# Dispatched by repackage-on-ingredient-bump.yml with local_release=true.
on:
  push:
    tags:
      - '*-mavericks.*'
    paths:
      - CMakeLists.txt
jobs:
  release:
    uses: ./.github/workflows/publish-release.yml
YML
( cd "$r" && git add -A && git commit -qm "add release.yml" && git tag 9.9p2-mavericks.1 )
printf '3.9.2\n' > "$r/components/libressl/version"
printf 'cmake_minimum_required(VERSION 3.10)\n' > "$r/CMakeLists.txt"
( cd "$r" && git add -A && git commit -qm "bump libressl, add CMakeLists" && git tag 9.9p2-mavericks.2 )
gen "$r" 9.9p2-mavericks.2 >/dev/null \
  || { echo "FAIL decoytrap: should succeed (the real caller sits right next to the decoy)"; exit 1; }
grep -q '3.8.2 -> 3.9.2' "$r/OUT.md" \
  || { echo "FAIL decoytrap: real moved pin (libressl) not reported -- decoy caller won"; cat "$r/OUT.md"; exit 1; }
grep -q 'CMakeLists.txt' "$r/OUT.md" \
  && { echo "FAIL decoytrap: decoy caller's unrelated path leaked into the ingredient section"; cat "$r/OUT.md"; exit 1; }

# --- a genuinely-wired caller written as a YAML folded scalar is still a caller ---------------------
# `uses: >-` with the reusable workflow's URI on the CONTINUATION line is valid YAML and a real call,
# but the word `uses:` and the filename are then on different lines, so a `uses:.*<filename>` regex
# never matches. This repo IS wired up and its libressl pin really moved; reading it as "no caller"
# ships "packaging changes only" at exit 0 -- the exact original openssh bug, silently, for nothing
# but a formatting choice.
r="$work/foldedcaller"; mkrepo "$r"
cat > "$r/.github/workflows/repackage-on-ingredient-bump.yml" <<'YML'
on:
  push:
    branches: [main]
    paths:
      - components/libressl/version
jobs:
  repackage:
    uses: >-
      ModernMavericks/shipyard/.github/workflows/repackage-on-ingredient-bump.yml@v1
    with:
      own-upstream-paths: UPSTREAM_VERSION
YML
( cd "$r" && git add -A && git commit -qm "folded-scalar caller" && git tag 9.9p2-mavericks.1 )
printf '3.9.2\n' > "$r/components/libressl/version"
( cd "$r" && git commit -qam "bump libressl" && git tag 9.9p2-mavericks.2 )
gen "$r" 9.9p2-mavericks.2 >/dev/null \
  || { echo "FAIL foldedcaller: a folded-scalar 'uses:' is a real call and must not be fatal"; exit 1; }
grep -q '### Build ingredients' "$r/OUT.md" \
  || { echo "FAIL foldedcaller: wired caller's moved pin dropped, no ingredient section"; cat "$r/OUT.md"; exit 1; }
grep -q '3.8.2 -> 3.9.2' "$r/OUT.md" \
  || { echo "FAIL foldedcaller: a real libressl bump must not read as packaging-only"; cat "$r/OUT.md"; exit 1; }

# --- a comment mention must not win DISCOVERY either, not just the default-path race ----------------
# decoytrap above is guarded by two rules at once (the default-path preference AND the comment
# filter), so deleting either one alone leaves it passing -- it proves nothing about the comment
# filter by itself. Here there is no file at the conventional path at all, so only the comment filter
# stands between the earlier-sorting decoy and the real caller: without it aaa-release.yml wins
# discovery outright and the notes report ITS path instead of the libressl bump that actually moved.
r="$work/commentonly"; mkrepo "$r"
mv "$r/.github/workflows/repackage-on-ingredient-bump.yml" "$r/.github/workflows/renovate-repackage.yml"
cat > "$r/.github/workflows/aaa-release.yml" <<'YML'
# Dispatched by repackage-on-ingredient-bump.yml with local_release=true.
on:
  push:
    tags:
      - '*-mavericks.*'
    paths:
      - CMakeLists.txt
jobs:
  release:
    uses: ./.github/workflows/publish-release.yml
YML
( cd "$r" && git add -A && git commit -qm "rename caller, add commenting decoy" && git tag 9.9p2-mavericks.1 )
printf '3.9.2\n' > "$r/components/libressl/version"
printf 'cmake_minimum_required(VERSION 3.10)\n' > "$r/CMakeLists.txt"
( cd "$r" && git add -A && git commit -qm "bump libressl, add CMakeLists" && git tag 9.9p2-mavericks.2 )
gen "$r" 9.9p2-mavericks.2 >/dev/null \
  || { echo "FAIL commentonly: a comment mention is not a second caller, so discovery is unambiguous"; exit 1; }
grep -q '3.8.2 -> 3.9.2' "$r/OUT.md" \
  || { echo "FAIL commentonly: real moved pin not reported -- the commenting decoy won discovery"; cat "$r/OUT.md"; exit 1; }
grep -q 'CMakeLists.txt' "$r/OUT.md" \
  && { echo "FAIL commentonly: the decoy's unrelated path leaked into the ingredient section"; cat "$r/OUT.md"; exit 1; }

# --- FATAL: discovery that finds two candidates must not guess which one owns the pins --------------
# With no workflow at the conventional path, an earlier-sorting file naming the reusable workflow on a
# NON-comment line is indistinguishable from the real caller by content: it yields pins of its own, and
# a genuine caller written as a folded scalar is the weaker textual match. Picking the first in glob
# order shipped the decoy's own file as "the ingredient that moved" and dropped the real libressl bump
# -- confidently wrong notes. Which workflow defines the ingredient set is a gap, so it stops here.
r="$work/twocallers"; mkrepo "$r"
mv "$r/.github/workflows/repackage-on-ingredient-bump.yml" "$r/.github/workflows/renovate-repackage.yml"
cat > "$r/.github/workflows/aaa-release.yml" <<'YML'
on:
  push:
    paths:
      - CMakeLists.txt
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - run: echo "dispatched by repackage-on-ingredient-bump.yml"
YML
( cd "$r" && git add -A && git commit -qm "rename caller, add mentioning decoy" && git tag 9.9p2-mavericks.1 )
printf '3.9.2\n' > "$r/components/libressl/version"
printf 'cmake_minimum_required(VERSION 3.10)\n' > "$r/CMakeLists.txt"
( cd "$r" && git add -A && git commit -qm "bump libressl, add CMakeLists" && git tag 9.9p2-mavericks.2 )
if gen "$r" 9.9p2-mavericks.2 >/dev/null 2>&1; then
  echo "FAIL twocallers: two discovery candidates must not be resolved by glob order"; cat "$r/OUT.md"; exit 1
fi
out="$(gen "$r" 9.9p2-mavericks.2 2>&1 || true)"
printf '%s\n' "$out" | grep -q 'aaa-release.yml' \
  || { echo "FAIL twocallers: the die must name the candidates: $out"; exit 1; }
printf '%s\n' "$out" | grep -q 'renovate-repackage.yml' \
  || { echo "FAIL twocallers: the die must name the candidates: $out"; exit 1; }

# --- a release that is BOTH a new upstream AND an ingredient repackage: both sections must appear,
# with the upstream content FIRST. Neither existing case covers this: `new` above is a first release
# with no baseline (so no ingredient diff is even possible), and `ing` above is a same-upstream
# repackage that explicitly asserts NO upstream claim. A real release can be both at once (a new
# upstream tarball that also bumps a vendored ingredient in the same cut), and nothing else here
# exercises that combination or its ordering.
r="$work/combo"; mkrepo "$r"
( cd "$r" && git tag 9.9p1-mavericks.1 )                       # baseline: a DIFFERENT upstream (9.9p1)
printf '3.9.2\n' > "$r/components/libressl/version"            # an ingredient pin moves too
( cd "$r" && git commit -qam "bump libressl" && git tag 9.9p2-mavericks.1 )  # this cut ships new upstream 9.9p2
gen "$r" 9.9p2-mavericks.1 >/dev/null
grep -q 'New upstream: OpenSSH 9.9p2 (was 9.9p1)' "$r/OUT.md" \
  || { echo "FAIL combo: missing new-upstream bullet"; cat "$r/OUT.md"; exit 1; }
grep -q '### Build ingredients' "$r/OUT.md" \
  || { echo "FAIL combo: missing ingredient section"; cat "$r/OUT.md"; exit 1; }
grep -q '3.8.2 -> 3.9.2' "$r/OUT.md" || { echo "FAIL combo: pin delta missing"; cat "$r/OUT.md"; exit 1; }
u="$(grep -n 'New upstream:' "$r/OUT.md" | cut -d: -f1)"
i="$(grep -n '### Build ingredients' "$r/OUT.md" | cut -d: -f1)"
[ -n "$u" ] && [ -n "$i" ] && [ "$u" -lt "$i" ] \
  || { echo "FAIL combo: upstream content should precede ingredients"; cat "$r/OUT.md"; exit 1; }

# --- FATAL: previous-release-tag.sh itself failing must not read as "no baseline" -------------------
# The only remaining `|| true` on a fact-bearing call: a nonzero exit from previous-release-tag.sh
# (e.g. it cannot list tags) used to be swallowed into PREV="", which reads exactly like a genuine
# first release -- silently dropping the ingredient section and the compare link on a release that may
# have both. An EMPTY result must stay legitimate; only a NONZERO exit is fatal, so this stubs the
# script to fail outright rather than to print nothing.
r="$work/prevtagfails"; mkrepo "$r"
( cd "$r" && git tag 9.9p2-mavericks.1 )
scripts_stub="$work/scripts-stub"
cp -R "$here/../scripts" "$scripts_stub"
printf '#!/bin/sh\necho "previous-release-tag.sh: boom, cannot list tags" >&2\nexit 7\n' \
  > "$scripts_stub/previous-release-tag.sh"
chmod +x "$scripts_stub/previous-release-tag.sh"
if ( cd "$r" && MAVERICKS_ROOT="$r" sh "$scripts_stub/release-notes.sh" --tag 9.9p2-mavericks.1 \
       --version 9.9p2-mavericks.1 --product OpenSSH --out "$r/OUT.md" ) >/dev/null 2>&1; then
  echo "FAIL prevtagfails: a failing previous-release-tag.sh must be fatal, not read as no baseline"; exit 1
fi
prevtag_out="$(cd "$r" && MAVERICKS_ROOT="$r" sh "$scripts_stub/release-notes.sh" --tag 9.9p2-mavericks.1 \
       --version 9.9p2-mavericks.1 --product OpenSSH --out "$r/OUT.md" 2>&1 || true)"
printf '%s\n' "$prevtag_out" | grep -qi 'previous-release-tag' \
  || { echo "FAIL prevtagfails: cause not named: $prevtag_out"; exit 1; }

# --- FATAL: missing required arguments -------------------------------------------------------------
r="$work/args"; mkrepo "$r"; ( cd "$r" && git tag 9.9p2-mavericks.1 )
if ( cd "$r" && MAVERICKS_ROOT="$r" sh "$S" --tag 9.9p2-mavericks.1 --version 9.9p2-mavericks.1 \
       --out "$r/OUT.md" ) >/dev/null 2>&1; then echo "FAIL args: --product must be required"; exit 1; fi

# --- G3: the footer '---' must not be emitted with nothing after it --------------------------------
# A release with no --min-os floor and no compare link (e.g., swift-toolchain in a fixture with no remote).
# The old code printed the rule unconditionally and then conditionally appended the floor/link, so a body
# with neither ended in a dangling <hr> and nothing after it.
r="$work/nofooter"; mkdir -p "$r/release-notes"
( cd "$r" && git init -q -b main . && git config user.email t@example.com && git config user.name tester )
( cd "$r" && echo x > README.md && git add -A && git commit -qm base && git tag v1.0.0 )
( cd "$r" && MAVERICKS_ROOT="$r" sh "$S" --tag v1.0.0 --version 1.0.0 \
    --product Shipyard --out "$r/OUT.md" ) >/dev/null
grep -q -- '^---$' "$r/OUT.md" \
  && { echo "FAIL G3: a footer rule with nothing after it was emitted"; cat "$r/OUT.md"; exit 1; }
# the body must still end with real content, not a blank trailer left behind by the buffering
[ -n "$(tail -1 "$r/OUT.md")" ] \
  || { echo "FAIL G3: body ends with a blank line"; cat "$r/OUT.md"; exit 1; }
sh "$here/../scripts/check-release-notes.sh" "$r/OUT.md" 1.0.0 >/dev/null \
  || { echo "FAIL G3: no-footer body should still pass the family shape check"; exit 1; }

# ...but when a floor line applies, the rule must still be emitted, right above it
r="$work/withfooter"; mkrepo "$r"
( cd "$r" && git tag 9.9p2-mavericks.1 )
gen "$r" 9.9p2-mavericks.1 >/dev/null
grep -q -- '^---$' "$r/OUT.md" || { echo "FAIL G3: footer rule missing when a floor line applies"; cat "$r/OUT.md"; exit 1; }

echo "PASS: release-notes"
