#!/bin/sh
# tests/lib/cmake_fixture.sh's copy_cmake_root, against the shape that broke three tests on macos-26
# and could not break anything here.
#
# The host's CMAKE_ROOT is whatever the box's cmake came with. Two properties of HOMEBREW's -- and
# only Homebrew's -- make copying it hazardous, and a pkgsrc box (this one) has neither:
#
#   1. it is a SYMLINK. BSD `cp -R` copies a symlink AS a symlink, so a naive copy leaves the
#      fixture's share/cmake pointing at the host's real tree, and the `cmake --install` that follows
#      writes MavericksShipyard INTO the host's cmake installation. Silent, and it damages the box.
#   2. it is READ-ONLY, and `cp -R` preserves the mode, so even a materialised copy cannot be
#      installed into: "file cannot create directory: ... Maybe need administrative privileges."
#      That is the error three tests died of on every macos-26 runner (R-P1-21).
#
# It is also named exactly `cmake`, which is the path shipyard installs into (share/cmake/
# MavericksShipyard) -- which is why 1 and 2 bite there and nowhere else.
#
# So this builds that shape out of ordinary directories: a read-only real tree, and a symlink named
# `cmake` pointing at it. No Homebrew required, and it fails on a 10.9 box if the helper regresses.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib/cmake_fixture.sh"

w="$(mktemp -d "${TMPDIR:-/tmp}/cmake-fixture-test.XXXXXX")"
# The host tree is read-only, so rm -rf cannot clear it without taking the write bit back first.
trap 'chmod -R u+w "$w" 2>/dev/null; rm -rf "$w"' EXIT

host="$w/host"                        # stands in for /opt/homebrew/Cellar/cmake/X/share/cmake
mkdir -p "$host/Modules"
printf 'the host cmake owns this\n' > "$host/Modules/FindFoo.cmake"
# A symlink INSIDE the tree, pointing out of it -- a packaged cmake is full of these. Without -L the
# copy keeps it as a link, and anything the fixture writes there lands outside the fixture. The
# trailing "/." alone would not have caught this: it dereferences only the top-level source.
printf 'outside the fixture\n' > "$w/outside.txt"
ln -s ../../outside.txt "$host/Modules/Outside.cmake"
ln -s host "$w/cmake"                 # ...reached as /opt/homebrew/share/cmake, a symlink named `cmake`
chmod -R a-w "$host"

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# --- what the naive idiom does, so the assertions below are known to be about something -------------
naive="$w/naive/share"; mkdir -p "$naive"
cp -R "$w/cmake" "$naive/cmake"
[ -L "$naive/cmake" ] \
  || fail "cp -R of a symlinked CMAKE_ROOT no longer yields a symlink on this platform -- if BSD cp " \
          "changed, the helper's -L is still correct but this test no longer proves why"

# --- the helper ------------------------------------------------------------------------------------
# The parent exists already, as it does in every real caller ($fx/share is made with $fx/bin). Without
# that, a naive `cp -R` would fail for the uninteresting reason that its destination's parent is
# missing, and this test would "pass" against a helper that had regressed.
dest="$w/fx/share/cmake"; mkdir -p "$w/fx/share"
copy_cmake_root "$w/cmake" "$dest"

[ ! -L "$dest" ] || fail "copy_cmake_root left $dest a SYMLINK; anything installed into the fixture " \
                         "would land in the host's own cmake tree"
[ -d "$dest" ] || fail "copy_cmake_root did not produce a directory at $dest"
[ -f "$dest/Modules/FindFoo.cmake" ] || fail "copy_cmake_root did not copy the tree's contents"

# Writable THROUGHOUT, which is the whole of R-P1-21: a `cmake --install` into this prefix creates
# share/cmake/MavericksShipyard, and a copy that kept the host's read-only mode cannot. Checked at the
# top of the copy AND inside it, because `mkdir -p` gives the top level a mode of its own -- only the
# subdirectories carry the source's.
mkdir "$dest/MavericksShipyard" 2>/dev/null \
  || fail "cannot create $dest/MavericksShipyard -- the copy kept the host's read-only mode, which is " \
          "exactly the macos-26 failure ('Maybe need administrative privileges')"
mkdir "$dest/Modules/Sub" 2>/dev/null \
  || fail "cannot create a directory INSIDE the copied tree; the copy kept the host's read-only mode"
printf 'x\n' > "$dest/Modules/FindFoo.cmake" 2>/dev/null \
  || fail "cannot overwrite a file in the copy; the fixture does not own what it must write into"

# A symlink inside the source must have been MATERIALISED, or writing to it escapes the fixture.
[ ! -L "$dest/Modules/Outside.cmake" ] \
  || fail "copy_cmake_root kept an internal symlink as a link; the fixture can write outside itself"
printf 'the fixture wrote this\n' > "$dest/Modules/Outside.cmake" 2>/dev/null \
  || fail "cannot write $dest/Modules/Outside.cmake"
[ "$(cat "$w/outside.txt")" = "outside the fixture" ] \
  || fail "writing inside the fixture changed $w/outside.txt -- an internal symlink was followed out"

# And the host is untouched. This is the one that matters most: the failure mode it guards is not a
# red test, it is a developer's cmake installation quietly gaining a MavericksShipyard directory.
[ ! -e "$host/MavericksShipyard" ] || fail "the host tree gained MavericksShipyard -- the fixture wrote THROUGH to it"
[ "$(cat "$host/Modules/FindFoo.cmake")" = "the host cmake owns this" ] \
  || fail "the host tree's contents changed -- the fixture wrote THROUGH to it"

[ "$fails" -eq 0 ] || { echo "FAIL: $fails case(s) in cmake-fixture"; exit 1; }
echo "PASS: cmake-fixture"
