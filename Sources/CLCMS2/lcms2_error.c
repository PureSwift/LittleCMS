/* Error dispatch and context-logger storage.
 *
 * This is the floor the generated stubs and the Swift boundary both stand
 * on, kept in C so that reporting "not implemented" never depends on the
 * thing that is not implemented.
 */

#include "swift_internal.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

/* Context0 storage.  Zero-initialized: no logger (the default handler does
 * nothing, as in the reference), no user data, no engine object.  Not an
 * exported symbol — the reference exports no data either. */
static struct _cmsContext_struct global_context;

/* The pool of contexts cmsCreateContext has made and not yet deleted.
 * Resolution walks it, and any pointer not in it means the global
 * context — the reference's rule, which its testbed leans on by passing
 * made-up handles.  The walk is unlocked, as the reference's is; only
 * the mutations take the lock. */
static struct _cmsContext_struct* context_pool;
static pthread_mutex_t context_pool_mutex = PTHREAD_MUTEX_INITIALIZER;

struct _cmsContext_struct* swift_c_resolve_context(cmsContext ContextID)
{
    struct _cmsContext_struct* ctx;

    if (ContextID == NULL) return &global_context;
    for (ctx = context_pool; ctx != NULL; ctx = ctx->next) {
        if (ctx == ContextID) return ctx;
    }
    return &global_context;
}

void swift_c_register_context(struct _cmsContext_struct* ctx)
{
    pthread_mutex_lock(&context_pool_mutex);
    ctx->next = context_pool;
    context_pool = ctx;
    pthread_mutex_unlock(&context_pool_mutex);
}

/* Unlinks a context; returns whether it was in the pool at all. */
int swift_c_unregister_context(struct _cmsContext_struct* ctx)
{
    struct _cmsContext_struct** link;
    int found = 0;

    pthread_mutex_lock(&context_pool_mutex);
    for (link = &context_pool; *link != NULL; link = &(*link)->next) {
        if (*link == ctx) {
            *link = ctx->next;
            found = 1;
            break;
        }
    }
    pthread_mutex_unlock(&context_pool_mutex);
    return found;
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
