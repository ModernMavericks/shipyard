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
# The two universal-binary assertions (the shipped cmake, and the updater) cannot be real here:
# making an x86_64+arm64 Mach-O needs a cross toolchain, and this suite runs on a 10.9 box that has
# none. `lipo` is stubbed on PATH instead, answering per argument, which proves the script's READING
# of lipo -info -- and which binary it read it for -- and nothing more.
#
# Note what that means for this fixture: its "shipyard-cmake" IS a foreign cmake of a matching
# version. That is deliberate. It is what the version check alone would happily accept, and it is why
# the script also demands a universal binary with shipyard-ctest and shipyard-cpack beside it.
#
# What only a real installed pkg can show, and therefore lives in CI rather than here: that Installer
# actually lays the prefix down at /usr/local/mavericks-shipyard with working symlinks in
# /usr/local/bin, that the CMake it ships is genuinely fat and runs on both kinds of box, that the
# merged updater is genuinely fat, that shipyard-ctest and shipyard-cpack are the real CMake tools
# rather than files with the right names, and that the pkg's preinstall/postinstall ran as themselves
# (not Rosetta).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/.." && pwd)"
. "$here/lib/cmake_fixture.sh"
S="$root/scripts/assert-installed-shipyard.sh"

real="$(command -v cmake 2>/dev/null)" || { echo "SKIP: no cmake to build a fixture prefix from"; exit 77; }
# macOS sets TMPDIR with a trailing slash; a doubled slash in $w is harmless as scratch but this test
# passes the fixture root ($fx, built under $w) as --root, which assert-installed-shipyard.sh folds
# into CFGDIR and greps for verbatim in cmake's own STATUS output -- and cmake normalizes // away when
# it prints MavericksShipyard_DIR, so the grep fails on every real macOS session while looking fine
# here with TMPDIR unset. Strip the trailing slash before use.
_tmp="${TMPDIR:-/tmp}"
w="$(mktemp -d "${_tmp%/}/assert-installed.XXXXXX")"; trap 'rm -rf "$w"' EXIT

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
# A real, writable tree of the fixture's own -- never the host's, and never a symlink to it. The two
# ways that goes wrong (Homebrew's CMAKE_ROOT is a symlink AND read-only, and `cp -R` preserves both)
# are written out in tests/lib/cmake_fixture.sh, which all three fixture-building tests now share;
# tests/cmake-fixture-test.sh proves it on this box.
copy_cmake_root "$croot" "$prefix/share/$(basename "$croot")"
# RELATIVE, exactly as package-pkg.sh writes it: the link must resolve on whatever volume it lands on.
ln -s ../mavericks-shipyard/bin/cmake "$fx/usr/local/bin/shipyard-cmake"
# The pkg puts three commands on the default PATH; ctest in particular is what both workflows and
# every consumer run. Real binaries when this box has them beside its cmake, stubs otherwise: the
# assertion is that they are there and executable, not what they do.
for c in ctest cpack; do
  if [ -x "$(dirname "$real")/$c" ]; then
    cp "$(dirname "$real")/$c" "$prefix/bin/$c"
  else
    printf '#!/bin/sh\nexit 0\n' > "$prefix/bin/$c"; chmod +x "$prefix/bin/$c"
  fi
  ln -s "../mavericks-shipyard/bin/$c" "$fx/usr/local/bin/shipyard-$c"
done
# Keep the output. Sent to /dev/null, a failure here killed the script under `set -e` having said
# NOTHING, and CI could only report "FAIL tests/assert-installed-shipyard-test.sh (exit 1)" -- which
# is what a real macos-26 run did, hiding the read-only-CMAKE_ROOT cause for a whole round.
"$real" -S "$root" -B "$w/sb" > "$w/configure.log" 2>&1 \
  || { echo "FAIL: could not configure shipyard for the fixture:"; sed 's/^/    | /' "$w/configure.log"; exit 1; }
HOME="$w/home-install" "$real" --install "$w/sb" --prefix "$prefix" > "$w/install.log" 2>&1 \
  || { echo "FAIL: could not install shipyard into the fixture prefix:"; sed 's/^/    | /' "$w/install.log"; exit 1; }

updir="$fx/Library/Application Support/ModernMavericks/MavericksShipyardUpdater.app/Contents/MacOS"
mkdir -p "$updir"
printf 'not a real Mach-O; lipo is stubbed below\n' > "$updir/MavericksShipyardUpdater"

# A never-written-to scratch HOME for every run: this box has a real shipyard installed and possibly a
# stale user-registry entry for it, and an ambient entry would outrank the fixture in find_package.
run_home="$w/home-run"; mkdir -p "$run_home"

stub="$w/stub"; mkdir -p "$stub"
# Per-ARGUMENT, because the script now asks about two different binaries: the shipped cmake (must be
# universal, or it is not ours) and the updater. A stub that answered the same for both could not tell
# "the cmake is thin" from "the updater is thin".
lipo_says() {  # $1 = the -info line for shipyard-cmake  $2 = the -info line for the updater
  cat > "$stub/lipo" <<EOF
#!/bin/sh
case "\$2" in
  *MavericksShipyardUpdater) printf '%s\n' "$2" ;;
  *) printf '%s\n' "$1" ;;
esac
EOF
  chmod +x "$stub/lipo"
}
UNIVERSAL_CMAKE="shipyard-cmake: architecture x86_64 arm64"
UNIVERSAL_APP="MavericksShipyardUpdater: architecture x86_64 arm64"
assert() {  # remaining args are appended to the script's own
  HOME="$run_home" PATH="$stub:$PATH" sh "$S" --root "$fx" "$@"
}

# --- the happy path -------------------------------------------------------------------------------
lipo_says "$UNIVERSAL_CMAKE" "$UNIVERSAL_APP"
check "a correctly installed shipyard passes" 0 "finds shipyard in" \
  assert --cmake-version "$ver"

# --- each assertion must be able to fail ----------------------------------------------------------
check "a shipyard-cmake that is not the pinned CMake fails" 1 "is not CMake" \
  assert --cmake-version 0.0.0-not-this-one

# The shipped cmake must be OURS, not just the right version. Everything else in this fixture IS a
# same-versioned foreign cmake, which is precisely why the version match alone proves nothing.
lipo_says "shipyard-cmake: is architecture: arm64" "$UNIVERSAL_APP"
check "a shipyard-cmake with no x86_64 slice fails (it could not run on 10.9)" 1 "shipyard-cmake has no x86_64 slice" \
  assert --cmake-version "$ver"
lipo_says "shipyard-cmake: is architecture: x86_64" "$UNIVERSAL_APP"
check "a shipyard-cmake with no arm64 slice fails (it could not run on Apple Silicon)" 1 "shipyard-cmake has no arm64 slice" \
  assert --cmake-version "$ver"
lipo_says "$UNIVERSAL_CMAKE" "$UNIVERSAL_APP"

for c in shipyard-ctest shipyard-cpack; do
  mv "$fx/usr/local/bin/$c" "$w/cmd-aside"
  check "a missing $c fails (both workflows and every consumer run it by name)" 1 "no executable .*$c" \
    assert --cmake-version "$ver"
  mv "$w/cmd-aside" "$fx/usr/local/bin/$c"
done

lipo_says "$UNIVERSAL_CMAKE" "MavericksShipyardUpdater: is architecture: arm64"
check "an updater with no x86_64 slice fails" 1 "no x86_64 slice" \
  assert --cmake-version "$ver"
lipo_says "$UNIVERSAL_CMAKE" "MavericksShipyardUpdater: is architecture: x86_64"
check "an updater with no arm64 slice fails" 1 "no arm64 slice" \
  assert --cmake-version "$ver"
lipo_says "$UNIVERSAL_CMAKE" "$UNIVERSAL_APP"

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
