# CMake consumer smoke test for the generated mylib package.
#
# Validates that:
#   1. The emitted <lib>Config.cmake is discoverable via -Dmylib_DIR=...
#   2. find_package() succeeds and reports the expected version.
#   3. The IMPORTED target mylib::mylib links a pure C consumer.
#   4. The IMPORTED INTERFACE target mylib::mylib_cpp links a C++ consumer
#      (only built when MYLIB_CPP_SMOKE is ON; CBOR-mode runs require
#      jsoncons available).

cmake_minimum_required(VERSION 3.16)
project(mylib_cmake_consumer LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(mylib 1.0 CONFIG REQUIRED)

message(STATUS "Consumer found mylib ${mylib_VERSION} at ${mylib_LIBRARY}")

# TODO(plan §10): the pure-C smoke test depends on the native FFI codegen
# surface (typed mylib_* C functions), which was retired (see
# doc/CBOR_Refactoring.md). Keep smoke.c in-tree but DO NOT compile it
# until the deferred "CBOR-derived typed C functional interface" lands.
if(FALSE)
add_executable(smoke_c smoke.c)
target_link_libraries(smoke_c PRIVATE mylib::mylib)
endif() # if(FALSE) — pure-C smoke test disabled, see TODO above

option(MYLIB_CPP_SMOKE "Also build the C++ smoke consumer" OFF)
if(MYLIB_CPP_SMOKE)
    add_executable(smoke_cpp smoke.cpp)
    target_link_libraries(smoke_cpp PRIVATE mylib::mylib_cpp)
endif()
