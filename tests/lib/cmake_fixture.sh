# Shared by the tests that build a fixture cmake PREFIX. (tests/lib/ is not itself run:
# run-repo-tests.sh takes top-level tests only.)
#
# Three tests need the same thing -- shipyard-cmake-refusal, msc-template, assert-installed-shipyard:
# a scratch prefix holding the host's cmake and a copy of its CMAKE_ROOT, with shipyard installed into
# that same prefix, so "a cmake finds shipyard in its OWN prefix" can be exercised without touching
# the real one. Copying CMAKE_ROOT is the whole difficulty, and it goes wrong two ways that are both
# INVISIBLE on a developer box with a pkgsrc cmake (share/cmake-X.Y, writable):
#
#   - Homebrew's CMAKE_ROOT is <prefix>/share/cmake -- the very path shipyard installs into -- and it
#     is itself a SYMLINK. BSD `cp -R` copies a symlink AS a symlink, so the fixture's share/cmake
#     would alias Homebrew's real share directory, and the `cmake --install` two lines later would
#     create MavericksShipyard INSIDE the host's own cmake installation. A test must never write
#     through to the tools it borrowed. (Same escape class as R-P1-14, arriving through a symlinked
#     SOURCE rather than a symlinked destination.)
#   - Homebrew's tree is also read-only, and `cp -R` preserves the source's mode, so even a properly
#     materialised copy could not be installed into: "file cannot create directory:
#     .../share/cmake/MavericksShipyard. Maybe need administrative privileges." That reddened all
#     three tests on every macos-26 runner while all three passed here (R-P1-21).
#
# Hence, in one place rather than three: materialise (-L), copy the CONTENTS into a directory the test
# made itself ("/." plus a trailing "/"), and take ownership of the result. Fixing this three times
# over is how one of the three keeps the bug.
#
# tests/cmake-fixture-test.sh drives this against a symlinked, read-only source named `cmake`, which
# is the Homebrew shape, and is runnable on a 10.9 box with a pkgsrc cmake.
#   usage: copy_cmake_root <CMAKE_ROOT> <destination dir>
copy_cmake_root() {
  mkdir -p "$2"
  cp -RL "$1"/. "$2"/
  chmod -R u+w "$2"
}
