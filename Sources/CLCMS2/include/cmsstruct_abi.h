/*
 * Completions of the structs the public headers leave opaque.
 *
 * The public ABI never sees inside these — lcms2.h forward-declares them
 * and hands out pointers — so their layout is ours to choose.  The rule for
 * what lives here directly: only plain data the C floor (error dispatch,
 * generated stubs) must reach without entering Swift.  Everything with a
 * lifetime managed by Swift hangs off the single opaque `swift_ctx` pointer,
 * which holds a retained Unmanaged reference to the engine object.
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

struct _cms_curve_struct           { void* swift_ctx; };
struct _cmsPipeline_struct         { void* swift_ctx; };
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
