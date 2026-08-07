#!/bin/sh
# include(Mavericks) is universally includable: it works for the common language sets
# with NO MAVERICKS_REQUIRE_LANGS (the gate auto-scopes to the enabled languages), is a
# no-op gate for LANGUAGES NONE, and does not touch a project's CMAKE_OSX_* (multi-arch
# safe). Needs Apple's clang at /usr/bin/clang (present on 10.9 and modern macOS).
set -eu
# ctest passes the source dir (see add_test). Called bare -- as the shared test runner does when it
# globs tests/*.sh -- there is nothing to include: 77 = SKIP, not a failure.
[ "$#" -ge 1 ] || { echo "no source dir given (ctest supplies it) -- skipping" >&2; exit 77; }
SRC="${1:?usage: umbrella-langs.sh <mavericks-shipyard source dir>}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
CC=/usr/bin/clang
[ -x "$CC" ] || { echo "SKIP: no Apple clang at $CC"; exit 0; }

cfg() { # $1=langs  $2...=extra -D
  langs=$1; shift
  d="$T/p"; rm -rf "$d"; mkdir -p "$d"
  cat > "$d/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.16)
project(u LANGUAGES $langs)
list(APPEND CMAKE_MODULE_PATH "$SRC")
include(Mavericks)
EOF
  cmake -S "$d" -B "$d/b" -DCMAKE_C_COMPILER=$CC -DCMAKE_OBJC_COMPILER=$CC -DCMAKE_CXX_COMPILER=${CC}++ "$@" >/dev/null 2>&1 \
    || { echo "FAIL: include(Mavericks) failed for LANGUAGES $langs"; exit 1; }
}

cfg NONE
cfg C
cfg OBJC
cfg "C OBJC"

# multi-arch safety: a project passing arm64/12.0 keeps them (umbrella must not force 10.9/x86_64)
d="$T/marr"; rm -rf "$d"; mkdir -p "$d"
cat > "$d/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.16)
project(u LANGUAGES C)
list(APPEND CMAKE_MODULE_PATH "$SRC")
include(Mavericks)
if(NOT CMAKE_OSX_ARCHITECTURES STREQUAL "arm64" OR NOT CMAKE_OSX_DEPLOYMENT_TARGET STREQUAL "12.0")
  message(FATAL_ERROR "umbrella changed arch/target to [\${CMAKE_OSX_ARCHITECTURES}]/[\${CMAKE_OSX_DEPLOYMENT_TARGET}]")
endif()
EOF
cmake -S "$d" -B "$d/b" -DCMAKE_C_COMPILER=$CC -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 >/dev/null 2>&1 \
  || { echo "FAIL: umbrella not multi-arch safe (clobbered arm64/12.0)"; exit 1; }

echo "umbrella-langs OK"
