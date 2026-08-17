/* clutprobe.c - CLUT stages, sampling and duplication, against the reference
 *
 * A CLUT stage is three pieces of memory that have to be the same
 * memory: the table, the _cmsStageCLutData block cmsStageData hands out,
 * and the cmsInterpParams that block points at.  So the probe writes
 * through the block the way a client does and then evaluates the stage,
 * which only agrees if the evaluator reads what the client wrote.
 *
 * Grids are deliberately granular — a different node count per input —
 * because a uniform grid hides an indexing mistake that a lopsided one
 * exposes immediately.
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
    if (v != v) { feed("NaN", 3); return; }   /* see docs/abi-audit.md */
    feed(&v, sizeof v);
}

static void report(const char* name)
{
    printf("%-36s %016llx\n", name, (unsigned long long) hash_state);
    hash_state = 1469598103934665603ULL;
}

static uint32_t seed = 7717;
static uint32_t next(void) { seed = seed * 1103515245u + 12345u; return seed >> 8; }

/* Drives a pipeline in both precisions, as pipeprobe does. */
static void run(cmsPipeline* lut, const char* label)
{
    if (lut == NULL) { printf("%-36s absent\n", label); return; }

    cmsUInt32Number in = cmsPipelineInputChannels(lut);
    cmsUInt32Number out = cmsPipelineOutputChannels(lut);
    printf("%-36s %u->%u stages %u\n", label, in, out, cmsPipelineStageCount(lut));

    seed = 7717;
    for (int trial = 0; trial < 400; trial++) {
        cmsFloat32Number fin[16], fout[16];
        cmsUInt16Number win[16], wout[16];

        for (cmsUInt32Number i = 0; i < in; i++) {
            int pick = (int) (next() % 8);
            fin[i] = pick == 0 ? 0.0f
                   : pick == 1 ? 1.0f
                   : pick == 2 ? -0.25f       /* below the grid */
                   : pick == 3 ? 1.25f        /* above it */
                   : (cmsFloat32Number) (next() & 0xFFFF) / 65535.0f;
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

/* Samplers.  Each computes its answer from the node position alone, so
 * the table it fills is a function of the grid and nothing else. */

static cmsInt32Number Fill16(CMSREGISTER const cmsUInt16Number In[],
                             CMSREGISTER cmsUInt16Number Out[],
                             CMSREGISTER void* Cargo)
{
    cmsUInt32Number outputs = *(cmsUInt32Number*) Cargo;
    for (cmsUInt32Number i = 0; i < outputs; i++) {
        cmsUInt32Number v = (cmsUInt32Number) In[i % 4] + i * 4096u;
        Out[i] = (cmsUInt16Number) (v & 0xFFFF);
    }
    return 1;
}

static cmsInt32Number FillFloat(CMSREGISTER const cmsFloat32Number In[],
                                CMSREGISTER cmsFloat32Number Out[],
                                CMSREGISTER void* Cargo)
{
    cmsUInt32Number outputs = *(cmsUInt32Number*) Cargo;
    /* Slicing has no table behind it and hands the sampler nowhere to
     * write; only the table walk does. */
    if (Out == NULL) return 1;
    for (cmsUInt32Number i = 0; i < outputs; i++)
        Out[i] = In[i % 4] * 0.75f + (cmsFloat32Number) i * 0.05f;
    return 1;
}

/* Records every node it is shown without writing anything back.
 *
 * Only `inputs` slots are read.  cmsSliceSpace16/Float leave the rest of
 * the input array uninitialized -- unlike cmsStageSampleCLut*, which
 * memsets it -- so reading past the count reads whatever was on the
 * stack.  That is not a difference worth measuring, and measuring it
 * agreed on one platform and disagreed on another. */
typedef struct { cmsUInt32Number visited; int inputs; int outputs; } Walk;

/* The float counterpart of Inspect16, with the same bound. */
static cmsInt32Number InspectFloat(CMSREGISTER const cmsFloat32Number In[],
                                   CMSREGISTER cmsFloat32Number Out[],
                                   CMSREGISTER void* Cargo)
{
    Walk* w = (Walk*) Cargo;
    for (int i = 0; i < w->inputs; i++) feed_float(In[i]);
    if (Out != NULL) for (int i = 0; i < w->outputs; i++) feed_float(Out[i]);
    w->visited++;
    return 1;
}

static cmsInt32Number Inspect16(CMSREGISTER const cmsUInt16Number In[],
                                CMSREGISTER cmsUInt16Number Out[],
                                CMSREGISTER void* Cargo)
{
    Walk* w = (Walk*) Cargo;
    for (int i = 0; i < w->inputs; i++) feed_u16(In[i]);
    if (Out != NULL) for (int i = 0; i < w->outputs; i++) feed_u16(Out[i]);
    w->visited++;
    return 1;
}

/* Refuses partway through, which must abandon the whole walk. */
static cmsUInt32Number refuse_after = 0;
static cmsInt32Number Refusing(CMSREGISTER const cmsUInt16Number In[],
                               CMSREGISTER cmsUInt16Number Out[],
                               CMSREGISTER void* Cargo)
{
    cmsUInt32Number* seen = (cmsUInt32Number*) Cargo;
    (void) In;
    if (Out != NULL) Out[0] = (cmsUInt16Number) (*seen);
    (*seen)++;
    return *seen > refuse_after ? 0 : 1;
}

/* Feeds the whole table as the block publishes it. */
static void feed_table(cmsStage* mpe, const char* label)
{
    _cmsStageCLutData* data = (_cmsStageCLutData*) cmsStageData(mpe);
    if (data == NULL) { printf("%-36s absent\n", label); return; }

    printf("%-36s entries %u float %d\n", label,
           (unsigned) data->nEntries, (int) data->HasFloatValues);

    /* The parameters describe the same grid the table is laid out for. */
    feed(&data->Params->nInputs, sizeof data->Params->nInputs);
    feed(&data->Params->nOutputs, sizeof data->Params->nOutputs);
    for (cmsUInt32Number i = 0; i < data->Params->nInputs; i++) {
        feed(&data->Params->nSamples[i], sizeof data->Params->nSamples[i]);
        feed(&data->Params->Domain[i], sizeof data->Params->Domain[i]);
        feed(&data->Params->opta[i], sizeof data->Params->opta[i]);
    }

    for (cmsUInt32Number i = 0; i < data->nEntries; i++) {
        if (data->HasFloatValues) feed_float(data->Tab.TFloat[i]);
        else feed_u16(data->Tab.T[i]);
    }
    report(label);
}

int main(void)
{
    /* Unbuffered, so that a probe which dies still says where it got to.
     * A buffered probe that crashes prints nothing, and two builds that
     * print nothing look like agreement. */
    setvbuf(stdout, NULL, _IONBF, 0);

    /* -- a uniform 16-bit CLUT, filled by sampling ------------------------ */
    {
        cmsUInt32Number outputs = 3;
        cmsStage* mpe = cmsStageAllocCLut16bit(NULL, 9, 3, 3, NULL);
        printf("allocated %d\n", mpe != NULL);
        printf("sampled %d\n", cmsStageSampleCLut16bit(mpe, Fill16, &outputs, 0));
        feed_table(mpe, "uniform 9^3 -> 3 table");

        cmsPipeline* lut = cmsPipelineAlloc(NULL, 3, 3);
        cmsPipelineInsertStage(lut, cmsAT_BEGIN, mpe);
        run(lut, "uniform 9^3 -> 3");
        cmsPipelineFree(lut);
    }

    /* -- a granular grid, where the per-axis node counts differ ----------- */
    {
        static const cmsUInt32Number points[3] = { 5, 11, 7 };
        cmsUInt32Number outputs = 4;
        cmsStage* mpe = cmsStageAllocCLut16bitGranular(NULL, points, 3, 4, NULL);
        printf("granular allocated %d\n", mpe != NULL);
        printf("sampled %d\n", cmsStageSampleCLut16bit(mpe, Fill16, &outputs, 0));
        feed_table(mpe, "granular 5x11x7 -> 4 table");

        cmsPipeline* lut = cmsPipelineAlloc(NULL, 3, 4);
        cmsPipelineInsertStage(lut, cmsAT_BEGIN, mpe);
        run(lut, "granular 5x11x7 -> 4");

        /* Duplicating must copy the table, not share it: changing the
         * copy afterwards has to leave the original alone. */
        cmsPipeline* copy = cmsPipelineDup(lut);
        run(copy, "granular duplicated");

        cmsUInt32Number counted = 0;
        cmsStageSampleCLut16bit(cmsPipelineGetPtrToFirstStage(copy),
                                Refusing, &counted, 0);
        run(lut, "original after copy scribbled");
        cmsPipelineFree(copy);
        cmsPipelineFree(lut);
    }

    /* -- the float table, which is interpolated without a conversion ------ */
    {
        static const cmsUInt32Number points[4] = { 6, 4, 5, 3 };
        cmsUInt32Number outputs = 3;
        cmsStage* mpe = cmsStageAllocCLutFloatGranular(NULL, points, 4, 3, NULL);
        printf("float allocated %d\n", mpe != NULL);
        printf("sampled %d\n", cmsStageSampleCLutFloat(mpe, FillFloat, &outputs, 0));
        feed_table(mpe, "float 6x4x5x3 -> 3 table");

        cmsPipeline* lut = cmsPipelineAlloc(NULL, 4, 3);
        cmsPipelineInsertStage(lut, cmsAT_BEGIN, mpe);
        run(lut, "float 4-input CLUT");
        cmsPipelineFree(lut);
    }

    /* -- a table supplied up front rather than sampled -------------------- */
    {
        static cmsUInt16Number table[2 * 2 * 2 * 3];
        for (int i = 0; i < 2 * 2 * 2 * 3; i++)
            table[i] = (cmsUInt16Number) (i * 4681);

        cmsStage* mpe = cmsStageAllocCLut16bit(NULL, 2, 3, 3, table);
        feed_table(mpe, "supplied 2^3 table");

        cmsPipeline* lut = cmsPipelineAlloc(NULL, 3, 3);
        cmsPipelineInsertStage(lut, cmsAT_BEGIN, mpe);
        run(lut, "supplied 2^3");
        cmsPipelineFree(lut);
    }

    /* -- inspection leaves the table alone -------------------------------- */
    {
        cmsUInt32Number outputs = 3;
        cmsStage* mpe = cmsStageAllocCLut16bit(NULL, 4, 4, 3, NULL);
        cmsStageSampleCLut16bit(mpe, Fill16, &outputs, 0);

        Walk walk = { 0, 4, 3 };
        printf("inspected %d\n",
               cmsStageSampleCLut16bit(mpe, Inspect16, &walk, SAMPLER_INSPECT));
        report("inspection walk");
        printf("visited %u nodes\n", (unsigned) walk.visited);
        feed_table(mpe, "table after inspection");
        cmsStageFree(mpe);
    }

    /* -- a sampler that gives up abandons the walk ------------------------ */
    {
        cmsStage* mpe = cmsStageAllocCLut16bit(NULL, 5, 2, 3, NULL);
        cmsUInt32Number seen = 0;
        refuse_after = 7;
        printf("refused walk returned %d after %u nodes\n",
               cmsStageSampleCLut16bit(mpe, Refusing, &seen, 0), (unsigned) seen);
        /* What it wrote before giving up is still in the table. */
        feed_table(mpe, "table after refusal");
        cmsStageFree(mpe);
    }

    /* -- slicing: the same walk with no table behind it -------------------- */
    {
        static const cmsUInt32Number points[3] = { 3, 4, 5 };
        Walk walk = { 0, 3, 0 };
        printf("slice16 %d\n", cmsSliceSpace16(3, points, Inspect16, &walk));
        report("slice16 walk");
        printf("slice16 visited %u\n", (unsigned) walk.visited);

        Walk fwalk = { 0, 3, 0 };
        printf("sliceFloat %d\n", cmsSliceSpaceFloat(3, points, InspectFloat, &fwalk));
        report("sliceFloat walk");
        printf("sliceFloat visited %u\n", (unsigned) fwalk.visited);

        /* Refusals: past the channel ceiling, and a degenerate axis. */
        static const cmsUInt32Number degenerate[3] = { 3, 1, 5 };
        Walk guard = { 0, 3, 0 };
        printf("degenerate axis -> %d\n",
               cmsSliceSpace16(3, degenerate, Inspect16, &guard));
        printf("too many inputs -> %d\n",
               cmsSliceSpace16(cmsMAXCHANNELS, points, Inspect16, &guard));
    }

    /* -- refusals from the allocators -------------------------------------- */
    {
        printf("17 inputs -> %s\n",
               cmsStageAllocCLut16bit(NULL, 2, 17, 3, NULL) ? "made" : "refused");
        static const cmsUInt32Number one[3] = { 1, 1, 1 };
        printf("single-node grid -> %s\n",
               cmsStageAllocCLut16bitGranular(NULL, one, 3, 3, NULL) ? "made" : "refused");
        printf("zero outputs -> %s\n",
               cmsStageAllocCLut16bit(NULL, 4, 3, 0, NULL) ? "made" : "refused");
    }

    /* -- concatenation copies, it does not move ---------------------------- */
    {
        cmsUInt32Number outputs = 3;
        cmsPipeline* a = cmsPipelineAlloc(NULL, 3, 3);
        cmsStage* clut = cmsStageAllocCLut16bit(NULL, 7, 3, 3, NULL);
        cmsStageSampleCLut16bit(clut, Fill16, &outputs, 0);
        cmsPipelineInsertStage(a, cmsAT_BEGIN, clut);

        cmsPipeline* b = cmsPipelineAlloc(NULL, 3, 3);
        cmsPipelineInsertStage(b, cmsAT_BEGIN, cmsStageAllocIdentity(NULL, 3));

        printf("cat -> %d\n", cmsPipelineCat(b, a));
        printf("a still has %u stages, b has %u\n",
               cmsPipelineStageCount(a), cmsPipelineStageCount(b));
        run(b, "identity then CLUT");
        run(a, "source after being appended");

        cmsPipelineFree(a);
        cmsPipelineFree(b);
    }

    /* -- a mismatched chain is reported, not undone ------------------------ */
    {
        cmsPipeline* lut = cmsPipelineAlloc(NULL, 3, 3);
        cmsPipelineInsertStage(lut, cmsAT_BEGIN, cmsStageAllocIdentity(NULL, 3));
        /* Four outputs feeding a three-input stage: the insert reports
         * the mismatch, and the stage is in the pipeline regardless. */
        printf("mismatched insert -> %d, stages now %u\n",
               cmsPipelineInsertStage(lut, cmsAT_BEGIN, cmsStageAllocIdentity(NULL, 4)),
               cmsPipelineStageCount(lut));
        printf("channels now %u->%u\n",
               cmsPipelineInputChannels(lut), cmsPipelineOutputChannels(lut));
        cmsPipelineFree(lut);
    }

    /* -- the reverse evaluator -------------------------------------------- */
    {
        /* A 3->3 pipeline whose inverse the solver has to find. */
        static const cmsFloat64Number matrix[9] = {
            0.9, 0.05, 0.05,
            0.1, 0.8,  0.1,
            0.05, 0.15, 0.8
        };
        cmsPipeline* lut = cmsPipelineAlloc(NULL, 3, 3);
        cmsPipelineInsertStage(lut, cmsAT_BEGIN, cmsStageAllocMatrix(NULL, 3, 3, matrix, NULL));

        seed = 31337;
        for (int trial = 0; trial < 60; trial++) {
            cmsFloat32Number target[4], result[4] = { 0, 0, 0, 0 };
            for (int i = 0; i < 3; i++)
                target[i] = (cmsFloat32Number) (next() & 0xFFFF) / 65535.0f;
            target[3] = 0;

            printf("reverse %d ", cmsPipelineEvalReverseFloat(target, result, NULL, lut));
            for (int i = 0; i < 3; i++) feed_float(result[i]);
        }
        printf("\n");
        report("reverse 3->3 no hint");

        /* With a hint, which changes where the search starts. */
        seed = 31337;
        for (int trial = 0; trial < 60; trial++) {
            cmsFloat32Number target[4], hint[3], result[4] = { 0, 0, 0, 0 };
            for (int i = 0; i < 3; i++)
                target[i] = (cmsFloat32Number) (next() & 0xFFFF) / 65535.0f;
            for (int i = 0; i < 3; i++)
                hint[i] = (cmsFloat32Number) (next() & 0xFFFF) / 65535.0f;
            target[3] = 0;

            cmsPipelineEvalReverseFloat(target, result, hint, lut);
            for (int i = 0; i < 3; i++) feed_float(result[i]);
        }
        report("reverse 3->3 with hint");

        cmsPipelineFree(lut);

        /* Shapes it refuses. */
        cmsPipeline* wrong = cmsPipelineAlloc(NULL, 2, 2);
        cmsPipelineInsertStage(wrong, cmsAT_BEGIN, cmsStageAllocIdentity(NULL, 2));
        cmsFloat32Number t[4] = { 0.5f, 0.5f, 0.5f, 0.5f }, r[4] = { 0, 0, 0, 0 };
        printf("2->2 reverse -> %d\n", cmsPipelineEvalReverseFloat(t, r, NULL, wrong));
        cmsPipelineFree(wrong);
    }

    printf("CLUT probe OK\n");
    return 0;
}
