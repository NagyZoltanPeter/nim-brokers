cmake_minimum_required(VERSION 3.16)
project(pytestlib_cpp_test CXX)

# ---------------------------------------------------------------------------
# Locate the Nim-built shared library and generated C++ header
# ---------------------------------------------------------------------------
# PYTESTLIB_DIR can be overridden at configure time; defaults to build/
# relative to this CMakeLists.txt.
if(NOT PYTESTLIB_DIR)
    set(PYTESTLIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/build")
endif()

get_filename_component(PYTESTLIB_DIR "${PYTESTLIB_DIR}" ABSOLUTE)

if(NOT EXISTS "${PYTESTLIB_DIR}/pytestlib.hpp")
    message(FATAL_ERROR
        "pytestlib.hpp not found in ${PYTESTLIB_DIR}.\n"
        "Run  nimble buildPyTestLib  first.")
endif()

add_library(pytestlib SHARED IMPORTED)
set_target_properties(pytestlib PROPERTIES
    IMPORTED_LOCATION
        "${PYTESTLIB_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}pytestlib${CMAKE_SHARED_LIBRARY_SUFFIX}"
    INTERFACE_INCLUDE_DIRECTORIES "${PYTESTLIB_DIR}"
)
if(APPLE)
    set_target_properties(pytestlib PROPERTIES
        IMPORTED_SONAME "@rpath/libpytestlib.dylib"
    )
endif()

# ---------------------------------------------------------------------------
# C++ test binary
# ---------------------------------------------------------------------------
add_executable(test_pytestlib test_pytestlib.cpp)
set_target_properties(test_pytestlib PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
    RUNTIME_OUTPUT_DIRECTORY "${PYTESTLIB_DIR}"
)
target_link_libraries(test_pytestlib PRIVATE pytestlib)

# Embed RPATH so the binary finds libpytestlib next to itself at runtime.
if(APPLE)
    set_target_properties(test_pytestlib PROPERTIES
        BUILD_RPATH  "@loader_path"
        INSTALL_RPATH "@loader_path"
    )
elseif(UNIX)
    set_target_properties(test_pytestlib PROPERTIES
        BUILD_RPATH  "$ORIGIN"
        INSTALL_RPATH "$ORIGIN"
    )
endif()

# Windows: copy the DLL next to the test binary
if(WIN32)
    add_custom_command(TARGET test_pytestlib POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${PYTESTLIB_DIR}/pytestlib.dll"
            "$<TARGET_FILE_DIR:test_pytestlib>/pytestlib.dll"
        COMMENT "Copying pytestlib.dll next to test binary"
    )
endif()
