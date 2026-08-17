/* curveprobe.c - tone curves, against the reference
 *
 * Curves are where the engine first hands a client a pointer into its own
 * storage: the estimated table and a segment are both borrowed, and both
 * have to stay valid and stay put for the curve's lifetime.  So this
 * measures the values a curve produces, and also the memory it lends —
 * including reading the table the reference's own testbed reads.
 */

#include "lcms2.h"
#include "lcms2_plugin.h"

#include <stdint.h>
#include <stdio.h>
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

/* A NaN is fed as a marker rather than as its bits.
 *
 * IEEE 754 fixes neither the sign nor the payload of a NaN produced by an
 * invalid operation, and the libraries disagree: log() of a negative
 * number comes back with one sign on Darwin and the other under glibc, so
 * the inverse sigmoid outside its domain is a NaN either way but not the
 * same bits.  Hashing those bits asks a question neither implementation
 * answers.  That a NaN appeared, and where, is still compared — the
 * marker is a value no real result can take. */
static void feed_double(double v)
{
    if (v != v) { feed("NaN", 3); return; }
    feed(&v, sizeof v);
}

static void feed_float(float v)
{
    if (v != v) { feed("NaN", 3); return; }
    feed(&v, sizeof v);
}

static void feed_u16(uint16_t v)  { feed(&v, sizeof v); }

static void report(const char* name)
{
    printf("%-30s %016llx\n", name, (unsigned long long) hash_state);
    hash_state = 1469598103934665603ULL;
}

/* Every point of a curve that is cheap to ask about. */
static void feed_curve(cmsToneCurve* c)
{
    if (c == NULL) { feed_double(-1); return; }

    cmsUInt32Number n = cmsGetToneCurveEstimatedTableEntries(c);
    const cmsUInt16Number* table = cmsGetToneCurveEstimatedTable(c);

    feed_double((double) n);
    feed_double((double) cmsGetToneCurveParametricType(c));
    feed_double((double) cmsIsToneCurveMultisegment(c));

    /* The borrowed table, in full.  This is what the reference's testbed
     * indexes directly. */
    for (cmsUInt32Number i = 0; i < n; i++)
        feed_u16(table[i]);

    /* Evaluated both ways across the range, including past both ends. */
    for (int i = -2; i <= 66; i++) {
        cmsUInt16Number v = (cmsUInt16Number) (i < 0 ? 0 : (i > 65 ? 65535 : i * 1000));
        feed_u16(cmsEvalToneCurve16(c, v));
    }
    for (int i = -3; i <= 13; i++)
        feed_float(cmsEvalToneCurveFloat(c, (cmsFloat32Number) (i / 10.0)));
}

int main(void)
{
    /* -- gamma curves --------------------------------------------------- */
    {
        static const double gammas[] = { 1.0, 1.0005, 2.2, 1.8, 0.45, 3.0, 0.0 };
        for (size_t i = 0; i < sizeof gammas / sizeof *gammas; i++) {
            cmsToneCurve* c = cmsBuildGamma(NULL, gammas[i]);
            feed_curve(c);
            /* An identity curve is stored in two entries, everything else
             * in 4096, and that difference is observable. */
            if (c) feed_double((double) cmsGetToneCurveEstimatedTableEntries(c));
            cmsFreeToneCurve(c);
        }
        report("gamma curves");
    }

    /* -- parametric curves ---------------------------------------------- */
    {
        struct { int type; double p[7]; } cases[] = {
            { 1,   { 2.2 } },
            { 2,   { 2.4, 0.9, 0.1 } },
            { 3,   { 2.4, 0.9, 0.1, 0.05 } },
            { 4,   { 2.4, 1.0/1.055, 0.055/1.055, 1.0/12.92, 0.04045 } },
            { 5,   { 2.4, 0.9, 0.1, 0.05, 0.2, 0.01, 0.02 } },
            { 6,   { 2.4, 0.9, 0.1, 0.05 } },
            { 7,   { 2.0, 0.5, 1.5, 0.2, 0.1 } },
            { 8,   { 0.7, 2.0, 1.3, 0.1, 0.05 } },
            { 108, { 2.0 } },
            { 109, { 3.0 } },
        };
        /* One line per type rather than one for all of them: a
         * fingerprint that covers ten curves says only that something
         * moved, and the next question is always which. */
        for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
            for (int sign = 1; sign >= -1; sign -= 2) {
                char label[40];
                cmsToneCurve* c = cmsBuildParametricToneCurve(NULL, cases[i].type * sign, cases[i].p);
                feed_curve(c);
                cmsFreeToneCurve(c);
                snprintf(label, sizeof label, "parametric type %d", cases[i].type * sign);
                report(label);
            }
        }

        /* A type that does not exist has to be refused, not guessed. */
        double p[1] = { 2.2 };
        printf("bad type -> %s\n",
               cmsBuildParametricToneCurve(NULL, 42, p) ? "built" : "refused");
    }

    /* -- tabulated curves ------------------------------------------------ */
    {
        cmsUInt16Number table[256];
        for (int i = 0; i < 256; i++) table[i] = (cmsUInt16Number) (i * 257);

        cmsToneCurve* c = cmsBuildTabulatedToneCurve16(NULL, 256, table);
        feed_curve(c);
        cmsFreeToneCurve(c);

        /* A descending table, where the fixed-point interpolation has to
         * not underflow. */
        for (int i = 0; i < 256; i++) table[i] = (cmsUInt16Number) (65535 - i * 257);
        c = cmsBuildTabulatedToneCurve16(NULL, 256, table);
        feed_curve(c);
        cmsFreeToneCurve(c);

        /* Two entries is the smallest table that still interpolates; one
         * entry is all endpoint. */
        cmsUInt16Number pair[2] = { 0, 65535 };
        c = cmsBuildTabulatedToneCurve16(NULL, 2, pair);
        feed_curve(c);
        cmsFreeToneCurve(c);

        cmsUInt16Number single[1] = { 12345 };
        c = cmsBuildTabulatedToneCurve16(NULL, 1, single);
        feed_curve(c);
        cmsFreeToneCurve(c);
        report("tabulated 16-bit curves");

        cmsFloat32Number values[64];
        for (int i = 0; i < 64; i++) values[i] = (cmsFloat32Number) (i / 63.0);
        c = cmsBuildTabulatedToneCurveFloat(NULL, 64, values);
        feed_curve(c);
        cmsFreeToneCurve(c);

        /* Non-monotonic, so the sampled segment is exercised properly. */
        for (int i = 0; i < 64; i++)
            values[i] = (cmsFloat32Number) (0.5 + 0.5 * ((i % 8) / 7.0));
        c = cmsBuildTabulatedToneCurveFloat(NULL, 64, values);
        feed_curve(c);
        cmsFreeToneCurve(c);
        report("tabulated float curves");
    }

    /* -- segments and duplication ---------------------------------------- */
    {
        cmsToneCurve* c = cmsBuildGamma(NULL, 2.2);
        const cmsCurveSegment* seg = cmsGetToneCurveSegment(0, c);
        printf("segment 0 type %d x0 %g x1 %g\n",
               seg ? seg->Type : -999,
               seg ? (double) seg->x0 : 0.0,
               seg ? (double) seg->x1 : 0.0);
        printf("segment 1 -> %s\n", cmsGetToneCurveSegment(1, c) ? "present" : "absent");
        printf("segment -1 -> %s\n", cmsGetToneCurveSegment(-1, c) ? "present" : "absent");

        /* A duplicate has to answer identically and own its own storage. */
        cmsToneCurve* d = cmsDupToneCurve(c);
        feed_curve(c);
        feed_curve(d);
        printf("dup table is distinct storage %d\n",
               cmsGetToneCurveEstimatedTable(c) != cmsGetToneCurveEstimatedTable(d));
        cmsFreeToneCurve(c);
        /* The duplicate must survive the original's death. */
        feed_curve(d);
        cmsFreeToneCurve(d);
        report("segments and duplication");
    }

    /* -- what a curve is -------------------------------------------------- */
    {
        cmsUInt16Number table[64];

        /* A linear ramp, a ramp with ripple inside the tolerance, one
         * with ripple past it, and a descending ramp. */
        for (int i = 0; i < 64; i++) table[i] = (cmsUInt16Number) (i * 65535 / 63);
        cmsToneCurve* linear = cmsBuildTabulatedToneCurve16(NULL, 64, table);

        for (int i = 0; i < 64; i++)
            table[i] = (cmsUInt16Number) (i * 65535 / 63 + ((i % 2) ? 1 : 0));
        cmsToneCurve* rippled = cmsBuildTabulatedToneCurve16(NULL, 64, table);

        for (int i = 0; i < 64; i++)
            table[i] = (cmsUInt16Number) ((i % 8) * 8000);
        cmsToneCurve* sawtooth = cmsBuildTabulatedToneCurve16(NULL, 64, table);

        for (int i = 0; i < 64; i++) table[i] = (cmsUInt16Number) (65535 - i * 65535 / 63);
        cmsToneCurve* descending = cmsBuildTabulatedToneCurve16(NULL, 64, table);

        cmsToneCurve* gamma = cmsBuildGamma(NULL, 2.2);

        cmsToneCurve* all[] = { linear, rippled, sawtooth, descending, gamma };
        static const char* names[] = { "linear", "rippled", "sawtooth", "descending", "gamma" };
        for (int i = 0; i < 5; i++) {
            printf("%-11s linear %d monotonic %d descending %d\n", names[i],
                   cmsIsToneCurveLinear(all[i]),
                   cmsIsToneCurveMonotonic(all[i]),
                   cmsIsToneCurveDescending(all[i]));
        }

        /* -- reversing ---------------------------------------------------- */
        for (int i = 0; i < 5; i++) {
            cmsToneCurve* r = cmsReverseToneCurve(all[i]);
            feed_curve(r);
            cmsFreeToneCurve(r);
            /* An explicit sample count takes the resampling path even for
             * a curve that could have been inverted analytically. */
            r = cmsReverseToneCurveEx(37, all[i]);
            feed_curve(r);
            cmsFreeToneCurve(r);
        }
        report("reversed curves");

        /* -- joining ------------------------------------------------------ */
        for (int i = 0; i < 5; i++) {
            cmsToneCurve* j = cmsJoinToneCurve(NULL, all[i], gamma, 128);
            feed_curve(j);
            cmsFreeToneCurve(j);
        }
        report("joined curves");

        /* -- estimating --------------------------------------------------- */
        for (int i = 0; i < 5; i++)
            feed_double(cmsEstimateGamma(all[i], 0.01));
        for (double precision = 0.001; precision < 10.0; precision *= 10.0) {
            feed_double(cmsEstimateGamma(gamma, precision));
            feed_double(cmsEstimateGamma(sawtooth, precision));
        }
        report("estimated gamma");

        /* -- smoothing ---------------------------------------------------- */
        {
            /* Smoothing mutates the curve, so each case gets its own. */
            static const double lambdas[] = { 0.0, 0.5, 1.0, 10.0, 100.0, -1.0, -100.0 };
            for (size_t k = 0; k < sizeof lambdas / sizeof *lambdas; k++) {
                cmsUInt16Number noisy[64];
                for (int i = 0; i < 64; i++)
                    noisy[i] = (cmsUInt16Number) (i * 65535 / 63 + ((i % 3) - 1) * 700);

                cmsToneCurve* c = cmsBuildTabulatedToneCurve16(NULL, 64, noisy);
                cmsBool ok = cmsSmoothToneCurve(c, lambdas[k]);
                feed_double((double) ok);
                feed_curve(c);
                cmsFreeToneCurve(c);
            }

            /* A linear curve needs no smoothing and says so. */
            cmsToneCurve* l = cmsBuildTabulatedToneCurve16(NULL, 64, table);
            for (int i = 0; i < 64; i++) table[i] = (cmsUInt16Number) (i * 65535 / 63);
            feed_double((double) cmsSmoothToneCurve(l, 1.0));
            cmsFreeToneCurve(l);
            report("smoothed curves");
        }

        cmsFreeToneCurve(linear);
        cmsFreeToneCurve(rippled);
        cmsFreeToneCurve(sawtooth);
        cmsFreeToneCurve(descending);
        cmsFreeToneCurve(gamma);
    }

    /* -- refusals --------------------------------------------------------- */
    {
        printf("65531 entries -> %s\n",
               cmsBuildTabulatedToneCurve16(NULL, 65531, NULL) ? "built" : "refused");
        printf("zero entries no segments -> %s\n",
               cmsBuildTabulatedToneCurve16(NULL, 0, NULL) ? "built" : "refused");
        printf("float curve with no values -> %s\n",
               cmsBuildTabulatedToneCurveFloat(NULL, 0, NULL) ? "built" : "refused");
        printf("dup of nothing -> %s\n", cmsDupToneCurve(NULL) ? "built" : "refused");
        cmsFreeToneCurve(NULL);
        printf("freeing nothing survived\n");
    }

    printf("curve probe OK\n");
    return 0;
}
