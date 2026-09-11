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
real="$(command -v cmake 2>/dev/null)" || { echo "SKIP: no cmake"; exit 77; }
w="$(mktemp -d "${TMPDIR:-/tmp}/refusal-test.XXXXXX")"; trap 'rm -rf "$w"' EXIT
croot="$(printf 'message("${CMAKE_ROOT}")\n' > "$w/r.cmake"; "$real" -P "$w/r.cmake" 2>&1)"
fx="$w/fx"; mkdir -p "$fx/bin" "$fx/share"
cp "$real" "$fx/bin/cmake"
# COPY, don't symlink: Homebrew's CMAKE_ROOT is <prefix>/share/cmake -- the SAME path shipyard is
# about to be installed into below (--prefix "$fx" -> $fx/share/cmake/MavericksShipyard). A symlink
# there would alias the fixture's install location straight at the host's real cmake share dir, and
# the install a few lines down would land INSIDE the host's actual cmake installation instead of the
# fixture. Copying gives the fixture a real tree of its own that the install can safely merge into.
cp -R "$croot" "$fx/share/$(basename "$croot")"
# HOME is scratch: until Task 5 removes it, CMakeLists.txt's install(CODE) writes the user package
# registry under $HOME -- a test must never repoint the real one. Each install gets its OWN scratch
# HOME (home-fx / home-dev) so their registry entries never collide in one directory; configures run
# under a THIRD, never-written-to scratch HOME (home-run) -- this box has a real shipyard pkg
# installed outside the fixture, registered in the REAL user package registry, and CMake's
# find_package search consults the user registry before it searches a cmake's own install prefix, so
# an ambient (or colliding) registry entry would silently outrank the fixture/dev copy under test.
"$real" -S "$root" -B "$w/sb" >/dev/null && HOME="$w/home-fx" "$real" --install "$w/sb" --prefix "$fx" >/dev/null
HOME="$w/home-dev" "$real" --install "$w/sb" --prefix "$w/dev" >/dev/null      # a second copy: the "dev" one

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
