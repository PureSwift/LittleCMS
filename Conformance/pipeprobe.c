/* pipeprobe.c - pipelines and stages, against the reference
 *
 * A pipeline evaluates in floating point whatever precision it is asked
 * in, so the 16-bit path is the float path with a conversion at each end.
 * The probe drives both, and reads the published stage data the way a
 * plugin does — cmsStageData returns the live block, not a copy.
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

        cmsPipelineFree(lut);
        /* The pipeline owns the curves once the stage is inserted, so
         * they are not freed here. */
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

    printf("pipeline probe OK\n");
    return 0;
}
