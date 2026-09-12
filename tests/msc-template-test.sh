#!/bin/sh
# The canonical msc.sh (scripts/templates/msc.sh) is how a product's build scripts find shipyard with
# no registry: $SHIPYARD_SCRIPTS if CI exported it, else ask shipyard-cmake where find_package lands.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/.." && pwd)"
. "$here/lib/cmake_fixture.sh"
T="$root/scripts/templates/msc.sh"
[ -f "$T" ] || { echo "FAIL: no $T"; exit 1; }
w="$(mktemp -d "${TMPDIR:-/tmp}/msc-test.XXXXXX")"; trap 'rm -rf "$w"' EXIT

# 1. SHIPYARD_SCRIPTS wins, and no cmake is run (PATH has none).
mkdir -p "$w/s"
got="$(env -i PATH=/usr/bin:/bin SHIPYARD_SCRIPTS="$w/s" sh -c ". '$T'; printf '%s' \"\$SHIPYARD\"")" \
  || { echo "FAIL: with SHIPYARD_SCRIPTS set, msc.sh must succeed"; exit 1; }
[ "$got" = "$w/s" ] || { echo "FAIL: SHIPYARD must be \$SHIPYARD_SCRIPTS; got '$got'"; exit 1; }

# 2. No SHIPYARD_SCRIPTS, no shipyard-cmake: fail, saying what to install.
if msg="$(env -i PATH=/usr/bin:/bin sh -c ". '$T'" 2>&1)"; then echo "FAIL: must fail with nothing to find"; exit 1; fi
printf '%s' "$msg" | grep -q 'install the shipyard pkg' || { echo "FAIL: message must say to install the pkg; got: $msg"; exit 1; }

# 3. The probe: a shipyard-cmake on PATH (fixture prefix, as in the refusal test) is asked.
real="$(command -v cmake 2>/dev/null)" || { echo "SKIP: no cmake for the probe case"; exit 77; }
croot="$(printf 'message("${CMAKE_ROOT}")\n' > "$w/r.cmake"; "$real" -P "$w/r.cmake" 2>&1)"
fx="$w/fx"; mkdir -p "$fx/bin" "$fx/share" "$w/pbin"
cp "$real" "$fx/bin/cmake"
# A real, writable tree of the fixture's own -- never the host's, and never a symlink to it. See
# tests/lib/cmake_fixture.sh for the two ways that goes wrong and why it is one helper, not three
# copies; tests/cmake-fixture-test.sh proves it.
copy_cmake_root "$croot" "$fx/share/$(basename "$croot")"
# HOME is scratch: until Task 5 removes it, CMakeLists.txt's install(CODE) writes the user package
# registry under $HOME -- a test must never repoint the real one.
# Keep the output: redirected to /dev/null, a failure here kills the script under `set -e` with
# nothing said, and CI reports a bare "FAIL tests/... (exit 1)" with no way to tell what broke.
"$real" -S "$root" -B "$w/sb" > "$w/configure.log" 2>&1 \
  || { echo "FAIL: could not configure shipyard for the fixture:"; sed 's/^/    | /' "$w/configure.log"; exit 1; }
HOME="$w/home" "$real" --install "$w/sb" --prefix "$fx" > "$w/install.log" 2>&1 \
  || { echo "FAIL: could not install shipyard into the fixture prefix:"; sed 's/^/    | /' "$w/install.log"; exit 1; }
ln -s "$fx/bin/cmake" "$w/pbin/shipyard-cmake"
got="$(env -i PATH="$w/pbin:/usr/bin:/bin" TMPDIR="${TMPDIR:-/tmp}" sh -c ". '$T'; printf '%s|%s' \"\$SHIPYARD\" \"\$SHIPYARD_SCRIPTS\"")" \
  || { echo "FAIL: the probe must find the fixture's shipyard"; exit 1; }
want="$fx/share/cmake/MavericksShipyard/scripts"
[ "$got" = "$want|$want" ] || { echo "FAIL: probe gave '$got', want '$want|$want'"; exit 1; }

echo "PASS: msc-template"
