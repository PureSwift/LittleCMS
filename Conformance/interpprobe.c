/* interpprobe.c - the interpolation kernels, against the reference
 *
 * These are reached the way a plugin reaches them: build the parameters
 * through the exported entry point, then call the function pointer the
 * union holds.  That is the published contract, and it is also the only
 * way to drive the kernels before pipelines exist.
 *
 * Every dimensionality from one to fifteen, in both precisions, with the
 * trilinear and tetrahedral variants of the three-input case, and one
 * fingerprint per shape so a failure names itself.
 */

#include "lcms2.h"
#include "lcms2_plugin.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

CMSAPI cmsInterpParams* CMSEXPORT _cmsComputeInterpParams(cmsContext ContextID,
    cmsUInt32Number nSamples, cmsUInt32Number InputChan, cmsUInt32Number OutputChan,
    const void* Table, cmsUInt32Number dwFlags);
CMSAPI void CMSEXPORT _cmsFreeInterpParams(cmsInterpParams* p);

static uint64_t hash_state = 1469598103934665603ULL;

static void feed(const void* bytes, size_t length)
{
    const unsigned char* p = (const unsigned char*) bytes;
    for (size_t i = 0; i < length; i++) {
        hash_state ^= p[i];
        hash_state *= 1099511628211ULL;
    }
}

static void feed_u16(uint16_t v) { feed(&v, sizeof v); }
static void feed_float(float v)
{
    if (v != v) { feed("NaN", 3); return; }   /* see docs/abi-audit.md */
    feed(&v, sizeof v);
}

static void report(const char* name)
{
    printf("%-34s %016llx\n", name, (unsigned long long) hash_state);
    hash_state = 1469598103934665603ULL;
}

/* A reproducible input stream, so both builds walk the same numbers. */
static uint32_t seed;
static uint32_t next(void) { seed = seed * 1103515245u + 12345u; return seed >> 8; }

/* How many table entries a grid of this shape needs. */
static size_t table_size(int nodes, int inputs, int outputs)
{
    size_t n = 1;
    for (int i = 0; i < inputs; i++) n *= (size_t) nodes;
    return n * (size_t) outputs;
}

static void probe_shape(int nodes, int inputs, int outputs, int isFloat, int trilinear)
{
    char label[64];
    snprintf(label, sizeof label, "%dD %d->%d %s%s",
             inputs, inputs, outputs, isFloat ? "float" : "16bit",
             trilinear ? " trilinear" : "");

    size_t entries = table_size(nodes, inputs, outputs);
    /* Keep the memory sane for the higher dimensions. */
    if (entries > 4u * 1024 * 1024) { printf("%-34s skipped (too large)\n", label); return; }

    cmsUInt32Number flags = (isFloat ? CMS_LERP_FLAGS_FLOAT : CMS_LERP_FLAGS_16BITS)
                          | (trilinear ? CMS_LERP_FLAGS_TRILINEAR : 0);

    void* table = malloc(entries * (isFloat ? sizeof(float) : sizeof(cmsUInt16Number)));
    if (table == NULL) { printf("%-34s skipped (no memory)\n", label); return; }

    seed = 20260817u;
    if (isFloat) {
        float* t = (float*) table;
        for (size_t i = 0; i < entries; i++) t[i] = (float) (next() & 0xFFFF) / 65535.0f;
    } else {
        cmsUInt16Number* t = (cmsUInt16Number*) table;
        for (size_t i = 0; i < entries; i++) t[i] = (cmsUInt16Number) (next() & 0xFFFF);
    }

    cmsInterpParams* p = _cmsComputeInterpParams(NULL, (cmsUInt32Number) nodes,
                                                 (cmsUInt32Number) inputs,
                                                 (cmsUInt32Number) outputs,
                                                 table, flags);
    if (p == NULL) { printf("%-34s refused\n", label); free(table); return; }

    /* The grid the parameters describe is part of the contract too:
     * plugins read these fields directly in their hot loops. */
    feed(&p->nInputs, sizeof p->nInputs);
    feed(&p->nOutputs, sizeof p->nOutputs);
    for (int i = 0; i < inputs; i++) {
        feed(&p->nSamples[i], sizeof p->nSamples[i]);
        feed(&p->Domain[i], sizeof p->Domain[i]);
        feed(&p->opta[i], sizeof p->opta[i]);
    }

    seed = 99887766u;
    for (int trial = 0; trial < 400; trial++) {
        if (isFloat) {
            float in[16], out[16];
            for (int i = 0; i < inputs; i++) {
                /* Inside the unit interval, and deliberately outside it
                 * at both ends, where the clamp decides. */
                int pick = (int) (next() % 10);
                in[i] = pick == 0 ? -0.25f
                      : pick == 1 ? 1.25f
                      : pick == 2 ? 0.0f
                      : pick == 3 ? 1.0f
                      : (float) (next() & 0xFFFF) / 65535.0f;
            }
            memset(out, 0, sizeof out);
            p->Interpolation.LerpFloat(in, out, p);
            for (int i = 0; i < outputs; i++) feed_float(out[i]);
        } else {
            cmsUInt16Number in[16], out[16];
            for (int i = 0; i < inputs; i++) {
                int pick = (int) (next() % 8);
                in[i] = pick == 0 ? 0
                      : pick == 1 ? 0xFFFF
                      : pick == 2 ? 0x8000
                      : (cmsUInt16Number) (next() & 0xFFFF);
            }
            memset(out, 0, sizeof out);
            p->Interpolation.Lerp16(in, out, p);
            for (int i = 0; i < outputs; i++) feed_u16(out[i]);
        }
    }

    report(label);
    _cmsFreeInterpParams(p);
    free(table);
}

int main(void)
{
    /* One and two inputs, where the single-output case takes its own
     * path and the multi-output case takes another. */
    probe_shape(17, 1, 1, 0, 0);
    probe_shape(17, 1, 1, 1, 0);
    probe_shape(17, 1, 3, 0, 0);
    probe_shape(17, 1, 3, 1, 0);
    probe_shape(2, 1, 1, 0, 0);       /* the smallest grid that interpolates */
    probe_shape(2, 1, 4, 1, 0);

    probe_shape(9, 2, 3, 0, 0);
    probe_shape(9, 2, 3, 1, 0);

    /* Three inputs, both variants of both precisions — the tetrahedral
     * kernels are where a misplaced comparison changes a colour. */
    probe_shape(9, 3, 3, 0, 0);
    probe_shape(9, 3, 3, 1, 0);
    probe_shape(9, 3, 3, 0, 1);
    probe_shape(9, 3, 3, 1, 1);
    probe_shape(2, 3, 3, 0, 0);
    probe_shape(33, 3, 4, 0, 0);
    probe_shape(33, 3, 4, 1, 0);

    /* Four inputs and up, where each dimension splits and recurses. */
    probe_shape(7, 4, 4, 0, 0);
    probe_shape(7, 4, 4, 1, 0);
    probe_shape(5, 5, 4, 0, 0);
    probe_shape(5, 5, 4, 1, 0);
    probe_shape(4, 6, 3, 0, 0);
    probe_shape(4, 6, 3, 1, 0);
    probe_shape(3, 7, 3, 0, 0);
    probe_shape(3, 7, 3, 1, 0);
    probe_shape(3, 8, 3, 0, 0);
    probe_shape(3, 8, 3, 1, 0);
    probe_shape(2, 9, 3, 0, 0);
    probe_shape(2, 10, 3, 0, 0);
    probe_shape(2, 11, 3, 0, 0);
    probe_shape(2, 12, 3, 0, 0);
    probe_shape(2, 13, 3, 0, 0);
    probe_shape(2, 14, 3, 0, 0);
    probe_shape(2, 15, 3, 0, 0);
    probe_shape(2, 15, 3, 1, 0);

    /* Refusals: past the dimension limit, and the guard on a wide grid. */
    printf("16 inputs -> %s\n",
           _cmsComputeInterpParams(NULL, 2, 16, 3, NULL, CMS_LERP_FLAGS_16BITS)
           ? "made" : "refused");
    printf("4 in 128 out -> %s\n",
           _cmsComputeInterpParams(NULL, 2, 4, 128, NULL, CMS_LERP_FLAGS_16BITS)
           ? "made" : "refused");
    printf("4 in 127 out -> %s\n",
           _cmsComputeInterpParams(NULL, 2, 4, 127, NULL, CMS_LERP_FLAGS_16BITS)
           ? "made" : "refused");

    _cmsFreeInterpParams(NULL);
    printf("freeing nothing survived\n");

    printf("interpolation probe OK\n");
    return 0;
}
