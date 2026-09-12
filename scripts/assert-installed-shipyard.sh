#!/bin/sh
# Is an INSTALLED mavericks-shipyard the thing we meant to ship?
#
# These four assertions used to live inline in release.yml's install smoke -- the one step that runs
# ONLY on a push to main. That made them unrunnable until the very push that must not be a rehearsal
# (spec 2026-09-11, R-P1-17). They live here instead so two callers can share them:
#
#   - release.yml installs the pkg it is about to publish and runs this against "/"
#   - ci.yml, on every branch push, builds the same pkg, installs it, and runs the SAME script
#
# and so tests/assert-installed-shipyard-test.sh can run them against a FIXTURE root: a prefix shaped
# exactly like the pkg's (bin/cmake + its CMAKE_ROOT + share/cmake/MavericksShipyard, with a relative
# ../mavericks-shipyard/bin/cmake symlink in usr/local/bin), built from whatever cmake the box has.
#
# What it asserts, and why each is worth a step of its own:
#   1. shipyard-cmake runs, and is the CMake in cmake.pin. A pkg built from a stale cache is a pkg
#      that says one version and ships another. And it is OURS: universal, with shipyard-ctest and
#      shipyard-cpack beside it. A version match alone would accept a same-versioned Homebrew cmake.
#   2. Under a STRIPPED environment (env -i: no PATH, no CMAKE_PREFIX_PATH, no registry), a probe
#      resolves shipyard inside shipyard-cmake's OWN prefix. That is the whole mechanism the design
#      rests on since the user package registry was removed -- if it ever stops working, every
#      consumer's find_package(MavericksShipyard) fails at once.
#   3. The updater is universal. It is merged from two single-arch builds; a merge that silently kept
#      one slice leaves half the family unable to update.
#   4. A cmake that is NOT shipyard's is refused, and the refusal names shipyard-cmake. The guardrail
#      is only useful if it fires and says what to run instead.
#
#   usage: assert-installed-shipyard.sh --cmake-version V [--root DIR]
#          --root defaults to "/" (a real install); a fixture root makes this unit-testable.
set -eu

ROOT="/"; WANT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2;;
    --cmake-version) WANT="$2"; shift 2;;
    *) echo "assert-installed-shipyard: unknown option $1" >&2; exit 2;;
  esac
done
# Exit 2 (a usage error), like the unknown-option case above: a caller that forgot the pin must not be
# told "the installed shipyard is wrong", and run-repo-tests.sh reserves 77 for SKIP, never 1, for this.
[ -n "$WANT" ] || { echo "assert-installed-shipyard: --cmake-version required" >&2; exit 2; }
[ -d "$ROOT" ] || { echo "assert-installed-shipyard: no such root: $ROOT" >&2; exit 2; }

# "/" -> "", so "$R/usr/local/..." is one absolute path whether the root is the volume or a fixture.
R="${ROOT%/}"
CM="$R/usr/local/bin/shipyard-cmake"
PREFIX="$R/usr/local/mavericks-shipyard"
CFGDIR="$PREFIX/share/cmake/MavericksShipyard"
EXE="$R/Library/Application Support/ModernMavericks/MavericksShipyardUpdater.app/Contents/MacOS/MavericksShipyardUpdater"

bad=0
fail() { echo "::error::installed shipyard: $*" >&2; bad=1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/shipyard-assert.XXXXXX")"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/probe"
printf '%s\n' \
  'cmake_minimum_required(VERSION 3.16)' \
  'project(probe NONE)' \
  'find_package(MavericksShipyard REQUIRED)' \
  'message(STATUS "DIR=${MavericksShipyard_DIR}")' \
  > "$W/probe/CMakeLists.txt"

# 1. shipyard-cmake is the pinned CMake.
if [ -x "$CM" ]; then
  if ! "$CM" --version > "$W/version.txt" 2>&1; then
    fail "shipyard-cmake ($CM) does not run: $(cat "$W/version.txt")"
  elif ! grep -q "cmake version $WANT" "$W/version.txt"; then
    fail "shipyard-cmake is not CMake $WANT: $(head -1 "$W/version.txt")"
  fi
else
  fail "no executable shipyard-cmake at $CM"
fi

# 1b. The shipped CMake is OURS. Everything in 1 and 2 would pass on a same-versioned Homebrew cmake
#     copied into the prefix -- which is exactly what the fixture test builds -- so it proves nothing
#     about what the pkg actually carries. What is ours about it: it is universal (we merge two
#     single-arch builds with lipo; nobody else's is), and it comes with the other two commands, which
#     both workflows and every consumer invoke by name.
for c in shipyard-cmake shipyard-ctest shipyard-cpack; do
  [ -x "$R/usr/local/bin/$c" ] \
    || fail "no executable $R/usr/local/bin/$c -- the pkg puts all three on the default PATH"
done
if [ -x "$CM" ]; then
  cmarchs="$(lipo -info "$CM" 2>&1 || true)"
  case "$cmarchs" in
    *x86_64*) ;;
    *) fail "shipyard-cmake has no x86_64 slice, so it cannot run on 10.9: $cmarchs" ;;
  esac
  case "$cmarchs" in
    *arm64*) ;;
    *) fail "shipyard-cmake has no arm64 slice, so it cannot run on Apple Silicon: $cmarchs" ;;
  esac
fi

# 2. It finds shipyard in its own prefix with nothing else to go on. env -i keeps a leaked
#    CMAKE_PREFIX_PATH (or an inherited PATH that puts another prefix first) from making this pass for
#    the wrong reason; HOME is carried through only because cmake wants somewhere to write cache files.
if [ -x "$CM" ]; then
  env -i HOME="${HOME:-$W}" PATH=/usr/bin:/bin \
    "$CM" -S "$W/probe" -B "$W/own" > "$W/own.log" 2>&1 || true
  grep -q "DIR=$CFGDIR" "$W/own.log" \
    || fail "shipyard-cmake did not find shipyard at $CFGDIR under a stripped environment: $(cat "$W/own.log")"
fi

# 3. The updater is universal. `lipo -info`, never `lipo -archs`: 10.9's lipo has no -archs, and the
#    portability gate bans the idiom outright.
if [ -f "$EXE" ]; then
  archs="$(lipo -info "$EXE" 2>&1 || true)"
  case "$archs" in
    *x86_64*) ;;
    *) fail "the installed updater has no x86_64 slice: $archs" ;;
  esac
  case "$archs" in
    *arm64*) ;;
    *) fail "the installed updater has no arm64 slice: $archs" ;;
  esac
else
  fail "no installed updater executable at $EXE"
fi

# 4. Any other cmake is refused, naming shipyard-cmake. A box with no second cmake cannot show this;
#    say so rather than report a check that did not run as a pass.
other="$(command -v cmake 2>/dev/null || true)"
case "$other" in
  "$PREFIX"/*) other="" ;;   # shipyard's own, reached under another name: not a foreign cmake
esac
if [ -n "$other" ]; then
  if "$other" -S "$W/probe" -B "$W/other" -DMavericksShipyard_DIR="$CFGDIR" > "$W/other.log" 2>&1; then
    fail "$other configured against shipyard; every cmake but shipyard's must be refused"
  fi
  grep -q 'shipyard-cmake' "$W/other.log" \
    || fail "the refusal does not name shipyard-cmake, so it does not say what to run instead: $(cat "$W/other.log")"
  refusal="other cmakes refused"
else
  echo "::warning::installed shipyard: no other cmake on PATH to check the refusal against" >&2
  refusal="no other cmake here to check the refusal against"
fi

[ "$bad" -eq 0 ] || exit 1
echo "installed shipyard: shipyard-cmake $WANT finds shipyard in $CFGDIR; updater universal; $refusal"
