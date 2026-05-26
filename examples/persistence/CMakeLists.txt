cmake_minimum_required(VERSION 3.16)
project(persistence_examples CXX)

# Locate the Nim-built shared library + generated header (built by the nimble
# task). PERSIST_DIR can be overridden at configure time.
if(NOT PERSIST_DIR)
    set(PERSIST_DIR "${CMAKE_CURRENT_SOURCE_DIR}/nimlib/build")
endif()
get_filename_component(PERSIST_DIRNAME "${PERSIST_DIR}" NAME)
get_filename_component(PERSIST_DIR "${PERSIST_DIR}" ABSOLUTE)

if(NOT EXISTS "${PERSIST_DIR}/persistence.h")
    message(FATAL_ERROR
        "persistence.h not found in ${PERSIST_DIR}.\n"
        "Run  nimble runPersistenceExampleCpp  (it builds the Nim library first).")
endif()

add_library(persistence SHARED IMPORTED)
set_target_properties(persistence PROPERTIES
    IMPORTED_LOCATION "${PERSIST_DIR}/${CMAKE_SHARED_LIBRARY_PREFIX}persistence${CMAKE_SHARED_LIBRARY_SUFFIX}"
    INTERFACE_INCLUDE_DIRECTORIES "${PERSIST_DIR}"
)
if(APPLE)
    set_target_properties(persistence PROPERTIES IMPORTED_SONAME "@rpath/libpersistence.dylib")
endif()
if(WIN32)
    set_target_properties(persistence PROPERTIES IMPORTED_IMPLIB "${PERSIST_DIR}/persistence.lib")
endif()

add_executable(persistence_cpp cpp_example/main.cpp)
set_target_properties(persistence_cpp PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
    OUTPUT_NAME example
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/cpp_example/build"
)

target_link_libraries(persistence_cpp PRIVATE persistence)

# Header-only jsoncons for CBOR encode/decode in persistence.hpp.
target_include_directories(persistence_cpp PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/../../vendor/jsoncons/include")

if(APPLE)
    set_target_properties(persistence_cpp PROPERTIES
        BUILD_RPATH "@loader_path/../../nimlib/${PERSIST_DIRNAME}"
        INSTALL_RPATH "@loader_path/../../nimlib/${PERSIST_DIRNAME}")
elseif(UNIX)
    set_target_properties(persistence_cpp PROPERTIES
        BUILD_RPATH "$ORIGIN/../../nimlib/${PERSIST_DIRNAME}"
        INSTALL_RPATH "$ORIGIN/../../nimlib/${PERSIST_DIRNAME}")
endif()

if(WIN32)
    add_custom_command(TARGET persistence_cpp POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${PERSIST_DIR}/persistence.dll" "$<TARGET_FILE_DIR:persistence_cpp>/persistence.dll"
        COMMENT "Copying persistence.dll next to C++ example")
endif()
