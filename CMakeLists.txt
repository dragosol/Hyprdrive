cmake_minimum_required(VERSION 3.27)

project(scrolloverview
    DESCRIPTION "scrolloverview plugin for Hyprland"
    VERSION 0.1
)

set(CMAKE_CXX_STANDARD 23)

file(GLOB_RECURSE SRC "*.cpp")

add_library(scrolloverview SHARED ${SRC})

set(VERSION_HEADER_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
set(VERSION_HEADER "${VERSION_HEADER_DIR}/PluginVersion.hpp")
add_custom_target(scrolloverview-version ALL
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${VERSION_HEADER_DIR}"
    COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/scripts/generate-plugin-version.sh" "${VERSION_HEADER}" "${CMAKE_CURRENT_SOURCE_DIR}"
    BYPRODUCTS "${VERSION_HEADER}"
    VERBATIM
)
add_dependencies(scrolloverview scrolloverview-version)
target_include_directories(scrolloverview PRIVATE "${VERSION_HEADER_DIR}")

find_package(PkgConfig REQUIRED)
pkg_check_modules(deps REQUIRED IMPORTED_TARGET
    hyprland
    libdrm
    libinput
    libudev
    lua5.4
    pangocairo
    pixman-1
    wayland-server
    xkbcommon
)
target_link_libraries(scrolloverview PRIVATE rt PkgConfig::deps)

install(TARGETS scrolloverview)
