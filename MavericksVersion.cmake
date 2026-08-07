# MavericksVersion.cmake -- one way for every product repo to learn its version at configure time.
#
#   mavericks_resolve_version(MYVAR)          # auto: the shipped N for this upstream
#   mavericks_resolve_version(MYVAR MODE local)   # a repackage: N+1
#   mavericks_resolve_version(MYVAR UPSTREAM_FILE "${CMAKE_SOURCE_DIR}/lines/126/UPSTREAM_VERSION")
#   mavericks_resolve_version(MYVAR ROOT "${CMAKE_SOURCE_DIR}/..")   # standalone subproject
#
# Replaces the `file(STRINGS "${CMAKE_SOURCE_DIR}/VERSION" ...)` every repo hand-rolled. That line
# needed VERSION to already exist, which was true only because four repos COMMITTED it -- and the
# committed copy went stale (container-tools built .14 from a file saying .2). VERSION is a build
# product now: gitignored, derived from UPSTREAM_VERSION + the shipped tags, written on first use.
# So a fresh clone configures without a release having been cut first.
#
# The logic lives in scripts/resolve-version.sh (shell, under test); this is the CMake doorway to it.
set(MAVERICKS_SHARED_DIR "${CMAKE_CURRENT_LIST_DIR}" CACHE INTERNAL "mavericks-shipyard root")

function(mavericks_resolve_version outvar)
  cmake_parse_arguments(A "" "MODE;UPSTREAM_FILE;ROOT" "" ${ARGN})
  if(NOT A_MODE)
    set(A_MODE auto)
  endif()
  # ROOT is the REPO root, which is not always the project root: container-tools builds updater/ and
  # menubar/ as standalone projects that still take their version from the repo they live in.
  if(NOT A_ROOT)
    set(A_ROOT "${CMAKE_SOURCE_DIR}")
  endif()
  get_filename_component(A_ROOT "${A_ROOT}" ABSOLUTE)

  set(_env)
  if(A_UPSTREAM_FILE)
    list(APPEND _env "MAVERICKS_UPSTREAM_FILE=${A_UPSTREAM_FILE}")
  endif()

  execute_process(
    COMMAND ${CMAKE_COMMAND} -E env "MAVERICKS_ROOT=${A_ROOT}" ${_env}
            sh "${MAVERICKS_SHARED_DIR}/scripts/resolve-version.sh" "${A_MODE}"
    OUTPUT_VARIABLE _ver
    ERROR_VARIABLE  _err
    RESULT_VARIABLE _rc
    OUTPUT_STRIP_TRAILING_WHITESPACE)

  # Fail the configure rather than carry on with an empty version: artifacts named "-mavericks."
  # with nothing in front look almost right, and the mistake surfaces at publish time.
  if(NOT _rc EQUAL 0 OR _ver STREQUAL "")
    message(FATAL_ERROR "mavericks_resolve_version: could not resolve the version\n${_err}")
  endif()

  set(${outvar} "${_ver}" PARENT_SCOPE)
endfunction()
