/* primprobe.c - the arithmetic primitives, against the reference
 *
 * Compiled twice from this source — once against our library, once against
 * the reference — and the outputs are compared.  These functions decide
 * how every value that crosses the ICC boundary rounds, so the standard is
 * bit-for-bit agreement, not closeness: the summaries printed here are
 * checksums and exact counts, and any disagreement moves one.
 *
 * The half-float sweeps are exhaustive (all 65536 codes, and every float
 * whose bit pattern this walks), because the table-driven conversion's
 * whole point is the boundary cases.
 */

#include "lcms2.h"
#include "lcms2_plugin.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* Three of these are exported by the reference but declared in no header it
 * installs, so they are declared here — which is exactly what a client
 * binding them has to do, and part of what is being tested.  The
 * signatures are the reference's, from its private lcms2_internal.h. */
CMSAPI cmsUInt16Number  CMSEXPORT _cmsQuantizeVal(cmsFloat64Number i, cmsUInt32Number MaxSamples);
CMSAPI cmsUInt16Number  CMSEXPORT _cmsFloat2Half(cmsFloat32Number flt);
CMSAPI cmsFloat32Number CMSEXPORT _cmsHalf2Float(cmsUInt16Number h);

/* FNV-1a over raw bytes: an exact fingerprint of a value sequence, so a
 * single differing bit anywhere shows up as a different line. */
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
static void feed_float(float v)   { feed(&v, sizeof v); }
static void feed_u16(uint16_t v)  { feed(&v, sizeof v); }
static void feed_u32(uint32_t v)  { feed(&v, sizeof v); }
static void feed_i32(int32_t v)   { feed(&v, sizeof v); }

static void report(const char* name)
{
    printf("%-28s %016llx\n", name, (unsigned long long) hash_state);
    hash_state = 1469598103934665603ULL;
}

/* The awkward doubles: zeroes and their signs, subnormals, the exact
 * halfway cases the fast floor is known to treat differently from floor(),
 * and the edges of the 15.16 range.
 *
 * Values whose 15.16 encoding overflows a signed 32-bit integer are
 * deliberately absent.  The reference reaches them through a C cast that
 * is undefined on overflow, and the hardware disagrees with itself about
 * what that does: arm64 saturates, x86-64 yields INT32_MIN whichever way
 * it overflowed.  Holding this library to "the reference's answer" there
 * would mean holding it to two different answers depending on the runner.
 * Our own behaviour for those inputs is defined and pinned by a unit test
 * in Tests/LittleCMSTests/FixedPointTests.swift instead.  An ICC 15.16
 * number cannot exceed +-32768, so nothing valid is going unmeasured. */
static const double adversarial[] = {
    0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 1.5, -1.5, 2.5, -2.5,
    0.4999999999999999, 0.5000000000000001, -0.4999999999999999, -0.5000000000000001,
    1.0 / 3.0, 2.0 / 3.0, 0.1, 0.2, 0.3, 0.7,
    1e-300, -1e-300, 5e-324, -5e-324,
    32767.0, 32767.5, -32768.0, -32767.5,
    32767.99998474121,
    1.0 / 65536.0, -1.0 / 65536.0, 0.9999847412109375,
    100.0, -100.0, 1000.5, 12345.678,
};

int main(void)
{
    /* -- 15.16 fixed point, both directions ---------------------------- */

    for (size_t i = 0; i < sizeof adversarial / sizeof *adversarial; i++)
        feed_i32(_cmsDoubleTo15Fixed16(adversarial[i]));
    report("15fixed16 <- adversarial");

    /* A dense sweep across the representable range, including negatives. */
    for (int32_t k = -40000; k <= 40000; k += 7)
        feed_i32(_cmsDoubleTo15Fixed16(k / 997.0));
    report("15fixed16 <- sweep");

    for (int64_t bits = INT32_MIN; bits <= INT32_MAX; bits += 65539)
        feed_double(_cms15Fixed16toDouble((cmsS15Fixed16Number) bits));
    report("15fixed16 -> double");

    /* -- 8.8 fixed point ----------------------------------------------- */

    for (size_t i = 0; i < sizeof adversarial / sizeof *adversarial; i++)
        feed_u16(_cmsDoubleTo8Fixed8(adversarial[i]));
    report("8fixed8 <- adversarial");

    for (uint32_t v = 0; v <= 0xFFFF; v++)
        feed_double(_cms8Fixed8toDouble((cmsUInt16Number) v));
    report("8fixed8 -> double (all)");

    /* -- quantization --------------------------------------------------- */

    for (cmsUInt32Number samples = 2; samples <= 256; samples++)
        for (cmsUInt32Number i = 0; i < samples; i++)
            feed_u16(_cmsQuantizeVal((cmsFloat64Number) i, samples));
    report("quantize grid");

    for (size_t i = 0; i < sizeof adversarial / sizeof *adversarial; i++)
        feed_u16(_cmsQuantizeVal(adversarial[i], 33));
    report("quantize adversarial");

    /* -- byte order ----------------------------------------------------- */

    for (uint32_t v = 0; v <= 0xFFFF; v++)
        feed_u16(_cmsAdjustEndianess16((cmsUInt16Number) v));
    report("endian16 (all)");

    for (uint64_t v = 0; v <= 0xFFFFFFFFULL; v += 65521)
        feed_u32(_cmsAdjustEndianess32((cmsUInt32Number) v));
    report("endian32 sweep");

    {
        cmsUInt64Number in, out;
        for (uint64_t k = 0; k < 4096; k++) {
            in = (cmsUInt64Number) (k * 0x0123456789ABCDEFULL + k);
            _cmsAdjustEndianess64(&out, &in);
            feed(&out, sizeof out);
        }
        report("endian64 sweep");
    }

    /* -- half precision, exhaustively ----------------------------------- */

    for (uint32_t h = 0; h <= 0xFFFF; h++)
        feed_float(_cmsHalf2Float((cmsUInt16Number) h));
    report("half -> float (all 65536)");

    /* Every half code, back through float: the round trip must be exact
     * for everything the format can represent. */
    for (uint32_t h = 0; h <= 0xFFFF; h++)
        feed_u16(_cmsFloat2Half(_cmsHalf2Float((cmsUInt16Number) h)));
    report("half round trip (all)");

    /* Floats spanning the whole exponent range, including subnormals,
     * infinities and NaNs, walked by bit pattern. */
    {
        union { float f; uint32_t u; } bits;
        for (uint64_t u = 0; u <= 0xFFFFFFFFULL; u += 8191) {
            bits.u = (uint32_t) u;
            feed_u16(_cmsFloat2Half(bits.f));
        }
        report("float -> half sweep");
    }

    {
        static const float interesting[] = {
            0.0f, -0.0f, 1.0f, -1.0f, 0.5f, 65504.0f, -65504.0f,
            65519.0f, 65520.0f, 131008.0f,
            6.10352e-5f, 6.09756e-5f, 5.96046e-8f, 2.98023e-8f,
            1e-45f, 1e38f, -1e38f,
        };
        for (size_t i = 0; i < sizeof interesting / sizeof *interesting; i++)
            feed_u16(_cmsFloat2Half(interesting[i]));
        feed_u16(_cmsFloat2Half(INFINITY));
        feed_u16(_cmsFloat2Half(-INFINITY));
        feed_u16(_cmsFloat2Half(NAN));
        report("float -> half boundaries");
    }

    printf("primitives probe OK\n");
    return 0;
}
