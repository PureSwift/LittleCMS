# CMakeLists.txt - builds the installable C library
#
# SwiftPM covers development and the Swift library, but it cannot set an install
# name, a soname, or an export list, and those are exactly what make a library
# substitutable for another one.  So the artifact that gets installed is built
# here.
#
# CMake compiles Swift only under the Ninja and Xcode generators, and a single
# target cannot mix Swift with another language, so the engine builds as static
# Swift archives and the C floor links them into the shared library.

cmake_minimum_required(VERSION 3.29) # CMP0157, for Swift compilation mode

project(LittleCMS
    VERSION 2.19.0
    DESCRIPTION "Little CMS 2, implemented in Swift"
    LANGUAGES C Swift)

include(GNUInstallDirs)

option(SLCMS_STATIC_STDLIB
    "Link the Swift runtime statically, so the library needs no toolchain at run time" OFF)
option(SLCMS_BUILD_TESTS "Build the conformance programs" ON)
set(SLCMS_UPSTREAM_DIR "" CACHE PATH
    "A Little-CMS source checkout at tag lcms2.19, enabling the upstream testbed suite")

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

# The ABI we are compatible with.  2 is the soname generation the reference
# has carried since Little CMS 2.0; the Mach-O versions are what the reference
# build of 2.19 records (libtool current:revision:age = 2:18:0, which libtool
# maps to compatibility 3.0.0 and current 3.18.0 on Mach-O, and to
# liblcms2.so.2.0.18 with soname liblcms2.so.2 on ELF).  Clients bind to
# these, so they are part of the contract rather than our own version number.
set(SLCMS_ABI_SONAME 2)
set(SLCMS_ELF_VERSION 2.0.18)
set(SLCMS_MACHO_COMPATIBILITY_VERSION 3.0.0)
set(SLCMS_MACHO_CURRENT_VERSION 3.18.0)

set(SLCMS_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/Sources/CLCMS2/include)
set(SLCMS_MODULE_MAP ${SLCMS_INCLUDE_DIR}/module.modulemap)

find_package(Python3 REQUIRED COMPONENTS Interpreter)

# -- generated sources -------------------------------------------------------
#
# The stub table and symbol list are committed as well as generated, so a
# checkout builds without Python and CI can diff the regenerated output to
# catch a stale file.  Only the link-time export controls are generated at
# build time, straight from the committed symbols.txt.

set(SLCMS_EXPORT_LIST ${CMAKE_CURRENT_BINARY_DIR}/lcms2.exp)
set(SLCMS_VERSION_SCRIPT ${CMAKE_CURRENT_BINARY_DIR}/lcms2.vers)

add_custom_command(
    OUTPUT ${SLCMS_EXPORT_LIST} ${SLCMS_VERSION_SCRIPT}
    COMMAND ${Python3_EXECUTABLE}
            ${CMAKE_CURRENT_SOURCE_DIR}/scripts/gen_symbols.py
            ${CMAKE_CURRENT_BINARY_DIR}
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/scripts/gen_symbols.py
            ${CMAKE_CURRENT_SOURCE_DIR}/scripts/symbols.txt
    COMMENT "Generating linker export lists")

add_custom_target(slcms_export_lists
    DEPENDS ${SLCMS_EXPORT_LIST} ${SLCMS_VERSION_SCRIPT})

# -- the engine --------------------------------------------------------------
#
# One CMake target per Swift module, matching the package's layout.  Building
# them as separate modules rather than compiling every source into one is what
# lets the same `import` lines work under both build systems, and it keeps the
# engine unable to reach the C API by accident.

# Whole-module optimisation matters here: a transform's hot path crosses
# formatter, pipeline, interpolation, and fixed-point files per pixel, and the
# inlining that removes those boundaries is what keeps it competitive.
set(SLCMS_COMPILATION_MODE $<IF:$<CONFIG:Release>,wholemodule,incremental>)

function(slcms_add_swift_module name)
    # Globbed on purpose: a hand-kept list silently omits a file SwiftPM
    # compiled, and the result is not a build error but a shared object
    # quietly missing part of its API.
    file(GLOB_RECURSE sources CONFIGURE_DEPENDS
        ${CMAKE_CURRENT_SOURCE_DIR}/Sources/${name}/*.swift)

    add_library(${name} STATIC ${sources})

    set_target_properties(${name} PROPERTIES
        POSITION_INDEPENDENT_CODE ON
        Swift_MODULE_NAME ${name}
        Swift_COMPILATION_MODE ${SLCMS_COMPILATION_MODE})

    # The API's own contract is one object per thread (transforms excepted,
    # and those are immutable after creation), so the dynamic bookkeeping
    # that catches overlapping exclusive accesses at run time has nothing to
    # catch.  Debug builds keep the checking.
    target_compile_options(${name} PRIVATE
        $<$<CONFIG:Release>:-enforce-exclusivity=unchecked>)
endfunction()

slcms_add_swift_module(LittleCMS)
slcms_add_swift_module(LCMS2ABI)

target_link_libraries(LCMS2ABI PUBLIC LittleCMS)

# Only the boundary module sees the C API.
target_compile_options(LCMS2ABI PRIVATE
    "SHELL:-Xcc -I${SLCMS_INCLUDE_DIR}"
    "SHELL:-Xcc -fmodule-map-file=${SLCMS_MODULE_MAP}")

# -- the shared library ------------------------------------------------------

add_library(lcms2 SHARED
    Sources/CLCMS2/lcms2_error.c
    Sources/CLCMS2/lcms2_variadic.c
    Sources/CLCMS2/gen/lcms2_stubs.c)

add_dependencies(lcms2 slcms_export_lists LCMS2ABI)

target_include_directories(lcms2
    PUBLIC $<BUILD_INTERFACE:${SLCMS_INCLUDE_DIR}>
           $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>)

# Driving the link with swiftc is what pulls in the Swift runtime and the
# metadata registration object the static archives need.
set_target_properties(lcms2 PROPERTIES
    LINKER_LANGUAGE Swift
    OUTPUT_NAME lcms2
    SOVERSION ${SLCMS_ABI_SONAME})

if(APPLE)
    # liblcms2.2.dylib, installed under the configured libdir's install name.
    set_target_properties(lcms2 PROPERTIES
        VERSION ${SLCMS_ABI_SONAME}
        INSTALL_NAME_DIR ${CMAKE_INSTALL_FULL_LIBDIR})

    # A client records the compatibility version of what it linked against,
    # and dyld refuses a library that offers a lower one, so this has to
    # match the reference build rather than track our own version number.
    #
    # The MACHO_COMPATIBILITY_VERSION and MACHO_CURRENT_VERSION properties do
    # not reach the link when the link is driven by swiftc, so the flags are
    # passed directly.
    target_link_options(lcms2 PRIVATE
        "LINKER:-compatibility_version,${SLCMS_MACHO_COMPATIBILITY_VERSION}"
        "LINKER:-current_version,${SLCMS_MACHO_CURRENT_VERSION}")

    # Without this the Swift engine's symbols would also be exported, letting
    # a client bind to something outside the published API.
    target_link_options(lcms2 PRIVATE
        "LINKER:-exported_symbols_list,${SLCMS_EXPORT_LIST}")

    # The export list is an input to the link, not just an argument: editing
    # symbols.txt has to relink, or the shipped library keeps yesterday's
    # exports and check_exports passes against a stale artifact.
    set_property(TARGET lcms2 APPEND PROPERTY LINK_DEPENDS ${SLCMS_EXPORT_LIST})

    target_link_libraries(lcms2 PRIVATE LCMS2ABI)
else()
    # liblcms2.so.2.0.18, soname liblcms2.so.2, exactly as libtool names the
    # reference build.
    set_target_properties(lcms2 PROPERTIES
        VERSION ${SLCMS_ELF_VERSION})

    # A shared object is allowed to carry unresolved symbols, and every
    # client discovers them instead: the library links, and linking a
    # program against it fails.  For a library whose whole purpose is to
    # be substituted into someone else's build, that is the worst place
    # to find out, so the link refuses here rather than deferring it.
    target_link_options(lcms2 PRIVATE
        "LINKER:--no-undefined"
        "LINKER:--version-script=${SLCMS_VERSION_SCRIPT}")

    # The published entry points live in the boundary archive and nothing
    # inside the library calls them, so an ELF link would drop their objects
    # as unreferenced — ld64 resolves the export list from the archive, but
    # GNU ld versions only what is already in the link.  The whole archive is
    # what the dynamic symbol table is made from, and the version script then
    # hides everything unpublished.
    #
    # The engine's archive follows *in these options* rather than through
    # target_link_libraries: the driver places linker options and libraries
    # in separate runs of the final command, and an archive scanned before
    # the whole archive raised its undefined references contributes nothing
    # to them.
    target_link_options(lcms2 PRIVATE
        "LINKER:--whole-archive,$<TARGET_FILE:LCMS2ABI>,--no-whole-archive"
        "LINKER:$<TARGET_FILE:LittleCMS>")

    # Naming the archives in link options makes them arguments, not inputs:
    # add_dependencies only orders the build, so an incremental build that
    # recompiles the engine would leave the shared library holding the
    # previous objects.  LINK_DEPENDS makes the archives real inputs, and
    # the version script with them.
    set_property(TARGET lcms2 APPEND PROPERTY LINK_DEPENDS
        $<TARGET_FILE:LCMS2ABI> $<TARGET_FILE:LittleCMS> ${SLCMS_VERSION_SCRIPT})

    # What the reference's own pkg-config declares as private
    # dependencies, named explicitly because --no-undefined means they
    # can no longer be left to whatever the driver happens to add.
    target_link_libraries(lcms2 PRIVATE m pthread)

    if(SLCMS_STATIC_STDLIB)
        target_link_options(lcms2 PRIVATE -static-stdlib)
    endif()
endif()

# -- install -----------------------------------------------------------------
#
# The layout mirrors the reference build's: both public headers flat in the
# include directory, the versioned library with its unversioned alias, and a
# pkg-config file — pkg-config is how most build systems find lcms2, so
# shipping it is part of being a drop-in rather than a nicety.

install(TARGETS lcms2
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR})

install(FILES
    ${SLCMS_INCLUDE_DIR}/lcms2.h
    ${SLCMS_INCLUDE_DIR}/lcms2_plugin.h
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

configure_file(cmake/lcms2.pc.in
    ${CMAKE_CURRENT_BINARY_DIR}/lcms2.pc @ONLY)

install(FILES ${CMAKE_CURRENT_BINARY_DIR}/lcms2.pc
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/pkgconfig)

# -- conformance -------------------------------------------------------------

if(SLCMS_BUILD_TESTS)
    enable_testing()
    add_subdirectory(Conformance)
endif()
