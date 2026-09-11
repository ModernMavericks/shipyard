#!/bin/sh
# Point cmake at an installed shipyard payload, whatever cmake that is.
#
# find_package() searches CMAKE_SYSTEM_PREFIX_PATH, which is baked into the cmake BINARY: it differs
# between a pkgsrc cmake, a Homebrew one and CMake.app, and can change when any of them updates. So
# discovery here does not depend on where the payload sits -- it records the location in the user
# package registry, which every cmake consults. That is what lets the payload live in a product-owned
# /usr/local/mavericks-shipyard instead of the shared /usr/local/share/cmake.
#
# The entry filename is FIXED, matching what CMakeLists.txt writes on `cmake --install`. Registering
# twice replaces the path rather than adding a second entry, so this never needs a migration step.
#
# Called by the pkg's postinstall, and by hand: it is the documented recovery when shipyard was
# installed before cmake was.
#   usage: register-with-cmake.sh <payload-dir> [home]
set -eu
payload="${1:?register-with-cmake: payload dir required}"
home="${2:-$HOME}"

[ -d "$payload" ] || { echo "register-with-cmake: no such payload dir: $payload" >&2; exit 1; }

command -v cmake >/dev/null 2>&1 || {
  echo "register-with-cmake: cmake is not on PATH, so shipyard's CMake side cannot be registered." >&2
  echo "    shipyard's shell scripts are installed and usable now." >&2
  echo "    fix: install cmake (any cmake -- we do not care which), then run:" >&2
  echo "         sh $payload/scripts/register-with-cmake.sh $payload" >&2
  exit 1
}

reg="$home/.cmake/packages/MavericksShipyard"
mkdir -p "$reg"
printf '%s' "$payload" > "$reg/mavericks-shipyard"
echo "registered MavericksShipyard -> $payload"
