cmake_minimum_required(VERSION 3.16)
project(mylib_example CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Path to the Nim library build output
set(NIMLIB_DIR "${CMAKE_SOURCE_DIR}/../nimlib/build" CACHE PATH "Path to built Nim library")

add_executable(example main.cpp)

target_include_directories(example PRIVATE ${NIMLIB_DIR})
target_link_directories(example PRIVATE ${NIMLIB_DIR})
target_link_libraries(example mylib)

# On Linux, link pthread
if(UNIX AND NOT APPLE)
    target_link_libraries(example pthread dl)
endif()

# Set RPATH so the executable can find the shared library
set_target_properties(example PROPERTIES
    BUILD_RPATH "${NIMLIB_DIR}"
    INSTALL_RPATH "${NIMLIB_DIR}"
)
