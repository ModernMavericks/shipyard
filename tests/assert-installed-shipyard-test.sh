#!/bin/sh
# scripts/assert-installed-shipyard.sh is the ONE place release.yml's install smoke and ci.yml's
# packaging rehearsal state what an installed shipyard must look like (R-P1-17). A shared assertion
# that nothing exercises is worse than an inline one: both callers would go green on a script that
# stopped asserting. So drive it against a FIXTURE root shaped exactly like the pkg's layout.
#
# Three of the four assertions run FOR REAL here, against this box's own cmake:
#   - shipyard-cmake is the pinned CMake (the fixture's cmake, whatever version it happens to be)
#   - a probe under `env -i` resolves shipyard inside shipyard-cmake's own prefix, reached through the
#     same relative ../mavericks-shipyard/bin/cmake symlink the pkg lays down
#   - a foreign cmake pointed straight at that prefix is refused, naming shipyard-cmake
#
# The universal-updater assertion cannot be real here: making an x86_64+arm64 Mach-O needs a cross
# toolchain, and this suite runs on a 10.9 box that has none. `lipo` is stubbed on PATH instead, which
# proves the script's READING of lipo -info (both slices present / a slice missing) and nothing more.
#
# What only a real installed pkg can show, and therefore lives in CI rather than here: that Installer
# actually lays the prefix down at /usr/local/mavericks-shipyard with working symlinks in
# /usr/local/bin, that the CMake it ships is universal and runs on both kinds of box, that the merged
# updater is genuinely fat, and that the pkg's preinstall/postinstall ran as themselves (not Rosetta).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/.." && pwd)"
S="$root/scripts/assert-installed-shipyard.sh"

real="$(command -v cmake 2>/dev/null)" || { echo "SKIP: no cmake to build a fixture prefix from"; exit 77; }
w="$(mktemp -d "${TMPDIR:-/tmp}/assert-installed.XXXXXX")"; trap 'rm -rf "$w"' EXIT

ver="$("$real" --version 2>&1 | sed -n 's/^cmake version //p' | head -1)"
[ -n "$ver" ] || { echo "SKIP: cannot read this cmake's version"; exit 77; }

fails=0
check() {  # $1 = what  $2 = expected exit (0 or 1)  $3 = substring the output must contain ("" = any)
  _what="$1"; _want="$2"; _sub="$3"; shift 3
  _rc=0; _out="$("$@" 2>&1)" || _rc=$?
  if [ "$_rc" -ne "$_want" ]; then
    echo "FAIL: $_what -- expected exit $_want, got $_rc:"; printf '%s\n' "$_out" | sed 's/^/    | /'
    fails=$((fails + 1)); return 0
  fi
  # grep -e: the expected substrings include ones that start with `--`, which grep would read as its
  # own option and die on ("unrecognized option") -- a green-looking crash rather than a comparison.
  if [ -n "$_sub" ] && ! printf '%s\n' "$_out" | grep -q -e "$_sub"; then
    echo "FAIL: $_what -- output does not mention '$_sub':"; printf '%s\n' "$_out" | sed 's/^/    | /'
    fails=$((fails + 1)); return 0
  fi
  echo "ok: $_what"
}

# --- the fixture: the pkg's layout, built from this box's cmake ------------------------------------
# COPY the binary and its CMAKE_ROOT (never symlink): a cmake finds CMAKE_ROOT relative to its REAL
# path, so a symlink would report the host's prefix and the whole point -- "shipyard-cmake finds
# shipyard in its OWN prefix" -- would be untested. Same reasoning as shipyard-cmake-refusal-test.sh.
croot="$(printf 'message("${CMAKE_ROOT}")\n' > "$w/r.cmake"; "$real" -P "$w/r.cmake" 2>&1)"
fx="$w/root"
prefix="$fx/usr/local/mavericks-shipyard"
mkdir -p "$prefix/bin" "$prefix/share" "$fx/usr/local/bin"
cp "$real" "$prefix/bin/cmake"
cp -R "$croot" "$prefix/share/$(basename "$croot")"
# RELATIVE, exactly as package-pkg.sh writes it: the link must resolve on whatever volume it lands on.
ln -s ../mavericks-shipyard/bin/cmake "$fx/usr/local/bin/shipyard-cmake"
"$real" -S "$root" -B "$w/sb" >/dev/null 2>&1
HOME="$w/home-install" "$real" --install "$w/sb" --prefix "$prefix" >/dev/null 2>&1

updir="$fx/Library/Application Support/ModernMavericks/MavericksShipyardUpdater.app/Contents/MacOS"
mkdir -p "$updir"
printf 'not a real Mach-O; lipo is stubbed below\n' > "$updir/MavericksShipyardUpdater"

# A never-written-to scratch HOME for every run: this box has a real shipyard installed and possibly a
# stale user-registry entry for it, and an ambient entry would outrank the fixture in find_package.
run_home="$w/home-run"; mkdir -p "$run_home"

stub="$w/stub"; mkdir -p "$stub"
lipo_says() {  # $1 = the line the stub `lipo` prints for -info
  cat > "$stub/lipo" <<EOF
#!/bin/sh
printf '%s\n' "$1"
EOF
  chmod +x "$stub/lipo"
}
assert() {  # remaining args are appended to the script's own
  HOME="$run_home" PATH="$stub:$PATH" sh "$S" --root "$fx" "$@"
}

# --- the happy path -------------------------------------------------------------------------------
lipo_says "$updir/MavericksShipyardUpdater: architecture x86_64 arm64"
check "a correctly installed shipyard passes" 0 "finds shipyard in" \
  assert --cmake-version "$ver"

# --- each assertion must be able to fail ----------------------------------------------------------
check "a shipyard-cmake that is not the pinned CMake fails" 1 "is not CMake" \
  assert --cmake-version 0.0.0-not-this-one

lipo_says "$updir/MavericksShipyardUpdater: is architecture: arm64"
check "an updater with no x86_64 slice fails" 1 "no x86_64 slice" \
  assert --cmake-version "$ver"
lipo_says "$updir/MavericksShipyardUpdater: is architecture: x86_64"
check "an updater with no arm64 slice fails" 1 "no arm64 slice" \
  assert --cmake-version "$ver"
lipo_says "$updir/MavericksShipyardUpdater: architecture x86_64 arm64"

mv "$updir/MavericksShipyardUpdater" "$w/updater-aside"
check "a missing updater fails" 1 "no installed updater executable" \
  assert --cmake-version "$ver"
mv "$w/updater-aside" "$updir/MavericksShipyardUpdater"

# The stripped-environment probe: with shipyard gone from the prefix, shipyard-cmake still runs and is
# still the pinned version, so ONLY assertion 2 can catch this.
mv "$prefix/share/cmake/MavericksShipyard" "$w/shipyard-aside"
check "a prefix whose shipyard is missing fails the stripped-environment probe" 1 "under a stripped environment" \
  assert --cmake-version "$ver"
mv "$w/shipyard-aside" "$prefix/share/cmake/MavericksShipyard"

mv "$fx/usr/local/bin/shipyard-cmake" "$w/link-aside"
check "a missing /usr/local/bin/shipyard-cmake fails" 1 "no executable shipyard-cmake" \
  assert --cmake-version "$ver"
mv "$w/link-aside" "$fx/usr/local/bin/shipyard-cmake"

# The refusal. On the happy path above it was checked against this box's REAL cmake (which is refused,
# for real). These two stub a `cmake` on PATH to show the other side: a foreign cmake that ACCEPTS, and
# one that fails without saying what to run instead, both have to be reported.
cat > "$stub/cmake" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$stub/cmake"
check "a foreign cmake that configures against shipyard fails" 1 "must be refused" \
  assert --cmake-version "$ver"
cat > "$stub/cmake" <<'STUB'
#!/bin/sh
echo "some unrelated configure error" >&2
exit 1
STUB
chmod +x "$stub/cmake"
check "a refusal that never names shipyard-cmake fails" 1 "does not name shipyard-cmake" \
  assert --cmake-version "$ver"
rm -f "$stub/cmake"

# --- the interface itself -------------------------------------------------------------------------
check "--cmake-version is required" 2 "--cmake-version required" \
  assert
check "an unknown option is refused rather than ignored" 2 "unknown option" \
  assert --cmake-version "$ver" --install-it-for-me
check "a root that does not exist is refused" 2 "no such root" \
  env HOME="$run_home" PATH="$stub:$PATH" sh "$S" --root "$w/no-such-root" --cmake-version "$ver"

[ "$fails" -eq 0 ] || { echo "FAIL: $fails case(s) in assert-installed-shipyard"; exit 1; }
echo "PASS: assert-installed-shipyard"
