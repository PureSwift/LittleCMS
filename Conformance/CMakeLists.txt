# Conformance - the programs that measure the drop-in claim
#
# These are C programs on purpose: the claim is that a C client built for
# lcms2 works against this library, and only a C client can test that.
# Every differential program is compiled twice from identical source — once
# against us, once against the reference — because an expectation written
# from memory rather than from observation is worse than no test.

# The reference library, for the second build of each differential program.
# CI builds it from source at the pinned tag; locally any installed 2.19
# serves.  Overridable so a source-built reference wins over a distro one.
find_package(PkgConfig)
if(PkgConfig_FOUND)
    pkg_check_modules(SLCMS_REFERENCE IMPORTED_TARGET lcms2)
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

add_test(NAME version_probe COMMAND version_probe_ours)

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
