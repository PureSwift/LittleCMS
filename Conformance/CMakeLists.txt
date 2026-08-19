# Conformance - the programs that measure the drop-in claim
#
# These are C programs on purpose: the claim is that a C client built for
# lcms2 works against this library, and only a C client can test that.
# Every differential program is compiled twice from identical source — once
# against us, once against the reference — because an expectation written
# from memory rather than from observation is worse than no test.

# The reference library, for the second build of each differential program.
#
# It must be one built by scripts/build_reference.sh, which pins the
# version and — the part that is easy to miss — disables floating-point
# contraction.  A stock build fuses multiply-add where Swift cannot, so its
# doubles differ from ours in the last bit, and differ between arm64 and
# x86-64 as well.  Point PKG_CONFIG_PATH at that prefix; CI does the same.
# If a reference has been built in-tree, it wins over anything installed
# on the system, without the caller having to remember to say so.
#
# A distro or Homebrew lcms2 is the same library and passes the identity
# guard below, but it is compiled with floating-point contraction on --
# so its doubles differ from ours in the last bit and five differentials
# fail for a reason that has nothing to do with this port. Finding that
# out costs an hour; making the right reference the default costs this
# paragraph.
set(SLCMS_IN_TREE_REFERENCE "${CMAKE_SOURCE_DIR}/build/reference/lib/pkgconfig")
if(EXISTS "${SLCMS_IN_TREE_REFERENCE}/lcms2.pc")
    if(DEFINED ENV{PKG_CONFIG_PATH})
        set(ENV{PKG_CONFIG_PATH} "${SLCMS_IN_TREE_REFERENCE}:$ENV{PKG_CONFIG_PATH}")
    else()
        set(ENV{PKG_CONFIG_PATH} "${SLCMS_IN_TREE_REFERENCE}")
    endif()
    message(STATUS "conformance: using the in-tree reference at ${SLCMS_IN_TREE_REFERENCE}")
endif()

find_package(PkgConfig)
if(PkgConfig_FOUND)
    pkg_check_modules(SLCMS_REFERENCE IMPORTED_TARGET "lcms2>=2.19")
endif()

# A reference that is actually us is worse than no reference: the suite
# would compare this library against itself and report agreement.
#
# The question to ask is whether the library found IS this one, and the
# direct form of it is what the library links: ours needs the Swift
# runtime and the reference never does.  Asking about paths instead —
# whether it sits inside our install prefix — gets the wrong answer where
# it matters most, because /usr/local is both CMake's default prefix and
# the sensible place for CI to put a reference built from source.  That
# guess cost a whole CI run: the suite went green having skipped every
# differential.
if(SLCMS_REFERENCE_FOUND)
    find_library(SLCMS_REFERENCE_LIBRARY
        NAMES lcms2
        HINTS ${SLCMS_REFERENCE_LIBRARY_DIRS}
        NO_DEFAULT_PATH)

    if(SLCMS_REFERENCE_LIBRARY)
        if(APPLE)
            execute_process(COMMAND otool -L "${SLCMS_REFERENCE_LIBRARY}"
                OUTPUT_VARIABLE SLCMS_REFERENCE_DEPENDENCIES
                ERROR_QUIET)
        else()
            execute_process(COMMAND readelf -d "${SLCMS_REFERENCE_LIBRARY}"
                OUTPUT_VARIABLE SLCMS_REFERENCE_DEPENDENCIES
                ERROR_QUIET)
        endif()

        if(SLCMS_REFERENCE_DEPENDENCIES MATCHES "swift")
            message(WARNING
                "The lcms2 found by pkg-config (${SLCMS_REFERENCE_LIBRARY}) links "
                "the Swift runtime, so it is this library rather than the "
                "reference.  The differential suites are disabled; point "
                "PKG_CONFIG_PATH at a reference built by scripts/build_reference.sh.")
            set(SLCMS_REFERENCE_FOUND FALSE)
        endif()
    endif()
endif()

# -- ABI invariants ----------------------------------------------------------

add_test(NAME abi_exports
    COMMAND ${CMAKE_SOURCE_DIR}/scripts/check_exports.sh
            $<TARGET_FILE:lcms2> ${CMAKE_SOURCE_DIR}/scripts/symbols.txt)

add_test(NAME generated_sources
    COMMAND ${CMAKE_SOURCE_DIR}/scripts/check_generated.sh)

# -- probes ------------------------------------------------------------------

add_executable(version_probe_ours version_probe.c)
target_link_libraries(version_probe_ours PRIVATE lcms2)

add_executable(stub_probe_ours stub_probe.c)
target_link_libraries(stub_probe_ours PRIVATE lcms2)

# Every probe that touches <math.h> must say so.  On Apple platforms
# libm is part of libSystem and linking is automatic; everywhere else it
# is a separate library and forgetting it is a build failure only the
# non-Apple job can see.  A helper rather than a repeated `if`, because
# the repeated `if` is what got forgotten.
function(slcms_probe_uses_math target)
    if(NOT APPLE)
        target_link_libraries(${target} PRIVATE m)
    endif()
endfunction()

add_executable(primprobe_ours primprobe.c)
target_link_libraries(primprobe_ours PRIVATE lcms2)
slcms_probe_uses_math(primprobe_ours)

add_executable(matprobe_ours matprobe.c)
target_link_libraries(matprobe_ours PRIVATE lcms2)

add_executable(md5probe_ours md5probe.c)
target_link_libraries(md5probe_ours PRIVATE lcms2)

add_test(NAME version_probe COMMAND version_probe_ours)
add_test(NAME primitives_probe COMMAND primprobe_ours)
add_test(NAME matrix_probe COMMAND matprobe_ours)
add_test(NAME md5_probe COMMAND md5probe_ours)

add_executable(ctxprobe_ours ctxprobe.c)
target_link_libraries(ctxprobe_ours PRIVATE lcms2)
add_test(NAME context_probe COMMAND ctxprobe_ours)

add_executable(ioprobe_ours ioprobe.c)
target_link_libraries(ioprobe_ours PRIVATE lcms2)
add_test(NAME io_probe COMMAND ioprobe_ours
    WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR})

add_executable(colorprobe_ours colorprobe.c)
target_link_libraries(colorprobe_ours PRIVATE lcms2)
slcms_probe_uses_math(colorprobe_ours)
add_test(NAME color_probe COMMAND colorprobe_ours)

add_executable(curveprobe_ours curveprobe.c)
target_link_libraries(curveprobe_ours PRIVATE lcms2)
add_test(NAME curve_probe COMMAND curveprobe_ours)

add_executable(mluprobe_ours mluprobe.c)
target_link_libraries(mluprobe_ours PRIVATE lcms2)
add_test(NAME mlu_probe COMMAND mluprobe_ours)

add_executable(namedprobe_ours namedprobe.c)
target_link_libraries(namedprobe_ours PRIVATE lcms2)
add_test(NAME named_probe COMMAND namedprobe_ours)

add_executable(dictprobe_ours dictprobe.c)
target_link_libraries(dictprobe_ours PRIVATE lcms2)
add_test(NAME dict_probe COMMAND dictprobe_ours)

add_executable(interpprobe_ours interpprobe.c)
target_link_libraries(interpprobe_ours PRIVATE lcms2)
add_test(NAME interp_probe COMMAND interpprobe_ours)

add_executable(pipeprobe_ours pipeprobe.c)
target_link_libraries(pipeprobe_ours PRIVATE lcms2)
add_test(NAME pipe_probe COMMAND pipeprobe_ours)

add_executable(clutprobe_ours clutprobe.c)
target_link_libraries(clutprobe_ours PRIVATE lcms2)
add_test(NAME clut_probe COMMAND clutprobe_ours)

add_executable(fmtprobe_ours fmtprobe.c)
target_link_libraries(fmtprobe_ours PRIVATE lcms2)
add_test(NAME formatter_probe COMMAND fmtprobe_ours)

add_executable(profileprobe_ours profileprobe.c)
target_link_libraries(profileprobe_ours PRIVATE lcms2)
slcms_probe_uses_math(profileprobe_ours)
add_test(NAME profile_probe COMMAND profileprobe_ours)

# The stubs' contract: the gap is reported through the error path and the
# call fails cleanly rather than answering.
add_test(NAME stub_behavior COMMAND stub_probe_ours)
set_tests_properties(stub_behavior PROPERTIES
    PASS_REGULAR_EXPRESSION "is not implemented"
    FAIL_REGULAR_EXPRESSION "stub returned")

# The same courtesy as the reference: if the upstream checkout is where
# scripts/build_reference.sh leaves its source, use it without being
# told. Silently running three fewer tests than yesterday is its own
# kind of wrong answer.  Decided here, before the differentials, because
# the profile-reading ones want the testbed's profiles too.
if(NOT SLCMS_UPSTREAM_DIR AND EXISTS "${CMAKE_SOURCE_DIR}/build/reference/src/testbed/testcms2.c")
    set(SLCMS_UPSTREAM_DIR "${CMAKE_SOURCE_DIR}/build/reference/src")
endif()

# -- against the reference ---------------------------------------------------

if(SLCMS_REFERENCE_FOUND)
    add_executable(version_probe_reference version_probe.c)
    target_link_libraries(version_probe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

    add_test(NAME version_probe_reference COMMAND version_probe_reference)

    add_test(NAME version_probe_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:version_probe_ours>
                $<TARGET_FILE:version_probe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)

    # The gate the whole engine rests on: every arithmetic primitive,
    # fingerprinted over exhaustive and adversarial inputs, must agree with
    # the reference exactly.
    add_executable(primprobe_reference primprobe.c)
    target_link_libraries(primprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)
    slcms_probe_uses_math(primprobe_reference)

    add_test(NAME primitives_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:primprobe_ours>
                $<TARGET_FILE:primprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)

    add_executable(matprobe_reference matprobe.c)
    target_link_libraries(matprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

    add_test(NAME matrix_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:matprobe_ours>
                $<TARGET_FILE:matprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)

    add_executable(md5probe_reference md5probe.c)
    target_link_libraries(md5probe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

    add_executable(ctxprobe_reference ctxprobe.c)
    target_link_libraries(ctxprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

    add_test(NAME context_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:ctxprobe_ours>
                $<TARGET_FILE:ctxprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)

    add_executable(ioprobe_reference ioprobe.c)
    target_link_libraries(ioprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

    add_test(NAME io_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:ioprobe_ours>
                $<TARGET_FILE:ioprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)

    add_executable(colorprobe_reference colorprobe.c)
    target_link_libraries(colorprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)
    slcms_probe_uses_math(colorprobe_reference)

    add_test(NAME color_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:colorprobe_ours>
                $<TARGET_FILE:colorprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)

    add_executable(curveprobe_reference curveprobe.c)
    target_link_libraries(curveprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

    add_test(NAME curve_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:curveprobe_ours>
                $<TARGET_FILE:curveprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)

    add_executable(mluprobe_reference mluprobe.c)
    target_link_libraries(mluprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

    add_test(NAME mlu_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:mluprobe_ours>
                $<TARGET_FILE:mluprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)

    add_executable(namedprobe_reference namedprobe.c)
    target_link_libraries(namedprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

    add_test(NAME named_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:namedprobe_ours>
                $<TARGET_FILE:namedprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)

    add_executable(dictprobe_reference dictprobe.c)
    target_link_libraries(dictprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

    add_test(NAME dict_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:dictprobe_ours>
                $<TARGET_FILE:dictprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)

    add_executable(interpprobe_reference interpprobe.c)
    target_link_libraries(interpprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

    add_test(NAME interp_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:interpprobe_ours>
                $<TARGET_FILE:interpprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)

    add_executable(pipeprobe_reference pipeprobe.c)
    target_link_libraries(pipeprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

    add_test(NAME pipe_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:pipeprobe_ours>
                $<TARGET_FILE:pipeprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)

    add_executable(clutprobe_reference clutprobe.c)
    target_link_libraries(clutprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

    add_test(NAME clut_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:clutprobe_ours>
                $<TARGET_FILE:clutprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)

    add_executable(it8probe_ours it8probe.c)
    target_link_libraries(it8probe_ours PRIVATE lcms2)
    add_executable(it8probe_reference it8probe.c)
    target_link_libraries(it8probe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

    add_test(NAME it8_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:it8probe_ours>
                $<TARGET_FILE:it8probe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)
    set_tests_properties(it8_differential PROPERTIES WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR})

    add_executable(virtprobe_ours virtprobe.c)
    target_link_libraries(virtprobe_ours PRIVATE lcms2)
    add_executable(virtprobe_reference virtprobe.c)
    target_link_libraries(virtprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

    add_test(NAME virtual_profile_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:virtprobe_ours>
                $<TARGET_FILE:virtprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences-virtual.txt)

    add_executable(fmtprobe_reference fmtprobe.c)
    target_link_libraries(fmtprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

    add_test(NAME formatter_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:fmtprobe_ours>
                $<TARGET_FILE:fmtprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences-formatter.txt)

    add_executable(profileprobe_reference profileprobe.c)
    target_link_libraries(profileprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)
    slcms_probe_uses_math(profileprobe_reference)

    add_test(NAME profile_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:profileprobe_ours>
                $<TARGET_FILE:profileprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)

    add_test(NAME md5_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:md5probe_ours>
                $<TARGET_FILE:md5probe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)

    # The synthetic profile corpus the differential suites will read.
    # Reference-linked: the corpus must be the reference's own bytes.
    add_executable(make_corpus make_corpus.c)
    target_link_libraries(make_corpus PRIVATE PkgConfig::SLCMS_REFERENCE)

    file(MAKE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/corpus)
    add_test(NAME corpus
        COMMAND make_corpus ${CMAKE_CURRENT_BINARY_DIR}/corpus)
    # Tests that read the corpus say so, so ctest orders them after it
    # and does not run them at all when it could not be made.
    set_tests_properties(corpus PROPERTIES FIXTURES_SETUP corpus)

    # The differentials that read profiles.  Both sides read the same
    # bytes: the corpus is the reference's own output, and the testbed's
    # profiles are checked in upstream.  When the upstream checkout is
    # present those come along too, since they are the LUT-based CMYK
    # profiles the corpus does not have.
    if(SLCMS_UPSTREAM_DIR)
        set(SLCMS_PROFILE_ARGS ${CMAKE_CURRENT_BINARY_DIR}/corpus ${SLCMS_UPSTREAM_DIR}/testbed)
    else()
        set(SLCMS_PROFILE_ARGS ${CMAKE_CURRENT_BINARY_DIR}/corpus)
    endif()

    add_executable(lutprobe_ours lutprobe.c)
    target_link_libraries(lutprobe_ours PRIVATE lcms2)
    add_executable(lutprobe_reference lutprobe.c)
    target_link_libraries(lutprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

    add_test(NAME lut_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:lutprobe_ours>
                $<TARGET_FILE:lutprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt
                ${SLCMS_PROFILE_ARGS})
    set_tests_properties(lut_differential PROPERTIES FIXTURES_REQUIRED corpus)

    add_executable(xformprobe_ours xformprobe.c)
    target_link_libraries(xformprobe_ours PRIVATE lcms2)
    add_executable(xformprobe_reference xformprobe.c)
    target_link_libraries(xformprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

    add_test(NAME transform_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:xformprobe_ours>
                $<TARGET_FILE:xformprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences-transform.txt
                ${SLCMS_PROFILE_ARGS})
    set_tests_properties(transform_differential PROPERTIES FIXTURES_REQUIRED corpus)

    # The same matrix with the optimizer on: the rewrites, evaluators
    # and fixed-point arithmetic of cmsopt.c.
    add_test(NAME transform_optimized_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:xformprobe_ours>
                $<TARGET_FILE:xformprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences-transform.txt
                ${SLCMS_PROFILE_ARGS} optimize)
    set_tests_properties(transform_optimized_differential PROPERTIES FIXTURES_REQUIRED corpus)

    add_executable(psprobe_ours psprobe.c)
    target_link_libraries(psprobe_ours PRIVATE lcms2)
    add_executable(psprobe_reference psprobe.c)
    target_link_libraries(psprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

    add_test(NAME postscript_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:psprobe_ours>
                $<TARGET_FILE:psprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt
                ${SLCMS_PROFILE_ARGS})
    set_tests_properties(postscript_differential PROPERTIES FIXTURES_REQUIRED corpus)

    add_executable(gbdprobe_ours gbdprobe.c)
    target_link_libraries(gbdprobe_ours PRIVATE lcms2)
    add_executable(gbdprobe_reference gbdprobe.c)
    target_link_libraries(gbdprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)
    if(NOT APPLE)
        target_link_libraries(gbdprobe_ours PRIVATE m)
        target_link_libraries(gbdprobe_reference PRIVATE m)
    endif()

    add_test(NAME gbd_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:gbdprobe_ours>
                $<TARGET_FILE:gbdprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)

    add_executable(pluginprobe_ours pluginprobe.c)
    target_link_libraries(pluginprobe_ours PRIVATE lcms2)
    add_executable(pluginprobe_reference pluginprobe.c)
    target_link_libraries(pluginprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)
    if(NOT APPLE)
        target_link_libraries(pluginprobe_ours PRIVATE m)
        target_link_libraries(pluginprobe_reference PRIVATE m)
    endif()

    add_test(NAME plugin_differential
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_conformance.sh
                $<TARGET_FILE:pluginprobe_ours>
                $<TARGET_FILE:pluginprobe_reference>
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)

elseif(SLCMS_REQUIRE_REFERENCE)
    message(FATAL_ERROR
        "No reference lcms2 found via pkg-config, and SLCMS_REQUIRE_REFERENCE "
        "is on.  A warning here is not enough: the suite would go green having "
        "skipped every differential, which is how a run reports success while "
        "measuring nothing.  Build one with scripts/build_reference.sh and "
        "point PKG_CONFIG_PATH at it.")
else()
    message(WARNING
        "No reference lcms2 found via pkg-config: the differential half of "
        "the conformance suite is not being built, and a suite that never "
        "compares against the reference is not measuring the claim.")
endif()

# -- the upstream testbed ----------------------------------------------------
#
# The reference's own test program, compiled unmodified and linked against
# our library.  It includes lcms2_internal.h, so the compile uses the
# upstream tree's headers — the public ones are byte-identical to our
# vendored copies — while the link is against us: whatever the testbed
# binds must come out of our 382 exports, which is the point.

if(NOT SLCMS_UPSTREAM_DIR)
    message(STATUS
        "conformance: no upstream checkout, so the testbed tests are skipped "
        "(set SLCMS_UPSTREAM_DIR to enable them)")
endif()

if(SLCMS_UPSTREAM_DIR)
    # The headers are vendored verbatim, and with the upstream tree in hand
    # that is measurable rather than merely asserted.  An edit here would
    # silently move the contract this library claims to satisfy.
    add_test(NAME header_verbatim_lcms2
        COMMAND ${CMAKE_COMMAND} -E compare_files
                ${SLCMS_INCLUDE_DIR}/lcms2.h
                ${SLCMS_UPSTREAM_DIR}/include/lcms2.h)

    add_test(NAME header_verbatim_lcms2_plugin
        COMMAND ${CMAKE_COMMAND} -E compare_files
                ${SLCMS_INCLUDE_DIR}/lcms2_plugin.h
                ${SLCMS_UPSTREAM_DIR}/include/lcms2_plugin.h)

    add_executable(testcms2
        ${SLCMS_UPSTREAM_DIR}/testbed/testcms2.c
        ${SLCMS_UPSTREAM_DIR}/testbed/testplugin.c
        ${SLCMS_UPSTREAM_DIR}/testbed/zoo_icc.c)

    target_include_directories(testcms2 PRIVATE
        ${SLCMS_UPSTREAM_DIR}/include
        ${SLCMS_UPSTREAM_DIR}/src)

    target_link_libraries(testcms2 PRIVATE lcms2)
    if(NOT APPLE)
        target_link_libraries(testcms2 PRIVATE m)
    endif()

    # The testbed runs to completion; the checks it still fails are listed
    # exactly in known-testbed-failures.txt and the driver requires the run
    # to match that list in both directions (a stale entry fails too), so
    # the list can only shrink honestly.  Empty list = exit status 0.
    add_test(NAME testbed
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_testbed.sh
                $<TARGET_FILE:testcms2>
                ${SLCMS_UPSTREAM_DIR}/testbed
                ${CMAKE_CURRENT_SOURCE_DIR}/known-testbed-failures.txt)
endif()
