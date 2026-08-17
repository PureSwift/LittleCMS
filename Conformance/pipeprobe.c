/* pipeprobe.c - pipelines and stages, against the reference
 *
 * A pipeline evaluates in floating point whatever precision it is asked
 * in, so the 16-bit path is the float path with a conversion at each end.
 * The probe drives both, and reads the published stage data the way a
 * plugin does — cmsStageData returns the live block, not a copy.
 */

#include "lcms2.h"
#include "lcms2_plugin.h"

/* Declared in no shipped header, but exported all the same -- part of
 * the de-facto ABI a plugin links against. */
CMSAPI cmsStage* CMSEXPORT _cmsStageAllocIdentityCurves(cmsContext ContextID,
                                                        cmsUInt32Number nChannels);
CMSAPI cmsStage* CMSEXPORT _cmsStageAllocLabV2ToV4(cmsContext ContextID);
CMSAPI cmsStage* CMSEXPORT _cmsStageAllocLabV4ToV2(cmsContext ContextID);
CMSAPI cmsStage* CMSEXPORT _cmsStageAllocIdentityCLut(cmsContext ContextID,
                                                      cmsUInt32Number nChan);
CMSAPI cmsStage* CMSEXPORT _cmsStageAllocLab2XYZ(cmsContext ContextID);
CMSAPI cmsStage* CMSEXPORT _cmsStageAllocXYZ2Lab(cmsContext ContextID);
CMSAPI cmsUInt32Number CMSEXPORT _cmsReasonableGridpointsByColorspace(
    cmsColorSpaceSignature Colorspace, cmsUInt32Number dwFlags);

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

static void feed_u16(uint16_t v) { feed(&v, sizeof v); }
static void feed_float(float v)
{
    if (v != v) { feed("NaN", 3); return; }
    feed(&v, sizeof v);
}

static void report(const char* name)
{
    printf("%-32s %016llx\n", name, (unsigned long long) hash_state);
    hash_state = 1469598103934665603ULL;
}

static uint32_t seed = 4242;
static uint32_t next(void) { seed = seed * 1103515245u + 12345u; return seed >> 8; }

static void run(cmsPipeline* lut, const char* label)
{
    cmsUInt32Number in = cmsPipelineInputChannels(lut);
    cmsUInt32Number out = cmsPipelineOutputChannels(lut);
    printf("%-32s %u->%u stages %u\n", label, in, out, cmsPipelineStageCount(lut));

    seed = 4242;
    for (int trial = 0; trial < 300; trial++) {
        cmsFloat32Number fin[16], fout[16];
        cmsUInt16Number win[16], wout[16];

        for (cmsUInt32Number i = 0; i < in; i++) {
            int pick = (int) (next() % 8);
            cmsFloat32Number v = pick == 0 ? 0.0f
                               : pick == 1 ? 1.0f
                               : pick == 2 ? -0.1f
                               : pick == 3 ? 1.1f
                               : (cmsFloat32Number) (next() & 0xFFFF) / 65535.0f;
            fin[i] = v;
            win[i] = (cmsUInt16Number) (next() & 0xFFFF);
        }

        memset(fout, 0, sizeof fout);
        cmsPipelineEvalFloat(fin, fout, lut);
        for (cmsUInt32Number i = 0; i < out; i++) feed_float(fout[i]);

        memset(wout, 0, sizeof wout);
        cmsPipelineEval16(win, wout, lut);
        for (cmsUInt32Number i = 0; i < out; i++) feed_u16(wout[i]);
    }
    report(label);
}

int main(void)
{
    /* -- an empty pipeline, and its limits --------------------------------- */
    {
        cmsPipeline* lut = cmsPipelineAlloc(NULL, 3, 3);
        printf("allocated %d\n", lut != NULL);
        run(lut, "empty 3->3");
        cmsPipelineFree(lut);

        printf("0 channels -> %s\n", cmsPipelineAlloc(NULL, 0, 0) ? "made" : "refused");
        printf("16 channels -> %s\n", cmsPipelineAlloc(NULL, 16, 3) ? "made" : "refused");
        printf("15 channels -> %s\n", cmsPipelineAlloc(NULL, 15, 3) ? "made" : "refused");
    }

    /* -- identity and matrix ------------------------------------------------ */
    {
        cmsPipeline* lut = cmsPipelineAlloc(NULL, 3, 3);
        cmsPipelineInsertStage(lut, cmsAT_BEGIN, cmsStageAllocIdentity(NULL, 3));
        run(lut, "identity");

        static const cmsFloat64Number matrix[9] = {
            0.4360747, 0.3850649, 0.1430804,
            0.2225045, 0.7168786, 0.0606169,
            0.0139322, 0.0971045, 0.7141733
        };
        static const cmsFloat64Number offset[3] = { 0.01, -0.02, 0.03 };

        cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocMatrix(NULL, 3, 3, matrix, NULL));
        run(lut, "identity + matrix");

        cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocMatrix(NULL, 3, 3, matrix, offset));
        run(lut, "with offset matrix");

        /* A non-square matrix changes the pipeline's own shape. */
        static const cmsFloat64Number wide[12] = {
            1, 0, 0, 0.5, 0, 1, 0, 0.25, 0, 0, 1, 0.125
        };
        cmsPipeline* other = cmsPipelineAlloc(NULL, 4, 3);
        cmsPipelineInsertStage(other, cmsAT_BEGIN, cmsStageAllocMatrix(NULL, 3, 4, wide, NULL));
        run(other, "4->3 matrix");
        cmsPipelineFree(other);

        cmsPipelineFree(lut);
    }

    /* -- tone curves --------------------------------------------------------- */
    {
        cmsPipeline* lut = cmsPipelineAlloc(NULL, 3, 3);

        /* No curves at all means an identity ramp per channel. */
        cmsPipelineInsertStage(lut, cmsAT_BEGIN, cmsStageAllocToneCurves(NULL, 3, NULL));
        run(lut, "default curves");
        cmsPipelineFree(lut);

        cmsToneCurve* curves[3];
        curves[0] = cmsBuildGamma(NULL, 2.2);
        curves[1] = cmsBuildGamma(NULL, 1.8);
        curves[2] = cmsBuildGamma(NULL, 1.0);

        lut = cmsPipelineAlloc(NULL, 3, 3);
        cmsPipelineInsertStage(lut, cmsAT_BEGIN, cmsStageAllocToneCurves(NULL, 3, curves));
        run(lut, "gamma curves");

        /* The published block, read the way a plugin reads it. */
        cmsStage* mpe = cmsPipelineGetPtrToFirstStage(lut);
        printf("stage type %08x in %u out %u\n",
               (unsigned) cmsStageType(mpe),
               cmsStageInputChannels(mpe), cmsStageOutputChannels(mpe));
        _cmsStageToneCurvesData* data = (_cmsStageToneCurvesData*) cmsStageData(mpe);
        printf("curve data %s nCurves %u\n", data ? "present" : "absent",
               data ? data->nCurves : 0);
        if (data) {
            for (cmsUInt32Number i = 0; i < data->nCurves; i++)
                feed_float(cmsEvalToneCurveFloat(data->TheCurves[i], 0.5f));
            report("curves through stage data");
        }

        /* The stage takes a *copy* of each curve, so the caller still
         * owns what it passed and may free it immediately.  Freeing
         * here and evaluating afterwards is the whole point: a stage
         * that had kept the caller's pointers would read freed memory,
         * and nothing else in this probe would notice. */
        cmsFreeToneCurve(curves[0]);
        cmsFreeToneCurve(curves[1]);
        cmsFreeToneCurve(curves[2]);
        run(lut, "gamma curves after caller freed");

        cmsPipelineFree(lut);
    }

    /* -- the chain ------------------------------------------------------------ */
    {
        cmsPipeline* lut = cmsPipelineAlloc(NULL, 3, 3);
        cmsPipelineInsertStage(lut, cmsAT_BEGIN, cmsStageAllocIdentity(NULL, 3));
        cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, NULL));
        cmsPipelineInsertStage(lut, cmsAT_BEGIN, cmsStageAllocIdentity(NULL, 3));

        /* Walked with the pointers a client would use. */
        int n = 0;
        for (cmsStage* s = cmsPipelineGetPtrToFirstStage(lut); s; s = cmsStageNext(s)) {
            printf("  stage %d type %08x\n", n++, (unsigned) cmsStageType(s));
        }
        printf("count %u last type %08x\n", cmsPipelineStageCount(lut),
               (unsigned) cmsStageType(cmsPipelineGetPtrToLastStage(lut)));

        /* Unlinking hands the stage back, and the caller then owns it. */
        cmsStage* taken = NULL;
        cmsPipelineUnlinkStage(lut, cmsAT_BEGIN, &taken);
        printf("unlinked type %08x count now %u\n",
               (unsigned) cmsStageType(taken), cmsPipelineStageCount(lut));
        cmsStageFree(taken);

        /* Unlinking with nowhere to put it frees the stage instead. */
        cmsPipelineUnlinkStage(lut, cmsAT_END, NULL);
        printf("count after dropping %u\n", cmsPipelineStageCount(lut));

        printf("save-as-8-bits was %d now %d\n",
               cmsPipelineSetSaveAs8bitsFlag(lut, TRUE),
               cmsPipelineSetSaveAs8bitsFlag(lut, FALSE));

        cmsPipelineFree(lut);
    }

    /* -- matching a pipeline against a shape -------------------------------- */
    {
        /* cmsPipelineCheckAndRetreiveStages takes n type signatures and
         * then n out-pointers as one variadic list.  Nothing is written
         * unless every type matches, so a caller can try several shapes
         * in turn against the same pointers and only the one that fits
         * fills them -- which is how the LutAToB writer decides which
         * layout a pipeline has. */
        cmsPipeline* lut = cmsPipelineAlloc(NULL, 3, 3);
        cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, NULL));
        cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocIdentity(NULL, 3));
        cmsPipelineInsertStage(lut, cmsAT_END, cmsStageAllocToneCurves(NULL, 3, NULL));

        cmsStage *a = NULL, *b = NULL, *c = NULL;

        /* Wrong count. */
        printf("count 2 -> %d\n",
               cmsPipelineCheckAndRetreiveStages(lut, 2,
                   cmsSigCurveSetElemType, cmsSigCurveSetElemType, &a, &b));
        printf("  untouched %d %d\n", a == NULL, b == NULL);

        /* Right count, wrong types: the pointers must stay untouched. */
        printf("wrong types -> %d\n",
               cmsPipelineCheckAndRetreiveStages(lut, 3,
                   cmsSigCurveSetElemType, cmsSigMatrixElemType, cmsSigCurveSetElemType,
                   &a, &b, &c));
        printf("  untouched %d %d %d\n", a == NULL, b == NULL, c == NULL);

        /* The shape it actually has. */
        printf("right shape -> %d\n",
               cmsPipelineCheckAndRetreiveStages(lut, 3,
                   cmsSigCurveSetElemType, cmsSigIdentityElemType, cmsSigCurveSetElemType,
                   &a, &b, &c));
        printf("  filled %d %d %d types %08x %08x %08x\n",
               a != NULL, b != NULL, c != NULL,
               a ? (unsigned) cmsStageType(a) : 0,
               b ? (unsigned) cmsStageType(b) : 0,
               c ? (unsigned) cmsStageType(c) : 0);
        printf("  first is head %d last is tail %d\n",
               a == cmsPipelineGetPtrToFirstStage(lut),
               c == cmsPipelineGetPtrToLastStage(lut));

        /* A null out-pointer is skipped rather than crashed on. */
        cmsStage* only = NULL;
        printf("null slots -> %d, middle %d\n",
               cmsPipelineCheckAndRetreiveStages(lut, 3,
                   cmsSigCurveSetElemType, cmsSigIdentityElemType, cmsSigCurveSetElemType,
                   NULL, &only, NULL),
               only != NULL);

        /* An empty pipeline matches only a count of zero. */
        cmsPipeline* empty = cmsPipelineAlloc(NULL, 3, 3);
        printf("empty vs 1 -> %d\n",
               cmsPipelineCheckAndRetreiveStages(empty, 1, cmsSigCurveSetElemType, &a));
        printf("empty vs 0 -> %d\n",
               cmsPipelineCheckAndRetreiveStages(empty, 0));
        cmsPipelineFree(empty);

        cmsPipelineFree(lut);
    }

    /* -- stages the library builds for itself --------------------------------- */
    {
        /* Version 2 Lab counts to 0xFF00 and version 4 to 0xFFFF, so the
         * conversion between them is a scale so close to one that it
         * looks like noise. Round-tripping through both is the check. */
        cmsPipeline* lut = cmsPipelineAlloc(NULL, 3, 3);
        cmsPipelineInsertStage(lut, cmsAT_END, _cmsStageAllocLabV2ToV4(NULL));
        run(lut, "Lab v2 to v4");

        cmsPipelineInsertStage(lut, cmsAT_END, _cmsStageAllocLabV4ToV2(NULL));
        run(lut, "Lab v2 to v4 and back");
        cmsPipelineFree(lut);

        /* Identity curves are a curve set that stands for an identity;
         * the type says what it is, not what it means. */
        cmsPipeline* ident = cmsPipelineAlloc(NULL, 4, 4);
        cmsStage* curves = _cmsStageAllocIdentityCurves(NULL, 4);
        printf("identity curves type %08x in %u out %u\n",
               (unsigned) cmsStageType(curves),
               cmsStageInputChannels(curves), cmsStageOutputChannels(curves));
        cmsPipelineInsertStage(ident, cmsAT_END, curves);
        run(ident, "identity curves");

        /* Duplicating must carry what the stage stands for, not just
         * what it is. */
        cmsPipeline* copy = cmsPipelineDup(ident);
        run(copy, "identity curves duplicated");
        cmsPipelineFree(copy);
        cmsPipelineFree(ident);
    }

    /* -- the identity CLUT and the grid heuristic ----------------------------- */
    {
        /* Two nodes on every axis is the fewest that still interpolate,
         * so this is the cheapest table that changes nothing. */
        for (int chans = 1; chans <= 4; chans++) {
            cmsPipeline* lut = cmsPipelineAlloc(NULL, (cmsUInt32Number) chans,
                                                (cmsUInt32Number) chans);
            cmsStage* clut = _cmsStageAllocIdentityCLut(NULL, (cmsUInt32Number) chans);
            printf("identity clut %d type %08x\n", chans,
                   (unsigned) cmsStageType(clut));
            cmsPipelineInsertStage(lut, cmsAT_END, clut);

            char label[32];
            snprintf(label, sizeof label, "identity clut %d", chans);
            run(lut, label);
            cmsPipelineFree(lut);
        }

        /* How fine a grid a transform is precalculated onto: a number in
         * the flags wins outright, otherwise it depends on the channel
         * count and which precision flag is set. */
        static const cmsColorSpaceSignature spaces[] = {
            cmsSigGrayData, cmsSigRgbData, cmsSigCmykData, cmsSigMCH6Data,
            (cmsColorSpaceSignature) 0
        };
        static const cmsUInt32Number flagsets[] = {
            0, cmsFLAGS_HIGHRESPRECALC, cmsFLAGS_LOWRESPRECALC,
            cmsFLAGS_GRIDPOINTS(11), cmsFLAGS_GRIDPOINTS(255),
            cmsFLAGS_GRIDPOINTS(31) | cmsFLAGS_HIGHRESPRECALC
        };
        for (size_t i = 0; i < sizeof spaces / sizeof spaces[0]; i++)
            for (size_t j = 0; j < sizeof flagsets / sizeof flagsets[0]; j++)
                printf("grid %08x flags %08x -> %u\n",
                       (unsigned) spaces[i], (unsigned) flagsets[j],
                       _cmsReasonableGridpointsByColorspace(spaces[i], flagsets[j]));
    }

    /* -- the two PCS conversion stages ---------------------------------------- */
    {
        /* A pipeline's channels run 0..1 but neither Lab nor XYZ does,
         * so each stage scales in, converts, and scales back out. The
         * XYZ scale is the largest value 15.16 can hold, not one. */
        cmsPipeline* toXYZ = cmsPipelineAlloc(NULL, 3, 3);
        cmsPipelineInsertStage(toXYZ, cmsAT_END, _cmsStageAllocLab2XYZ(NULL));
        run(toXYZ, "Lab to XYZ");

        cmsPipeline* toLab = cmsPipelineAlloc(NULL, 3, 3);
        cmsPipelineInsertStage(toLab, cmsAT_END, _cmsStageAllocXYZ2Lab(NULL));
        run(toLab, "XYZ to Lab");

        /* Through both, which should return very nearly what went in --
         * the point being that "very nearly" is identical in both
         * libraries, down to the last bit. */
        cmsPipelineInsertStage(toXYZ, cmsAT_END, _cmsStageAllocXYZ2Lab(NULL));
        run(toXYZ, "Lab to XYZ and back");

        /* Named landmarks rather than random input, so a divergence
         * says which colour moved. */
        static const cmsFloat32Number probes[5][3] = {
            { 1.0f, 0.5f, 0.5f },        /* white */
            { 0.0f, 0.5f, 0.5f },        /* black */
            { 0.5f, 0.5f, 0.5f },        /* mid grey */
            { 0.53f, 0.82f, 0.75f },     /* a saturated red */
            { 0.87f, 0.29f, 0.94f }      /* a saturated yellow */
        };
        for (int i = 0; i < 5; i++) {
            cmsFloat32Number out[3];
            memset(out, 0, sizeof out);
            cmsPipelineEvalFloat(probes[i], out, toXYZ);
            printf("  round trip %d: %.6f %.6f %.6f -> %.6f %.6f %.6f\n", i,
                   probes[i][0], probes[i][1], probes[i][2],
                   out[0], out[1], out[2]);
        }

        cmsPipelineFree(toXYZ);
        cmsPipelineFree(toLab);
    }

    printf("pipeline probe OK\n");
    return 0;
}
