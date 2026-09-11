#!/bin/sh
# Build the CMake shipyard ships as shipyard-cmake: ONE arch and deployment floor per run, into a
# prefix. Universal comes from running this twice (x86_64/10.9, arm64/11.0) and lipo-merge-tree.sh.
#
# From Kitware's SOURCE tarball, verified against the release's own cmake-<v>-SHA-256.txt, and built
# with CMake's own ./bootstrap -- so no cmake is needed to build cmake. The arch and floor go ONLY to
# the real build (the options after `--`), never into CFLAGS: bootstrap first compiles a stage-0 cmake
# that must RUN on this host, and a runner without Rosetta cannot run an x86_64 stage-0.
#
# The compiler is the environment's CC/CXX, which bootstrap honours. The x86_64/10.9 half MUST be built
# with the family's mavericks-clang-22 (CC/CXX=<its prefix>/bin/clang{,++}): CMake 4.x needs C++17, the
# 10.9 box's Xcode 6 cannot provide it, and mavericks-clang links its own libc++ statically, so the
# result needs nothing outside the OS. The arm64/11.0 half uses Apple's clang (the default).
#
#   usage: build-cmake.sh --arch x86_64|arm64 --min-os VER --prefix DIR [--jobs N] [--sysroot DIR]
#          build-cmake.sh --fetch-only --dest DIR          (download + verify only; prints the path)
#   env:   SHIPYARD_CMAKE_URL_BASE  (default https://github.com/Kitware/CMake/releases/download)
#   --sysroot DIR defaults to `xcrun --show-sdk-path` -- passed through as CMAKE_OSX_SYSROOT.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
ARCH=""; MINOS=""; PREFIX=""; JOBS=""; FETCH_ONLY=""; DEST=""; SYSROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2;;
    --min-os) MINOS="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --jobs) JOBS="$2"; shift 2;;
    --sysroot) SYSROOT="$2"; shift 2;;
    --fetch-only) FETCH_ONLY=1; shift;;
    --dest) DEST="$2"; shift 2;;
    *) echo "build-cmake: unknown option $1" >&2; exit 2;;
  esac
done

V="$(sed -n 's/^CMAKE_VERSION=//p' "$SELF/../cmake.pin")"
[ -n "$V" ] || { echo "build-cmake: no CMAKE_VERSION in $SELF/../cmake.pin" >&2; exit 1; }
BASE="${SHIPYARD_CMAKE_URL_BASE:-https://github.com/Kitware/CMake/releases/download}"
TARBALL="cmake-$V.tar.gz"

fetch_verified() {  # $1 = dir to download into; prints the tarball path
  mkdir -p "$1"
  curl -fsSL -o "$1/$TARBALL" "$BASE/v$V/$TARBALL" \
    || { echo "build-cmake: could not download $BASE/v$V/$TARBALL" >&2; return 1; }
  curl -fsSL -o "$1/cmake-$V-SHA-256.txt" "$BASE/v$V/cmake-$V-SHA-256.txt" \
    || { echo "build-cmake: could not download Kitware's checksum file for $V" >&2; return 1; }
  want="$(awk -v f="$TARBALL" '$2 == f { print $1 }' "$1/cmake-$V-SHA-256.txt")"
  [ -n "$want" ] || { echo "build-cmake: checksum file for $V does not list $TARBALL; refusing" >&2; return 1; }
  got="$(shasum -a 256 "$1/$TARBALL" | awk '{ print $1 }')"
  [ "$got" = "$want" ] \
    || { echo "build-cmake: checksum mismatch for $TARBALL (got $got, Kitware published $want); refusing" >&2; return 1; }
  printf '%s\n' "$1/$TARBALL"
}

if [ -n "$FETCH_ONLY" ]; then
  : "${DEST:?build-cmake: --fetch-only needs --dest}"
  fetch_verified "$DEST"; exit 0
fi

[ -n "$ARCH" ] && [ -n "$MINOS" ] && [ -n "$PREFIX" ] \
  || { echo "build-cmake: need --arch, --min-os and --prefix" >&2; exit 2; }
[ -n "$JOBS" ] || JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
[ -n "$SYSROOT" ] || SYSROOT="$(xcrun --show-sdk-path)"
[ -d "$SYSROOT" ] || { echo "build-cmake: --sysroot $SYSROOT is not a directory" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/build-cmake.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
tb="$(fetch_verified "$WORK")"
tar -xzf "$tb" -C "$WORK"
cd "$WORK/cmake-$V"
# Patches are part of the recipe: CI's cache key must cover patches/cmake/* too, or a patch change
# won't invalidate a cached build.
for p in "$SELF"/../patches/cmake/*.patch; do
  [ -f "$p" ] || continue
  patch -p1 < "$p" || { echo "build-cmake: $p does not apply to CMake $V" >&2; exit 1; }
done
# --no-system-libs: every third-party library CMake needs -- curl included -- is its own bundled
# copy, built and linked statically. Without this, CMake's own configure will happily find and link
# whatever curl/zlib/etc. the build host has installed (pkgsrc, Homebrew, MacPorts) -- which is
# exactly what it must never do, since a shipyard-cmake binary is built on ONE box and run on
# others that don't have that package manager or that library at that path.
#
# Consequence: shipyard-cmake ships WITHOUT HTTPS in CMake's own downloader (spec 2026-09-11
# decision 3). Bundled curl 8.20 has no macOS TLS backend without OpenSSL, which we cannot ship; the
# OS's own curl (10.9's SDK: 7.30) is too old for CMake 4.4's cmCurl.cxx (needs 7.34+, for
# CURL_SSLVERSION_TLSv1_0/1/2). Neither is usable, so file(DOWNLOAD https://...) fails loudly
# (CURLE_UNSUPPORTED_PROTOCOL) instead of silently doing something fragile. The family fetches with
# mavericks_fetch.sh / clone_pinned.sh, never CMake's own downloader.
#
# CMAKE_IGNORE_PREFIX_PATH stays as defence in depth: even under --no-system-libs, nothing should be
# able to find a package manager's copy of anything CMake bundles.
#
# BUILD_CursesDialog=OFF: ccmake is not shipped (only cmake/ctest/cpack) and needs curses.
./bootstrap --prefix="$PREFIX" --parallel="$JOBS" --no-system-libs -- \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINOS" \
  -DCMAKE_OSX_SYSROOT="$SYSROOT" \
  -DCMAKE_USE_OPENSSL=OFF \
  -DBUILD_CursesDialog=OFF \
  "-DCMAKE_IGNORE_PREFIX_PATH=/opt/pkg;/opt/local;/opt/homebrew;/usr/local;/sw" \
  -DBUILD_TESTING=OFF
make -j"$JOBS"
make install

# Self-check: every Mach-O we just installed may link only the OS's own dylibs. A build-host
# package manager (pkgsrc, Homebrew, MacPorts) leaking into bin/* would run fine here and fail to
# even launch on a box that lacks that exact library at that exact path.
for f in "$PREFIX"/bin/*; do
  lipo -info "$f" >/dev/null 2>&1 || continue
  bad="$(otool -L "$f" | sed 1d | awk '{print $1}' | grep -v -e '^/usr/lib/' -e '^/System/' || true)"
  [ -z "$bad" ] || { echo "build-cmake: $f links outside the OS: $bad" >&2; exit 1; }
done

echo "build-cmake: CMake $V ($ARCH, min $MINOS) -> $PREFIX" >&2
