/*
 * Completions of the structs the public headers leave opaque.
 *
 * The public ABI does not see inside these — lcms2.h forward-declares them
 * and hands out pointers — so their layout is mostly ours to choose.  The
 * rule for what lives here directly: only plain data the C floor (error
 * dispatch, generated stubs) must reach without entering Swift.  Everything
 * with a lifetime managed by Swift hangs off the single opaque `swift_ctx`
 * pointer, which holds a retained Unmanaged reference to the engine object.
 *
 * "Mostly", because the reference's own testbed is part of this project's
 * conformance contract: Conformance/CMakeLists.txt compiles testcms2.c
 * unmodified against the reference's private lcms2_internal.h and links it
 * against us, and that suite has to pass eventually.  The testbed reaches
 * through two of these layouts on objects it obtained from us, which makes
 * their upstream field order contract in the same way the eighteen
 * CMSCHECKPOINT symbols are ABI:
 *
 *   _cms_curve_struct     testcms2.c reads InterpParams->ContextID and
 *                         indexes Table16[], and writes Table16[] and
 *                         Segments[0].Type, on curves from cmsBuildGamma
 *                         and cmsBuildTabulatedToneCurve16.  Reproduce
 *                         upstream's prefix (InterpParams, nSegments,
 *                         Segments, SegInterp, Evals, nEntries, Table16)
 *                         and append swift_ctx after it — the testbed only
 *                         ever holds pointers we allocated, so extending
 *                         the tail is invisible to it.
 *
 *   _cmstransform_struct  testcms2.c stack-allocates one at upstream
 *                         sizeof, sets InputFormat/OutputFormat at upstream
 *                         offsets, and hands it to the formatters that
 *                         _cmsGetFormatter returns, so the head of the
 *                         struct through OutputFormat is constrained too.
 *
 * Neither object exists yet.  The phase that first allocates one takes the
 * upstream layout with it; the layouts below are free of that constraint
 * only because nothing reaches into them.
 *
 * lcms2 has no setjmp/longjmp contract — errors are a logger callback plus
 * NULL/FALSE returns — so unlike a libpng-style boundary there is no jump
 * buffer and no message staging area to keep C-visible.
 *
 * Requires lcms2.h to be included first.  This header is not installed.
 */

#ifndef _cmsstruct_abi_H
#define _cmsstruct_abi_H

/* The public handle type is `struct _cmsContext_struct*`, so the C error
 * floor can read the logger straight off the handle.  A static instance of
 * this struct in lcms2_error.c backs the ContextID == NULL global context. */
struct _cmsContext_struct {
    cmsLogErrorHandlerFunction error_logger;  /* NULL = the default handler, which does nothing */
    void* user_data;                          /* cmsGetContextUserData's answer */
    void* swift_ctx;                          /* retained Unmanaged<Context>, engine-owned */
};

/* The field order through Table16 is the reference's, because its testbed
 * dereferences these on curves this library allocated — see the note
 * above.  swift_ctx is appended after, where nothing reaching in by that
 * layout can see it. */
struct _cms_curve_struct {
    cmsInterpParams*  InterpParams;   /* the 16-bit table's interpolation */

    cmsUInt32Number   nSegments;      /* zero for a purely table-based curve */
    cmsCurveSegment*  Segments;
    cmsInterpParams** SegInterp;      /* one per sampled segment, else null */

    cmsParametricCurveEvaluator* Evals;   /* one per segment */

    cmsUInt32Number   nEntries;
    cmsUInt16Number*  Table16;

    void* swift_ctx;                  /* unused for curves; the storage is C */
};
struct _cmsPipeline_struct         { void* swift_ctx; };

/* The dictionary behind a cmsHANDLE.  Its own layout is private — only
 * the entries it hands out are published — but it is C memory because
 * those entries are, and the list has to hang off something. */
struct _cms_dict_struct {
    cmsContext    ContextID;
    cmsDICTentry* head;
};
struct _cmsStage_struct            { void* swift_ctx; };
struct _cms_MLU_struct             { void* swift_ctx; };
struct _cms_NAMEDCOLORLIST_struct  { void* swift_ctx; };

/* cmsHPROFILE, cmsHTRANSFORM, and cmsHANDLE are plain void* in the public
 * header; the structs backing them are declared here when the engine first
 * allocates them.
 *
 * Deliberately NOT completed here: cmsIOHANDLER, cmsInterpParams, and
 * cmsDICTentry.  Their layouts are public in the vendored headers — they
 * are contract, not ours to define. */

#endif  /* _cmsstruct_abi_H */
