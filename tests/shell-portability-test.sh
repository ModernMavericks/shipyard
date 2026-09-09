#!/bin/sh
# The 10.9-portability lint. Each rule must fire on a real violation, stay quiet on the legal form,
# and the whole thing must fail loudly if a pattern ever stops matching its own sample.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/check-shell-portability.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/shell-portability.XXXXXX")"; trap 'rm -rf "$work"' EXIT

mkrepo() {  # $1 = dir
  mkdir -p "$1"
  (cd "$1" && git init -q)
}

# a repo whose scripts are all legal passes
mkrepo "$work/ok"
printf '#!/bin/sh\nd="$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX")"\nt="$(mktemp -d -t pfx)"\n' > "$work/ok/a.sh"
(cd "$work/ok" && git add -A) >/dev/null 2>&1
(cd "$work/ok" && sh "$S" >/dev/null) || { echo "FAIL legal mktemp forms should pass"; exit 1; }

# sort -V is caught, and the message says what to use instead
mkrepo "$work/v"
printf '#!/bin/sh\ngit tag --list | sort -V | tail -1\n' > "$work/v/a.sh"  # portability-ok: a lint fixture must contain the violation it tests for
(cd "$work/v" && git add -A) >/dev/null 2>&1
if out="$(cd "$work/v" && sh "$S" 2>&1)"; then echo "FAIL sort -V should fail"; exit 1; fi  # portability-ok: names the construct under test
printf '%s\n' "$out" | grep -q 'a.sh:2' || { echo "FAIL should name file:line: $out"; exit 1; }
printf '%s\n' "$out" | grep -qi 'ver_cmp' || { echo "FAIL should say what to use instead: $out"; exit 1; }

# ...including its long-form spelling
mkrepo "$work/v2"
printf '#!/bin/sh\nprintf x | sort --version-sort\n' > "$work/v2/a.sh"  # portability-ok: a lint fixture must contain the violation it tests for
(cd "$work/v2" && git add -A) >/dev/null 2>&1
if (cd "$work/v2" && sh "$S" >/dev/null 2>&1); then echo "FAIL sort --version-sort should fail"; exit 1; fi  # portability-ok: names the construct under test

# a bare mktemp is caught in both spellings
mkrepo "$work/m"
printf '#!/bin/sh\nw="$(mktemp -d)"\nl="$(mktemp)"\n' > "$work/m/a.sh"  # portability-ok: a lint fixture must contain the violation it tests for
(cd "$work/m" && git add -A) >/dev/null 2>&1
if out="$(cd "$work/m" && sh "$S" 2>&1)"; then echo "FAIL bare mktemp should fail"; exit 1; fi
printf '%s\n' "$out" | grep -q 'a.sh:2' || { echo "FAIL should catch mktemp -d: $out"; exit 1; }
printf '%s\n' "$out" | grep -q 'a.sh:3' || { echo "FAIL should catch bare mktemp: $out"; exit 1; }

# prose ABOUT a ban is not a violation -- otherwise the docs cannot explain the rule
mkrepo "$work/c"
printf '#!/bin/sh\n# never use sort -V here; and not $(mktemp -d) either\necho ok\n' > "$work/c/a.sh"  # portability-ok: a lint fixture must contain the violation it tests for
(cd "$work/c" && git add -A) >/dev/null 2>&1
(cd "$work/c" && sh "$S" >/dev/null) || { echo "FAIL full-line comments should not trip the lint"; exit 1; }

# .bats files are shell too, and the first cut of this lint scanned only *.sh -- so it called
# ed25519 clean while tests/version.bats was dying on a bare mktemp in setup(). Assert the coverage.
mkrepo "$work/b"
printf '#!/bin/sh\necho ok\n' > "$work/b/a.sh"
printf 'setup() {\n  TMP="$(mktemp -d)"\n}\n' > "$work/b/tests.bats"  # portability-ok: a lint fixture must contain the violation
(cd "$work/b" && git add -A) >/dev/null 2>&1
if out="$(cd "$work/b" && sh "$S" 2>&1)"; then echo "FAIL a .bats violation should fail"; exit 1; fi
printf '%s\n' "$out" | grep -q 'tests.bats:2' || { echo "FAIL should name the .bats file:line: $out"; exit 1; }

# UNTRACKED files are out of scope: vendored/fetched upstream trees are not ours to rewrite
mkrepo "$work/u"
printf '#!/bin/sh\necho ok\n' > "$work/u/a.sh"
(cd "$work/u" && git add -A) >/dev/null 2>&1
printf '#!/bin/sh\nsort -V\n' > "$work/u/vendored.sh"  # portability-ok: a lint fixture must contain the violation it tests for
(cd "$work/u" && sh "$S" >/dev/null) || { echo "FAIL untracked files should be out of scope"; exit 1; }

# a rule that no longer matches its own sample is DEAD, and must say so rather than pass
sed 's/^sort\[\[:space:\]\]/sortXX[[:space:]]/' "$S" > "$work/dead.sh"
if out="$(cd "$work/ok" && sh "$work/dead.sh" 2>&1)"; then echo "FAIL a dead rule should fail"; exit 1; fi
printf '%s\n' "$out" | grep -qi 'lint is dead' || { echo "FAIL should say the lint is dead: $out"; exit 1; }

# and the real repo must itself be clean
(cd "$here/.." && sh "$S" >/dev/null) || { echo "FAIL shipyard's own scripts must be clean"; exit 1; }

echo "PASS: shell-portability"
