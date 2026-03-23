cmake_minimum_required(VERSION 3.16)
project(mylib_examples C CXX)

# ---------------------------------------------------------------------------
# Locate the Nim-built shared library and generated header
# ---------------------------------------------------------------------------
# MYLIB_DIR can be overridden at configure time; defaults to nimlib/build
# relative to this CMakeLists.txt.
if(NOT MYLIB_DIR)
    set(MYLIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/nimlib/build")
endif()

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

# ---------------------------------------------------------------------------
# Pure C example
# ---------------------------------------------------------------------------
add_executable(example_c example/main.c)
set_target_properties(example_c PROPERTIES
    C_STANDARD 11
    C_STANDARD_REQUIRED ON
    OUTPUT_NAME example
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/example/build"
)
target_link_libraries(example_c PRIVATE mylib)

# RPATH: embed the path to the shared library so the binary runs in-tree
if(APPLE)
    set_target_properties(example_c PROPERTIES
        BUILD_RPATH "@loader_path/../../nimlib/build"
        INSTALL_RPATH "@loader_path/../../nimlib/build"
    )
elseif(UNIX)
    set_target_properties(example_c PROPERTIES
        BUILD_RPATH "$ORIGIN/../../nimlib/build"
        INSTALL_RPATH "$ORIGIN/../../nimlib/build"
    )
endif()

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
target_link_libraries(example_cpp PRIVATE mylib)

if(APPLE)
    set_target_properties(example_cpp PROPERTIES
        BUILD_RPATH "@loader_path/../../nimlib/build"
        INSTALL_RPATH "@loader_path/../../nimlib/build"
    )
elseif(UNIX)
    set_target_properties(example_cpp PROPERTIES
        BUILD_RPATH "$ORIGIN/../../nimlib/build"
        INSTALL_RPATH "$ORIGIN/../../nimlib/build"
    )
endif()

# ---------------------------------------------------------------------------
# Windows: copy the DLL next to the executables so they can be run directly
# ---------------------------------------------------------------------------
if(WIN32)
    add_custom_command(TARGET example_c POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${MYLIB_DIR}/mylib.dll"
            "$<TARGET_FILE_DIR:example_c>/mylib.dll"
        COMMENT "Copying mylib.dll next to C example"
    )
    add_custom_command(TARGET example_cpp POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${MYLIB_DIR}/mylib.dll"
            "$<TARGET_FILE_DIR:example_cpp>/mylib.dll"
        COMMENT "Copying mylib.dll next to C++ example"
    )
endif()
