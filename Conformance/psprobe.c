/* psprobe - PostScript colour space arrays and rendering dictionaries
 *
 * Each is generated into memory and printed in full — every number is a
 * printf conversion whose text must agree — except the header's
 * timestamp line, which is masked, since it is the clock.  The sizes
 * that come back from the counting call and the writing call are printed
 * too.
 *
 * Usage: psprobe <corpus-dir> [<testbed-dir>]
 */

#include "lcms2.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void logger(cmsContext id, cmsUInt32Number code, const char* text)
{
    (void) id;
    printf("  error %u: %s\n", code, text);
}

static void print_masked(const char* text, cmsUInt32Number n)
{
    /* Print line by line; the "% Created:" line carries the clock. */
    const char* p = text;
    const char* end = text + n;
    while (p < end) {
        const char* nl = memchr(p, '\n', (size_t) (end - p));
        size_t len = nl ? (size_t) (nl - p) + 1 : (size_t) (end - p);
        if (len >= 10 && strncmp(p, "% Created:", 10) == 0) fputs("% Created: <masked>\n", stdout);
        else fwrite(p, 1, len, stdout);
        p += len;
    }
    if (n == 0 || text[n - 1] != '\n') printf("\n");
}

static void csa(cmsHPROFILE h, const char* name, cmsUInt32Number intent, cmsUInt32Number flags)
{
    if (h == NULL) return;
    printf("== CSA %s intent %u flags %x\n", name, intent, flags);
    cmsUInt32Number n = cmsGetPostScriptCSA(NULL, h, intent, flags, NULL, 0);
    printf("size %u\n", n);
    if (n == 0) return;
    char* buf = (char*) calloc(n + 1, 1);
    cmsUInt32Number m = cmsGetPostScriptCSA(NULL, h, intent, flags, buf, n + 1);
    printf("written %u\n", m);
    print_masked(buf, m);
    free(buf);
}

static void crd(cmsHPROFILE h, const char* name, cmsUInt32Number intent, cmsUInt32Number flags)
{
    if (h == NULL) return;
    printf("== CRD %s intent %u flags %x\n", name, intent, flags);
    cmsUInt32Number n = cmsGetPostScriptCRD(NULL, h, intent, flags, NULL, 0);
    printf("size %u\n", n);
    if (n == 0) return;
    char* buf = (char*) calloc(n + 1, 1);
    cmsUInt32Number m = cmsGetPostScriptCRD(NULL, h, intent, flags, buf, n + 1);
    printf("written %u\n", m);
    print_masked(buf, m);
    free(buf);
}

static cmsHPROFILE open_named(const char* dir, const char* name)
{
    char path[1024];
    snprintf(path, sizeof path, "%s/%s.icc", dir, name);
    return cmsOpenProfileFromFile(path, "r");
}

int main(int argc, char** argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 2) { fprintf(stderr, "usage: psprobe <corpus-dir> [<testbed-dir>]\n"); return 2; }
    cmsSetLogErrorHandler(logger);

    cmsHPROFILE srgb = open_named(argv[1], "srgb");
    cmsHPROFILE gray = open_named(argv[1], "gray22");
    cmsHPROFILE lab4 = open_named(argv[1], "lab4");
    cmsHPROFILE t1 = NULL, t3 = NULL, crayons = NULL, ibm = NULL;
    if (argc > 2) {
        t1 = open_named(argv[2], "test1");
        t3 = open_named(argv[2], "test3");
        crayons = open_named(argv[2], "crayons");
        ibm = open_named(argv[2], "ibm-t61");
    }

    /* Matrix-shaper and grey CSAs: small, so every intent. */
    for (cmsUInt32Number intent = 0; intent < 4; intent++) csa(srgb, "srgb", intent, 0);
    csa(gray, "gray22", 0, 0);
    csa(gray, "gray22", 1, 0);
    csa(lab4, "lab4", 0, 0);
    /* LUT-based CSAs are tables: at the low resolution to keep the text short. */
    csa(t1, "test1", 0, cmsFLAGS_LOWRESPRECALC);
    csa(t1, "test1", 3, cmsFLAGS_LOWRESPRECALC);
    csa(ibm, "ibm-t61", 1, cmsFLAGS_LOWRESPRECALC);
    csa(crayons, "crayons", 0, 0);

    /* CRDs, likewise at low resolution. */
    crd(srgb, "srgb", 0, cmsFLAGS_LOWRESPRECALC);
    crd(srgb, "srgb", 1, cmsFLAGS_LOWRESPRECALC | cmsFLAGS_BLACKPOINTCOMPENSATION);
    crd(srgb, "srgb", 3, cmsFLAGS_LOWRESPRECALC);
    crd(srgb, "srgb", 2, cmsFLAGS_LOWRESPRECALC | cmsFLAGS_NODEFAULTRESOURCEDEF | cmsFLAGS_NOWHITEONWHITEFIXUP);
    crd(gray, "gray22", 1, cmsFLAGS_LOWRESPRECALC);
    crd(t3, "test3", 0, cmsFLAGS_LOWRESPRECALC);
    crd(t3, "test3", 3, cmsFLAGS_LOWRESPRECALC | cmsFLAGS_BLACKPOINTCOMPENSATION);
    crd(crayons, "crayons", 0, 0);

    /* Refusals: a Lab profile as a CSA source has no matrix-shaper and its
     * PCS is not a device space; a wrong resource type falls to CRD. */
    printf("== through the resource entry\n");
    cmsIOHANDLER* io = cmsOpenIOhandlerFromNULL(NULL);
    printf("as CRD %u\n", cmsGetPostScriptColorResource(NULL, cmsPS_RESOURCE_CRD, srgb, 0, cmsFLAGS_LOWRESPRECALC, io));
    cmsCloseIOhandler(io);
    io = cmsOpenIOhandlerFromNULL(NULL);
    printf("as other %u\n", cmsGetPostScriptColorResource(NULL, (cmsPSResourceType) 7, srgb, 0, cmsFLAGS_LOWRESPRECALC, io));
    cmsCloseIOhandler(io);

    cmsCloseProfile(srgb); cmsCloseProfile(gray); cmsCloseProfile(lab4);
    if (t1) cmsCloseProfile(t1); if (t3) cmsCloseProfile(t3); if (crayons) cmsCloseProfile(crayons); if (ibm) cmsCloseProfile(ibm);
    return 0;
}
