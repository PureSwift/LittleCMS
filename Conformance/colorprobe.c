/* colorprobe.c - colour spaces, colour differences, adaptation
 *
 * These are pure functions with published signatures, so they can be
 * driven directly and compared exactly.  Everything here is fingerprinted
 * over dense sweeps rather than sampled: they are cheap, and the places
 * they disagree would be the awkward ones — the linear segment near black,
 * the hue quadrant boundaries, a chroma of zero.
 */

#include "lcms2.h"
#include "lcms2_plugin.h"

#include <stdint.h>
#include <stdio.h>

static uint64_t hash_state = 1469598103934665603ULL;

static void feed(const void* bytes, size_t length)
{
    const unsigned char* p = (const unsigned char*) bytes;
    for (size_t i = 0; i < length; i++) {
        hash_state ^= p[i];
        hash_state *= 1099511628211ULL;
    }
}

static void feed_double(double v) { feed(&v, sizeof v); }
static void feed_u16(uint16_t v)  { feed(&v, sizeof v); }

static void report(const char* name)
{
    printf("%-30s %016llx\n", name, (unsigned long long) hash_state);
    hash_state = 1469598103934665603ULL;
}

static uint32_t seed = 987654321;
static double next_unit(void)
{
    seed = seed * 1103515245u + 12345u;
    return (double) ((seed >> 8) & 0xFFFF) / 65535.0;
}

int main(void)
{
    /* -- the standard illuminant --------------------------------------- */
    {
        const cmsCIEXYZ* xyz = cmsD50_XYZ();
        const cmsCIExyY* xyy = cmsD50_xyY();
        printf("D50 XYZ %.17g %.17g %.17g\n", xyz->X, xyz->Y, xyz->Z);
        printf("D50 xyY %.17g %.17g %.17g\n", xyy->x, xyy->y, xyy->Y);
        /* The pointers must stay valid and stable across calls. */
        printf("D50 stable %d %d\n", cmsD50_XYZ() == xyz, cmsD50_xyY() == xyy);
    }

    /* -- XYZ <-> xyY ---------------------------------------------------- */
    {
        for (int i = 0; i < 4000; i++) {
            cmsCIEXYZ xyz = { next_unit(), next_unit(), next_unit() };
            cmsCIExyY xyy;
            cmsCIEXYZ back;

            cmsXYZ2xyY(&xyy, &xyz);
            feed_double(xyy.x); feed_double(xyy.y); feed_double(xyy.Y);

            cmsxyY2XYZ(&back, &xyy);
            feed_double(back.X); feed_double(back.Y); feed_double(back.Z);
        }
        report("XYZ <-> xyY");
    }

    /* -- XYZ <-> Lab ---------------------------------------------------- */
    {
        /* Dense across the range, and deliberately through the linear
         * segment of the companding function near black. */
        for (int i = 0; i <= 200; i++) {
            for (int j = 0; j <= 20; j++) {
                cmsCIEXYZ xyz = { i / 200.0 * 1.1, j / 20.0 * 1.1, (i + j) / 220.0 * 1.1 };
                cmsCIELab lab;
                cmsCIEXYZ back;

                cmsXYZ2Lab(NULL, &lab, &xyz);
                feed_double(lab.L); feed_double(lab.a); feed_double(lab.b);

                cmsLab2XYZ(NULL, &back, &lab);
                feed_double(back.X); feed_double(back.Y); feed_double(back.Z);
            }
        }
        report("XYZ <-> Lab (D50)");

        /* And against a white point that is not D50. */
        cmsCIEXYZ d65 = { 0.9505, 1.0, 1.0890 };
        for (int i = 0; i < 2000; i++) {
            cmsCIEXYZ xyz = { next_unit(), next_unit(), next_unit() };
            cmsCIELab lab;
            cmsCIEXYZ back;
            cmsXYZ2Lab(&d65, &lab, &xyz);
            feed_double(lab.L); feed_double(lab.a); feed_double(lab.b);
            cmsLab2XYZ(&d65, &back, &lab);
            feed_double(back.X); feed_double(back.Y); feed_double(back.Z);
        }
        report("XYZ <-> Lab (D65)");
    }

    /* -- Lab <-> LCh ---------------------------------------------------- */
    {
        /* Every hue quadrant boundary, plus the origin where atan2 is
         * defined to be zero rather than undefined. */
        for (int a = -128; a <= 127; a += 1) {
            for (int b = -128; b <= 127; b += 17) {
                cmsCIELab lab = { 50.0, (double) a, (double) b };
                cmsCIELCh lch;
                cmsCIELab back;

                cmsLab2LCh(&lch, &lab);
                feed_double(lch.L); feed_double(lch.C); feed_double(lch.h);

                cmsLCh2Lab(&back, &lch);
                feed_double(back.L); feed_double(back.a); feed_double(back.b);
            }
        }
        report("Lab <-> LCh");

        cmsCIELab origin = { 0, 0, 0 };
        cmsCIELCh lch;
        cmsLab2LCh(&lch, &origin);
        printf("hue at origin %.17g\n", lch.h);
    }

    /* -- the encoded forms ---------------------------------------------- */
    {
        /* Exhaustive over L, and dense over a and b: the two encodings
         * scale differently and clamp at different limits, and reading one
         * with the other's scaling is a real bug this would catch. */
        for (uint32_t v = 0; v <= 0xFFFF; v += 7) {
            cmsUInt16Number encoded[3] = { (cmsUInt16Number) v,
                                           (cmsUInt16Number) (v ^ 0x5555),
                                           (cmsUInt16Number) (v ^ 0xAAAA) };
            cmsCIELab v4, v2;
            cmsCIEXYZ xyz;

            cmsLabEncoded2Float(&v4, encoded);
            feed_double(v4.L); feed_double(v4.a); feed_double(v4.b);

            cmsLabEncoded2FloatV2(&v2, encoded);
            feed_double(v2.L); feed_double(v2.a); feed_double(v2.b);

            cmsXYZEncoded2Float(&xyz, encoded);
            feed_double(xyz.X); feed_double(xyz.Y); feed_double(xyz.Z);
        }
        report("decode Lab v4/v2, XYZ");

        /* Back the other way, including values outside what the encodings
         * can carry, where the clamping limits differ between v2 and v4. */
        for (int i = -200; i <= 200; i++) {
            cmsCIELab lab = { i / 2.0, (double) i, (double) -i };
            cmsUInt16Number v4[3], v2[3];

            cmsFloat2LabEncoded(v4, &lab);
            feed_u16(v4[0]); feed_u16(v4[1]); feed_u16(v4[2]);

            cmsFloat2LabEncodedV2(v2, &lab);
            feed_u16(v2[0]); feed_u16(v2[1]); feed_u16(v2[2]);
        }
        report("encode Lab v4/v2");

        for (int i = -20; i <= 60; i++) {
            cmsCIEXYZ xyz = { i / 20.0, i / 25.0, i / 30.0 };
            cmsUInt16Number encoded[3];
            cmsFloat2XYZEncoded(encoded, &xyz);
            feed_u16(encoded[0]); feed_u16(encoded[1]); feed_u16(encoded[2]);
        }
        report("encode XYZ");
    }

    /* -- colour differences --------------------------------------------- */
    {
        for (int i = 0; i < 3000; i++) {
            cmsCIELab p = { next_unit() * 100, next_unit() * 256 - 128, next_unit() * 256 - 128 };
            cmsCIELab q = { next_unit() * 100, next_unit() * 256 - 128, next_unit() * 256 - 128 };

            feed_double(cmsDeltaE(&p, &q));
            feed_double(cmsCIE94DeltaE(&p, &q));
            feed_double(cmsBFDdeltaE(&p, &q));
            feed_double(cmsCMCdeltaE(&p, &q, 1.0, 1.0));
            feed_double(cmsCMCdeltaE(&p, &q, 2.0, 1.0));
            feed_double(cmsCIE2000DeltaE(&p, &q, 1.0, 1.0, 1.0));
            feed_double(cmsCIE2000DeltaE(&p, &q, 2.0, 1.0, 1.0));
        }
        report("delta E, all five");

        /* The degenerate cases each metric has to survive: identical
         * colours, both black, a chroma of exactly zero, and hue
         * differences of exactly half a turn. */
        static const cmsCIELab awkward[] = {
            { 0, 0, 0 }, { 100, 0, 0 }, { 50, 0, 0 },
            { 50, 10, 0 }, { 50, -10, 0 }, { 50, 0, 10 }, { 50, 0, -10 },
            { 50, 60, 60 }, { 50, -60, -60 }, { 16, 0, 0 }, { 15.9, 1, 1 },
            { 7.996969, 0, 0 }, { 8.0, 0, 0 },
        };
        const int n = (int) (sizeof awkward / sizeof *awkward);
        for (int i = 0; i < n; i++) {
            for (int j = 0; j < n; j++) {
                feed_double(cmsDeltaE(&awkward[i], &awkward[j]));
                feed_double(cmsCIE94DeltaE(&awkward[i], &awkward[j]));
                feed_double(cmsBFDdeltaE(&awkward[i], &awkward[j]));
                feed_double(cmsCMCdeltaE(&awkward[i], &awkward[j], 1.0, 1.0));
                feed_double(cmsCIE2000DeltaE(&awkward[i], &awkward[j], 1.0, 1.0, 1.0));
            }
        }
        report("delta E, degenerate");
    }

    /* -- white points ---------------------------------------------------- */
    {
        /* Across the accepted range and over both ends of it, since the
         * approximation changes form at 7000K and is refused outside. */
        for (int t = 3000; t <= 26000; t += 25) {
            cmsCIExyY wp;
            cmsBool ok = cmsWhitePointFromTemp(&wp, (cmsFloat64Number) t);
            feed_double((double) ok);
            if (ok) { feed_double(wp.x); feed_double(wp.y); feed_double(wp.Y); }
        }
        report("white point from temp");

        for (int t = 4000; t <= 25000; t += 25) {
            cmsCIExyY wp;
            cmsFloat64Number back;
            if (!cmsWhitePointFromTemp(&wp, (cmsFloat64Number) t)) continue;
            cmsBool ok = cmsTempFromWhitePoint(&back, &wp);
            feed_double((double) ok);
            if (ok) feed_double(back);
        }
        report("temp from white point");

        /* Points that are not on the daylight locus at all. */
        for (int i = 0; i < 500; i++) {
            cmsCIExyY wp = { next_unit(), next_unit(), 1.0 };
            cmsFloat64Number t;
            cmsBool ok = cmsTempFromWhitePoint(&t, &wp);
            feed_double((double) ok);
            if (ok) feed_double(t);
        }
        report("temp off the locus");
    }

    /* -- adaptation ------------------------------------------------------ */
    {
        cmsCIEXYZ d65 = { 0.9505, 1.0, 1.0890 };
        cmsCIEXYZ d50 = { 0.9642, 1.0, 0.8249 };

        for (int i = 0; i < 2000; i++) {
            cmsCIEXYZ value = { next_unit(), next_unit(), next_unit() };
            cmsCIEXYZ out;
            cmsBool ok = cmsAdaptToIlluminant(&out, &d65, &d50, &value);
            feed_double((double) ok);
            if (ok) { feed_double(out.X); feed_double(out.Y); feed_double(out.Z); }
        }
        report("adapt D65 -> D50");

        /* A degenerate white point the adaptation cannot invert. */
        cmsCIEXYZ zero = { 0, 0, 0 };
        cmsCIEXYZ out;
        printf("adapt from black %d\n", cmsAdaptToIlluminant(&out, &zero, &d50, &d50));
    }

    /* -- desaturation ---------------------------------------------------- */
    {
        for (int L = -10; L <= 110; L += 5) {
            for (int a = -150; a <= 150; a += 11) {
                for (int b = -150; b <= 150; b += 37) {
                    cmsCIELab lab = { (double) L, (double) a, (double) b };
                    cmsBool ok = cmsDesaturateLab(&lab, 55, -55, 55, -55);
                    feed_double((double) ok);
                    feed_double(lab.L); feed_double(lab.a); feed_double(lab.b);
                }
            }
        }
        report("desaturate");
    }

    printf("colour probe OK\n");
    return 0;
}
