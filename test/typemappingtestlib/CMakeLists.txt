cmake_minimum_required(VERSION 3.16)
project(typemappingtestlib_cpp_test CXX)

option(ASAN "Enable AddressSanitizer (requires clang)" OFF)

# ---------------------------------------------------------------------------
# Locate the Nim-built shared library and generated C++ header
# ---------------------------------------------------------------------------
# TYPEMAPTEST_DIR can be overridden at configure time; defaults to build/
# relative to this CMakeLists.txt.
if(NOT TYPEMAPTEST_DIR)
    set(TYPEMAPTEST_DIR "${CMAKE_CURRENT_SOURCE_DIR}/build")
endif()

get_filename_component(TYPEMAPTEST_DIR "${TYPEMAPTEST_DIR}" ABSOLUTE)

if(NOT EXISTS "${TYPEMAPTEST_DIR}/typemappingtestlib.hpp")
    message(FATAL_ERROR
        "typemappingtestlib.hpp not found in ${TYPEMAPTEST_DIR}.\n"
        "Run  nimble buildTypeMapTestLib  first.")
endif()

add_library(typemappingtestlib SHARED IMPORTED)
set_target_properties(typemappingtestlib PROPERTIES
    IMPORTED_LOCATION
        "${TYPEMAPTEST_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}typemappingtestlib${CMAKE_SHARED_LIBRARY_SUFFIX}"
    INTERFACE_INCLUDE_DIRECTORIES "${TYPEMAPTEST_DIR}"
)
if(APPLE)
    set_target_properties(typemappingtestlib PROPERTIES
        IMPORTED_SONAME "@rpath/libtypemappingtestlib.dylib"
    )
endif()
if(WIN32)
    # Linking against a SHARED IMPORTED target on Windows needs the import
    # library (.lib), not just the runtime DLL referenced by IMPORTED_LOCATION.
    # Nim emits typemappingtestlib.lib alongside the .dll in TYPEMAPTEST_DIR.
    set_target_properties(typemappingtestlib PROPERTIES
        IMPORTED_IMPLIB "${TYPEMAPTEST_DIR}/typemappingtestlib.lib"
    )
endif()

# ---------------------------------------------------------------------------
# C++ test binary
# ---------------------------------------------------------------------------
add_executable(test_typemappingtestlib test_typemappingtestlib.cpp)
set_target_properties(test_typemappingtestlib PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
    RUNTIME_OUTPUT_DIRECTORY "${TYPEMAPTEST_DIR}"
)

# Detect the architecture of the Nim-built .so and force the C++ compiler
# to match.  On Linux i386 CI the Nim compiler (a 64-bit binary) produces a
# 64-bit .so while gcc defaults to 32-bit — linking fails with "file in
# wrong format" unless we pass -m64.
if(UNIX AND NOT APPLE)
    set(SO_PATH "${TYPEMAPTEST_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}typemappingtestlib${CMAKE_SHARED_LIBRARY_SUFFIX}")
    if(EXISTS "${SO_PATH}")
        execute_process(
            COMMAND file "${SO_PATH}"
            OUTPUT_VARIABLE SO_FILE_INFO
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
        )
        if(SO_FILE_INFO MATCHES "ELF 64-bit")
            set(LIB_BITS 64)
        elseif(SO_FILE_INFO MATCHES "ELF 32-bit")
            set(LIB_BITS 32)
        endif()

        if(DEFINED LIB_BITS)
            if(CMAKE_SIZEOF_VOID_P EQUAL 4 AND LIB_BITS EQUAL 64)
                message(STATUS "Nim library is 64-bit, forcing C++ compiler to match")
                target_compile_options(test_typemappingtestlib PRIVATE -m64)
                target_link_options(test_typemappingtestlib PRIVATE -m64)
            elseif(CMAKE_SIZEOF_VOID_P EQUAL 8 AND LIB_BITS EQUAL 32)
                message(STATUS "Nim library is 32-bit, forcing C++ compiler to match")
                target_compile_options(test_typemappingtestlib PRIVATE -m32)
                target_link_options(test_typemappingtestlib PRIVATE -m32)
            endif()
        endif()
    endif()
endif()

if(ASAN)
    if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        message(WARNING "ASAN=ON but compiler is not clang — results may vary")
    endif()
    target_compile_options(test_typemappingtestlib PRIVATE -fsanitize=address -fno-omit-frame-pointer)
    target_link_options(test_typemappingtestlib PRIVATE -fsanitize=address)
    if(WIN32)
        # CRT alignment is handled at configure time via
        # CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL — see brokers.nimble's
        # cmakeWindowsConfigureExtras(). Only the ASAN-specific PDB flags
        # remain here, since debug-info format is per-target.
        target_compile_options(test_typemappingtestlib PRIVATE -gcodeview)
        target_link_options(test_typemappingtestlib PRIVATE -Wl,/debug)
    endif()
endif()

target_link_libraries(test_typemappingtestlib PRIVATE typemappingtestlib)

# Embed RPATH so the binary finds libtypemappingtestlib next to itself at runtime.
if(APPLE)
    set_target_properties(test_typemappingtestlib PROPERTIES
        BUILD_RPATH  "@loader_path"
        INSTALL_RPATH "@loader_path"
    )
elseif(UNIX)
    set_target_properties(test_typemappingtestlib PROPERTIES
        BUILD_RPATH  "$ORIGIN"
        INSTALL_RPATH "$ORIGIN"
    )
endif()

# Windows: copy the DLL next to the test binary
if(WIN32)
    add_custom_command(TARGET test_typemappingtestlib POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${TYPEMAPTEST_DIR}/typemappingtestlib.dll"
            "$<TARGET_FILE_DIR:test_typemappingtestlib>/typemappingtestlib.dll"
        COMMENT "Copying typemappingtestlib.dll next to test binary"
    )
endif()
