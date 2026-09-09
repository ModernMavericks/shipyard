#!/bin/sh
# run-repo-tests.sh: run a repo's tests the same way everywhere, so a newly added test file runs the
# day it lands. Exit 77 = SKIP (the idiom container-tools already uses for its boot-proof).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/run-repo-tests.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/run-repo-tests-test.XXXXXX")"; trap 'rm -rf "$work"' EXIT
cd "$work"; mkdir -p tests

# no tests dir at all -> succeed, say so
mkdir -p empty && (cd empty && sh "$S" >/dev/null) || { echo "FAIL no-tests-dir should pass"; exit 1; }

printf '#!/bin/sh\necho ok\n'        > tests/a-test.sh
printf '#!/bin/sh\nexit 77\n'        > tests/b-skips.sh
out="$(sh "$S")" || { echo "FAIL all-passing should exit 0: $out"; exit 1; }
printf '%s\n' "$out" | grep -q 'PASS.*a-test.sh' || { echo "FAIL pass line: $out"; exit 1; }
printf '%s\n' "$out" | grep -q 'SKIP.*b-skips.sh' || { echo "FAIL skip line: $out"; exit 1; }

# a genuine failure fails the runner, and is not reported as a skip
printf '#!/bin/sh\nexit 1\n' > tests/c-fails.sh
if out="$(sh "$S" 2>&1)"; then echo "FAIL failing test should fail the runner: $out"; exit 1; fi
printf '%s\n' "$out" | grep -q 'FAIL.*c-fails.sh' || { echo "FAIL fail line: $out"; exit 1; }
printf '%s\n' "$out" | grep -q 'SKIP.*c-fails.sh' && { echo "FAIL failure reported as skip"; exit 1; }
rm tests/c-fails.sh

# subdirectories are fixtures/sub-suites with their own entry points, not tests to run
mkdir -p tests/fixtures
printf '#!/bin/sh\nexit 1\n' > tests/fixtures/nested.sh
sh "$S" >/dev/null || { echo "FAIL nested script must not be run"; exit 1; }

# A .bats file with no bats is a FAILURE, not a skip: install@v1 provides bats on every runner, so its
# absence means the environment is broken -- and a skipped assertion is one nobody is checking, which
# is the whole hole this runner exists to close.
printf '#!/usr/bin/env bats\n@test "trivial" { true; }\n' > tests/d.bats
if out="$(PATH=/usr/bin:/bin sh "$S" 2>&1)"; then echo "FAIL missing bats should fail the runner: $out"; exit 1; fi
printf '%s\n' "$out" | grep -q 'FAIL tests/d.bats' || { echo "FAIL should report the bats file as FAIL: $out"; exit 1; }
printf '%s\n' "$out" | grep -qi 'bats' || { echo "FAIL should say bats is missing: $out"; exit 1; }
# with bats present it runs normally
sh "$S" >/dev/null || { echo "FAIL bats file should pass when bats is installed"; exit 1; }

# A failing test must SAY something. Reporting "FAIL tests/x.sh (exit 1)" and discarding the output
# leaves whoever reads CI with no way to tell a broken test from a broken product -- which is exactly
# the position ed25519 put us in.
printf '#!/bin/sh\necho "the specific reason it broke"\nexit 1\n' > tests/e-loud.sh
out="$(sh "$S" 2>&1 || true)"
printf '%s\n' "$out" | grep -q 'the specific reason it broke' \
  || { echo "FAIL a failing test's output must be shown; got: $out"; exit 1; }
rm -f tests/e-loud.sh

# ...and a PASSING test stays quiet, or the signal drowns
printf '#!/bin/sh\necho "chatty but fine"\nexit 0\n' > tests/f-chatty.sh
out="$(sh "$S" 2>&1 || true)"
printf '%s\n' "$out" | grep -q 'chatty but fine' \
  && { echo "FAIL a passing test should not print its output"; exit 1; }
rm -f tests/f-chatty.sh

echo "PASS: run-repo-tests"
