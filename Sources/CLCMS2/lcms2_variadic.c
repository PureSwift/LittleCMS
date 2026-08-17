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
    /* The variable arguments are `n` stage-type signatures followed by
     * `n` cmsStage** out-pointers -- one list, read in two passes.  The
     * second pass continues the same va_list rather than restarting it,
     * which is why the two groups cannot be interleaved.
     *
     * Nothing is written unless every type matches, so a caller may try
     * several shapes in turn against the same out-pointers and only the
     * shape that fits will fill them.  That is how the LutAToB writer
     * decides which of its four layouts a pipeline has.
     *
     * Stays hand-written C forever: a variadic function cannot be
     * defined in Swift.  It reaches the pipeline only through exported
     * accessors, so the engine behind them is still Swift. */
    va_list args;
    cmsUInt32Number i;
    cmsStage* mpe;

    if (cmsPipelineStageCount(Lut) != n) return FALSE;

    va_start(args, n);

    mpe = cmsPipelineGetPtrToFirstStage(Lut);
    for (i = 0; i < n; i++) {

        /* cmsStageSignature is promoted to int through the ellipsis. */
        cmsStageSignature Type = (cmsStageSignature) va_arg(args, int);

        if (mpe == NULL || cmsStageType(mpe) != Type) {
            va_end(args);
            return FALSE;
        }
        mpe = cmsStageNext(mpe);
    }

    mpe = cmsPipelineGetPtrToFirstStage(Lut);
    for (i = 0; i < n; i++) {

        void** ElemPtr = va_arg(args, void**);
        if (ElemPtr != NULL)
            *ElemPtr = mpe;

        mpe = cmsStageNext(mpe);
    }

    va_end(args);
    return TRUE;
}
