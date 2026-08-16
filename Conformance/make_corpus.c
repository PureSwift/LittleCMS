/* make_corpus.c - synthesize the profile corpus with the reference library
 *
 * Compiled against the REFERENCE only.  The differential suites need real
 * ICC bytes produced by the implementation being measured against, and a
 * corpus described by the program that makes it beats a directory of opaque
 * committed binaries.  Output lands in the build tree, never the repo.
 *
 * usage: make_corpus <output-directory>
 */

#include "lcms2.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;

static void save(cmsHPROFILE profile, const char* directory, const char* name)
{
    char path[1024];

    if (profile == NULL) {
        fprintf(stderr, "make_corpus: could not create %s\n", name);
        failures++;
        return;
    }
    snprintf(path, sizeof path, "%s/%s.icc", directory, name);
    if (!cmsSaveProfileToFile(profile, path)) {
        fprintf(stderr, "make_corpus: could not save %s\n", path);
        failures++;
    }
    cmsCloseProfile(profile);
    printf("%s.icc\n", name);
}

int main(int argc, char** argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: make_corpus <output-directory>\n");
        return 2;
    }
    const char* dir = argv[1];

    save(cmsCreate_sRGBProfile(), dir, "srgb");
    save(cmsCreateLab4Profile(NULL), dir, "lab4");
    save(cmsCreateLab2Profile(NULL), dir, "lab2");
    save(cmsCreateXYZProfile(), dir, "xyz");
    save(cmsCreateNULLProfile(), dir, "null");

    {
        cmsToneCurve* gamma22 = cmsBuildGamma(NULL, 2.2);
        save(cmsCreateGrayProfile(cmsD50_xyY(), gamma22), dir, "gray22");
        cmsFreeToneCurve(gamma22);
    }

    {
        /* Rec.709 primaries, D65, sRGB-ish parametric curves. */
        cmsCIExyY d65 = { 0.3127, 0.3290, 1.0 };
        cmsCIExyYTRIPLE primaries = {
            { 0.640, 0.330, 1.0 },
            { 0.300, 0.600, 1.0 },
            { 0.150, 0.060, 1.0 },
        };
        cmsFloat64Number srgb_params[5] = { 2.4, 1.0 / 1.055, 0.055 / 1.055, 1.0 / 12.92, 0.04045 };
        cmsToneCurve* curve = cmsBuildParametricToneCurve(NULL, 4, srgb_params);
        cmsToneCurve* curves[3] = { curve, curve, curve };
        save(cmsCreateRGBProfile(&d65, &primaries, curves), dir, "rgb709");
        cmsFreeToneCurve(curve);
    }

    {
        cmsToneCurve* linear = cmsBuildGamma(NULL, 1.0);
        cmsToneCurve* curves[3] = { linear, linear, linear };
        save(cmsCreateLinearizationDeviceLink(cmsSigRgbData, curves), dir, "linear-devicelink");
        cmsFreeToneCurve(linear);
    }

    save(cmsCreateInkLimitingDeviceLink(cmsSigCmykData, 250.0), dir, "inklimit-devicelink");

    return failures ? 1 : 0;
}
