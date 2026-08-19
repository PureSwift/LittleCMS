/* fmtprobe.c - the pixel formatters, against the reference
 *
 * A formatter is a function pointer, and pointers cannot be compared
 * across two libraries.  What can be compared is what one does: run it
 * over a buffer and hash both the channels it produced and the pointer
 * advance it reported.  A formatter that reads the wrong byte, writes
 * the wrong channel, or advances by the wrong amount all show up.
 *
 * Every layout is asked for even when neither library is expected to
 * have one, because "both declined" is itself the agreement being
 * measured -- and because a layout ours declines while the reference
 * serves is exactly the gap this is here to find.
 */

#include "lcms2.h"
#include "lcms2_plugin.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

CMSAPI cmsFormatter CMSEXPORT _cmsGetFormatter(cmsContext ContextID,
    cmsUInt32Number Type, cmsFormatterDirection Dir, cmsUInt32Number dwFlags);

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
    printf("%-28s %016llx\n", name, (unsigned long long) hash_state);
    hash_state = 1469598103934665603ULL;
}

/* A buffer with every byte distinct, so a formatter reading the wrong
 * one cannot coincidentally produce the right answer. */
static void fill(cmsUInt8Number* buffer, size_t n)
{
    for (size_t i = 0; i < n; i++) buffer[i] = (cmsUInt8Number) (i * 37 + 11);
}

/* Whether the formatter may be *run* with no transform.
 *
 * The interleaved integer formatters ignore the transform pointer
 * entirely -- every one of them says so with cmsUNUSED_PARAMETER(info).
 * The float and Lab ones do not: they reach into it, and handing them a
 * null crashes the reference. Asking which formatter is selected is
 * safe for every layout; running one is not, so the two questions are
 * asked separately.
 */
static void probe_selection(const char* name, cmsUInt32Number type)
{
    cmsFormatter in = _cmsGetFormatter(NULL, type, cmsFormatterInput,
                                       CMS_PACK_FLAGS_16BITS);
    cmsFormatter out = _cmsGetFormatter(NULL, type, cmsFormatterOutput,
                                        CMS_PACK_FLAGS_16BITS);
    printf("%-28s in %d out %d\n", name, in.Fmt16 != NULL, out.Fmt16 != NULL);
}

static void probe(const char* name, cmsUInt32Number type)
{
    cmsFormatter in = _cmsGetFormatter(NULL, type, cmsFormatterInput,
                                       CMS_PACK_FLAGS_16BITS);
    cmsFormatter out = _cmsGetFormatter(NULL, type, cmsFormatterOutput,
                                        CMS_PACK_FLAGS_16BITS);

    printf("%-28s in %d out %d\n", name, in.Fmt16 != NULL, out.Fmt16 != NULL);

    if (in.Fmt16 != NULL) {
        cmsUInt8Number buffer[64];
        cmsUInt16Number values[cmsMAXCHANNELS];
        memset(values, 0, sizeof values);
        fill(buffer, sizeof buffer);

        cmsUInt8Number* end = in.Fmt16(NULL, values, buffer, 0);
        /* The channels it produced... */
        feed(values, sizeof values);
        /* ...and how far it moved, which is the stride a caller relies on. */
        int advance = (int) (end - buffer);
        feed(&advance, sizeof advance);
        printf("  %s unpacked advance %d\n", name, advance);
    }

    if (out.Fmt16 != NULL) {
        cmsUInt8Number buffer[64];
        cmsUInt16Number values[cmsMAXCHANNELS];
        memset(buffer, 0, sizeof buffer);
        for (int i = 0; i < cmsMAXCHANNELS; i++)
            values[i] = (cmsUInt16Number) (i * 4099 + 7);

        cmsUInt8Number* end = out.Fmt16(NULL, values, buffer, 0);
        feed(buffer, sizeof buffer);
        int advance = (int) (end - buffer);
        feed(&advance, sizeof advance);
        printf("  %s packed advance %d\n", name, advance);
    }

    report(name);
}


/* -- every layout, through a null transform ---------------------------------
 *
 * The generic formatters read the layout back from the transform they
 * are handed, so they can only be run through one.  A null transform is
 * formatters and nothing else: unpack, pack, no pipeline.  Every layout
 * the header names is run through three of them — to itself, to a
 * fixed word layout, and from a fixed byte layout — over a buffer of
 * distinct bytes, and the output hashed.  A layout neither library
 * serves prints as refused on both sides.
 */

static const struct { const char* name; cmsUInt32Number type; } every_layout[] = {
    { "GRAY_8", TYPE_GRAY_8 },
    { "GRAY_8_REV", TYPE_GRAY_8_REV },
    { "GRAY_16", TYPE_GRAY_16 },
    { "GRAY_16_REV", TYPE_GRAY_16_REV },
    { "GRAY_16_SE", TYPE_GRAY_16_SE },
    { "GRAYA_8", TYPE_GRAYA_8 },
    { "GRAYA_8_PREMUL", TYPE_GRAYA_8_PREMUL },
    { "GRAYA_16", TYPE_GRAYA_16 },
    { "GRAYA_16_PREMUL", TYPE_GRAYA_16_PREMUL },
    { "GRAYA_16_SE", TYPE_GRAYA_16_SE },
    { "GRAYA_8_PLANAR", TYPE_GRAYA_8_PLANAR },
    { "GRAYA_16_PLANAR", TYPE_GRAYA_16_PLANAR },
    { "RGB_8", TYPE_RGB_8 },
    { "RGB_8_PLANAR", TYPE_RGB_8_PLANAR },
    { "BGR_8", TYPE_BGR_8 },
    { "BGR_8_PLANAR", TYPE_BGR_8_PLANAR },
    { "RGB_16", TYPE_RGB_16 },
    { "RGB_16_PLANAR", TYPE_RGB_16_PLANAR },
    { "RGB_16_SE", TYPE_RGB_16_SE },
    { "BGR_16", TYPE_BGR_16 },
    { "BGR_16_PLANAR", TYPE_BGR_16_PLANAR },
    { "BGR_16_SE", TYPE_BGR_16_SE },
    { "RGBA_8", TYPE_RGBA_8 },
    { "RGBA_8_PREMUL", TYPE_RGBA_8_PREMUL },
    { "RGBA_8_PLANAR", TYPE_RGBA_8_PLANAR },
    { "RGBA_16", TYPE_RGBA_16 },
    { "RGBA_16_PREMUL", TYPE_RGBA_16_PREMUL },
    { "RGBA_16_PLANAR", TYPE_RGBA_16_PLANAR },
    { "RGBA_16_SE", TYPE_RGBA_16_SE },
    { "ARGB_8", TYPE_ARGB_8 },
    { "ARGB_8_PREMUL", TYPE_ARGB_8_PREMUL },
    { "ARGB_8_PLANAR", TYPE_ARGB_8_PLANAR },
    { "ARGB_16", TYPE_ARGB_16 },
    { "ARGB_16_PREMUL", TYPE_ARGB_16_PREMUL },
    { "ABGR_8", TYPE_ABGR_8 },
    { "ABGR_8_PREMUL", TYPE_ABGR_8_PREMUL },
    { "ABGR_8_PLANAR", TYPE_ABGR_8_PLANAR },
    { "ABGR_16", TYPE_ABGR_16 },
    { "ABGR_16_PREMUL", TYPE_ABGR_16_PREMUL },
    { "ABGR_16_PLANAR", TYPE_ABGR_16_PLANAR },
    { "ABGR_16_SE", TYPE_ABGR_16_SE },
    { "BGRA_8", TYPE_BGRA_8 },
    { "BGRA_8_PREMUL", TYPE_BGRA_8_PREMUL },
    { "BGRA_8_PLANAR", TYPE_BGRA_8_PLANAR },
    { "BGRA_16", TYPE_BGRA_16 },
    { "BGRA_16_PREMUL", TYPE_BGRA_16_PREMUL },
    { "BGRA_16_SE", TYPE_BGRA_16_SE },
    { "CMY_8", TYPE_CMY_8 },
    { "CMY_8_PLANAR", TYPE_CMY_8_PLANAR },
    { "CMY_16", TYPE_CMY_16 },
    { "CMY_16_PLANAR", TYPE_CMY_16_PLANAR },
    { "CMY_16_SE", TYPE_CMY_16_SE },
    { "CMYK_8", TYPE_CMYK_8 },
    { "CMYKA_8", TYPE_CMYKA_8 },
    { "CMYK_8_REV", TYPE_CMYK_8_REV },
    { "CMYK_8_PLANAR", TYPE_CMYK_8_PLANAR },
    { "CMYK_16", TYPE_CMYK_16 },
    { "CMYK_16_REV", TYPE_CMYK_16_REV },
    { "CMYK_16_PLANAR", TYPE_CMYK_16_PLANAR },
    { "CMYK_16_SE", TYPE_CMYK_16_SE },
    { "KYMC_8", TYPE_KYMC_8 },
    { "KYMC_16", TYPE_KYMC_16 },
    { "KYMC_16_SE", TYPE_KYMC_16_SE },
    { "KCMY_8", TYPE_KCMY_8 },
    { "KCMY_8_REV", TYPE_KCMY_8_REV },
    { "KCMY_16", TYPE_KCMY_16 },
    { "KCMY_16_REV", TYPE_KCMY_16_REV },
    { "KCMY_16_SE", TYPE_KCMY_16_SE },
    { "CMYK5_8", TYPE_CMYK5_8 },
    { "CMYK5_16", TYPE_CMYK5_16 },
    { "CMYK5_16_SE", TYPE_CMYK5_16_SE },
    { "KYMC5_8", TYPE_KYMC5_8 },
    { "KYMC5_16", TYPE_KYMC5_16 },
    { "KYMC5_16_SE", TYPE_KYMC5_16_SE },
    { "CMYK6_8", TYPE_CMYK6_8 },
    { "CMYK6_8_PLANAR", TYPE_CMYK6_8_PLANAR },
    { "CMYK6_16", TYPE_CMYK6_16 },
    { "CMYK6_16_PLANAR", TYPE_CMYK6_16_PLANAR },
    { "CMYK6_16_SE", TYPE_CMYK6_16_SE },
    { "CMYK7_8", TYPE_CMYK7_8 },
    { "CMYK7_16", TYPE_CMYK7_16 },
    { "CMYK7_16_SE", TYPE_CMYK7_16_SE },
    { "KYMC7_8", TYPE_KYMC7_8 },
    { "KYMC7_16", TYPE_KYMC7_16 },
    { "KYMC7_16_SE", TYPE_KYMC7_16_SE },
    { "CMYK8_8", TYPE_CMYK8_8 },
    { "CMYK8_16", TYPE_CMYK8_16 },
    { "CMYK8_16_SE", TYPE_CMYK8_16_SE },
    { "KYMC8_8", TYPE_KYMC8_8 },
    { "KYMC8_16", TYPE_KYMC8_16 },
    { "KYMC8_16_SE", TYPE_KYMC8_16_SE },
    { "CMYK9_8", TYPE_CMYK9_8 },
    { "CMYK9_16", TYPE_CMYK9_16 },
    { "CMYK9_16_SE", TYPE_CMYK9_16_SE },
    { "KYMC9_8", TYPE_KYMC9_8 },
    { "KYMC9_16", TYPE_KYMC9_16 },
    { "KYMC9_16_SE", TYPE_KYMC9_16_SE },
    { "CMYK10_8", TYPE_CMYK10_8 },
    { "CMYK10_16", TYPE_CMYK10_16 },
    { "CMYK10_16_SE", TYPE_CMYK10_16_SE },
    { "KYMC10_8", TYPE_KYMC10_8 },
    { "KYMC10_16", TYPE_KYMC10_16 },
    { "KYMC10_16_SE", TYPE_KYMC10_16_SE },
    { "CMYK11_8", TYPE_CMYK11_8 },
    { "CMYK11_16", TYPE_CMYK11_16 },
    { "CMYK11_16_SE", TYPE_CMYK11_16_SE },
    { "KYMC11_8", TYPE_KYMC11_8 },
    { "KYMC11_16", TYPE_KYMC11_16 },
    { "KYMC11_16_SE", TYPE_KYMC11_16_SE },
    { "CMYK12_8", TYPE_CMYK12_8 },
    { "CMYK12_16", TYPE_CMYK12_16 },
    { "CMYK12_16_SE", TYPE_CMYK12_16_SE },
    { "KYMC12_8", TYPE_KYMC12_8 },
    { "KYMC12_16", TYPE_KYMC12_16 },
    { "KYMC12_16_SE", TYPE_KYMC12_16_SE },
    { "XYZ_16", TYPE_XYZ_16 },
    { "Lab_8", TYPE_Lab_8 },
    { "LabV2_8", TYPE_LabV2_8 },
    { "ALab_8", TYPE_ALab_8 },
    { "ALabV2_8", TYPE_ALabV2_8 },
    { "Lab_16", TYPE_Lab_16 },
    { "LabV2_16", TYPE_LabV2_16 },
    { "Yxy_16", TYPE_Yxy_16 },
    { "YCbCr_8", TYPE_YCbCr_8 },
    { "YCbCr_8_PLANAR", TYPE_YCbCr_8_PLANAR },
    { "YCbCr_16", TYPE_YCbCr_16 },
    { "YCbCr_16_PLANAR", TYPE_YCbCr_16_PLANAR },
    { "YCbCr_16_SE", TYPE_YCbCr_16_SE },
    { "YUV_8", TYPE_YUV_8 },
    { "YUV_8_PLANAR", TYPE_YUV_8_PLANAR },
    { "YUV_16", TYPE_YUV_16 },
    { "YUV_16_PLANAR", TYPE_YUV_16_PLANAR },
    { "YUV_16_SE", TYPE_YUV_16_SE },
    { "HLS_8", TYPE_HLS_8 },
    { "HLS_8_PLANAR", TYPE_HLS_8_PLANAR },
    { "HLS_16", TYPE_HLS_16 },
    { "HLS_16_PLANAR", TYPE_HLS_16_PLANAR },
    { "HLS_16_SE", TYPE_HLS_16_SE },
    { "HSV_8", TYPE_HSV_8 },
    { "HSV_8_PLANAR", TYPE_HSV_8_PLANAR },
    { "HSV_16", TYPE_HSV_16 },
    { "HSV_16_PLANAR", TYPE_HSV_16_PLANAR },
    { "HSV_16_SE", TYPE_HSV_16_SE },
    { "NAMED_COLOR_INDEX", TYPE_NAMED_COLOR_INDEX },
    { "XYZ_FLT", TYPE_XYZ_FLT },
    { "Lab_FLT", TYPE_Lab_FLT },
    { "LabA_FLT", TYPE_LabA_FLT },
    { "GRAY_FLT", TYPE_GRAY_FLT },
    { "GRAYA_FLT", TYPE_GRAYA_FLT },
    { "GRAYA_FLT_PREMUL", TYPE_GRAYA_FLT_PREMUL },
    { "RGB_FLT", TYPE_RGB_FLT },
    { "RGBA_FLT", TYPE_RGBA_FLT },
    { "RGBA_FLT_PREMUL", TYPE_RGBA_FLT_PREMUL },
    { "ARGB_FLT", TYPE_ARGB_FLT },
    { "ARGB_FLT_PREMUL", TYPE_ARGB_FLT_PREMUL },
    { "BGR_FLT", TYPE_BGR_FLT },
    { "BGRA_FLT", TYPE_BGRA_FLT },
    { "BGRA_FLT_PREMUL", TYPE_BGRA_FLT_PREMUL },
    { "ABGR_FLT", TYPE_ABGR_FLT },
    { "ABGR_FLT_PREMUL", TYPE_ABGR_FLT_PREMUL },
    { "CMYK_FLT", TYPE_CMYK_FLT },
    { "XYZ_DBL", TYPE_XYZ_DBL },
    { "Lab_DBL", TYPE_Lab_DBL },
    { "GRAY_DBL", TYPE_GRAY_DBL },
    { "RGB_DBL", TYPE_RGB_DBL },
    { "BGR_DBL", TYPE_BGR_DBL },
    { "CMYK_DBL", TYPE_CMYK_DBL },
    { "OKLAB_DBL", TYPE_OKLAB_DBL },
    { "GRAY_HALF_FLT", TYPE_GRAY_HALF_FLT },
    { "RGB_HALF_FLT", TYPE_RGB_HALF_FLT },
    { "CMYK_HALF_FLT", TYPE_CMYK_HALF_FLT },
    { "RGBA_HALF_FLT", TYPE_RGBA_HALF_FLT },
    { "ARGB_HALF_FLT", TYPE_ARGB_HALF_FLT },
    { "BGR_HALF_FLT", TYPE_BGR_HALF_FLT },
    { "BGRA_HALF_FLT", TYPE_BGRA_HALF_FLT },
    { "ABGR_HALF_FLT", TYPE_ABGR_HALF_FLT },
};

static size_t layout_bytes(cmsUInt32Number f)
{
    size_t b = T_BYTES(f) == 0 ? 8 : T_BYTES(f);
    return b * (T_CHANNELS(f) + T_EXTRA(f));
}

static void null_pair(const char* what, cmsUInt32Number in_fmt, cmsUInt32Number out_fmt)
{
    static unsigned char in[24 * 16 * 8], out[24 * 16 * 8];
    /* A profile is needed to carry the context, and nothing else: with
     * cmsFLAGS_NULLTRANSFORM the colour spaces are not checked. */
    cmsHPROFILE h = cmsCreateLab4Profile(NULL);
    cmsHTRANSFORM x = cmsCreateTransform(h, in_fmt, h, out_fmt, 0, cmsFLAGS_NULLTRANSFORM);
    cmsCloseProfile(h);
    if (x == NULL) { printf("%-28s refused\n", what); return; }

    fill(in, sizeof in);
    /* Floats and doubles read from arbitrary bytes are wild; keep them
     * finite and in a sane range so the two builds see the same thing. */
    if (T_FLOAT(in_fmt)) {
        size_t n = 24 * (T_CHANNELS(in_fmt) + T_EXTRA(in_fmt));
        if (T_BYTES(in_fmt) == 4) { float* f = (float*) in; for (size_t i = 0; i < n; i++) f[i] = (float) ((i * 37 % 113) / 100.0 - 0.05); }
        else if (T_BYTES(in_fmt) == 0) { double* d = (double*) in; for (size_t i = 0; i < n; i++) d[i] = (i * 37 % 113) / 100.0 - 0.05; }
        /* Halves: any bit pattern is a value; NaN patterns are avoided by
         * clearing the exponent's top bit. */
        else { unsigned short* s = (unsigned short*) in; for (size_t i = 0; i < n; i++) s[i] &= 0xBFFF; }
    }
    memset(out, 0xEE, sizeof out);
    cmsDoTransform(x, in, out, 24);
    feed(out, layout_bytes(out_fmt) * 24);
    cmsDeleteTransform(x);
    report(what);
}

static void probe_every_layout(void)
{
    char what[80];
    for (size_t i = 0; i < sizeof every_layout / sizeof every_layout[0]; i++) {
        snprintf(what, sizeof what, "null %s>%s", every_layout[i].name, every_layout[i].name);
        null_pair(what, every_layout[i].type, every_layout[i].type);
        snprintf(what, sizeof what, "null %s>CMYK_16", every_layout[i].name);
        null_pair(what, every_layout[i].type, TYPE_CMYK_16);
        snprintf(what, sizeof what, "null RGB_8>%s", every_layout[i].name);
        null_pair(what, TYPE_RGB_8, every_layout[i].type);
    }
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);

    /* Eight bits, every ordering the table distinguishes. */
    probe("GRAY_8", TYPE_GRAY_8);
    probe("GRAY_8_REV", TYPE_GRAY_8_REV);
    probe("RGB_8", TYPE_RGB_8);
    probe("BGR_8", TYPE_BGR_8);
    /* No specific entry: it falls to a generic formatter that reads the
     * layout out of the transform, so it cannot be run without one. */
    probe_selection("RGBA_8", TYPE_RGBA_8);
    probe("ARGB_8", TYPE_ARGB_8);
    probe("ABGR_8", TYPE_ABGR_8);
    probe("BGRA_8", TYPE_BGRA_8);
    probe("CMYK_8", TYPE_CMYK_8);
    probe("CMYK_8_REV", TYPE_CMYK_8_REV);
    probe("KYMC_8", TYPE_KYMC_8);
    probe("KCMY_8", TYPE_KCMY_8);

    /* Sixteen bits. */
    probe("GRAY_16", TYPE_GRAY_16);
    probe("RGB_16", TYPE_RGB_16);
    probe("BGR_16", TYPE_BGR_16);
    probe("CMYK_16", TYPE_CMYK_16);
    probe("KYMC_16", TYPE_KYMC_16);
    /* Input has a specific entry, output does not -- there is no
     * four-channel word packer with swap-first -- so packing goes
     * through the generic path and needs a transform. */
    probe_selection("KCMY_16", TYPE_KCMY_16);

    /* Word layouts with specific entries the earlier list did not
     * reach: reversed, and the three-channel-plus-one orderings. */
    probe_selection("GRAY_16_REV", TYPE_GRAY_16_REV);
    probe_selection("CMYK_16_REV", TYPE_CMYK_16_REV);
    probe_selection("ARGB_16", TYPE_ARGB_16);
    probe_selection("ABGR_16", TYPE_ABGR_16);
    probe_selection("BGRA_16", TYPE_BGRA_16);
    probe_selection("RGBA_16", TYPE_RGBA_16);

    /* Layouts we do not run, only ask about: either they are not served
     * yet, or their formatters need a transform we do not have here. A
     * difference in these lines is the reference selecting something we
     * decline, which is the gap worth knowing about. */
    probe_selection("RGB_8_PLANAR", TYPE_RGB_8_PLANAR);
    probe_selection("RGB_16_SE", TYPE_RGB_16_SE);
    probe_selection("Lab_DBL", TYPE_Lab_DBL);
    probe_selection("RGB_FLT", TYPE_RGB_FLT);
    probe_selection("XYZ_DBL", TYPE_XYZ_DBL);
    probe_selection("Lab_8", TYPE_Lab_8);

    /* No colour channels at all has no formatter by definition. */
    probe_selection("zero channels", 0);

    probe_every_layout();

    printf("formatter probe OK\n");
    return 0;
}
