/* Error dispatch and context-logger storage.
 *
 * This is the floor the generated stubs and the Swift boundary both stand
 * on, kept in C so that reporting "not implemented" never depends on the
 * thing that is not implemented.
 */

#include "swift_internal.h"

#include <stdio.h>
#include <stdlib.h>

/* Context0 storage.  Zero-initialized: no logger (the default handler does
 * nothing, as in the reference), no user data, no engine object.  Not an
 * exported symbol — the reference exports no data either. */
static struct _cmsContext_struct global_context;

struct _cmsContext_struct* swift_c_resolve_context(cmsContext ContextID)
{
    return ContextID ? ContextID : &global_context;
}

void swift_c_signal_error(cmsContext ContextID, cmsUInt32Number ErrorCode, const char* Text)
{
    struct _cmsContext_struct* ctx = swift_c_resolve_context(ContextID);

    /* The handler receives the ID the caller passed, not the resolved
     * handle — a client logger installed on the global context expects
     * NULL there, as in the reference. */
    if (ctx->error_logger)
        ctx->error_logger(ContextID, ErrorCode, Text);
}

void swift_unimplemented_fatal(const char* name)
{
    fprintf(stderr, "liblcms2 (Swift): %s is not implemented\n", name);
    fflush(stderr);
    abort();
}

void CMSEXPORT cmsSetLogErrorHandlerTHR(cmsContext ContextID, cmsLogErrorHandlerFunction Fn)
{
    /* Passing NULL restores the default handler; the default does nothing,
     * so NULL is how we store it. */
    swift_c_resolve_context(ContextID)->error_logger = Fn;
}

void CMSEXPORT cmsSetLogErrorHandler(cmsLogErrorHandlerFunction Fn)
{
    cmsSetLogErrorHandlerTHR(NULL, Fn);
}
