# MavericksFetch.cmake -- defines mavericks_fetch_sdk(). No side effects, so a
# consumer can include just this module without the compiler gate / mode check.
set(MAVERICKS_SHARED_DIR "${CMAKE_CURRENT_LIST_DIR}" CACHE INTERNAL "mavericks-shipyard root")

# mavericks_fetch_sdk(<out_var>): fetch+cache+verify the pinned MacOSX10.9 SDK
# (cross builds only) and return its root in out_var. Native builds use the system SDK.
function(mavericks_fetch_sdk out_var)
  execute_process(
    COMMAND sh "${MAVERICKS_SHARED_DIR}/scripts/fetch_sdk.sh"
    OUTPUT_VARIABLE _sdk OUTPUT_STRIP_TRAILING_WHITESPACE RESULT_VARIABLE _rc)
  if(NOT _rc EQUAL 0)
    message(FATAL_ERROR "fetch_sdk.sh failed")
  endif()
  set(${out_var} "${_sdk}" PARENT_SCOPE)
endfunction()
