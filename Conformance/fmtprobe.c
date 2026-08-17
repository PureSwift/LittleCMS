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

    printf("formatter probe OK\n");
    return 0;
}
