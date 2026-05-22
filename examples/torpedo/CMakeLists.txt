cmake_minimum_required(VERSION 3.16)
project(torpedo_examples CXX)

# ---------------------------------------------------------------------------
# Locate the Nim-built shared library and generated header
# ---------------------------------------------------------------------------
# CBOR is the only FFI mode (the native codegen was retired — see
# doc/design/CBOR_Refactoring.md). TORPEDOLIB_DIR can be overridden at
# configure time; by default it points at the standard
# -d:BrokerFfiApi build output and the C++ target pulls in jsoncons
# headers.
if(NOT TORPEDOLIB_DIR)
    set(TORPEDOLIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/nimlib/build")
endif()

get_filename_component(TORPEDOLIB_DIRNAME "${TORPEDOLIB_DIR}" NAME)
get_filename_component(TORPEDOLIB_DIR "${TORPEDOLIB_DIR}" ABSOLUTE)

if(NOT EXISTS "${TORPEDOLIB_DIR}/torpedolib.h")
    message(FATAL_ERROR
        "torpedolib.h not found in ${TORPEDOLIB_DIR}.\n"
        "Run  nimble buildTorpedoExample  first to build the Nim library.")
endif()

# Import the Nim-built shared library as a CMake target
add_library(torpedolib SHARED IMPORTED)
set_target_properties(torpedolib PROPERTIES
    IMPORTED_LOCATION "${TORPEDOLIB_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}torpedolib${CMAKE_SHARED_LIBRARY_SUFFIX}"
    INTERFACE_INCLUDE_DIRECTORIES "${TORPEDOLIB_DIR}"
)
if(APPLE)
    set_target_properties(torpedolib PROPERTIES
        IMPORTED_SONAME "@rpath/libtorpedolib.dylib"
    )
endif()
if(WIN32)
    # Linking a SHARED IMPORTED target on Windows needs the import library
    # (.lib) in addition to the runtime DLL — Nim emits both alongside.
    set_target_properties(torpedolib PROPERTIES
        IMPORTED_IMPLIB "${TORPEDOLIB_DIR}/torpedolib.lib"
    )
endif()

# ---------------------------------------------------------------------------
# Modern C++ example
# ---------------------------------------------------------------------------
add_executable(torpedo_cpp cpp_example/main.cpp)
set_target_properties(torpedo_cpp PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
    OUTPUT_NAME torpedo
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/cpp_example/build"
)

# Detect the architecture of the Nim-built .so and force the C++ compiler
# to match (same rationale as typemappingtestlib CMakeLists.txt).
if(UNIX AND NOT APPLE)
    set(SO_PATH "${TORPEDOLIB_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}torpedolib${CMAKE_SHARED_LIBRARY_SUFFIX}")
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
                target_compile_options(torpedo_cpp PRIVATE -m64)
                target_link_options(torpedo_cpp PRIVATE -m64)
            elseif(CMAKE_SIZEOF_VOID_P EQUAL 8 AND LIB_BITS EQUAL 32)
                message(STATUS "Nim library is 32-bit, forcing C++ compiler to match")
                target_compile_options(torpedo_cpp PRIVATE -m32)
                target_link_options(torpedo_cpp PRIVATE -m32)
            endif()
        endif()
    endif()
endif()

target_link_libraries(torpedo_cpp PRIVATE torpedolib)

# Header-only jsoncons for CBOR encode/decode in <torpedolib>.hpp.
target_include_directories(torpedo_cpp PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/../../vendor/jsoncons/include")

if(APPLE)
    set_target_properties(torpedo_cpp PROPERTIES
        BUILD_RPATH "@loader_path/../../nimlib/${TORPEDOLIB_DIRNAME}"
        INSTALL_RPATH "@loader_path/../../nimlib/${TORPEDOLIB_DIRNAME}"
    )
elseif(UNIX)
    set_target_properties(torpedo_cpp PROPERTIES
        BUILD_RPATH "$ORIGIN/../../nimlib/${TORPEDOLIB_DIRNAME}"
        INSTALL_RPATH "$ORIGIN/../../nimlib/${TORPEDOLIB_DIRNAME}"
    )
endif()

# ---------------------------------------------------------------------------
# Windows: copy the DLL next to the executable so it can be run directly
# ---------------------------------------------------------------------------
if(WIN32)
    add_custom_command(TARGET torpedo_cpp POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${TORPEDOLIB_DIR}/torpedolib.dll"
            "$<TARGET_FILE_DIR:torpedo_cpp>/torpedolib.dll"
        COMMENT "Copying torpedolib.dll next to C++ example"
    )
endif()
