#!/bin/sh
# Run this repo's tests the same way every repo does, so a newly added test file runs the day it
# lands instead of waiting for someone to remember a CI line. (macports-legacy-support had 9 test
# files that CI never ran; two had silently rotted.)
#
# Respects the drivers already in use rather than replacing them:
#   - a ctest preset + tests defined in CMakeLists.txt  -> ctest (container-tools, tailscale)
#   - otherwise                                          -> every top-level tests/*.sh and tests/*.bats
# Subdirectories are fixtures and sub-suites with their own entry points, not tests to run here.
#
# EXIT 77 = SKIP, the idiom container-tools already uses (SKIP_RETURN_CODE 77): a test needing
# artifacts that do not exist yet (a built toolchain, a real 10.9 host) skips instead of failing.
#   usage: run-repo-tests.sh [ctest-preset]
set -eu
preset="${1:-}"

# Every real macOS session (every GitHub runner, and every 10.9 box with a login shell) sets TMPDIR
# with a trailing slash. A box that runs with TMPDIR unset falls back to a clean /tmp and never
# exercises the doubled-slash path a test's own `mktemp -d "$TMPDIR/x.XXXXXX"` produces everywhere
# else -- which is exactly how two suites shipped broken and only failed in CI (see the fix for
# msc-template-test.sh and assert-installed-shipyard-test.sh). Force the shape here so this box can
# catch that class of defect too.
: "${TMPDIR:=/tmp/}"
export TMPDIR

if [ -n "$preset" ] && [ -f CMakeLists.txt ] && grep -q 'add_test' CMakeLists.txt; then
  # shipyard-ctest, not ctest: the tree under test was configured by shipyard-cmake (the config
  # refuses any other), so its CTestTestfiles name that cmake's own generator.
  #
  # Guarded, because "wherever the runner runs" is not everywhere. install@v1 installs the pkg only on
  # a macOS runner; on Linux there IS no pkg, so shipyard-ctest is simply absent -- and a bare `exec`
  # would end the run with "shipyard-ctest: not found" and no hint that the missing thing is an
  # install step rather than a broken test. Say which it is.
  command -v shipyard-ctest >/dev/null 2>&1 || {
    echo "run-repo-tests: shipyard-ctest not found, and a ctest preset ($preset) was asked for" >&2
    echo "    the shipyard pkg provides shipyard-cmake/ctest/cpack in /usr/local/bin;" >&2
    echo "    install@v1 installs it on a macOS runner, and there is no pkg for Linux --" >&2
    echo "    a Linux job cannot run a shipyard-configured ctest preset" >&2
    exit 1
  }
  echo "run-repo-tests: shipyard-ctest --preset $preset"
  exec shipyard-ctest --preset "$preset" --output-on-failure
fi

[ -d tests ] || { echo "run-repo-tests: no tests/ directory — nothing to run"; exit 0; }

status=0
ran=0
for t in tests/*.sh tests/*.bats; do
  [ -f "$t" ] || continue
  ran=$((ran + 1))
  # `rc=0; cmd || rc=$?` and not `cmd; rc=$?`: under set -e the bare form exits the runner on the
  # first failing OR SKIPPING test, so nothing after it is ever reported.
  rc=0
  log="$(mktemp "${TMPDIR:-/tmp}/run-repo-tests.XXXXXX")"
  case "$t" in
    *.bats)
      # Missing bats is a FAILURE, not a skip: install@v1 puts it on every runner, so its absence
      # means the environment is broken. Skipping would leave these assertions running nowhere --
      # the exact hole this runner exists to close.
      command -v bats >/dev/null 2>&1 || {
        echo "FAIL $t (bats not installed -- install@v1 provides it in CI; 'brew install bats-core' locally)"
        status=1; rm -f "$log"; continue
      }
      bats "$t" > "$log" 2>&1 || rc=$? ;;
    *) sh "$t" > "$log" 2>&1 || rc=$? ;;
  esac
  case "$rc" in
    0)  echo "PASS $t" ;;
    77) echo "SKIP $t (unmet prerequisites)" ;;
    # Show what a failing test SAID. "FAIL tests/x.sh (exit 1)" with the output discarded leaves
    # whoever reads CI unable to tell a broken test from a broken product; a passing test stays quiet
    # so the signal does not drown.
    *)  echo "FAIL $t (exit $rc)"; sed 's/^/    | /' "$log"; status=1 ;;
  esac
  rm -f "$log"
done
[ "$ran" -gt 0 ] || echo "run-repo-tests: tests/ has no *.sh or *.bats at top level"
exit "$status"
