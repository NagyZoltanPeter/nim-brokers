cmake_minimum_required(VERSION 3.16)
project(typemappingtestlib_cbor_cpp_test CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Set by brokers.nimble on the macOS + Nim 2.2.4 + refc + debug combo to
# compile-time-skip stress tests that would otherwise trip the upstream
# stdlib Channel[T].send regression. See LIMITATION.md.
option(BROKER_TESTS_SKIP_FRAGILE_REFC_BURSTS
       "Skip cross-thread stress tests known to trip Nim 2.2.4 macOS refc debug" OFF)

# The Nim build emits libtypemappingtestlib_cbor.* + .h + .hpp into
# build/ — see brokers.nimble's buildTypeMapTestLibCbor task.
set(NIMLIB_BUILD "${CMAKE_CURRENT_SOURCE_DIR}/build")
set(JSONCONS_INCLUDE
    "${CMAKE_CURRENT_SOURCE_DIR}/../../vendor/jsoncons/include")

if(NOT EXISTS "${NIMLIB_BUILD}/typemappingtestlib_cbor.hpp")
  message(FATAL_ERROR
    "${NIMLIB_BUILD}/typemappingtestlib_cbor.hpp not found — "
    "run `nimble buildTypeMapTestLibCbor` first.")
endif()
if(NOT EXISTS "${JSONCONS_INCLUDE}/jsoncons/json.hpp")
  message(FATAL_ERROR
    "jsoncons headers not found at ${JSONCONS_INCLUDE} — "
    "checkout submodules under vendor/.")
endif()

add_executable(test_typemappingtestlib_cbor test_typemappingtestlib_cbor.cpp)
target_include_directories(test_typemappingtestlib_cbor PRIVATE
  "${NIMLIB_BUILD}"
  "${JSONCONS_INCLUDE}")

if(BROKER_TESTS_SKIP_FRAGILE_REFC_BURSTS)
  target_compile_definitions(test_typemappingtestlib_cbor PRIVATE
    BROKER_TESTS_SKIP_FRAGILE_REFC_BURSTS=1)
endif()

add_library(typemappingtestlib_cbor SHARED IMPORTED)
if(APPLE)
  set_target_properties(typemappingtestlib_cbor PROPERTIES
    IMPORTED_LOCATION "${NIMLIB_BUILD}/libtypemappingtestlib_cbor.dylib")
elseif(UNIX)
  set_target_properties(typemappingtestlib_cbor PROPERTIES
    IMPORTED_LOCATION "${NIMLIB_BUILD}/libtypemappingtestlib_cbor.so")
elseif(WIN32)
  set_target_properties(typemappingtestlib_cbor PROPERTIES
    IMPORTED_LOCATION "${NIMLIB_BUILD}/typemappingtestlib_cbor.dll"
    IMPORTED_IMPLIB   "${NIMLIB_BUILD}/typemappingtestlib_cbor.lib")
endif()

target_link_libraries(test_typemappingtestlib_cbor
  PRIVATE typemappingtestlib_cbor)
set_target_properties(test_typemappingtestlib_cbor PROPERTIES
  BUILD_RPATH   "${NIMLIB_BUILD}"
  INSTALL_RPATH "${NIMLIB_BUILD}")
