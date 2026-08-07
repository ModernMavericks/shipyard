# Mavericks.cmake -- shared build conventions for the mavericks-* family.
#
# These projects all build native artifacts that run on OS X 10.9 "Mavericks"
# and cross-build for it from a modern macOS on GitHub Actions. This module
# centralizes what that takes; each project keeps its own targets/packaging.
#
# Usage (in a project CMakeLists.txt): every mavericks-* project can include this.
#
#   project(foo LANGUAGES C OBJC)
#
#   find_package(MavericksShipyard REQUIRED)   # sets up CMAKE_MODULE_PATH
#   include(Mavericks)                 # mode detect + AppleClang check + helpers
#   # (Sparkle-updater projects also: include(MavericksSparkle))
#
#   add_executable(foo ...)
#   mavericks_assert_binary_compatible(foo)        # assert the binary stays 10.9-safe
#
# Deployment target + architecture must be set BEFORE project() to take effect, so
# they come from your preset (inherit mavericks-native / mavericks-cross from
# mavericks-presets.json) -- NOT from this umbrella, which runs after project(). A
# project on a non-Apple toolchain sets(MAVERICKS_REQUIRE_APPLECLANG OFF) first.
# Install once with `cmake --install` (self-registers); see README.

set(MAVERICKS_SHARED_DIR "${CMAKE_CURRENT_LIST_DIR}" CACHE INTERNAL "mavericks-shipyard root")

# Newer SDKs deprecate the 10.9-era Cocoa/IOKit APIs these projects use; we still
# target them deliberately. (Deployment target + arch are the consumer's, set before
# project() via the preset -- this umbrella runs too late to set them.)
add_compile_options(-Wall -Wno-deprecated-declarations)

include(MavericksMode)          # -> MAVERICKS_MODE, guard vs the preset's expected mode
include(RequireAppleClang)      # reject gcc / Homebrew / pkgsrc clang
include(MavericksFetch)         # mavericks_fetch_sdk()
include(MavericksCompatGuard)   # mavericks_assert_binary_compatible()
include(MavericksVersion)       # mavericks_resolve_version() -- VERSION is derived, never committed
include(MavericksDecisions)     # mavericks_require_icon() -- forced icon decision
