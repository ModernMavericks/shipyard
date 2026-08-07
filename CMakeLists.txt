cmake_minimum_required(VERSION 3.16)
# First-party repo (we are the upstream): the self-owned version lives in committed UPSTREAM_VERSION;
# VERSION is the gitignored build product. Read VERSION if present, else fall back to UPSTREAM_VERSION —
# the same shape this project's own conventions require of every consumer (a committed VERSION goes stale
# while tags move; check-family-conventions.sh fails a tracked one). Not resolve-version.sh: that hardcodes
# `-mavericks.N`, which is for repackaged upstreams, not for us.
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION")
  file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" _MSC_VERSION LIMIT_COUNT 1)
else()
  file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/UPSTREAM_VERSION" _MSC_VERSION LIMIT_COUNT 1)
endif()
project(MavericksShipyard VERSION ${_MSC_VERSION} LANGUAGES NONE)

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
