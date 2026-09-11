#!/bin/sh
# The canonical msc.sh (scripts/templates/msc.sh) is how a product's build scripts find shipyard with
# no registry: $SHIPYARD_SCRIPTS if CI exported it, else ask shipyard-cmake where find_package lands.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/.." && pwd)"
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
# COPY the CMAKE_ROOT tree, never symlink it (as in tests/shipyard-cmake-refusal-test.sh): a symlinked
# share/cmake-X.Y could alias the fixture's install destination straight at the host's real cmake
# share dir, and the install below would land INSIDE the host's actual cmake installation.
cp "$real" "$fx/bin/cmake"; cp -R "$croot" "$fx/share/$(basename "$croot")"
# HOME is scratch: until Task 5 removes it, CMakeLists.txt's install(CODE) writes the user package
# registry under $HOME -- a test must never repoint the real one.
"$real" -S "$root" -B "$w/sb" >/dev/null && HOME="$w/home" "$real" --install "$w/sb" --prefix "$fx" >/dev/null
ln -s "$fx/bin/cmake" "$w/pbin/shipyard-cmake"
got="$(env -i PATH="$w/pbin:/usr/bin:/bin" TMPDIR="${TMPDIR:-/tmp}" sh -c ". '$T'; printf '%s|%s' \"\$SHIPYARD\" \"\$SHIPYARD_SCRIPTS\"")" \
  || { echo "FAIL: the probe must find the fixture's shipyard"; exit 1; }
want="$fx/share/cmake/MavericksShipyard/scripts"
[ "$got" = "$want|$want" ] || { echo "FAIL: probe gave '$got', want '$want|$want'"; exit 1; }

echo "PASS: msc-template"
