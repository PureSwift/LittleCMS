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

add_executable(primprobe_ours primprobe.c)
target_link_libraries(primprobe_ours PRIVATE lcms2)
if(NOT APPLE)
    target_link_libraries(primprobe_ours PRIVATE m)
endif()

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
if(NOT APPLE)
    target_link_libraries(colorprobe_ours PRIVATE m)
endif()
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

add_executable(profileprobe_ours profileprobe.c)
target_link_libraries(profileprobe_ours PRIVATE lcms2)
add_test(NAME profile_probe COMMAND profileprobe_ours)

# The stubs' contract: the gap is reported through the error path and the
# call fails cleanly rather than answering.
add_test(NAME stub_behavior COMMAND stub_probe_ours)
set_tests_properties(stub_behavior PROPERTIES
    PASS_REGULAR_EXPRESSION "is not implemented"
    FAIL_REGULAR_EXPRESSION "stub returned")

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
    if(NOT APPLE)
        target_link_libraries(primprobe_reference PRIVATE m)
    endif()

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
    if(NOT APPLE)
        target_link_libraries(colorprobe_reference PRIVATE m)
    endif()

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

    add_executable(profileprobe_reference profileprobe.c)
    target_link_libraries(profileprobe_reference PRIVATE PkgConfig::SLCMS_REFERENCE)

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

    # Until the engine is complete the run must die at the first
    # unimplemented call — loudly and attributably, never with a plausible
    # wrong answer.  The driver script owns that inverted contract (an
    # abnormal exit outranks PASS_REGULAR_EXPRESSION, so ctest cannot
    # express it directly) and flips to requiring success when the suite
    # starts passing for real.
    add_test(NAME testbed_fails_loudly
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_testbed.sh
                $<TARGET_FILE:testcms2>
                ${SLCMS_UPSTREAM_DIR}/testbed)
endif()
