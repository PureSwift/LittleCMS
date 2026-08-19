/* virtprobe - the built-in profiles
 *
 * Each virtual profile is created, saved to memory, and its bytes
 * hashed with the creation date masked out (it is stamped from the
 * clock).  Everything else — header, tag directory, every tag's bytes —
 * has to agree with the reference.  Each is then opened again from those
 * bytes and used as an end of a transform, so that what it *does* is
 * compared too, not only what it stores.
 */

#include "lcms2.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t hash_state = 1469598103934665603ULL;

static void feed(const void* bytes, size_t length)
{
    const unsigned char* p = (const unsigned char*) bytes;
    for (size_t i = 0; i < length; i++) {
        hash_state ^= p[i];
        hash_state *= 1099511628211ULL;
    }
}

static void report(const char* name)
{
    printf("  %-40s %016llx\n", name, (unsigned long long) hash_state);
    hash_state = 1469598103934665603ULL;
}

static void logger(cmsContext id, cmsUInt32Number code, const char* text)
{
    (void) id;
    printf("  error %u: %s\n", code, text);
}

/* Save, hash (date masked), print size and the tag directory, and hand
 * back a copy opened from the saved bytes — or NULL. */
static cmsHPROFILE saved(const char* name, cmsHPROFILE h)
{
    if (h == NULL) { printf("%s: (not created)\n", name); return NULL; }
    printf("%s\n", name);

    cmsUInt32Number size = 0;
    cmsSaveProfileToMem(h, NULL, &size);
    unsigned char* bytes = (unsigned char*) malloc(size ? size : 1);
    if (!cmsSaveProfileToMem(h, bytes, &size)) { printf("  (save failed)\n"); free(bytes); cmsCloseProfile(h); return NULL; }

    for (cmsUInt32Number i = 0; i < size; i++) {
        if (i >= 24 && i < 36) continue;   /* creation date */
        feed(&bytes[i], 1);
    }
    printf("  size %u version %.1f class %08x space %08x pcs %08x tags %d\n", size,
           cmsGetProfileVersion(h), cmsGetDeviceClass(h), cmsGetColorSpace(h), cmsGetPCS(h), cmsGetTagCount(h));
    for (int i = 0; i < cmsGetTagCount(h); i++) {
        cmsTagSignature s = cmsGetTagSignature(h, i);
        printf("   %c%c%c%c", (s >> 24) & 0xFF, (s >> 16) & 0xFF, (s >> 8) & 0xFF, s & 0xFF);
    }
    printf("\n");
    report("bytes");

    cmsHPROFILE reopened = cmsOpenProfileFromMem(bytes, size);
    free(bytes);
    cmsCloseProfile(h);
    return reopened;
}

/* A grid of RGB_16 through a pair, hashed. */
static void through(const char* what, cmsHPROFILE a, cmsUInt32Number fin, cmsHPROFILE b, cmsUInt32Number fout, cmsUInt32Number intent)
{
    if (a == NULL || b == NULL) return;
    cmsHTRANSFORM x = cmsCreateTransform(a, fin, b, fout, intent, cmsFLAGS_NOOPTIMIZE);
    if (x == NULL) { printf("  %-40s (refused)\n", what); return; }
    unsigned short in[16], out[16];
    unsigned char in8[16], out8[16 * 8];
    for (int i = 0; i < 6 * 6 * 6; i++) {
        int r = i % 6, g = (i / 6) % 6, bl = i / 36;
        in[0] = (unsigned short) (r * 13107); in[1] = (unsigned short) (g * 13107); in[2] = (unsigned short) (bl * 13107); in[3] = (unsigned short) ((r + g) * 6553);
        in8[0] = (unsigned char) (r * 51); in8[1] = (unsigned char) (g * 51); in8[2] = (unsigned char) (bl * 51); in8[3] = (unsigned char) ((r + g) * 25);
        memset(out, 0, sizeof out); memset(out8, 0, sizeof out8);
        if (T_BYTES(fin) == 1) cmsDoTransform(x, in8, T_BYTES(fout) == 1 ? (void*) out8 : (void*) out, 1);
        else cmsDoTransform(x, in, T_BYTES(fout) == 1 ? (void*) out8 : (void*) out, 1);
        if (T_BYTES(fout) == 1) feed(out8, 16); else feed(out, sizeof out);
    }
    cmsDeleteTransform(x);
    report(what);
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    cmsSetLogErrorHandler(logger);

    cmsHPROFILE srgb = saved("sRGB", cmsCreate_sRGBProfile());
    cmsHPROFILE lab4 = saved("Lab4", cmsCreateLab4Profile(NULL));
    cmsHPROFILE lab2 = saved("Lab2", cmsCreateLab2Profile(NULL));
    cmsCIExyY d65 = { 0.3127, 0.3290, 1.0 };
    cmsHPROFILE lab4d65 = saved("Lab4 D65", cmsCreateLab4Profile(&d65));
    cmsHPROFILE lab2d65 = saved("Lab2 D65", cmsCreateLab2Profile(&d65));
    cmsHPROFILE xyz = saved("XYZ", cmsCreateXYZProfile());
    cmsHPROFILE nullp = saved("NULL", cmsCreateNULLProfile());

    cmsToneCurve* g22 = cmsBuildGamma(NULL, 2.2);
    cmsHPROFILE gray = saved("gray 2.2 D50", cmsCreateGrayProfile(cmsD50_xyY(), g22));
    cmsHPROFILE grayNoWP = saved("gray no white point", cmsCreateGrayProfile(NULL, g22));
    cmsHPROFILE grayNoCurve = saved("gray no curve", cmsCreateGrayProfile(&d65, NULL));

    cmsCIExyYTRIPLE rec709 = { { 0.64, 0.33, 1.0 }, { 0.30, 0.60, 1.0 }, { 0.15, 0.06, 1.0 } };
    cmsToneCurve* three[3] = { g22, g22, g22 };
    cmsHPROFILE rgb709 = saved("RGB 709 gamma 2.2", cmsCreateRGBProfile(&d65, &rec709, three));
    cmsToneCurve* g18 = cmsBuildGamma(NULL, 1.8);
    cmsToneCurve* mixed[3] = { g22, g18, g22 };
    cmsHPROFILE rgbMixed = saved("RGB 709 mixed curves", cmsCreateRGBProfile(&d65, &rec709, mixed));
    cmsHPROFILE rgbNoCurves = saved("RGB 709 no curves", cmsCreateRGBProfile(&d65, &rec709, NULL));
    cmsHPROFILE rgbWhiteOnly = saved("RGB white only", cmsCreateRGBProfile(&d65, NULL, NULL));
    cmsHPROFILE rgbEmpty = saved("RGB nothing", cmsCreateRGBProfile(NULL, NULL, NULL));

    cmsToneCurve* four[4] = { g22, g18, g22, g18 };
    cmsHPROFILE linRGB = saved("linearization RGB", cmsCreateLinearizationDeviceLink(cmsSigRgbData, three));
    cmsHPROFILE linCMYK = saved("linearization CMYK", cmsCreateLinearizationDeviceLink(cmsSigCmykData, four));
    cmsHPROFILE ink250 = saved("ink limit 250", cmsCreateInkLimitingDeviceLink(cmsSigCmykData, 250.0));
    cmsHPROFILE ink400 = saved("ink limit 400", cmsCreateInkLimitingDeviceLink(cmsSigCmykData, 400.0));
    printf("ink limit out of range\n");
    cmsHPROFILE inkLow = saved("ink limit 0.5 (clamped)", cmsCreateInkLimitingDeviceLink(cmsSigCmykData, 0.5));
    printf("ink limit wrong space: %s\n", cmsCreateInkLimitingDeviceLink(cmsSigRgbData, 200.0) ? "created" : "refused");

    cmsHPROFILE bchsw = saved("BCHSW 17 bright 5 contrast 1.1", cmsCreateBCHSWabstractProfile(17, 5.0, 1.1, 10.0, 3.0, 5000, 5000));
    cmsHPROFILE bchswTemp = saved("BCHSW 9 with temperature shift", cmsCreateBCHSWabstractProfile(9, 0.0, 1.0, 0.0, 0.0, 6500, 5000));

    /* OkLab cannot be saved (the float normalisation stages have no tag
     * type), so it is described and used, not saved. */
    cmsHPROFILE oklab = cmsCreate_OkLabProfile(NULL);
    printf("OkLab %s\n", oklab ? "created" : "(not created)");
    if (oklab) printf("  class %08x space %08x pcs %08x\n", cmsGetDeviceClass(oklab), cmsGetColorSpace(oklab), cmsGetPCS(oklab));

    printf("transforms\n");
    through("sRGB>rgb709", srgb, TYPE_RGB_16, rgb709, TYPE_RGB_16, 0);
    through("sRGB>rgbMixed rel", srgb, TYPE_RGB_16, rgbMixed, TYPE_RGB_16, 1);
    through("rgbMixed>sRGB abs", rgbMixed, TYPE_RGB_16, srgb, TYPE_RGB_16, 3);
    through("sRGB>lab4", srgb, TYPE_RGB_16, lab4, TYPE_Lab_16, 1);
    through("sRGB>lab4d65 abs", srgb, TYPE_RGB_16, lab4d65, TYPE_Lab_16, 3);
    through("sRGB>lab2d65", srgb, TYPE_RGB_16, lab2d65, TYPE_Lab_16, 1);
    through("lab2>lab4", lab2, TYPE_Lab_16, lab4, TYPE_Lab_16, 0);
    through("sRGB>xyz", srgb, TYPE_RGB_16, xyz, TYPE_XYZ_16, 1);
    through("gray>sRGB", gray, TYPE_GRAY_16, srgb, TYPE_RGB_16, 1);
    through("sRGB>gray", srgb, TYPE_RGB_16, gray, TYPE_GRAY_16, 1);
    through("grayNoWP>lab4", grayNoWP, TYPE_GRAY_16, lab4, TYPE_Lab_16, 3);
    through("sRGB>null", srgb, TYPE_RGB_16, nullp, TYPE_GRAY_16, 0);
    through("linRGB alone", linRGB, TYPE_RGB_16, NULL, 0, 0);
    through("sRGB>linRGB>", srgb, TYPE_RGB_16, linRGB, TYPE_RGB_16, 0);
    through("ink250 alone", ink250, TYPE_CMYK_16, NULL, 0, 0);
    through("ink400 alone", ink400, TYPE_CMYK_16, NULL, 0, 0);
    through("inkLow alone", inkLow, TYPE_CMYK_16, NULL, 0, 0);
    through("linCMYK alone", linCMYK, TYPE_CMYK_16, NULL, 0, 0);
    through("sRGB>bchsw>sRGB", srgb, TYPE_RGB_16, bchsw, TYPE_RGB_16, 0);   /* two-profile: ends in Lab; refused */
    {
        cmsHPROFILE chain[3] = { srgb, bchsw, srgb };
        cmsHTRANSFORM x = cmsCreateMultiprofileTransform(chain, 3, TYPE_RGB_16, TYPE_RGB_16, 0, cmsFLAGS_NOOPTIMIZE);
        if (x) {
            unsigned short in[3], out[3];
            for (int i = 0; i < 216; i++) {
                in[0] = (unsigned short) ((i % 6) * 13107); in[1] = (unsigned short) (((i / 6) % 6) * 13107); in[2] = (unsigned short) ((i / 36) * 13107);
                cmsDoTransform(x, in, out, 1); feed(out, sizeof out);
            }
            cmsDeleteTransform(x); report("sRGB>bchsw>sRGB (multiprofile)");
        } else printf("  (refused)\n");
        cmsHPROFILE chain2[3] = { srgb, bchswTemp, rgb709 };
        x = cmsCreateMultiprofileTransform(chain2, 3, TYPE_RGB_16, TYPE_RGB_16, 1, cmsFLAGS_NOOPTIMIZE);
        if (x) {
            unsigned short in[3], out[3];
            for (int i = 0; i < 216; i++) {
                in[0] = (unsigned short) ((i % 6) * 13107); in[1] = (unsigned short) (((i / 6) % 6) * 13107); in[2] = (unsigned short) ((i / 36) * 13107);
                cmsDoTransform(x, in, out, 1); feed(out, sizeof out);
            }
            cmsDeleteTransform(x); report("sRGB>bchswTemp>rgb709");
        } else printf("  (refused)\n");
    }
    if (oklab) {
        through("sRGB>oklab", srgb, TYPE_RGB_16, oklab, TYPE_RGB_16, 1);
        through("oklab>sRGB", oklab, TYPE_RGB_16, srgb, TYPE_RGB_16, 1);
    }

    /* -- a transform written back out as a devicelink -- */
    printf("transform to devicelink\n");
    {
        cmsHTRANSFORM x = cmsCreateTransform(srgb, TYPE_RGB_16, rgb709, TYPE_RGB_16, 1, cmsFLAGS_NOOPTIMIZE);
        /* Two matrix-shapers link into curves-matrix-matrix-curves, which
         * no LUT tag holds as-is: the optimizer resamples it. */
        cmsHPROFILE re0 = saved("matrix-shaper pair as v4.4", cmsTransform2DeviceLink(x, 4.4, 0));
        through("re-saved matrix-shaper pair alone", re0, TYPE_RGB_16, NULL, 0, 0);
        if (re0) cmsCloseProfile(re0);
        re0 = saved("matrix-shaper pair as v2.1", cmsTransform2DeviceLink(x, 2.1, 0));
        through("re-saved matrix-shaper pair v2 alone", re0, TYPE_RGB_16, NULL, 0, 0);
        if (re0) cmsCloseProfile(re0);
        cmsDeleteTransform(x);

        /* A devicelink of a single linearization is curves only, which v4 holds. */
        x = cmsCreateTransform(linRGB, TYPE_RGB_16, NULL, TYPE_RGB_16, 0, cmsFLAGS_NOOPTIMIZE);
        cmsHPROFILE re = saved("linRGB as devicelink v4.4", cmsTransform2DeviceLink(x, 4.4, 0));
        through("re-saved linRGB alone", re, TYPE_RGB_16, NULL, 0, 0);
        cmsDeleteTransform(x);
        if (re) cmsCloseProfile(re);

        /* An ink-limiting link is curves-clut-curves, which v2 and v4 both hold. */
        x = cmsCreateTransform(ink250, TYPE_CMYK_16, NULL, TYPE_CMYK_16, 0, cmsFLAGS_NOOPTIMIZE);
        re = saved("ink250 as devicelink v2.1", cmsTransform2DeviceLink(x, 2.1, 0));
        through("re-saved ink250 alone", re, TYPE_CMYK_16, NULL, 0, 0);
        if (re) cmsCloseProfile(re);
        re = saved("ink250 as devicelink v4.4 8-bit", cmsTransform2DeviceLink(x, 4.4, cmsFLAGS_8BITS_DEVICELINK));
        through("re-saved ink250 8-bit alone", re, TYPE_CMYK_16, NULL, 0, 0);
        if (re) cmsCloseProfile(re);
        cmsDeleteTransform(x);

        /* Lab to Lab through the identity, as a v2 abstract profile guessed from the ends. */
        x = cmsCreateTransform(lab4, TYPE_Lab_16, lab4, TYPE_Lab_16, 0, cmsFLAGS_NOOPTIMIZE);
        re = saved("lab4>lab4 as v2.1 guessed class", cmsTransform2DeviceLink(x, 2.1, cmsFLAGS_GUESSDEVICECLASS));
        through("re-saved lab4>lab4 alone", re, TYPE_Lab_16, NULL, 0, 0);
        if (re) cmsCloseProfile(re);
        cmsDeleteTransform(x);
    }

    cmsFreeToneCurve(g22); cmsFreeToneCurve(g18);
    cmsHPROFILE all[] = { srgb, lab4, lab2, lab4d65, lab2d65, xyz, nullp, gray, grayNoWP, grayNoCurve, rgb709, rgbMixed,
                          rgbNoCurves, rgbWhiteOnly, rgbEmpty, linRGB, linCMYK, ink250, ink400, inkLow, bchsw, bchswTemp, oklab };
    for (size_t i = 0; i < sizeof all / sizeof all[0]; i++) if (all[i]) cmsCloseProfile(all[i]);
    return 0;
}
