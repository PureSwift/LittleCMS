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
# would compare this library against itself and report agreement.  Once
# this library is installed somewhere pkg-config looks, that is exactly
# what happens, so the discovered library is rejected when it resolves
# inside our own install prefix.
if(SLCMS_REFERENCE_FOUND)
    foreach(dir ${SLCMS_REFERENCE_LIBRARY_DIRS})
        cmake_path(IS_PREFIX CMAKE_INSTALL_PREFIX "${dir}" NORMALIZE is_ours)
        if(is_ours)
            message(WARNING
                "The lcms2 pkg-config found (${dir}) is inside this project's "
                "install prefix, so it is probably this library rather than the "
                "reference.  The differential suites are disabled; point "
                "PKG_CONFIG_PATH at a reference build of 2.19.")
            set(SLCMS_REFERENCE_FOUND FALSE)
        endif()
    endforeach()
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

add_test(NAME version_probe COMMAND version_probe_ours)
add_test(NAME primitives_probe COMMAND primprobe_ours)
add_test(NAME matrix_probe COMMAND matprobe_ours)

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

    # The synthetic profile corpus the differential suites will read.
    # Reference-linked: the corpus must be the reference's own bytes.
    add_executable(make_corpus make_corpus.c)
    target_link_libraries(make_corpus PRIVATE PkgConfig::SLCMS_REFERENCE)

    file(MAKE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/corpus)
    add_test(NAME corpus
        COMMAND make_corpus ${CMAKE_CURRENT_BINARY_DIR}/corpus)
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
