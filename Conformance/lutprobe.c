/* lutprobe - a profile read as a pipeline
 *
 * The three LUT readers pick a tag per intent and direction, copy the
 * pipeline out of it, and add whatever conversion the tag's type calls
 * for at the ends.  Which tag they pick and which stages they add is
 * only visible through what the resulting pipeline computes, so each is
 * evaluated over a fixed grid in both precisions and hashed, for every
 * intent and every profile in the corpus.  The capability queries are
 * printed alongside, since the readers' choices follow from them.
 *
 * Usage: lutprobe <corpus-dir> [<testbed-dir>]
 */

#include "lcms2.h"
#include "lcms2_plugin.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Exported by the reference but declared in no shipped header. */
CMSAPI cmsPipeline* CMSEXPORT _cmsReadInputLUT(cmsHPROFILE hProfile, cmsUInt32Number Intent);
CMSAPI cmsPipeline* CMSEXPORT _cmsReadOutputLUT(cmsHPROFILE hProfile, cmsUInt32Number Intent);
CMSAPI cmsPipeline* CMSEXPORT _cmsReadDevicelinkLUT(cmsHPROFILE hProfile, cmsUInt32Number Intent);

static uint64_t hash_state = 1469598103934665603ULL;

static void feed(const void* bytes, size_t length)
{
    const unsigned char* p = (const unsigned char*) bytes;
    for (size_t i = 0; i < length; i++) {
        hash_state ^= p[i];
        hash_state *= 1099511628211ULL;
    }
}

static void feed_float(float v)
{
    if (v != v) { feed("NaN", 3); return; }
    feed(&v, sizeof v);
}

static void report(const char* name)
{
    printf("  %-40s %016llx\n", name, (unsigned long long) hash_state);
    hash_state = 1469598103934665603ULL;
}

static void describe_stages(cmsPipeline* lut)
{
    printf("   ");
    for (cmsStage* s = cmsPipelineGetPtrToFirstStage(lut); s != NULL; s = cmsStageNext(s)) {
        cmsStageSignature t = cmsStageType(s);
        printf(" %c%c%c%c(%u>%u)", (t >> 24) & 0xFF, (t >> 16) & 0xFF, (t >> 8) & 0xFF, t & 0xFF,
               cmsStageInputChannels(s), cmsStageOutputChannels(s));
    }
    printf("\n");
}

/* Every corner of the input cube plus a few interior points, in both
 * precisions.  Enough to tell one tag from another and one end
 * conversion from none. */
static void evaluate(cmsPipeline* lut, const char* what)
{
    cmsUInt32Number in = cmsPipelineInputChannels(lut);
    cmsUInt32Number out = cmsPipelineOutputChannels(lut);
    if (in == 0 || in > 4) { printf("  %-40s %u>%u not evaluated\n", what, in, out); return; }

    describe_stages(lut);
    printf("  %-40s %u>%u\n", what, in, out);

    int steps = (in <= 3) ? 5 : 3;
    int total = 1;
    for (cmsUInt32Number c = 0; c < in; c++) total *= steps;

    for (int k = 0; k < total; k++) {
        cmsFloat32Number fin[cmsMAXCHANNELS] = { 0 }, fout[cmsMAXCHANNELS] = { 0 };
        cmsUInt16Number win[cmsMAXCHANNELS] = { 0 }, wout[cmsMAXCHANNELS] = { 0 };
        int r = k;
        for (cmsUInt32Number c = 0; c < in; c++) {
            int q = r % steps; r /= steps;
            fin[c] = (cmsFloat32Number) q / (cmsFloat32Number) (steps - 1);
            win[c] = (cmsUInt16Number) (q * 65535 / (steps - 1));
        }
        cmsPipelineEvalFloat(fin, fout, lut);
        for (cmsUInt32Number c = 0; c < out; c++) feed_float(fout[c]);
        cmsPipelineEval16(win, wout, lut);
        feed(wout, out * sizeof(cmsUInt16Number));
    }
    report("  evaluated");
}

static const char* intent_names[] = { "perceptual", "relative", "saturation", "absolute" };

static void probe(const char* path)
{
    cmsHPROFILE h = cmsOpenProfileFromFile(path, "r");
    const char* base = strrchr(path, '/');
    base = base ? base + 1 : path;
    if (h == NULL) { printf("%s: cannot open\n", base); return; }

    printf("%s\n", base);
    printf("  matrix-shaper %d\n", cmsIsMatrixShaper(h));
    for (int i = 0; i < 4; i++) {
        printf("  %-11s clut in %d out %d proof %d  supported in %d out %d proof %d\n",
               intent_names[i],
               cmsIsCLUT(h, i, LCMS_USED_AS_INPUT), cmsIsCLUT(h, i, LCMS_USED_AS_OUTPUT),
               cmsIsCLUT(h, i, LCMS_USED_AS_PROOF),
               cmsIsIntentSupported(h, i, LCMS_USED_AS_INPUT),
               cmsIsIntentSupported(h, i, LCMS_USED_AS_OUTPUT),
               cmsIsIntentSupported(h, i, LCMS_USED_AS_PROOF));
    }
    /* Extended intents are never CLUT-based, and a bad direction is refused. */
    printf("  extended clut %d bad-direction %d\n",
           cmsIsCLUT(h, INTENT_PRESERVE_K_ONLY_PERCEPTUAL, LCMS_USED_AS_INPUT),
           cmsIsCLUT(h, 0, 99));

    char text[256];
    wchar_t wide[64];
    cmsUInt32Number n = cmsGetProfileInfoASCII(h, cmsInfoDescription, "en", "US", text, sizeof text);
    printf("  description %u '%s'\n", n, n ? text : "");
    n = cmsGetProfileInfoUTF8(h, cmsInfoCopyright, "en", "US", text, sizeof text);
    printf("  copyright %u '%s'\n", n, n ? text : "");
    n = cmsGetProfileInfo(h, cmsInfoManufacturer, "en", "US", wide, sizeof wide);
    printf("  manufacturer %u\n", n);
    n = cmsGetProfileInfo(h, cmsInfoModel, "en", "US", NULL, 0);
    printf("  model %u\n", n);
    printf("  bad info %u\n", cmsGetProfileInfoASCII(h, (cmsInfoType) 99, "en", "US", text, sizeof text));

    for (int i = 0; i < 4; i++) {
        char what[64];
        cmsPipeline* lut;

        snprintf(what, sizeof what, "input %s", intent_names[i]);
        lut = _cmsReadInputLUT(h, i);
        if (lut) { evaluate(lut, what); cmsPipelineFree(lut); }
        else printf("  %-40s (none)\n", what);

        snprintf(what, sizeof what, "output %s", intent_names[i]);
        lut = _cmsReadOutputLUT(h, i);
        if (lut) { evaluate(lut, what); cmsPipelineFree(lut); }
        else printf("  %-40s (none)\n", what);

        snprintf(what, sizeof what, "devicelink %s", intent_names[i]);
        lut = _cmsReadDevicelinkLUT(h, i);
        if (lut) { evaluate(lut, what); cmsPipelineFree(lut); }
        else printf("  %-40s (none)\n", what);
    }

    /* The matrix-shaper regardless of LUTs, and the refusal past the
     * ICC intents. */
    cmsPipeline* lut = _cmsReadInputLUT(h, 0xFFFFFFFF);
    if (lut) { evaluate(lut, "input matrix-shaper forced"); cmsPipelineFree(lut); }
    else printf("  %-40s (none)\n", "input matrix-shaper forced");
    printf("  devicelink extended %s\n", _cmsReadDevicelinkLUT(h, 10) ? "given" : "(none)");

    cmsCloseProfile(h);
}

int main(int argc, char** argv)
{
    static const char* corpus[] = {
        "srgb", "lab4", "lab2", "xyz", "null", "gray22", "rgb709",
        "linear-devicelink", "inklimit-devicelink", NULL
    };
    static const char* testbed[] = {
        "test1", "test2", "test3", "test4", "test5", "ibm-t61", "crayons", "new", NULL
    };
    char path[1024];

    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 2) { fprintf(stderr, "usage: lutprobe <corpus-dir> [<testbed-dir>]\n"); return 2; }

    for (int i = 0; corpus[i]; i++) {
        snprintf(path, sizeof path, "%s/%s.icc", argv[1], corpus[i]);
        probe(path);
    }
    if (argc > 2) {
        for (int i = 0; testbed[i]; i++) {
            snprintf(path, sizeof path, "%s/%s.icc", argv[2], testbed[i]);
            probe(path);
        }
    }
    return 0;
}
