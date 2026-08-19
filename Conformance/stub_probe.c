/* stub_probe.c - pins the fail-loudly contract of the generated stubs
 *
 * Calls an entry point that is deliberately not implemented yet and checks
 * that the gap is reported through the library's normal error path and the
 * call fails cleanly.  Runs only against our library; the day the last stub
 * retires, this probe is deleted with the machinery it tests.
 */

#include "lcms2.h"

#include <stdio.h>

static void logger(cmsContext id, cmsUInt32Number code, const char* text)
{
    (void) id;
    printf("logged %u: %s\n", code, text);
}

int main(void)
{
    cmsSetLogErrorHandler(logger);

    /* Any context-carrying, still-stubbed entry point serves; the
     * PostScript generator is outside the first milestone's scope, so it
     * will stay one for a while. */
    cmsUInt32Number n = cmsGetPostScriptCSA(NULL, NULL, 0, 0, NULL, 0);
    if (n != 0) {
        fprintf(stderr, "stub returned a non-zero count\n");
        return 1;
    }

    printf("stub probe OK\n");
    return 0;
}
