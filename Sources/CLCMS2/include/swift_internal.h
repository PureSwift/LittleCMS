/*
 * The umbrella the Swift boundary imports.  One include yields the public
 * API, the plugin API, the exported-but-unheadered declarations, and the
 * completed control structures — imported so that every `@c @implementation`
 * function in LCMS2ABI can be type-checked against the declaration clients
 * were compiled against.
 *
 * Naming convention for the internal cross-language surface:
 *
 *   swift_c_*      implemented in C, called from Swift
 *   swift_swift_*  implemented in Swift with @c, called from C
 *
 * Neither family is exported from the finished library; the export list
 * drops them.  This header is not installed.
 */

#ifndef _swift_internal_H
#define _swift_internal_H

#include "lcms2.h"
#include "lcms2_plugin.h"

/* The TYPE_* constants as values, since Swift cannot import a macro
 * expression.  Generated; see scripts/gen_pixel_types.py. */
#include "lcms2_pixel_types.h"
#include "lcms2_unshipped.h"
#include "cmsstruct_abi.h"

#ifdef __cplusplus
extern "C" {
#endif

/* lcms2_error.c ------------------------------------------------------------ */

/* The handle for a context ID, never NULL: the static global-context
 * instance when ContextID is NULL, the handle itself otherwise. */
struct _cmsContext_struct* swift_c_resolve_context(cmsContext ContextID);

/* Non-variadic error dispatch: Swift cannot call the variadic
 * cmsSignalError, and the generated stubs need the same funnel.  Runs the
 * context's logger; the default logger does nothing, as in the reference. */
void swift_c_signal_error(cmsContext ContextID, cmsUInt32Number ErrorCode, const char* Text);

/* The stub body for functions with no error channel: a plausible zero
 * return from them would be a wrong answer rather than a failure, so the
 * only honest report is a loud one. */
void swift_unimplemented_fatal(const char* name) __attribute__((__noreturn__));

#ifdef __cplusplus
}
#endif

#endif  /* _swift_internal_H */
