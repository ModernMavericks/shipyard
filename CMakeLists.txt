cmake_minimum_required(VERSION 3.16)
# VERSION (a gitignored build product) wins when present -- release.yml writes it. Otherwise derive
# from the commit count, so a developer's `cmake --install` from a checkout stamps the REAL version
# rather than the bare line: an install is a snapshot with no staleness signal of its own, and the
# number it carries is the only way to tell one apart from another. UPSTREAM_VERSION is the last
# resort, for a tarball with no .git (it yields the line, which is honest about being imprecise).
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION")
  file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" _MSC_VERSION LIMIT_COUNT 1)
else()
  execute_process(
    COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/scripts/shipyard-version.sh"
    OUTPUT_VARIABLE _MSC_VERSION_OUT ERROR_QUIET RESULT_VARIABLE _MSC_VERSION_RC
    OUTPUT_STRIP_TRAILING_WHITESPACE)
  if(_MSC_VERSION_RC EQUAL 0)
    string(REGEX MATCH "FULL=([^\n]*)" _MSC_VERSION_MATCH "${_MSC_VERSION_OUT}")
    set(_MSC_VERSION "${CMAKE_MATCH_1}")
  else()
    file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/UPSTREAM_VERSION" _MSC_VERSION LIMIT_COUNT 1)
  endif()
endif()
project(MavericksShipyard VERSION ${_MSC_VERSION} LANGUAGES NONE)

# The Sparkle updater that keeps an installed shipyard current. OPT-IN: shipyard is LANGUAGES NONE
# and compiles nothing, so `cmake --install` works on a box with no ObjC compiler -- and the payload
# stays buildable where there is no Objective-C at all. Only the pkg job turns this on.
#
# One target, configured TWICE (x86_64/10.9 and arm64) rather than two targets: CMAKE_OSX_ARCHITECTURES
# and the deployment target are directory-scoped, and arm64 has no 10.9. mavericks-golang does the
# same with build/updater and build/updater-cross.
option(SHIPYARD_BUILD_UPDATER "Build the Sparkle updater app (needed only to package the pkg)" OFF)
if(SHIPYARD_BUILD_UPDATER)
  enable_language(OBJC)
  include("${CMAKE_CURRENT_SOURCE_DIR}/MavericksSparkle.cmake")

  # The two slices are staged into ONE pkg (Task 3), so same-named .app bundles would overwrite each
  # other -- unlike mavericks-golang's updater, which builds one variant per invocation into its own
  # dir. Give each slice its own target NAME (mirroring mavericks-golang's GoUpdater/GoCrossUpdater)
  # as well as its own bundle-id suffix, matching mavericks-clang's identifiers.
  set(_upd_name "MavericksShipyardUpdater")
  set(_upd_suffix "")
  if(CMAKE_OSX_ARCHITECTURES MATCHES "arm64")
    set(_upd_name "MavericksShipyardCrossUpdater")
    set(_upd_suffix "-cross")
  endif()

  mavericks_add_updater_app(
    NAME ${_upd_name}
    PRODUCT_NAME "Mavericks Shipyard"
    BUNDLE_ID "dev.modernmavericks.mavericks-shipyard${_upd_suffix}"
    FEED_URL "https://github.com/ModernMavericks/shipyard/releases/latest/download/appcast.xml"
    VERSION "${PROJECT_VERSION}"
    LOG_PREFIX "MavShipyardUpdater"
    CONFIRM_TITLE "Mavericks Shipyard updated"
    CONFIRM_BODY "The shared CMake modules and scripts in /usr/local/mavericks-shipyard were updated."
    RELAUNCH_MARKER "/tmp/.mavericks-shipyard-updater-relaunched"
    ALLOW_GENERIC
    # no PANE_HINT_KEY -> a background-found update posts an NSUserNotification. shipyard has no UI.
  )
endif()

# This project ships CMake modules + helper scripts (no compiled artifacts). It
# installs itself as a find_package() config package so consumers can just:
#   find_package(MavericksShipyard REQUIRED)
#   include(Mavericks)
# instead of vendoring a submodule. Install to a prefix your cmake searches
# (e.g. a pkgsrc package -> /opt/pkg), or pass -DCMAKE_PREFIX_PATH=<prefix>.

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)

set(_dest "${CMAKE_INSTALL_DATADIR}/cmake/MavericksShipyard")

install(FILES
  MavericksShipyardConfig.cmake
  Mavericks.cmake
  MavericksMode.cmake
  RequireAppleClang.cmake
  MavericksFetch.cmake
  MavericksCompatGuard.cmake
  MavericksSparkle.cmake
  MavericksVersion.cmake
  MavericksDecisions.cmake
  mavericks-presets.json
  DESTINATION "${_dest}")

# Scripts keep their executable bit (they are run via `sh` but stay +x for direct use).
# scripts/ carries the Sparkle fetch scripts + native signer/keygen sources too.
install(DIRECTORY scripts DESTINATION "${_dest}" USE_SOURCE_PERMISSIONS)
# Sparkle updater templates (configure_file'd per product by MavericksSparkle.cmake).
install(DIRECTORY updater DESTINATION "${_dest}")

write_basic_package_version_file(
  "${CMAKE_CURRENT_BINARY_DIR}/MavericksShipyardConfigVersion.cmake"
  VERSION "${PROJECT_VERSION}"
  COMPATIBILITY SameMajorVersion)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/MavericksShipyardConfigVersion.cmake"
  DESTINATION "${_dest}")

# Self-register in the per-user CMake package registry so consumers find this
# with a bare `find_package(MavericksShipyard)` -- no CMAKE_PREFIX_PATH, no
# submodule, wherever you chose to --prefix install it. find_package consults
# ~/.cmake/packages/<Name>/ by default. Set MAVERICKS_NO_USER_REGISTRY to skip
# (e.g. a system/CI install that shouldn't touch $HOME).
option(MAVERICKS_NO_USER_REGISTRY "Do not register in the user package registry" OFF)
if(NOT MAVERICKS_NO_USER_REGISTRY)
  install(CODE "
    set(_reg \"\$ENV{HOME}/.cmake/packages/MavericksShipyard\")
    file(MAKE_DIRECTORY \"\${_reg}\")
    file(WRITE \"\${_reg}/mavericks-shipyard\" \"\${CMAKE_INSTALL_PREFIX}/${_dest}\")
    message(STATUS \"Registered MavericksShipyard -> \${CMAKE_INSTALL_PREFIX}/${_dest} (user package registry)\")
  ")
endif()

# Self-tests for the shared shell helpers. `cmake -S . -B build && ctest --test-dir build`.
enable_testing()
find_program(BATS_EXECUTABLE bats)
if(BATS_EXECUTABLE)
  add_test(NAME mavericks-fetch
    COMMAND ${BATS_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/mavericks_fetch.bats)
  add_test(NAME clone-pinned
    COMMAND ${BATS_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/clone_pinned.bats)
  add_test(NAME compat-guard
    COMMAND ${BATS_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/compat_guard.bats)
  add_test(NAME gen-appcast
    COMMAND ${BATS_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/gen_appcast.bats)
  add_test(NAME relaunch-decision
    COMMAND ${BATS_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/relaunch_decision.bats)
else()
  message(STATUS "bats not found -- shell helper tests won't run via ctest (install bats to enable)")
endif()

# Prove the à-la-carte modules load without include(Mavericks) / the AppleClang gate.
# Point find_package at THIS source tree (it carries the config + modules).
add_test(NAME standalone-include
  COMMAND sh ${CMAKE_CURRENT_SOURCE_DIR}/tests/standalone-include.sh ${CMAKE_CURRENT_SOURCE_DIR})

# Prove include(Mavericks) is universally includable: auto-scoped gate (no
# MAVERICKS_REQUIRE_LANGS), LANGUAGES NONE no-op, and multi-arch safe.
add_test(NAME umbrella-langs
  COMMAND sh ${CMAKE_CURRENT_SOURCE_DIR}/tests/umbrella-langs.sh ${CMAKE_CURRENT_SOURCE_DIR})

# Prove stage_updater.sh stages an updater .app + LaunchAgent and renders the templates.
add_test(NAME stage-updater
  COMMAND sh ${CMAKE_CURRENT_SOURCE_DIR}/tests/stage_updater.sh ${CMAKE_CURRENT_SOURCE_DIR})

# Prove sign_and_appcast.sh signs a pkg and emits an appcast with the EdDSA enclosure attrs.
add_test(NAME sign-and-appcast
  COMMAND sh ${CMAKE_CURRENT_SOURCE_DIR}/tests/sign_and_appcast.sh ${CMAKE_CURRENT_SOURCE_DIR})

# Prove the Renovate preset is valid and includes the mavericks-legacysupport customManager.
add_test(NAME renovate-preset
  COMMAND sh ${CMAKE_CURRENT_SOURCE_DIR}/tests/renovate_preset.sh)
