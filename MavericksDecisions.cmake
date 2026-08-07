# MavericksDecisions.cmake -- forced explicit decisions (no silent defaults for
# decisions that matter). Currently: the app icon. include()d by Mavericks.cmake.
set(MAVERICKS_DECISIONS_DIR "${CMAKE_CURRENT_LIST_DIR}" CACHE INTERNAL "mavericks-shipyard root (decisions)")

# mavericks_reject_placeholder_icon(<target> <icns>)
#   FATAL if <icns> is a registered PLACEHOLDER (scripts/placeholder-icons.sha256), unless
#   MAVERICKS_ALLOW_GENERIC_ICON=ON (the explicit opt-in). A ModernMavericks product must not ship
#   a placeholder icon it never chose. The denylist path is overridable via
#   MAVERICKS_PLACEHOLDER_DENYLIST (for tests). Reused by mavericks_require_icon and the Sparkle
#   updater so BOTH icon entry points are gated.
function(mavericks_reject_placeholder_icon target icns)
  if(MAVERICKS_ALLOW_GENERIC_ICON)
    return()
  endif()
  set(_denylist "${MAVERICKS_DECISIONS_DIR}/scripts/placeholder-icons.sha256")
  if(MAVERICKS_PLACEHOLDER_DENYLIST)
    set(_denylist "${MAVERICKS_PLACEHOLDER_DENYLIST}")
  endif()
  if(NOT EXISTS "${_denylist}" OR NOT EXISTS "${icns}")
    return()
  endif()
  file(SHA256 "${icns}" _icnshash)
  string(TOLOWER "${_icnshash}" _icnshash)
  file(STRINGS "${_denylist}" _lines)
  foreach(_line IN LISTS _lines)
    string(STRIP "${_line}" _line)
    if(_line STREQUAL "" OR _line MATCHES "^#")
      continue()
    endif()
    string(REGEX MATCH "^[0-9a-fA-F]+" _banned "${_line}")
    string(TOLOWER "${_banned}" _banned)
    if(_banned STREQUAL _icnshash)
      message(FATAL_ERROR
        "mavericks: ${target} ships a known PLACEHOLDER icon (${icns}, sha256 ${_icnshash}). "
        "Replace it with real artwork, or set -DMAVERICKS_ALLOW_GENERIC_ICON=ON to ship a generic "
        "icon on purpose. ModernMavericks products must not ship an unopted placeholder icon.")
    endif()
  endforeach()
endfunction()

# mavericks_require_icon(TARGET <t> [ICNS <path>] [ALLOW_GENERIC])
#   Gate + wiring for a bundle's app icon. Exactly one of:
#     * ICNS <path> that EXISTS  -> bundle it (MACOSX_BUNDLE_ICON_FILE) -- the real icon.
#     * ALLOW_GENERIC (or -DMAVERICKS_ALLOW_GENERIC_ICON=ON) -> ship generic ON PURPOSE.
#     * neither -> FATAL_ERROR: you must decide.
#   ICNS given but missing (e.g. container-extraction failed) is also FATAL -- never
#   silently iconless.
function(mavericks_require_icon)
  cmake_parse_arguments(MRI "ALLOW_GENERIC" "TARGET;ICNS" "" ${ARGN})
  if(NOT MRI_TARGET)
    message(FATAL_ERROR "mavericks_require_icon: TARGET is required")
  endif()
  if(MRI_ICNS)
    if(NOT EXISTS "${MRI_ICNS}")
      message(FATAL_ERROR
        "mavericks_require_icon(${MRI_TARGET}): declared icon '${MRI_ICNS}' does not exist "
        "-- it wasn't produced (e.g. the source container was down and extraction failed). "
        "Bring the source up and re-configure, or set -DMAVERICKS_ALLOW_GENERIC_ICON=ON to "
        "ship the generic icon on purpose. Refusing to build ${MRI_TARGET} with no/wrong icon.")
    endif()
    if(NOT MRI_ALLOW_GENERIC)
      mavericks_reject_placeholder_icon("${MRI_TARGET}" "${MRI_ICNS}")   # a real path that is a placeholder still FATALs
    endif()
    get_filename_component(_mri_name "${MRI_ICNS}" NAME)
    set_source_files_properties("${MRI_ICNS}" PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
    target_sources(${MRI_TARGET} PRIVATE "${MRI_ICNS}")
    set_target_properties(${MRI_TARGET} PROPERTIES MACOSX_BUNDLE_ICON_FILE "${_mri_name}")
    message(STATUS "Mavericks: ${MRI_TARGET} ships app icon ${_mri_name}")
    return()
  endif()
  if(MRI_ALLOW_GENERIC OR MAVERICKS_ALLOW_GENERIC_ICON)
    message(STATUS "Mavericks: ${MRI_TARGET} ships the GENERIC icon by explicit opt-in")
    return()
  endif()
  message(FATAL_ERROR
    "mavericks_require_icon(${MRI_TARGET}): no icon decided. Provide ICNS <path/to.icns>, "
    "or opt into generic with ALLOW_GENERIC (or -DMAVERICKS_ALLOW_GENERIC_ICON=ON). "
    "ModernMavericks apps must make an explicit icon decision.")
endfunction()
