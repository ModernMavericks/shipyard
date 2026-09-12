#!/bin/sh
# Only shipyard's own cmake may configure against shipyard (spec 2026-09-11 decision 2). "Its own" =
# the running cmake lives in a prefix that also holds a shipyard. Any other cmake -- even one pointed
# straight at shipyard -- must fail at configure, naming shipyard-cmake. A dev override
# (CMAKE_PREFIX_PATH) through a real shipyard-cmake must still work and load the dev copy.
#
# The fixture is a prefix built from THIS box's cmake: the binary copied into <fx>/bin (a cmake finds
# its CMAKE_ROOT relative to its REAL path, so a symlink would report the original prefix) and its
# share/cmake-X.Y (or, on Homebrew, share/cmake) COPIED beside it, plus shipyard installed into the
# same prefix.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/.." && pwd)"
. "$here/lib/cmake_fixture.sh"
real="$(command -v cmake 2>/dev/null)" || { echo "SKIP: no cmake"; exit 77; }
w="$(mktemp -d "${TMPDIR:-/tmp}/refusal-test.XXXXXX")"; trap 'rm -rf "$w"' EXIT
croot="$(printf 'message("${CMAKE_ROOT}")\n' > "$w/r.cmake"; "$real" -P "$w/r.cmake" 2>&1)"
fx="$w/fx"; mkdir -p "$fx/bin" "$fx/share"
cp "$real" "$fx/bin/cmake"
# A real, writable tree of the fixture's own -- never the host's, and never a symlink to it. The two
# ways that goes wrong, and why the helper exists rather than three copies of these lines, are written
# out in tests/lib/cmake_fixture.sh; tests/cmake-fixture-test.sh proves it on this box.
copy_cmake_root "$croot" "$fx/share/$(basename "$croot")"
# HOME is scratch: until Task 5 removes it, CMakeLists.txt's install(CODE) writes the user package
# registry under $HOME -- a test must never repoint the real one. Each install gets its OWN scratch
# HOME (home-fx / home-dev) so their registry entries never collide in one directory; configures run
# under a THIRD, never-written-to scratch HOME (home-run) -- this box has a real shipyard pkg
# installed outside the fixture, registered in the REAL user package registry, and CMake's
# find_package search consults the user registry before it searches a cmake's own install prefix, so
# an ambient (or colliding) registry entry would silently outrank the fixture/dev copy under test.
# Keep the output: redirected to /dev/null, a failure here kills the script under `set -e` with
# nothing said, and CI reports a bare "FAIL tests/... (exit 1)" with no way to tell what broke.
"$real" -S "$root" -B "$w/sb" > "$w/configure.log" 2>&1 \
  || { echo "FAIL: could not configure shipyard for the fixture:"; sed 's/^/    | /' "$w/configure.log"; exit 1; }
HOME="$w/home-fx" "$real" --install "$w/sb" --prefix "$fx" > "$w/install-fx.log" 2>&1 \
  || { echo "FAIL: could not install shipyard into the fixture prefix:"; sed 's/^/    | /' "$w/install-fx.log"; exit 1; }
HOME="$w/home-dev" "$real" --install "$w/sb" --prefix "$w/dev" > "$w/install-dev.log" 2>&1 \
  || { echo "FAIL: could not install the second (dev) copy:"; sed 's/^/    | /' "$w/install-dev.log"; exit 1; }

mkdir -p "$w/c"
printf 'cmake_minimum_required(VERSION 3.16)\nproject(c NONE)\nfind_package(MavericksShipyard REQUIRED)\nmessage(STATUS "DIR=${MavericksShipyard_DIR}")\n' > "$w/c/CMakeLists.txt"

# 1. The fixture's own cmake finds its own shipyard.
out="$(HOME="$w/home-run" "$fx/bin/cmake" -S "$w/c" -B "$w/b1" 2>&1)" || { echo "FAIL: a shipyard-cmake must configure; got:"; echo "$out"; exit 1; }
printf '%s' "$out" | grep -q "DIR=$fx/share/cmake/MavericksShipyard" || { echo "FAIL: expected the fixture's shipyard; got:"; echo "$out"; exit 1; }

# 2. A foreign cmake pointed straight at shipyard is refused, naming shipyard-cmake.
if out="$(HOME="$w/home-run" "$real" -S "$w/c" -B "$w/b2" -DMavericksShipyard_DIR="$fx/share/cmake/MavericksShipyard" 2>&1)"; then
  echo "FAIL: a foreign cmake must be refused"; exit 1
fi
printf '%s' "$out" | grep -q 'shipyard-cmake' || { echo "FAIL: the refusal must name shipyard-cmake; got:"; echo "$out"; exit 1; }

# 3. A dev override through a real shipyard-cmake loads the dev copy.
out="$(HOME="$w/home-run" CMAKE_PREFIX_PATH="$w/dev" "$fx/bin/cmake" -S "$w/c" -B "$w/b3" 2>&1)" || { echo "FAIL: dev override must configure; got:"; echo "$out"; exit 1; }
printf '%s' "$out" | grep -q "DIR=$w/dev/share/cmake/MavericksShipyard" || { echo "FAIL: dev override must load the dev copy; got:"; echo "$out"; exit 1; }

echo "PASS: shipyard-cmake-refusal"
