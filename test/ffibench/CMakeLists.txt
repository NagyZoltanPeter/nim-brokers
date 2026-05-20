cmake_minimum_required(VERSION 3.16)
project(ffibench_cpp_driver CXX)

# Phase 0 microbenchmark driver — see doc/CBOR_Refactoring.md §7.3.
# CBOR is the only FFI mode (the native codegen was retired). BENCH_DIR
# can still be overridden at configure time; by default it points at the
# CBOR build output.
option(ASAN "Enable AddressSanitizer on the C++ drivers (lib must also be ASAN-built)" OFF)

if(NOT BENCH_DIR)
    set(BENCH_DIR "${CMAKE_CURRENT_SOURCE_DIR}/build_cbor")
endif()

get_filename_component(BENCH_DIR "${BENCH_DIR}" ABSOLUTE)

if(NOT EXISTS "${BENCH_DIR}/benchlib.hpp")
    message(FATAL_ERROR
        "benchlib.hpp not found in ${BENCH_DIR}.\n"
        "Build the Nim library first (see test/ffibench/README or the nimble tasks).")
endif()

add_library(benchlib SHARED IMPORTED)
set_target_properties(benchlib PROPERTIES
    IMPORTED_LOCATION
        "${BENCH_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}benchlib${CMAKE_SHARED_LIBRARY_SUFFIX}"
    INTERFACE_INCLUDE_DIRECTORIES "${BENCH_DIR}"
)
if(APPLE)
    set_target_properties(benchlib PROPERTIES
        IMPORTED_SONAME "@rpath/libbenchlib.dylib"
    )
endif()
if(WIN32)
    set_target_properties(benchlib PROPERTIES
        IMPORTED_IMPLIB "${BENCH_DIR}/benchlib.lib"
    )
endif()

function(add_ffibench_target tgt src)
    add_executable(${tgt} ${src})
    set_target_properties(${tgt} PROPERTIES
        CXX_STANDARD 20
        CXX_STANDARD_REQUIRED ON
        RUNTIME_OUTPUT_DIRECTORY "${BENCH_DIR}"
    )
    target_link_libraries(${tgt} PRIVATE benchlib)
    # jsoncons (header-only) used by the generated CBOR wrapper.
    target_include_directories(${tgt} PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/../../vendor/jsoncons/include")
    if(ASAN)
        target_compile_options(${tgt} PRIVATE
            -fsanitize=address -fno-omit-frame-pointer)
        target_link_options(${tgt} PRIVATE -fsanitize=address)
    endif()
    if(APPLE)
        set_target_properties(${tgt} PROPERTIES
            BUILD_RPATH  "@loader_path"
            INSTALL_RPATH "@loader_path"
        )
    elseif(UNIX)
        set_target_properties(${tgt} PROPERTIES
            BUILD_RPATH  "$ORIGIN"
            INSTALL_RPATH "$ORIGIN"
        )
    endif()
    if(WIN32)
        add_custom_command(TARGET ${tgt} POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${BENCH_DIR}/benchlib.dll"
                "$<TARGET_FILE_DIR:${tgt}>/benchlib.dll"
        )
    endif()
endfunction()

add_ffibench_target(bench_driver bench_driver.cpp)
add_ffibench_target(stress_mt stress_mt.cpp)
add_ffibench_target(stress_shutdown stress_shutdown.cpp)
