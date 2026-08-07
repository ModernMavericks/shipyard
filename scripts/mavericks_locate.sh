#!/bin/sh
# Echo the installed mavericks-shipyard scripts dir, for POST-configure shell
# callers (a ctest gate script, etc.). Resolution: $MAVERICKS_SHARED_SCRIPTS if set,
# else the CMake user package registry (the registry file's content is the install
# config dir, which contains scripts/). Exits non-zero if it cannot resolve.
#
# NOTE: a PRE-configure caller (run before cmake, e.g. to produce a -D path) cannot
# use this without first bootstrap-finding it -- that ~3-line registry read is
# irreducible. This helper serves callers that already know the package is installed.
set -eu
if [ -n "${MAVERICKS_SHARED_SCRIPTS:-}" ]; then
  printf '%s\n' "$MAVERICKS_SHARED_SCRIPTS"; exit 0
fi
_dir=$(cat "$HOME/.cmake/packages/MavericksShipyard/"* 2>/dev/null | head -1)
[ -n "$_dir" ] && [ -d "$_dir/scripts" ] || {
  echo "mavericks_locate: cannot resolve the installed scripts dir (set MAVERICKS_SHARED_SCRIPTS)" >&2
  exit 1
}
printf '%s\n' "$_dir/scripts"
