cmake_minimum_required(VERSION 3.16)
project(mylibcbor_cpp_example CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# The Nim build emits libmylibcbor.* + mylibcbor.h + mylibcbor.hpp into
# ../nimlib/build/ — see brokers.nimble's buildFfiCborExample task.
set(NIMLIB_BUILD "${CMAKE_CURRENT_SOURCE_DIR}/../nimlib/build")
set(JSONCONS_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/../../../vendor/jsoncons/include")

if(NOT EXISTS "${NIMLIB_BUILD}/mylibcbor.hpp")
  message(FATAL_ERROR
    "${NIMLIB_BUILD}/mylibcbor.hpp not found — run `nimble buildFfiCborExample` first.")
endif()
if(NOT EXISTS "${JSONCONS_INCLUDE}/jsoncons/json.hpp")
  message(FATAL_ERROR
    "jsoncons headers not found at ${JSONCONS_INCLUDE} — run `git -C vendor clone --depth 1 https://github.com/danielaparker/jsoncons.git` first.")
endif()

add_executable(mylibcbor_cpp_example src/main.cpp)
target_include_directories(mylibcbor_cpp_example PRIVATE
  "${NIMLIB_BUILD}"
  "${JSONCONS_INCLUDE}")

# Link against the Nim-built shared library and rpath it so the binary
# can find it at runtime when invoked from the build directory.
add_library(mylibcbor SHARED IMPORTED)
if(APPLE)
  set_target_properties(mylibcbor PROPERTIES
    IMPORTED_LOCATION "${NIMLIB_BUILD}/libmylibcbor.dylib")
elseif(UNIX)
  set_target_properties(mylibcbor PROPERTIES
    IMPORTED_LOCATION "${NIMLIB_BUILD}/libmylibcbor.so")
elseif(WIN32)
  set_target_properties(mylibcbor PROPERTIES
    IMPORTED_LOCATION "${NIMLIB_BUILD}/mylibcbor.dll"
    IMPORTED_IMPLIB   "${NIMLIB_BUILD}/mylibcbor.lib")
endif()

target_link_libraries(mylibcbor_cpp_example PRIVATE mylibcbor)
set_target_properties(mylibcbor_cpp_example PROPERTIES
  BUILD_RPATH   "${NIMLIB_BUILD}"
  INSTALL_RPATH "${NIMLIB_BUILD}")
