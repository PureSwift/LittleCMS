/* version_probe.c - the floor of the conformance suite
 *
 * Verifies the version report and the error-logging path.  Compiled twice
 * from this one source — once against our library, once against the
 * reference — and both binaries must pass and print identical output: an
 * expectation written from memory rather than from observation is worse
 * than no test.
 */

#include "lcms2.h"
#include "lcms2_plugin.h"   /* cmsSignalError lives in the plugin header */

#include <stdio.h>
#include <string.h>

static char last_text[1024];
static cmsUInt32Number last_code;

static void logger(cmsContext id, cmsUInt32Number code, const char* text)
{
    (void) id;
    last_code = code;
    snprintf(last_text, sizeof last_text, "%s", text);
}

int main(void)
{
    printf("version %d\n", cmsGetEncodedCMMversion());
    if (cmsGetEncodedCMMversion() != LCMS_VERSION) return 1;

    /* Silent by default: the default handler must swallow this. */
    last_text[0] = 0;
    cmsSignalError(NULL, cmsERROR_RANGE, "must not appear");
    if (last_text[0] != 0) return 1;

    cmsSetLogErrorHandler(logger);
    cmsSignalError(NULL, cmsERROR_RANGE, "range %d..%d in %s", 1, 7, "probe");
    if (last_code != cmsERROR_RANGE) return 1;
    if (strcmp(last_text, "range 1..7 in probe") != 0) return 1;
    printf("logger %u: %s\n", last_code, last_text);

    /* NULL restores the do-nothing default. */
    cmsSetLogErrorHandler(NULL);
    last_text[0] = 0;
    cmsSignalError(NULL, cmsERROR_RANGE, "must not appear either");
    if (last_text[0] != 0) return 1;

    printf("version probe OK\n");
    return 0;
}
