#!/bin/sh
# Configures tests/standalone-include (LANGUAGES NONE) against the shared package's
# config to prove the à-la-carte modules load without the AppleClang gate.
# Arg 1: the MavericksShipyard config dir (holds the Config + the modules).
set -eu
# Scratch consumers must configure under a shipyard-cmake: MavericksShipyardConfig.cmake refuses any
# other cmake. SHIPYARD_CMAKE overrides (CI's source-build mode sets it); else the installed one.
SC="${SHIPYARD_CMAKE:-$(command -v shipyard-cmake 2>/dev/null || true)}"
[ -n "$SC" ] || { echo "SKIP: no shipyard-cmake (install the shipyard pkg, or set SHIPYARD_CMAKE)"; exit 77; }
# ctest passes the installed config dir (see add_test). Called bare -- as the shared test runner
# does when it globs tests/*.sh -- there is nothing configured to test: 77 = SKIP, not a failure.
[ "$#" -ge 1 ] || { echo "no config dir given (ctest supplies it) -- skipping" >&2; exit 77; }
CFGDIR="${1:?config dir required}"
SRC=$(cd "$(dirname "$0")/standalone-include" && pwd)
WORK="$(mktemp -d -t standalone_include)"
trap 'rm -rf "$WORK"' EXIT
"$SC" -S "$SRC" -B "$WORK" -DMavericksShipyard_DIR="$CFGDIR" >/dev/null
echo "standalone-include: OK"
