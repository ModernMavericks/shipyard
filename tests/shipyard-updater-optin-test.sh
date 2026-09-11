#!/bin/sh
# The updater must be OPT-IN. shipyard is LANGUAGES NONE: it compiles nothing, so `cmake --install`
# works on a box with no ObjC compiler -- and the payload stays buildable somewhere that has no
# Objective-C at all, which the design deliberately does not preclude. An unconditional ObjC target
# would quietly make a compiler a requirement for installing a package of shell scripts.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
command -v cmake >/dev/null 2>&1 || { echo "SKIP: no cmake"; exit 77; }
work="$(mktemp -d "${TMPDIR:-/tmp}/updater-optin.XXXXXX")"; trap 'rm -rf "$work"' EXIT

# Default configure: no languages enabled, nothing to compile.
cmake -S "$root" -B "$work/off" >"$work/off.log" 2>&1 || { echo "FAIL: default configure failed"; sed -n '1,20p' "$work/off.log"; exit 1; }
grep -qi "The OBJC compiler identification" "$work/off.log" \
  && { echo "FAIL: default configure enabled ObjC; the updater must be opt-in"; exit 1; }
[ -d "$work/off/CMakeFiles/MavericksShipyardUpdater.dir" ] \
  && { echo "FAIL: default configure created an updater target"; exit 1; }

# Opt in: the target exists.
if cmake -S "$root" -B "$work/on" -DSHIPYARD_BUILD_UPDATER=ON -DMAVERICKS_ALLOW_GENERIC_ICON=ON >"$work/on.log" 2>&1; then
  grep -qi "The OBJC compiler identification" "$work/on.log" \
    || { echo "FAIL: opt-in configure did not enable ObjC"; exit 1; }
else
  # No Sparkle/network on this box is a legitimate skip; a CMake syntax error is not.
  grep -qiE "fetch_sparkle|download|network|curl" "$work/on.log" \
    || { echo "FAIL: opt-in configure failed for a non-Sparkle reason"; sed -n '1,25p' "$work/on.log"; exit 1; }
  echo "SKIP: cannot fetch Sparkle here; opt-in path not exercised"; exit 77
fi

echo "PASS: shipyard-updater-optin"
