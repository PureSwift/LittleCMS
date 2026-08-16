/* matprobe.c - the vector and matrix primitives, against the reference
 *
 * Compiled against both libraries and the outputs compared.  Chromatic
 * adaptation and the matrix-shaper path run on these, and the order the
 * reference sums its products in decides the last bit, so the standard is
 * bit-for-bit agreement over a deterministic corpus of matrices — well
 * conditioned, nearly singular, exactly singular, and outright degenerate.
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
static void feed_vec(const cmsVEC3* v) { feed(v, sizeof *v); }
static void feed_mat(const cmsMAT3* m) { feed(m, sizeof *m); }

static void report(const char* name)
{
    printf("%-28s %016llx\n", name, (unsigned long long) hash_state);
    hash_state = 1469598103934665603ULL;
}

/* A reproducible stream with no library dependence, so both builds walk
 * exactly the same numbers. */
static uint32_t seed = 12345;
static double next_double(void)
{
    seed = seed * 1103515245u + 12345u;
    return ((double) ((seed >> 8) & 0xFFFF) / 32768.0) - 1.0;
}

/* Matrices worth exercising, beyond the random ones. */
static void special_matrix(int which, cmsMAT3* m)
{
    switch (which) {
    case 0:  /* identity */
        _cmsMAT3identity(m);
        break;
    case 1:  /* Bradford, the adaptation matrix the engine leans on */
        _cmsVEC3init(&m->v[0],  0.8951,  0.2664, -0.1614);
        _cmsVEC3init(&m->v[1], -0.7502,  1.7135,  0.0367);
        _cmsVEC3init(&m->v[2],  0.0389, -0.0685,  1.0296);
        break;
    case 2:  /* sRGB primaries to XYZ */
        _cmsVEC3init(&m->v[0], 0.4360747, 0.3850649, 0.1430804);
        _cmsVEC3init(&m->v[1], 0.2225045, 0.7168786, 0.0606169);
        _cmsVEC3init(&m->v[2], 0.0139322, 0.0971045, 0.7141733);
        break;
    case 3:  /* exactly singular: a repeated row */
        _cmsVEC3init(&m->v[0], 1.0, 2.0, 3.0);
        _cmsVEC3init(&m->v[1], 1.0, 2.0, 3.0);
        _cmsVEC3init(&m->v[2], 4.0, 5.0, 6.0);
        break;
    case 4:  /* all zeroes */
        _cmsVEC3init(&m->v[0], 0.0, 0.0, 0.0);
        _cmsVEC3init(&m->v[1], 0.0, 0.0, 0.0);
        _cmsVEC3init(&m->v[2], 0.0, 0.0, 0.0);
        break;
    case 5:  /* determinant just under the singularity tolerance */
        _cmsVEC3init(&m->v[0], 0.00001, 0.0, 0.0);
        _cmsVEC3init(&m->v[1], 0.0, 1.0, 0.0);
        _cmsVEC3init(&m->v[2], 0.0, 0.0, 1.0);
        break;
    case 6:  /* determinant just over it */
        _cmsVEC3init(&m->v[0], 0.001, 0.0, 0.0);
        _cmsVEC3init(&m->v[1], 0.0, 1.0, 0.0);
        _cmsVEC3init(&m->v[2], 0.0, 0.0, 1.0);
        break;
    default: /* within one 16-bit code of the identity, either side of the
              * tolerance isIdentity uses */
        _cmsVEC3init(&m->v[0], 1.0 + 1.0 / 131070.0, 0.0, 0.0);
        _cmsVEC3init(&m->v[1], 0.0, 1.0, 0.0);
        _cmsVEC3init(&m->v[2], 0.0, 0.0, 1.0 - 1.0 / 32767.0);
        break;
    }
}

#define SPECIALS 8

int main(void)
{
    cmsVEC3 a, b, r;

    /* -- vector arithmetic ---------------------------------------------- */

    for (int i = 0; i < 2000; i++) {
        _cmsVEC3init(&a, next_double(), next_double(), next_double());
        _cmsVEC3init(&b, next_double(), next_double(), next_double());

        _cmsVEC3minus(&r, &a, &b);
        feed_vec(&r);
        _cmsVEC3cross(&r, &a, &b);
        feed_vec(&r);
        feed_double(_cmsVEC3dot(&a, &b));
        feed_double(_cmsVEC3length(&a));
        feed_double(_cmsVEC3distance(&a, &b));
    }
    report("vector arithmetic");

    /* Degenerate vectors: zeroes, signed zeroes, and very small values,
     * where the square roots decide the last bit. */
    {
        static const double edge[] = { 0.0, -0.0, 1e-160, -1e-160, 1e160, 1.0, -1.0 };
        const size_t n = sizeof edge / sizeof *edge;
        for (size_t i = 0; i < n; i++)
            for (size_t j = 0; j < n; j++) {
                _cmsVEC3init(&a, edge[i], edge[j], edge[(i + j) % n]);
                _cmsVEC3init(&b, edge[j], edge[i], edge[(i + 1) % n]);
                feed_double(_cmsVEC3length(&a));
                feed_double(_cmsVEC3distance(&a, &b));
                feed_double(_cmsVEC3dot(&a, &b));
                _cmsVEC3cross(&r, &a, &b);
                feed_vec(&r);
            }
        report("vector edges");
    }

    /* -- matrices -------------------------------------------------------- */

    {
        cmsMAT3 m, n, product, inverse;

        for (int i = 0; i < SPECIALS; i++) {
            special_matrix(i, &m);
            feed_mat(&m);
            feed_double((double) _cmsMAT3isIdentity(&m));

            for (int j = 0; j < SPECIALS; j++) {
                special_matrix(j, &n);
                _cmsMAT3per(&product, &m, &n);
                feed_mat(&product);
            }

            /* The return value matters as much as the result: singular
             * matrices must be rejected at the same threshold. */
            cmsBool ok = _cmsMAT3inverse(&m, &inverse);
            feed_double((double) ok);
            if (ok) feed_mat(&inverse);

            _cmsVEC3init(&a, 0.3, 0.5, 0.7);
            _cmsMAT3eval(&r, &m, &a);
            feed_vec(&r);

            cmsMAT3 copy = m;
            cmsVEC3 rhs;
            _cmsVEC3init(&rhs, 1.0, 2.0, 3.0);
            cmsBool solved = _cmsMAT3solve(&r, &copy, &rhs);
            feed_double((double) solved);
            if (solved) feed_vec(&r);
        }
        report("matrix specials");

        for (int i = 0; i < 1000; i++) {
            for (int row = 0; row < 3; row++)
                _cmsVEC3init(&m.v[row], next_double(), next_double(), next_double());

            feed_double((double) _cmsMAT3isIdentity(&m));

            for (int row = 0; row < 3; row++)
                _cmsVEC3init(&n.v[row], next_double(), next_double(), next_double());

            _cmsMAT3per(&product, &m, &n);
            feed_mat(&product);

            cmsBool ok = _cmsMAT3inverse(&m, &inverse);
            feed_double((double) ok);
            if (ok) {
                feed_mat(&inverse);
                /* m * m^-1 should be near identity; feed it so any
                 * divergence in either direction shows up. */
                _cmsMAT3per(&product, &m, &inverse);
                feed_mat(&product);
                feed_double((double) _cmsMAT3isIdentity(&product));
            }

            _cmsVEC3init(&a, next_double(), next_double(), next_double());
            _cmsMAT3eval(&r, &m, &a);
            feed_vec(&r);

            cmsMAT3 copy = m;
            cmsBool solved = _cmsMAT3solve(&r, &copy, &a);
            feed_double((double) solved);
            if (solved) feed_vec(&r);
        }
        report("matrix random");
    }

    printf("matrix probe OK\n");
    return 0;
}
