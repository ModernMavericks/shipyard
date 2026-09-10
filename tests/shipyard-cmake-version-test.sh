#!/bin/sh
# The installed package must report the DERIVED version. A local `cmake --install` is a snapshot with
# no staleness signal of its own, so the number it carries is the only way to tell one apart from
# another. Reporting the bare line (1.0) would be worse than what it replaced.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
command -v cmake >/dev/null 2>&1 || { echo "SKIP: no cmake"; exit 77; }
work="$(mktemp -d "${TMPDIR:-/tmp}/shipyard-cmakever.XXXXXX")"; trap 'rm -rf "$work"' EXIT

want="$(sh "$root/scripts/shipyard-version.sh" | sed -n 's/^FULL=//p')"
cmake -S "$root" -B "$work/b" >/dev/null 2>&1 || { echo "FAIL: configure failed"; exit 1; }
got="$(sed -n 's/^set(PACKAGE_VERSION "\(.*\)")$/\1/p' "$work/b/MavericksShipyardConfigVersion.cmake" | head -1)"
[ "$got" = "$want" ] || { echo "FAIL: installed package says '$got', derived version is '$want'"; exit 1; }
case "$got" in
  *.*.*) : ;;
  *) echo "FAIL: '$got' is a bare line, not a full version"; exit 1 ;;
esac
echo "PASS: shipyard-cmake-version"
