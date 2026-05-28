cmake_minimum_required(VERSION 3.16)
project(hierlib_examples CXX)

# Locate the Nim-built shared library + generated header (built by
# `nimble buildHierExample`). HIERLIB_DIR can be overridden at configure time.
if(NOT HIERLIB_DIR)
    set(HIERLIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/nimlib/build")
endif()
get_filename_component(HIERLIB_DIRNAME "${HIERLIB_DIR}" NAME)
get_filename_component(HIERLIB_DIR "${HIERLIB_DIR}" ABSOLUTE)

if(NOT EXISTS "${HIERLIB_DIR}/hierlib.h")
    message(FATAL_ERROR
        "hierlib.h not found in ${HIERLIB_DIR}.\n"
        "Run  nimble buildHierExample  first to build the Nim library.")
endif()

add_library(hierlib SHARED IMPORTED)
set_target_properties(hierlib PROPERTIES
    IMPORTED_LOCATION "${HIERLIB_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}hierlib${CMAKE_SHARED_LIBRARY_SUFFIX}"
    INTERFACE_INCLUDE_DIRECTORIES "${HIERLIB_DIR}"
)
if(APPLE)
    set_target_properties(hierlib PROPERTIES IMPORTED_SONAME "@rpath/libhierlib.dylib")
endif()
if(WIN32)
    set_target_properties(hierlib PROPERTIES IMPORTED_IMPLIB "${HIERLIB_DIR}/hierlib.lib")
endif()

add_executable(hier_cpp cpp_example/main.cpp)
set_target_properties(hier_cpp PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
    OUTPUT_NAME example
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/cpp_example/build"
)

# Match the compiler arch to the Nim-built .so (Linux i386 CI guard).
if(UNIX AND NOT APPLE)
    set(SO_PATH "${HIERLIB_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}hierlib${CMAKE_SHARED_LIBRARY_SUFFIX}")
    if(EXISTS "${SO_PATH}")
        execute_process(COMMAND file "${SO_PATH}" OUTPUT_VARIABLE SO_FILE_INFO
            OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
        if(SO_FILE_INFO MATCHES "ELF 64-bit")
            set(LIB_BITS 64)
        elseif(SO_FILE_INFO MATCHES "ELF 32-bit")
            set(LIB_BITS 32)
        endif()
        if(DEFINED LIB_BITS)
            if(CMAKE_SIZEOF_VOID_P EQUAL 4 AND LIB_BITS EQUAL 64)
                target_compile_options(hier_cpp PRIVATE -m64)
                target_link_options(hier_cpp PRIVATE -m64)
            elseif(CMAKE_SIZEOF_VOID_P EQUAL 8 AND LIB_BITS EQUAL 32)
                target_compile_options(hier_cpp PRIVATE -m32)
                target_link_options(hier_cpp PRIVATE -m32)
            endif()
        endif()
    endif()
endif()

target_link_libraries(hier_cpp PRIVATE hierlib)

# Header-only jsoncons for CBOR encode/decode in hierlib.hpp.
target_include_directories(hier_cpp PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../vendor/jsoncons/include")

if(APPLE)
    set_target_properties(hier_cpp PROPERTIES
        BUILD_RPATH "@loader_path/../../nimlib/${HIERLIB_DIRNAME}"
        INSTALL_RPATH "@loader_path/../../nimlib/${HIERLIB_DIRNAME}")
elseif(UNIX)
    set_target_properties(hier_cpp PROPERTIES
        BUILD_RPATH "$ORIGIN/../../nimlib/${HIERLIB_DIRNAME}"
        INSTALL_RPATH "$ORIGIN/../../nimlib/${HIERLIB_DIRNAME}")
endif()

if(WIN32)
    add_custom_command(TARGET hier_cpp POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${HIERLIB_DIR}/hierlib.dll" "$<TARGET_FILE_DIR:hier_cpp>/hierlib.dll"
        COMMENT "Copying hierlib.dll next to C++ example")
endif()
