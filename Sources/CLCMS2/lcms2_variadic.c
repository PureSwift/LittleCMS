/* The three variadic entry points.
 *
 * Swift cannot define a C variadic function, so these are hand-written C
 * from day one and stay that way; the generator treats a variadic in the
 * stub set as an error.  The printf-shaped pair must match the reference's
 * output byte for byte, so their bodies mirror cmserr.c and cmsplugin.c —
 * buffer sizes, truncation policy, and the comma rewrite included.
 */

#include "swift_internal.h"

#include <stdarg.h>
#include <stdio.h>

/* The reference's cmserr.c value. */
#define MAX_ERROR_MESSAGE_LEN 1024

void CMSEXPORT cmsSignalError(cmsContext ContextID, cmsUInt32Number ErrorCode, const char* ErrorText, ...)
{
    va_list args;
    char Buffer[MAX_ERROR_MESSAGE_LEN];

    va_start(args, ErrorText);
    vsnprintf(Buffer, MAX_ERROR_MESSAGE_LEN - 1, ErrorText, args);
    va_end(args);

    swift_c_signal_error(ContextID, ErrorCode, Buffer);
}

cmsBool CMSEXPORT _cmsIOPrintf(cmsIOHANDLER* io, const char* frm, ...)
{
    va_list args;
    int len;
    cmsUInt8Number Buffer[2048];
    cmsBool rc;
    cmsUInt8Number* ptr;

    if (io == NULL || frm == NULL) return FALSE;

    va_start(args, frm);

    len = vsnprintf((char*) Buffer, 2047, frm, args);
    if (len < 0 || len >= 2047) {
        va_end(args);
        return FALSE;   /* truncated, which is a fatal error for us */
    }

    /* setlocale may be active; the PostScript generator is the only client
     * and needs no commas. */
    for (ptr = Buffer; *ptr; ptr++) {
        if (*ptr == ',') *ptr = '.';
    }

    rc = io->Write(io, (cmsUInt32Number) len, Buffer);

    va_end(args);

    return rc;
}

cmsBool CMSEXPORT cmsPipelineCheckAndRetreiveStages(const cmsPipeline* Lut, cmsUInt32Number n, ...)
{
    /* The va_list here is `n` stage-type signatures followed by `n`
     * cmsStage** out-pointers; walking it needs the pipeline engine, so
     * until stages exist this reports through the normal error path.  It
     * signals on the global context because reaching the pipeline's
     * context is itself part of what is not implemented yet. */
    (void) Lut;
    (void) n;
    swift_c_signal_error(NULL, cmsERROR_NOT_SUITABLE,
                         "cmsPipelineCheckAndRetreiveStages is not implemented");
    return FALSE;
}
