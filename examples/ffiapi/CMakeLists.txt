cmake_minimum_required(VERSION 3.16)
project(mylib_examples C CXX)

# ---------------------------------------------------------------------------
# Locate the Nim-built shared library and generated header
# ---------------------------------------------------------------------------
# CBOR is the only FFI mode (the native codegen was retired — see
# doc/CBOR_Refactoring.md). MYLIB_DIR can still be overridden at configure
# time; by default it points at the -d:BrokerFfiApiCBOR build output.
if(NOT MYLIB_DIR)
    set(MYLIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/nimlib/build_cbor")
endif()

# Subdir name used for embedded RPATH — keeps the example binary
# discovering the right .dylib/.so without requiring LD_LIBRARY_PATH.
get_filename_component(MYLIB_DIRNAME "${MYLIB_DIR}" NAME)

# Resolve to absolute so downstream targets work regardless of build dir
get_filename_component(MYLIB_DIR "${MYLIB_DIR}" ABSOLUTE)

if(NOT EXISTS "${MYLIB_DIR}/mylib.h")
    message(FATAL_ERROR
        "mylib.h not found in ${MYLIB_DIR}.\n"
        "Run  nimble buildFfiExample  first to build the Nim library.")
endif()

# Import the Nim-built shared library as a CMake target
add_library(mylib SHARED IMPORTED)
set_target_properties(mylib PROPERTIES
    IMPORTED_LOCATION "${MYLIB_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}mylib${CMAKE_SHARED_LIBRARY_SUFFIX}"
    INTERFACE_INCLUDE_DIRECTORIES "${MYLIB_DIR}"
)
# macOS: the dylib has an install name — help the linker find it at runtime
if(APPLE)
    set_target_properties(mylib PROPERTIES
        IMPORTED_SONAME "@rpath/libmylib.dylib"
    )
endif()
if(WIN32)
    # Linking a SHARED IMPORTED target on Windows needs the import library
    # (.lib) in addition to the runtime DLL — Nim emits both alongside.
    set_target_properties(mylib PROPERTIES
        IMPORTED_IMPLIB "${MYLIB_DIR}/mylib.lib"
    )
endif()

# ---------------------------------------------------------------------------
# Pure C example
# ---------------------------------------------------------------------------
# TODO(plan §10): the native FFI codegen surface was retired (see
# doc/CBOR_Refactoring.md). Pure-C consumers temporarily have only the raw
# 11-function CBOR ABI — they would have to hand-encode CBOR against it.
# The deferred "CBOR-derived typed C functional interface" will restore
# this example. Until then, keep `example/main.c` in-tree but DO NOT compile
# it so the build does not break in surprising ways.
if(FALSE)
add_executable(example_c example/main.c)
set_target_properties(example_c PROPERTIES
    C_STANDARD 11
    C_STANDARD_REQUIRED ON
    OUTPUT_NAME example
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/example/build"
)

# Detect the architecture of the Nim-built .so and force the C/C++ compiler
# to match.  On Linux i386 CI the Nim compiler (a 64-bit binary) produces a
# 64-bit .so while gcc defaults to 32-bit — linking fails with "file in
# wrong format" unless we pass -m64.
if(UNIX AND NOT APPLE)
    set(SO_PATH "${MYLIB_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}mylib${CMAKE_SHARED_LIBRARY_SUFFIX}")
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
                message(STATUS "Nim library is 64-bit, forcing C/C++ compiler to match")
                target_compile_options(example_c PRIVATE -m64)
                target_link_options(example_c PRIVATE -m64)
            elseif(CMAKE_SIZEOF_VOID_P EQUAL 8 AND LIB_BITS EQUAL 32)
                message(STATUS "Nim library is 32-bit, forcing C/C++ compiler to match")
                target_compile_options(example_c PRIVATE -m32)
                target_link_options(example_c PRIVATE -m32)
            endif()
        endif()
    endif()
endif()

target_link_libraries(example_c PRIVATE mylib)

# RPATH: embed the path to the shared library so the binary runs in-tree
if(APPLE)
    set_target_properties(example_c PROPERTIES
        BUILD_RPATH "@loader_path/../../nimlib/${MYLIB_DIRNAME}"
        INSTALL_RPATH "@loader_path/../../nimlib/${MYLIB_DIRNAME}"
    )
elseif(UNIX)
    set_target_properties(example_c PROPERTIES
        BUILD_RPATH "$ORIGIN/../../nimlib/${MYLIB_DIRNAME}"
        INSTALL_RPATH "$ORIGIN/../../nimlib/${MYLIB_DIRNAME}"
    )
endif()
endif() # if(FALSE) — pure-C example disabled, see TODO above

# ---------------------------------------------------------------------------
# Modern C++ example
# ---------------------------------------------------------------------------
add_executable(example_cpp cpp_example/main.cpp)
set_target_properties(example_cpp PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
    OUTPUT_NAME example
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/cpp_example/build"
)

# Same architecture detection as the C example above.
if(UNIX AND NOT APPLE)
    set(SO_PATH "${MYLIB_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}mylib${CMAKE_SHARED_LIBRARY_SUFFIX}")
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
                target_compile_options(example_cpp PRIVATE -m64)
                target_link_options(example_cpp PRIVATE -m64)
            elseif(CMAKE_SIZEOF_VOID_P EQUAL 8 AND LIB_BITS EQUAL 32)
                message(STATUS "Nim library is 32-bit, forcing C++ compiler to match")
                target_compile_options(example_cpp PRIVATE -m32)
                target_link_options(example_cpp PRIVATE -m32)
            endif()
        endif()
    endif()
endif()

target_link_libraries(example_cpp PRIVATE mylib)

# Header-only jsoncons for CBOR encode/decode in <mylib>.hpp.
target_include_directories(example_cpp PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/../../vendor/jsoncons/include")

if(APPLE)
    set_target_properties(example_cpp PROPERTIES
        BUILD_RPATH "@loader_path/../../nimlib/${MYLIB_DIRNAME}"
        INSTALL_RPATH "@loader_path/../../nimlib/${MYLIB_DIRNAME}"
    )
elseif(UNIX)
    set_target_properties(example_cpp PROPERTIES
        BUILD_RPATH "$ORIGIN/../../nimlib/${MYLIB_DIRNAME}"
        INSTALL_RPATH "$ORIGIN/../../nimlib/${MYLIB_DIRNAME}"
    )
endif()

# ---------------------------------------------------------------------------
# Windows: copy the DLL next to the executables so they can be run directly
# ---------------------------------------------------------------------------
if(WIN32)
    # NB: pure-C example_c target is gated off (see TODO above); its DLL
    # copy step lives with it once the typed C wrapper is restored.
    add_custom_command(TARGET example_cpp POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${MYLIB_DIR}/mylib.dll"
            "$<TARGET_FILE_DIR:example_cpp>/mylib.dll"
        COMMENT "Copying mylib.dll next to C++ example"
    )
endif()
