/* xformprobe - transforms, created and applied
 *
 * A transform is a chain of profiles linked into one pipeline with a
 * pixel layout at each end.  What can be observed of it is what it does
 * to pixels, so each combination of profiles, intent, layout and flags
 * is applied to a fixed pseudo-random buffer and the result hashed.  The
 * accessors and the failure paths are printed alongside, with the error
 * logger installed so that a refusal's message is compared too.
 *
 * Every transform is created with cmsFLAGS_NOOPTIMIZE: the reference's
 * optimizer rewrites a pipeline into a slightly different one, and that
 * rewrite is not part of this library yet.  Black point compensation and
 * gamut checking are likewise left out until the pieces they rest on
 * exist.
 *
 * Usage: xformprobe <corpus-dir> [<testbed-dir>]
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
    printf("  %-56s %016llx\n", name, (unsigned long long) hash_state);
    hash_state = 1469598103934665603ULL;
}

static void logger(cmsContext id, cmsUInt32Number code, const char* text)
{
    (void) id;
    printf("  error %u: %s\n", code, text);
}

static uint32_t seed = 5150;
static uint32_t next(void) { seed = seed * 1103515245u + 12345u; return seed >> 8; }

/* A pixel buffer of a given layout, filled deterministically.  The
 * corners of the cube are included first so that white, black and the
 * primaries are always in it. */
#define PIXELS 300
static size_t bytes_per_pixel(cmsUInt32Number fmt)
{
    size_t b = T_BYTES(fmt) == 0 ? 8 : T_BYTES(fmt);
    return b * (T_CHANNELS(fmt) + T_EXTRA(fmt));
}

static void fill(unsigned char* buf, cmsUInt32Number fmt)
{
    size_t bpp = bytes_per_pixel(fmt);
    size_t total = bpp * PIXELS;
    seed = 5150 + fmt;
    for (size_t i = 0; i < total; i++) buf[i] = (unsigned char) next();

    /* First 2^n pixels: corners. */
    unsigned n = T_CHANNELS(fmt) + T_EXTRA(fmt);
    unsigned corners = 1u << (n > 4 ? 4 : n);
    for (unsigned c = 0; c < corners && c < PIXELS; c++) {
        for (unsigned ch = 0; ch < n; ch++) {
            int on = (c >> ch) & 1;
            unsigned char* px = buf + c * bpp + ch * (bpp / n);
            if (T_BYTES(fmt) == 1) px[0] = on ? 0xFF : 0;
            else if (T_BYTES(fmt) == 2) { px[0] = on ? 0xFF : 0; px[1] = on ? 0xFF : 0; }
        }
    }
}

static const char* intent_name(cmsUInt32Number i)
{
    switch (i) {
    case 0: return "perc"; case 1: return "rel"; case 2: return "sat"; case 3: return "abs";
    default: return "?";
    }
}

static const char* fmt_name(cmsUInt32Number f)
{
    /* Two buffers, since one call's answer is printed next to another's. */
    static char outs[2][64];
    static int which = 0;
    char* out = outs[which ^= 1];
    snprintf(out, 64, "%s%u_%u%s",
             T_COLORSPACE(f) == PT_RGB ? "RGB" : T_COLORSPACE(f) == PT_GRAY ? "GRAY" :
             T_COLORSPACE(f) == PT_CMYK ? "CMYK" : T_COLORSPACE(f) == PT_Lab ? "Lab" :
             T_COLORSPACE(f) == PT_XYZ ? "XYZ" : T_COLORSPACE(f) == PT_ANY ? "ANY" : "?",
             T_CHANNELS(f), T_BYTES(f) * 8, T_DOSWAP(f) ? "_swap" : "");
    return out;
}

/* Apply, three ways, and hash each: the plain call, the stride call over
 * two lines with padding, and the legacy stride call.  All three must
 * agree with each other and with the reference. */
static void apply(cmsHTRANSFORM xform, cmsUInt32Number in_fmt, cmsUInt32Number out_fmt, const char* what)
{
    static unsigned char in[PIXELS * 16 * 8], out[PIXELS * 16 * 8], out2[PIXELS * 16 * 8];
    size_t ibpp = bytes_per_pixel(in_fmt), obpp = bytes_per_pixel(out_fmt);
    char name[128];

    fill(in, in_fmt);

    memset(out, 0xA5, sizeof out);
    cmsDoTransform(xform, in, out, PIXELS);
    feed(out, obpp * PIXELS);
    snprintf(name, sizeof name, "%s", what);
    report(name);

    /* Two lines of PIXELS/2 with 7 bytes of padding on each. */
    memset(out2, 0xA5, sizeof out2);
    cmsDoTransformLineStride(xform, in, out2, PIXELS / 2, 2,
                             (cmsUInt32Number) (ibpp * (PIXELS / 2)) , (cmsUInt32Number) (obpp * (PIXELS / 2) + 7),
                             (cmsUInt32Number) ibpp, (cmsUInt32Number) obpp);
    /* The second line lands 7 bytes further along than the plain call put it. */
    int same = memcmp(out, out2, obpp * (PIXELS / 2)) == 0
            && memcmp(out + obpp * (PIXELS / 2), out2 + obpp * (PIXELS / 2) + 7, obpp * (PIXELS / 2)) == 0;
    printf("  %-56s line-stride %s\n", "", same ? "agrees" : "DIFFERS");

    memset(out2, 0xA5, sizeof out2);
    cmsDoTransformStride(xform, in, out2, PIXELS, (cmsUInt32Number) ibpp);
    printf("  %-56s stride %s\n", "", memcmp(out, out2, obpp * PIXELS) == 0 ? "agrees" : "DIFFERS");
}

static void describe(cmsHTRANSFORM xform)
{
    cmsPipeline* lut = cmsGetTransformPipeline(xform);
    printf("  formats %08x %08x pipeline %u>%u stages %u gamut %s colorants %s/%s\n",
           cmsGetTransformInputFormat(xform), cmsGetTransformOutputFormat(xform),
           lut ? cmsPipelineInputChannels(lut) : 0, lut ? cmsPipelineOutputChannels(lut) : 0,
           lut ? cmsPipelineStageCount(lut) : 0,
           cmsGetTransformGamutCheckPipeline(xform) ? "yes" : "no",
           cmsGetTransformInputColorants(xform) ? "in" : "-",
           cmsGetTransformOutputColorants(xform) ? "out" : "-");
    if (lut) {
        printf("   ");
        for (cmsStage* s = cmsPipelineGetPtrToFirstStage(lut); s; s = cmsStageNext(s)) {
            cmsStageSignature t = cmsStageType(s);
            printf(" %c%c%c%c", (t >> 24) & 0xFF, (t >> 16) & 0xFF, (t >> 8) & 0xFF, t & 0xFF);
        }
        printf("\n");
    }
}

static cmsHPROFILE open_named(const char* dir, const char* name)
{
    char path[1024];
    snprintf(path, sizeof path, "%s/%s.icc", dir, name);
    return cmsOpenProfileFromFile(path, "r");
}

static void pair(cmsHPROFILE a, const char* an, cmsUInt32Number in_fmt,
                 cmsHPROFILE b, const char* bn, cmsUInt32Number out_fmt,
                 cmsUInt32Number intent, cmsUInt32Number flags)
{
    char what[128];
    cmsHTRANSFORM x;

    if (a == NULL || (b == NULL && bn != NULL)) return;

    snprintf(what, sizeof what, "%s>%s %s>%s %s%s%s", an, bn ? bn : "-", fmt_name(in_fmt),
             fmt_name(out_fmt), intent_name(intent),
             flags & cmsFLAGS_NOCACHE ? " nocache" : "",
             flags & cmsFLAGS_NONEGATIVES ? " noneg" : "");
    printf(" %s\n", what);
    x = cmsCreateTransform(a, in_fmt, b, out_fmt, intent, flags | cmsFLAGS_NOOPTIMIZE);
    if (x == NULL) { printf("  (refused)\n"); return; }
    describe(x);
    apply(x, in_fmt, out_fmt, what);
    cmsDeleteTransform(x);
}

int main(int argc, char** argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 2) { fprintf(stderr, "usage: xformprobe <corpus-dir> [<testbed-dir>]\n"); return 2; }
    cmsSetLogErrorHandler(logger);

    const char* corpus = argv[1];
    cmsHPROFILE srgb = open_named(corpus, "srgb");
    cmsHPROFILE rgb709 = open_named(corpus, "rgb709");
    cmsHPROFILE gray = open_named(corpus, "gray22");
    cmsHPROFILE lab4 = open_named(corpus, "lab4");
    cmsHPROFILE lab2 = open_named(corpus, "lab2");
    cmsHPROFILE xyz = open_named(corpus, "xyz");
    cmsHPROFILE nullp = open_named(corpus, "null");
    cmsHPROFILE lindl = open_named(corpus, "linear-devicelink");
    cmsHPROFILE inkdl = open_named(corpus, "inklimit-devicelink");
    cmsHPROFILE t1 = NULL, t2 = NULL, t3 = NULL, t5 = NULL, ibm = NULL, crayons = NULL;
    if (argc > 2) {
        t1 = open_named(argv[2], "test1");
        t2 = open_named(argv[2], "test2");
        t3 = open_named(argv[2], "test3");
        t5 = open_named(argv[2], "test5");
        ibm = open_named(argv[2], "ibm-t61");
        crayons = open_named(argv[2], "crayons");
    }

    /* -- the intents there are -- */
    {
        cmsUInt32Number codes[16];
        char* descriptions[16];
        cmsUInt32Number n = cmsGetSupportedIntents(16, codes, descriptions);
        printf("intents %u\n", n);
        for (cmsUInt32Number i = 0; i < n && i < 16; i++)
            printf("  %u %s\n", codes[i], descriptions[i]);
        printf("intents (capped) %u\n", cmsGetSupportedIntents(2, codes, descriptions));
        printf("intents (count only) %u\n", cmsGetSupportedIntents(0, NULL, NULL));
    }

    /* -- matrix-shaper to matrix-shaper, every intent, both widths -- */
    printf("matrix-shaper pairs\n");
    for (cmsUInt32Number intent = 0; intent < 4; intent++) {
        pair(srgb, "srgb", TYPE_RGB_8, rgb709, "rgb709", TYPE_RGB_8, intent, 0);
        pair(srgb, "srgb", TYPE_RGB_16, rgb709, "rgb709", TYPE_RGB_16, intent, cmsFLAGS_NOCACHE);
    }
    pair(srgb, "srgb", TYPE_BGR_8, rgb709, "rgb709", TYPE_BGR_8, 0, 0);
    pair(rgb709, "rgb709", TYPE_RGB_16, srgb, "srgb", TYPE_RGB_8, 1, 0);
    pair(srgb, "srgb", TYPE_RGB_8, srgb, "srgb", TYPE_RGB_8, 0, 0);
    pair(srgb, "srgb", TYPE_RGB_16, srgb, "srgb", TYPE_RGB_16, 3, cmsFLAGS_NOCACHE);

    /* -- to and from the PCS profiles -- */
    printf("PCS pairs\n");
    for (cmsUInt32Number intent = 0; intent < 4; intent++) {
        pair(srgb, "srgb", TYPE_RGB_8, lab4, "lab4", TYPE_Lab_16, intent, 0);
        pair(lab4, "lab4", TYPE_Lab_16, srgb, "srgb", TYPE_RGB_16, intent, cmsFLAGS_NOCACHE);
    }
    pair(srgb, "srgb", TYPE_RGB_16, lab2, "lab2", TYPE_Lab_16, 1, 0);
    pair(lab2, "lab2", TYPE_LabV2_16, srgb, "srgb", TYPE_RGB_8, 1, 0);
    pair(srgb, "srgb", TYPE_RGB_16, xyz, "xyz", TYPE_XYZ_16, 1, 0);
    pair(xyz, "xyz", TYPE_XYZ_16, srgb, "srgb", TYPE_RGB_16, 1, 0);
    pair(xyz, "xyz", TYPE_XYZ_16, lab4, "lab4", TYPE_Lab_16, 1, 0);
    pair(lab4, "lab4", TYPE_Lab_16, xyz, "xyz", TYPE_XYZ_16, 3, 0);
    pair(lab4, "lab4", TYPE_Lab_16, lab2, "lab2", TYPE_Lab_16, 1, 0);
    pair(lab4, "lab4", TYPE_Lab_16, lab4, "lab4", TYPE_Lab_16, 0, 0);

    /* -- grey -- */
    printf("grey pairs\n");
    for (cmsUInt32Number intent = 0; intent < 4; intent++) {
        pair(gray, "gray22", TYPE_GRAY_8, srgb, "srgb", TYPE_RGB_8, intent, 0);
        pair(srgb, "srgb", TYPE_RGB_16, gray, "gray22", TYPE_GRAY_16, intent, cmsFLAGS_NOCACHE);
    }
    pair(gray, "gray22", TYPE_GRAY_16, lab4, "lab4", TYPE_Lab_16, 1, 0);
    pair(lab4, "lab4", TYPE_Lab_16, gray, "gray22", TYPE_GRAY_8, 1, 0);
    pair(gray, "gray22", TYPE_GRAY_8, gray, "gray22", TYPE_GRAY_8, 0, 0);

    /* -- devicelinks -- */
    printf("devicelinks\n");
    pair(lindl, "lindl", TYPE_RGB_8, NULL, NULL, TYPE_RGB_8, 0, 0);
    pair(lindl, "lindl", TYPE_RGB_16, NULL, NULL, TYPE_RGB_16, 1, cmsFLAGS_NOCACHE);
    pair(inkdl, "inkdl", TYPE_CMYK_8, NULL, NULL, TYPE_CMYK_8, 0, 0);
    pair(inkdl, "inkdl", TYPE_CMYK_16, NULL, NULL, TYPE_CMYK_16, 0, cmsFLAGS_NOCACHE);
    pair(nullp, "null", TYPE_GRAY_8, NULL, NULL, TYPE_GRAY_8, 0, 0);
    /* Wrong space against a devicelink is refused. */
    pair(lindl, "lindl", TYPE_CMYK_8, NULL, NULL, TYPE_RGB_8, 0, 0);

    /* -- the LUT-based profiles from the testbed -- */
    if (t1) {
        printf("LUT profiles\n");
        for (cmsUInt32Number intent = 0; intent < 4; intent++) {
            pair(srgb, "srgb", TYPE_RGB_8, t1, "test1", TYPE_CMYK_8, intent, 0);
            pair(t1, "test1", TYPE_CMYK_16, srgb, "srgb", TYPE_RGB_16, intent, cmsFLAGS_NOCACHE);
            pair(t1, "test1", TYPE_CMYK_8, t3, "test3", TYPE_CMYK_8, intent, 0);
        }
        pair(t1, "test1", TYPE_CMYK_16, lab4, "lab4", TYPE_Lab_16, 1, 0);
        pair(lab4, "lab4", TYPE_Lab_16, t1, "test1", TYPE_CMYK_16, 1, 0);
        pair(t2, "test2", TYPE_CMYK_8, t5, "test5", TYPE_CMYK_8, 0, 0);
        pair(t5, "test5", TYPE_CMYK_16, srgb, "srgb", TYPE_RGB_8, 2, 0);
        pair(ibm, "ibm", TYPE_RGB_8, srgb, "srgb", TYPE_RGB_8, 1, 0);
        pair(ibm, "ibm", TYPE_RGB_16, lab4, "lab4", TYPE_Lab_16, 3, cmsFLAGS_NOCACHE);
        pair(srgb, "srgb", TYPE_RGB_16, ibm, "ibm", TYPE_RGB_16, 3, 0);
        pair(t1, "test1", TYPE_CMYK_8, t1, "test1", TYPE_CMYK_8, 1, cmsFLAGS_NONEGATIVES);
        pair(srgb, "srgb", TYPE_RGB_8, t1, "test1", TYPE_CMYK_8, 1, cmsFLAGS_NONEGATIVES);
        /* A named colour profile as the single profile: index in, colorant out. */
        if (crayons) {
            printf(" crayons\n");
            cmsHTRANSFORM x = cmsCreateTransform(crayons, TYPE_NAMED_COLOR_INDEX, NULL, TYPE_RGB_8, 0, cmsFLAGS_NOOPTIMIZE);
            if (x) {
                describe(x);
                printf("  named list %s\n", cmsGetNamedColorList(x) ? "present" : "absent");
                unsigned short idx[8] = { 0, 1, 2, 3, 10, 20, 30, 40 };
                unsigned char rgb[8 * 3];
                cmsDoTransform(x, idx, rgb, 8);
                feed(rgb, sizeof rgb);
                report("crayons index>rgb");
                cmsDeleteTransform(x);
            } else printf("  (refused)\n");
        }
    }

    /* -- multiprofile -- */
    printf("multiprofile\n");
    {
        cmsHPROFILE chain[4] = { srgb, lab4, rgb709, NULL };
        cmsHTRANSFORM x = cmsCreateMultiprofileTransform(chain, 3, TYPE_RGB_8, TYPE_RGB_8, 1, cmsFLAGS_NOOPTIMIZE);
        if (x) { describe(x); apply(x, TYPE_RGB_8, TYPE_RGB_8, "srgb>lab4>rgb709"); cmsDeleteTransform(x); }
        else printf("  (refused)\n");

        cmsHPROFILE chain2[4] = { srgb, lindl, rgb709, NULL };
        x = cmsCreateMultiprofileTransform(chain2, 3, TYPE_RGB_16, TYPE_RGB_16, 0, cmsFLAGS_NOOPTIMIZE | cmsFLAGS_NOCACHE);
        if (x) { describe(x); apply(x, TYPE_RGB_16, TYPE_RGB_16, "srgb>lindl>rgb709"); cmsDeleteTransform(x); }
        else printf("  (refused)\n");

        if (t1) {
            cmsHPROFILE chain3[4] = { srgb, t1, t3, srgb };
            x = cmsCreateMultiprofileTransform(chain3, 4, TYPE_RGB_8, TYPE_RGB_8, 1, cmsFLAGS_NOOPTIMIZE);
            if (x) { describe(x); apply(x, TYPE_RGB_8, TYPE_RGB_8, "srgb>test1>test3>srgb"); cmsDeleteTransform(x); }
            else printf("  (refused)\n");
        }

        /* Sequence kept. */
        x = cmsCreateMultiprofileTransform(chain, 3, TYPE_RGB_8, TYPE_RGB_8, 1, cmsFLAGS_NOOPTIMIZE | cmsFLAGS_KEEP_SEQUENCE);
        if (x) { describe(x); cmsDeleteTransform(x); }

        /* Extended, with per-profile intents and states. */
        cmsUInt32Number intents[3] = { 0, 3, 1 };
        cmsBool bpc[3] = { 0, 0, 0 };
        cmsFloat64Number states[3] = { 1.0, 1.0, 1.0 };
        x = cmsCreateExtendedTransform(NULL, 3, chain, bpc, intents, states, NULL, 0, TYPE_RGB_8, TYPE_RGB_8, cmsFLAGS_NOOPTIMIZE);
        if (x) { describe(x); apply(x, TYPE_RGB_8, TYPE_RGB_8, "extended srgb>lab4>rgb709 mixed intents"); cmsDeleteTransform(x); }
        else printf("  (refused)\n");

        /* Absolute colorimetric with a partial adaptation state. */
        cmsHPROFILE two[2] = { srgb, rgb709 };
        cmsUInt32Number abs2[2] = { 3, 3 };
        cmsBool bpc2[2] = { 0, 0 };
        cmsFloat64Number half[2] = { 0.5, 0.5 };
        cmsFloat64Number none[2] = { 0.0, 0.0 };
        x = cmsCreateExtendedTransform(NULL, 2, two, bpc2, abs2, half, NULL, 0, TYPE_RGB_16, TYPE_RGB_16, cmsFLAGS_NOOPTIMIZE);
        if (x) { describe(x); apply(x, TYPE_RGB_16, TYPE_RGB_16, "srgb>rgb709 abs half-adapted"); cmsDeleteTransform(x); }
        else printf("  (refused)\n");
        x = cmsCreateExtendedTransform(NULL, 2, two, bpc2, abs2, none, NULL, 0, TYPE_RGB_16, TYPE_RGB_16, cmsFLAGS_NOOPTIMIZE);
        if (x) { describe(x); apply(x, TYPE_RGB_16, TYPE_RGB_16, "srgb>rgb709 abs unadapted"); cmsDeleteTransform(x); }
        else printf("  (refused)\n");

        /* Adaptation state through the context. */
        cmsFloat64Number previous = cmsSetAdaptationState(0.3);
        printf("  adaptation was %.2f\n", previous);
        pair(srgb, "srgb", TYPE_RGB_16, rgb709, "rgb709", TYPE_RGB_16, 3, 0);
        cmsSetAdaptationState(previous);
    }

    /* -- proofing without the flags is a plain transform -- */
    printf("proofing\n");
    {
        cmsHTRANSFORM x = cmsCreateProofingTransform(srgb, TYPE_RGB_8, rgb709, TYPE_RGB_8, lab4, 0, 1, cmsFLAGS_NOOPTIMIZE);
        if (x) { describe(x); apply(x, TYPE_RGB_8, TYPE_RGB_8, "proof srgb>rgb709 (no proofing flags)"); cmsDeleteTransform(x); }
        else printf("  (refused)\n");
        if (t1) {
            x = cmsCreateProofingTransform(srgb, TYPE_RGB_8, rgb709, TYPE_RGB_8, t1, 0, 1, cmsFLAGS_NOOPTIMIZE | cmsFLAGS_SOFTPROOFING);
            if (x) { describe(x); apply(x, TYPE_RGB_8, TYPE_RGB_8, "softproof srgb>test1>rgb709"); cmsDeleteTransform(x); }
            else printf("  (refused)\n");
        }
    }

    /* -- null transform, formatters only -- */
    printf("null transform\n");
    {
        cmsHTRANSFORM x = cmsCreateTransform(srgb, TYPE_RGB_8, srgb, TYPE_BGR_8, 0, cmsFLAGS_NULLTRANSFORM);
        if (x) { describe(x); apply(x, TYPE_RGB_8, TYPE_BGR_8, "null RGB_8>BGR_8"); cmsDeleteTransform(x); }
        x = cmsCreateTransform(srgb, TYPE_RGB_16, srgb, TYPE_RGB_8, 0, cmsFLAGS_NULLTRANSFORM);
        if (x) { describe(x); apply(x, TYPE_RGB_16, TYPE_RGB_8, "null RGB_16>RGB_8"); cmsDeleteTransform(x); }
    }

    /* -- changing the buffer formats -- */
    printf("change buffers format\n");
    {
        cmsHTRANSFORM x = cmsCreateTransform(srgb, TYPE_RGB_16, rgb709, TYPE_RGB_16, 0, cmsFLAGS_NOOPTIMIZE);
        if (x) {
            printf("  16>16 to 8>8: %d\n", cmsChangeBuffersFormat(x, TYPE_RGB_8, TYPE_RGB_8));
            describe(x);
            apply(x, TYPE_RGB_8, TYPE_RGB_8, "changed to RGB_8>RGB_8");
            printf("  to BGR_16>RGB_16: %d\n", cmsChangeBuffersFormat(x, TYPE_BGR_16, TYPE_RGB_16));
            apply(x, TYPE_BGR_16, TYPE_RGB_16, "changed to BGR_16>RGB_16");
            printf("  to unsupported: %d\n", cmsChangeBuffersFormat(x, TYPE_RGB_16, (7 << 3) | 2 | (3 << 7) | (1 << 12)));
            cmsDeleteTransform(x);
        }
        /* An 8-bit input transform cannot be changed. */
        x = cmsCreateTransform(srgb, TYPE_RGB_8, rgb709, TYPE_RGB_8, 0, cmsFLAGS_NOOPTIMIZE);
        if (x) {
            printf("  8>8 to 16>16: %d\n", cmsChangeBuffersFormat(x, TYPE_RGB_16, TYPE_RGB_16));
            cmsDeleteTransform(x);
        }
    }

    /* -- refusals -- */
    printf("refusals\n");
    {
        cmsHTRANSFORM x;
        x = cmsCreateTransform(srgb, TYPE_CMYK_8, rgb709, TYPE_RGB_8, 0, cmsFLAGS_NOOPTIMIZE);
        printf("  wrong input space: %s\n", x ? "created" : "refused");
        x = cmsCreateTransform(srgb, TYPE_RGB_8, rgb709, TYPE_GRAY_8, 0, cmsFLAGS_NOOPTIMIZE);
        printf("  wrong output space: %s\n", x ? "created" : "refused");
        x = cmsCreateTransform(srgb, TYPE_RGB_8, rgb709, TYPE_RGB_8, 42, cmsFLAGS_NOOPTIMIZE);
        printf("  unknown intent: %s\n", x ? "created" : "refused");
        x = cmsCreateTransform(srgb, TYPE_RGB_8, NULL, TYPE_RGB_8, 0, cmsFLAGS_NOOPTIMIZE);
        printf("  matrix-shaper alone: %s\n", x ? "created" : "refused");
        if (x) { describe(x); apply(x, TYPE_RGB_8, TYPE_RGB_8, "srgb alone"); cmsDeleteTransform(x); }
        x = cmsCreateTransform(srgb, TYPE_RGB_8, gray, TYPE_RGB_8, 0, cmsFLAGS_NOOPTIMIZE);
        printf("  gray as RGB: %s\n", x ? "created" : "refused");
        cmsHPROFILE none[1] = { NULL };
        x = cmsCreateMultiprofileTransform(none, 0, TYPE_RGB_8, TYPE_RGB_8, 0, 0);
        printf("  zero profiles: %s\n", x ? "created" : "refused");
        x = cmsCreateTransform(NULL, TYPE_RGB_8, srgb, TYPE_RGB_8, 0, cmsFLAGS_NOOPTIMIZE);
        printf("  null input profile: %s\n", x ? "created" : "refused");
        /* A layout no formatter serves. */
        x = cmsCreateTransform(srgb, (7 << 3) | 2 | (3 << 7) | (1 << 12), rgb709, TYPE_RGB_8, 0, cmsFLAGS_NOOPTIMIZE);
        printf("  unsupported layout: %s\n", x ? "created" : "refused");
        /* Lab against LabV2 is accepted either way. */
        x = cmsCreateTransform(lab4, TYPE_LabV2_16, srgb, TYPE_RGB_8, 0, cmsFLAGS_NOOPTIMIZE);
        printf("  labv2 layout on v4 profile: %s\n", x ? "created" : "refused");
        if (x) { apply(x, TYPE_LabV2_16, TYPE_RGB_8, "lab4 as LabV2_16>srgb"); cmsDeleteTransform(x); }
        /* Copy-alpha with mismatched extra channels. */
        x = cmsCreateTransform(srgb, TYPE_RGB_8, rgb709, TYPE_RGB_16, 0, cmsFLAGS_NOOPTIMIZE | cmsFLAGS_COPY_ALPHA);
        printf("  copy alpha, no alpha: %s\n", x ? "created" : "refused");
        if (x) cmsDeleteTransform(x);
    }

    /* -- accessors on a null handle -- */
    printf("null handle: ctx %p in %u out %u lut %p\n",
           (void*) cmsGetTransformContextID(NULL), cmsGetTransformInputFormat(NULL),
           cmsGetTransformOutputFormat(NULL), (void*) cmsGetTransformPipeline(NULL));

    cmsCloseProfile(srgb); cmsCloseProfile(rgb709); cmsCloseProfile(gray);
    cmsCloseProfile(lab4); cmsCloseProfile(lab2); cmsCloseProfile(xyz);
    cmsCloseProfile(nullp); cmsCloseProfile(lindl); cmsCloseProfile(inkdl);
    if (t1) cmsCloseProfile(t1); if (t2) cmsCloseProfile(t2); if (t3) cmsCloseProfile(t3);
    if (t5) cmsCloseProfile(t5); if (ibm) cmsCloseProfile(ibm); if (crayons) cmsCloseProfile(crayons);
    return 0;
}
