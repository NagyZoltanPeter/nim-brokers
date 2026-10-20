cmake_minimum_required(VERSION 3.16)
project(extapi_examples C CXX)

# EXTAPI examples (doc/design/EXTAPI_PLAN.md §14), C++ side:
#   storage_cpp_plugin  — the `storage` plugin (exe mode, loaded by the Nim host)
#   codec_cpp           — a plain C-ABI library imported by the Nim host
#   storage_cpp_host_lib — lib mode: hosts libstoragelib and implements `notes`
#
# Generated headers come from the Nim builds (see `nimble runExtExampleCpp`):
#   nimhost/build : storage_ext.hpp, storage_ext.h, broker_ext.h
#   nimlib/build  : notes_ext.hpp, storagelib.hpp, libstoragelib

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

get_filename_component(REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(JSONCONS_INCLUDE "${REPO_ROOT}/vendor/jsoncons/include")
set(NIMHOST_GEN "${CMAKE_CURRENT_SOURCE_DIR}/nimhost/build")
set(NIMLIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/nimlib/build")

if(NOT EXISTS "${JSONCONS_INCLUDE}/jsoncons/json.hpp")
  message(FATAL_ERROR "jsoncons not found — run `nimble fetchVendor` first.")
endif()
foreach(f "${NIMHOST_GEN}/storage_ext.hpp" "${NIMLIB_DIR}/notes_ext.hpp")
  if(NOT EXISTS "${f}")
    message(FATAL_ERROR "${f} missing — run `nimble runExtExampleCpp` (it builds the Nim side first).")
  endif()
endforeach()

# --- storage plugin (exe mode) ----------------------------------------------
add_library(storage_cpp_plugin SHARED cpp_plugin/plugin.cpp)
target_include_directories(storage_cpp_plugin PRIVATE "${NIMHOST_GEN}" "${JSONCONS_INCLUDE}")
set_target_properties(storage_cpp_plugin PROPERTIES CXX_VISIBILITY_PRESET hidden)
if(UNIX)
  find_package(Threads REQUIRED)
  target_link_libraries(storage_cpp_plugin PRIVATE Threads::Threads)
endif()

# --- codec: C-ABI library imported by the Nim host ---------------------------
add_library(codec_cpp SHARED cpp_cimport/codec.cpp)
set_target_properties(codec_cpp PROPERTIES CXX_VISIBILITY_PRESET hidden)

# --- lib mode host app --------------------------------------------------------
add_library(storagelib SHARED IMPORTED)
set_target_properties(storagelib PROPERTIES
  IMPORTED_LOCATION "${NIMLIB_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}storagelib${CMAKE_SHARED_LIBRARY_SUFFIX}"
  INTERFACE_INCLUDE_DIRECTORIES "${NIMLIB_DIR}")
if(APPLE)
  set_target_properties(storagelib PROPERTIES IMPORTED_SONAME "@rpath/libstoragelib.dylib")
endif()
if(WIN32)
  set_target_properties(storagelib PROPERTIES IMPORTED_IMPLIB "${NIMLIB_DIR}/storagelib.lib")
endif()

add_executable(storage_cpp_host_lib cpp_host_lib/main.cpp)
target_include_directories(storage_cpp_host_lib PRIVATE "${NIMLIB_DIR}" "${JSONCONS_INCLUDE}")
target_link_libraries(storage_cpp_host_lib PRIVATE storagelib)
set_target_properties(storage_cpp_host_lib PROPERTIES
  BUILD_RPATH "${NIMLIB_DIR}"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
if(UNIX)
  target_link_libraries(storage_cpp_host_lib PRIVATE Threads::Threads)
endif()
if(WIN32)
  # No rpath on Windows: the loader looks next to the exe.
  add_custom_command(TARGET storage_cpp_host_lib POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${NIMLIB_DIR}/storagelib.dll"
      "$<TARGET_FILE_DIR:storage_cpp_host_lib>/storagelib.dll"
    COMMENT "Copying storagelib.dll next to storage_cpp_host_lib")
endif()
