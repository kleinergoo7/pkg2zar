# SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
# SPDX-License-Identifier: GPL-3.0-or-later

cmake_minimum_required(VERSION 3.21)
project(ps4_pkg2zar LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# No hard-coded locations: take $ZIG, else the first zig on PATH. The version check below
# refuses anything but 0.16.0, so a conflicting install must be selected explicitly.
if(NOT ZIG_EXECUTABLE)
  if(DEFINED ENV{ZIG} AND NOT "$ENV{ZIG}" STREQUAL "")
    set(ZIG_EXECUTABLE "$ENV{ZIG}" CACHE FILEPATH "Zig 0.16.0 compiler")
  else()
    find_program(ZIG_EXECUTABLE NAMES zig zig-0.16 zig0.16)
  endif()
endif()
if(NOT ZIG_EXECUTABLE)
  message(FATAL_ERROR "Zig 0.16.0 not found. Set ZIG, pass -DZIG_EXECUTABLE=<path>, or put it on PATH.")
endif()
execute_process(
  COMMAND "${ZIG_EXECUTABLE}" version
  OUTPUT_VARIABLE ZIG_VERSION
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
if(NOT ZIG_VERSION VERSION_EQUAL "0.16.0")
  message(FATAL_ERROR "Zig 0.16.0 required, found '${ZIG_VERSION}'")
endif()

find_package(Qt6 REQUIRED COMPONENTS Widgets)
find_library(ZSTD_LIBRARY NAMES zstd REQUIRED)

set(P2Z_ZIG_PREFIX "${CMAKE_BINARY_DIR}/zig")
# shortcut: host target only, MSVC uses .lib; add explicit target selection when cross builds are needed.
if(WIN32)
  set(P2Z_CORE_LIB "${P2Z_ZIG_PREFIX}/lib/p2z_core.lib")
else()
  set(P2Z_CORE_LIB "${P2Z_ZIG_PREFIX}/lib/libp2z_core.a")
endif()

file(GLOB_RECURSE P2Z_ZIG_SOURCES CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/core/src/*.zig")

add_custom_command(
  OUTPUT "${P2Z_CORE_LIB}"
  COMMAND "${ZIG_EXECUTABLE}" build -Doptimize=ReleaseFast --prefix "${P2Z_ZIG_PREFIX}"
  WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
  DEPENDS
    "${CMAKE_SOURCE_DIR}/build.zig"
    "${CMAKE_SOURCE_DIR}/build.zig.zon"
    ${P2Z_ZIG_SOURCES}
  COMMENT "Building p2z_core with Zig"
  VERBATIM
)

add_custom_target(p2z_core_build DEPENDS "${P2Z_CORE_LIB}")

add_library(p2z_core STATIC IMPORTED GLOBAL)
set_target_properties(p2z_core PROPERTIES IMPORTED_LOCATION "${P2Z_CORE_LIB}")
add_dependencies(p2z_core p2z_core_build)

qt_add_executable(ps4-pkg2zar ui/main.cpp)
target_include_directories(ps4-pkg2zar PRIVATE core/src)
target_link_libraries(ps4-pkg2zar PRIVATE p2z_core Qt6::Widgets "${ZSTD_LIBRARY}")

add_custom_target(p2z_zig_test
  COMMAND "${ZIG_EXECUTABLE}" build test
  WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
  COMMENT "Running Zig unit tests"
  VERBATIM
)
