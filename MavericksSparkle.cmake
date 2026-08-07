# MavericksSparkle.cmake -- Sparkle auto-update tooling shared across mavericks-* products.
# No side effects on include (mirrors MavericksFetch.cmake). Provides:
#   mavericks_fetch_sparkle(<out_framework>)   -- fetch+thin Sparkle 1.27.3, return the .framework path
#   mavericks_add_updater_app(...)             -- build a Sparkle-hosting .app (Cocoa-only, NO Swift)
# The EdDSA signing tools are NOT built here -- use the prebuilt ed25519-keygen / ed25519-sign from
# mavericks-ed25519 (https://github.com/ModernMavericks/ed25519). Sign+appcast + payload staging are
# CI shell steps (not CMake functions) -- see each product's release workflow:
#   scripts/stage_updater.sh     -- stage the updater .app + LaunchAgent into a pkg payload,
#                                   rendering updater/{updatecheck.plist,postinstall}.in per product
#   scripts/sign_and_appcast.sh  -- sign a .pkg (via ed25519-sign) then emit appcast.xml (gen_appcast.sh)
set(MAVERICKS_SHARED_DIR "${CMAKE_CURRENT_LIST_DIR}" CACHE INTERNAL "mavericks-shipyard root")
include("${MAVERICKS_SHARED_DIR}/MavericksDecisions.cmake")   # mavericks_reject_placeholder_icon()

function(mavericks_fetch_sparkle out_var)
  # The Sparkle slice MUST match the arch of the updater that links it, so derive it from
  # CMAKE_OSX_ARCHITECTURES (x86_64 -> 10.9 Intel slice, arm64 -> Apple-Silicon slice, both
  # -> fat). A project never hand-plumbs the arch; a mismatch is impossible by construction.
  # An explicit MAVERICKS_SPARKLE_ARCH in the environment still wins (escape hatch).
  set(_arch "$ENV{MAVERICKS_SPARKLE_ARCH}")
  if(NOT _arch)
    if(CMAKE_OSX_ARCHITECTURES MATCHES "arm64" AND CMAKE_OSX_ARCHITECTURES MATCHES "x86_64")
      set(_arch all)
    elseif(CMAKE_OSX_ARCHITECTURES MATCHES "arm64")
      set(_arch arm64)
    else()
      set(_arch x86_64)
    endif()
  endif()
  execute_process(
    COMMAND ${CMAKE_COMMAND} -E env "MAVERICKS_SPARKLE_ARCH=${_arch}"
            sh "${MAVERICKS_SHARED_DIR}/scripts/fetch_sparkle_framework.sh"
    OUTPUT_VARIABLE _v OUTPUT_STRIP_TRAILING_WHITESPACE RESULT_VARIABLE _rc)
  if(NOT _rc EQUAL 0)
    message(FATAL_ERROR "fetch_sparkle_framework.sh failed (arch=${_arch})")
  endif()
  set(${out_var} "${_v}" PARENT_SCOPE)
endfunction()

# mavericks_add_updater_app(
#   NAME <target>  BUNDLE_ID <id>  FEED_URL <appcast url>
#   CONFIRM_TITLE <str>  CONFIRM_BODY <str>          # ^ the required (per-project) values
#   [ICON <path/to.icns> | ALLOW_GENERIC]   # a real icon (placeholder-gated), OR the generic macOS
#                                            # app icon on purpose (empty CFBundleIconFile, no artwork)
#   [PRODUCT_NAME <str>]        # default: NAME              (shown in Sparkle dialogs)
#   [VERSION <str>]             # default: ${PROJECT_VERSION}
#   [AUTO_CHECK <true|false>]   # default: true
#   [SPARKLE_FRAMEWORK <path>]  # default: mavericks_fetch_sparkle()
#   [LOG_PREFIX <str>]          # default: NAME
#   [RELAUNCH_MARKER <path>]    # default: /tmp/.<BUNDLE_ID>-relaunched
#   [ED_PUBKEY <base64> | ED_PUBKEY_FILE <path>]   # default: updater/ed25519_key.pub -> Info.plist SUPublicEDKey
#   [PANE_HINT_KEY <str>]  [POST_UPDATE_HELPER <abs path>])
# Builds ${CMAKE_BINARY_DIR}/<NAME>.app hosting Sparkle. Cocoa-only; links NO libswiftCore.
# PANE_HINT_KEY omitted/empty => background-found updates post an NSUserNotification (no-pane products).
# POST_UPDATE_HELPER: absolute path to an executable the updater runs (as the user) after a successful
# install + the confirmation -- for product-specific follow-up (e.g. offer to roll a VM onto a new image).
function(mavericks_add_updater_app)
  cmake_parse_arguments(A "ALLOW_GENERIC"
    "NAME;PRODUCT_NAME;BUNDLE_ID;FEED_URL;ED_PUBKEY;ED_PUBKEY_FILE;ICON;VERSION;AUTO_CHECK;SPARKLE_FRAMEWORK;LOG_PREFIX;CONFIRM_TITLE;CONFIRM_BODY;RELAUNCH_MARKER;PANE_HINT_KEY;POST_UPDATE_HELPER" "" ${ARGN})
  foreach(req NAME BUNDLE_ID FEED_URL CONFIRM_TITLE CONFIRM_BODY)
    if(NOT DEFINED A_${req})
      message(FATAL_ERROR "mavericks_add_updater_app: ${req} required")
    endif()
  endforeach()

  # Defaults for the mechanical args -- only NAME/BUNDLE_ID/FEED_URL/ICON/CONFIRM_TITLE/CONFIRM_BODY are required.
  if(NOT A_PRODUCT_NAME)
    set(A_PRODUCT_NAME "${A_NAME}")
  endif()
  if(NOT A_VERSION)
    set(A_VERSION "${PROJECT_VERSION}")
  endif()
  if(NOT DEFINED A_AUTO_CHECK)
    set(A_AUTO_CHECK "true")
  endif()
  if(NOT A_LOG_PREFIX)
    set(A_LOG_PREFIX "${A_NAME}")
  endif()
  if(NOT A_RELAUNCH_MARKER)
    set(A_RELAUNCH_MARKER "/tmp/.${A_BUNDLE_ID}-relaunched")
  endif()
  if(NOT A_SPARKLE_FRAMEWORK)
    mavericks_fetch_sparkle(A_SPARKLE_FRAMEWORK)
  endif()

  # EdDSA public key: an explicit ED_PUBKEY wins; else ED_PUBKEY_FILE; else the convention path
  # updater/ed25519_key.pub (where `mv ed25519_key.pub updater/` puts mavericks-ed25519's keygen output).
  if(NOT A_ED_PUBKEY)
    if(A_ED_PUBKEY_FILE)
      set(_pubfile "${A_ED_PUBKEY_FILE}")
    else()
      set(_pubfile "${CMAKE_SOURCE_DIR}/updater/ed25519_key.pub")
    endif()
    if(NOT EXISTS "${_pubfile}")
      message(FATAL_ERROR
        "mavericks_add_updater_app: no ED_PUBKEY and no pubkey file at ${_pubfile}. Generate a keypair "
        "(mavericks-ed25519 ed25519-keygen) and `mv ed25519_key.pub updater/`, or pass ED_PUBKEY / ED_PUBKEY_FILE.")
    endif()
    file(STRINGS "${_pubfile}" A_ED_PUBKEY LIMIT_COUNT 1)
  endif()

  # configure_file(@ONLY) substitution vars for the templates.
  set(MAVERICKS_EXECUTABLE      "${A_NAME}")
  set(MAVERICKS_PRODUCT_NAME    "${A_PRODUCT_NAME}")
  set(MAVERICKS_BUNDLE_ID       "${A_BUNDLE_ID}")
  set(MAVERICKS_FEED_URL        "${A_FEED_URL}")
  set(MAVERICKS_ED_PUBKEY       "${A_ED_PUBKEY}")
  set(MAVERICKS_VERSION         "${A_VERSION}")                   # display (CFBundleShortVersionString)
  # Sparkle compares CFBundleVersion (and the appcast's <sparkle:version>) with SUStandardVersionComparator,
  # which CANNOT order the "-mavericks.N" suffix: it reads 1.2.3-mavericks.3 and 1.2.3-mavericks.4 as EQUAL,
  # so a same-upstream repackage (every -mavericks.(N+1) ingredient/patch bump) is invisible to auto-update.
  # Give the comparator a numeric-only build version by turning "-mavericks." into ".", e.g.
  # 1.102.0-mavericks.4 -> 1.102.0.4. That orders correctly on BOTH axes (upstream and N), and an already
  # installed "-mavericks.N" host still sees a numeric appcast as newer (Sparkle ranks a number above the
  # "-mavericks" string), so existing installs self-migrate. Must match scripts/gen_appcast.sh.
  # Also normalize an OpenSSH-portable-style "pN" patch to ".N" (9.9p2 -> 9.9.2), order-preserving, so a
  # non-dotted-numeric upstream still yields an orderable CFBundleVersion.
  string(REPLACE "-mavericks." "." MAVERICKS_BUILD_VERSION "${A_VERSION}")
  string(REGEX REPLACE "([0-9])p([0-9])" "\\1.\\2" MAVERICKS_BUILD_VERSION "${MAVERICKS_BUILD_VERSION}")  # comparison (CFBundleVersion)
  set(MAVERICKS_AUTO_CHECK      "${A_AUTO_CHECK}")                 # plist: true|false
  set(MAVERICKS_LOG_PREFIX      "${A_LOG_PREFIX}")
  set(MAVERICKS_CONFIRM_TITLE   "${A_CONFIRM_TITLE}")
  set(MAVERICKS_CONFIRM_BODY    "${A_CONFIRM_BODY}")
  set(MAVERICKS_RELAUNCH_MARKER "${A_RELAUNCH_MARKER}")
  set(MAVERICKS_PANE_HINT_KEY   "${A_PANE_HINT_KEY}")              # empty => notification mode
  set(MAVERICKS_POST_UPDATE_HELPER "${A_POST_UPDATE_HELPER}")      # empty => no post-install hook
  # Icon decision (mirrors mavericks_require_icon): a real ICON is gated through the placeholder
  # guard; NO icon requires an explicit generic opt-in and ships the standard macOS app icon
  # (empty CFBundleIconFile) -- embedding no artwork at all.
  if(A_ICON)
    mavericks_reject_placeholder_icon("${A_NAME}" "${A_ICON}")
    get_filename_component(MAVERICKS_ICON_NAME "${A_ICON}" NAME_WE)
  elseif(A_ALLOW_GENERIC OR MAVERICKS_ALLOW_GENERIC_ICON)
    set(MAVERICKS_ICON_NAME "")   # empty CFBundleIconFile => generic macOS app icon, no artwork shipped
    message(STATUS "Mavericks: ${A_NAME} ships the GENERIC macOS app icon by explicit opt-in")
  else()
    message(FATAL_ERROR
      "mavericks_add_updater_app(${A_NAME}): no ICON. Provide ICON <path/to.icns>, or opt into the "
      "generic macOS app icon with ALLOW_GENERIC (or -DMAVERICKS_ALLOW_GENERIC_ICON=ON).")
  endif()
  # main.m needs the ObjC boolean form.
  if(A_AUTO_CHECK STREQUAL "true")
    set(MAVERICKS_AUTO_CHECK_OBJC "YES")
  else()
    set(MAVERICKS_AUTO_CHECK_OBJC "NO")
  endif()

  set(_app "${CMAKE_BINARY_DIR}/${A_NAME}.app")
  configure_file("${MAVERICKS_SHARED_DIR}/updater/Info.plist.in" "${CMAKE_BINARY_DIR}/${A_NAME}-Info.plist" @ONLY)
  configure_file("${MAVERICKS_SHARED_DIR}/updater/main.m.in"     "${CMAKE_BINARY_DIR}/${A_NAME}-main.m"      @ONLY)

  add_executable(${A_NAME} "${CMAKE_BINARY_DIR}/${A_NAME}-main.m")
  target_compile_options(${A_NAME} PRIVATE -fobjc-arc)
  target_include_directories(${A_NAME} PRIVATE "${MAVERICKS_SHARED_DIR}/updater")  # relaunch_decision.h
  target_link_libraries(${A_NAME} PRIVATE
    "-F${A_SPARKLE_FRAMEWORK}/.." "-framework Sparkle" "-framework Cocoa"
    "-Wl,-rpath,@executable_path/../Frameworks")

  add_custom_command(TARGET ${A_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_app}/Contents/MacOS
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_app}/Contents/Frameworks
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_app}/Contents/Resources
    COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:${A_NAME}> ${_app}/Contents/MacOS/${A_NAME}
    COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_BINARY_DIR}/${A_NAME}-Info.plist ${_app}/Contents/Info.plist
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${A_SPARKLE_FRAMEWORK} ${_app}/Contents/Frameworks/Sparkle.framework
    COMMENT "Assembling ${A_NAME}.app")
  if(A_ICON)
    add_custom_command(TARGET ${A_NAME} POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy ${A_ICON} ${_app}/Contents/Resources/${MAVERICKS_ICON_NAME}.icns
      COMMENT "Adding ${A_NAME}.app icon ${MAVERICKS_ICON_NAME}.icns")
  endif()
endfunction()
