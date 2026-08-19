/* Plugin registry differential (cmsplugin.c and every _cmsRegister*Plugin).
 *
 * One plugin of each kind — modelled on the reference testbed's samples,
 * with the ones there that only pass/fail turned into ones that print
 * what they saw — registered on a context, inherited by two rounds of
 * cmsDupContext, exercised, and then unregistered so the built-ins are
 * seen to come back.  The listing order of cmsGetSupportedIntents, the
 * legacy one-scanline transform adaptor, and the three plain integer
 * array tag types are covered too, since none of them is reached from
 * anywhere else.
 */

#include <lcms2.h>
#include <lcms2_plugin.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static void logger(cmsContext c, cmsUInt32Number code, const char* text)
{
    (void) c;
    printf("  error %u: %s\n", code, text);
}

/* --- interpolation ------------------------------------------------------ */

static void Fake1Dfloat(const cmsFloat32Number Value[], cmsFloat32Number Output[], const cmsInterpParams* p)
{
    const cmsFloat32Number* LutTable = (const cmsFloat32Number*) p->Table;
    cmsFloat32Number val2;
    int cell;
    if (Value[0] >= 1.0) { Output[0] = LutTable[p->Domain[0]]; return; }
    val2 = p->Domain[0] * Value[0];
    cell = (int) floor(val2);
    Output[0] = LutTable[cell];
}

static void Fake3D16(CMSREGISTER const cmsUInt16Number Input[], CMSREGISTER cmsUInt16Number Output[], CMSREGISTER const struct _cms_interp_struc* p)
{
    (void) p;
    Output[0] = 0xFFFF - Input[2];
    Output[1] = 0xFFFF - Input[1];
    Output[2] = 0xFFFF - Input[0];
}

static cmsInterpFunction my_Interpolators_Factory(cmsUInt32Number nInputChannels, cmsUInt32Number nOutputChannels, cmsUInt32Number dwFlags)
{
    cmsInterpFunction Interpolation;
    cmsBool IsFloat = (dwFlags & CMS_LERP_FLAGS_FLOAT);
    memset(&Interpolation, 0, sizeof(Interpolation));
    if (nInputChannels == 1 && nOutputChannels == 1 && IsFloat) Interpolation.LerpFloat = Fake1Dfloat;
    else if (nInputChannels == 3 && nOutputChannels == 3 && !IsFloat) Interpolation.Lerp16 = Fake3D16;
    return Interpolation;
}

static cmsPluginInterpolation InterpPluginSample = {
    { cmsPluginMagicNumber, 2060, cmsPluginInterpolationSig, NULL }, my_Interpolators_Factory
};

static void interp_checks(cmsContext ctx, const char* label)
{
    const cmsFloat32Number tab[] = { 0.0f, 0.10f, 0.20f, 0.30f, 0.40f, 0.50f, 0.60f, 0.70f, 0.80f, 0.90f, 1.00f };
    cmsUInt16Number identity[] = { 0,0,0, 0,0,0xffff, 0,0xffff,0, 0,0xffff,0xffff, 0xffff,0,0, 0xffff,0,0xffff, 0xffff,0xffff,0, 0xffff,0xffff,0xffff };
    cmsToneCurve* c = cmsBuildTabulatedToneCurveFloat(ctx, 11, tab);
    cmsPipeline* p;
    cmsStage* clut;
    cmsUInt16Number In[3] = { 10, 20, 30 }, Out[3];
    printf("%s 1D: %.4f %.4f %.4f %.4f\n", label,
        cmsEvalToneCurveFloat(c, 0.10f), cmsEvalToneCurveFloat(c, 0.13f), cmsEvalToneCurveFloat(c, 0.55f), cmsEvalToneCurveFloat(c, 0.9999f));
    cmsFreeToneCurve(c);

    p = cmsPipelineAlloc(ctx, 3, 3);
    clut = cmsStageAllocCLut16bit(ctx, 2, 3, 3, identity);
    cmsPipelineInsertStage(p, cmsAT_BEGIN, clut);
    cmsPipelineEval16(In, Out, p);
    printf("%s 3D: %04x %04x %04x\n", label, Out[0], Out[1], Out[2]);
    cmsPipelineFree(p);
}

/* --- parametric curves -------------------------------------------------- */

#define TYPE_SIN  1000
#define TYPE_COS  1010
#define TYPE_TAN  1020
#define TYPE_709  709

static cmsFloat64Number my_fns(cmsInt32Number Type, const cmsFloat64Number Params[], cmsFloat64Number R)
{
    cmsFloat64Number Val;
    switch (Type) {
    case TYPE_SIN: Val = Params[0] * sin(R * M_PI); break;
    case -TYPE_SIN: Val = asin(R) / (M_PI * Params[0]); break;
    case TYPE_COS: Val = Params[0] * cos(R * M_PI); break;
    case -TYPE_COS: Val = acos(R) / (M_PI * Params[0]); break;
    default: return -1.0;
    }
    return Val;
}

static cmsFloat64Number my_fns2(cmsInt32Number Type, const cmsFloat64Number Params[], cmsFloat64Number R)
{
    switch (Type) {
    case TYPE_TAN: return Params[0] * tan(R * M_PI);
    case -TYPE_TAN: return atan(R) / (M_PI * Params[0]);
    default: return -1.0;
    }
}

static cmsFloat64Number Rec709Math(int Type, const cmsFloat64Number Params[], cmsFloat64Number R)
{
    cmsFloat64Number Fun = 0;
    switch (Type) {
    case 709:
        if (R <= (Params[3] * Params[4])) Fun = R / Params[3];
        else Fun = pow(((R - Params[2]) / Params[1]), Params[0]);
        break;
    case -709:
        if (R <= Params[4]) Fun = R * Params[3];
        else Fun = Params[1] * pow(R, (1 / Params[0])) + Params[2];
        break;
    }
    return Fun;
}

static cmsPluginParametricCurves Rec709Plugin = {
    { cmsPluginMagicNumber, 2060, cmsPluginParametricCurveSig, NULL }, 1, { TYPE_709 }, { 5 }, Rec709Math
};
static cmsPluginParametricCurves CurvePluginSample = {
    { cmsPluginMagicNumber, 2060, cmsPluginParametricCurveSig, NULL }, 2, { TYPE_SIN, TYPE_COS }, { 1, 1 }, my_fns
};
static cmsPluginParametricCurves CurvePluginSample2 = {
    { cmsPluginMagicNumber, 2060, cmsPluginParametricCurveSig, NULL }, 1, { TYPE_TAN }, { 1 }, my_fns2
};

static void curve_checks(cmsContext ctx, const char* label)
{
    cmsFloat64Number scale = 1.0;
    cmsFloat64Number params709[5] = { 1.0 / 0.45, 1.0 / 1.099, 0.099 / 1.099, 1.0 / 4.5, 4.5 * 0.018 };
    cmsToneCurve* s = cmsBuildParametricToneCurve(ctx, TYPE_SIN, &scale);
    cmsToneCurve* c = cmsBuildParametricToneCurve(ctx, TYPE_COS, &scale);
    cmsToneCurve* t = cmsBuildParametricToneCurve(ctx, TYPE_TAN, &scale);
    cmsToneCurve* r = cmsBuildParametricToneCurve(ctx, TYPE_709, params709);
    cmsToneCurve* rs = s ? cmsReverseToneCurve(s) : NULL;
    printf("%s curves: sin=%d cos=%d tan=%d 709=%d\n", label, s != NULL, c != NULL, t != NULL, r != NULL);
    if (s) printf("%s sin %.5f %.5f rev %.5f\n", label, cmsEvalToneCurveFloat(s, 0.1f), cmsEvalToneCurveFloat(s, 0.6f), rs ? cmsEvalToneCurveFloat(rs, 0.6f) : -1);
    if (c) printf("%s cos %.5f %.5f\n", label, cmsEvalToneCurveFloat(c, 0.1f), cmsEvalToneCurveFloat(c, 0.6f));
    if (t) printf("%s tan %.5f %.5f\n", label, cmsEvalToneCurveFloat(t, 0.1f), cmsEvalToneCurveFloat(t, 0.6f));
    if (r) {
        cmsToneCurve* rr = cmsReverseToneCurve(r);
        int i;
        printf("%s 709", label);
        for (i = 0; i <= 10; i++) printf(" %.5f", cmsEvalToneCurveFloat(r, i / 10.0f));
        printf(" | 16bit %u %u | rev %.5f\n", cmsEvalToneCurve16(r, 1000), cmsEvalToneCurve16(r, 60000), rr ? cmsEvalToneCurveFloat(rr, 0.5f) : -1);
        cmsFreeToneCurve(rr);
    }
    if (s) cmsFreeToneCurve(s);
    if (c) cmsFreeToneCurve(c);
    if (t) cmsFreeToneCurve(t);
    if (r) cmsFreeToneCurve(r);
    if (rs) cmsFreeToneCurve(rs);
}

/* --- formatters --------------------------------------------------------- */

#define TYPE_RGB_565  (COLORSPACE_SH(PT_RGB)|CHANNELS_SH(3)|BYTES_SH(0) | (1 << 23))

static cmsUInt8Number* my_Unroll565(CMSREGISTER struct _cmstransform_struct* nfo, CMSREGISTER cmsUInt16Number wIn[], CMSREGISTER cmsUInt8Number* accum, CMSREGISTER cmsUInt32Number Stride)
{
    cmsUInt16Number pixel = *(cmsUInt16Number*) accum;
    int r = (int) floor(((pixel & 31) * 65535.0) / 31.0 + 0.5);
    int g = (int) floor((((pixel >> 5) & 63) * 65535.0) / 63.0 + 0.5);
    int b = (int) floor((((pixel >> 11) & 31) * 65535.0) / 31.0 + 0.5);
    (void) nfo; (void) Stride;
    wIn[2] = (cmsUInt16Number) r; wIn[1] = (cmsUInt16Number) g; wIn[0] = (cmsUInt16Number) b;
    return accum + 2;
}

static cmsUInt8Number* my_Pack565(CMSREGISTER struct _cmstransform_struct* nfo, CMSREGISTER cmsUInt16Number wOut[], CMSREGISTER cmsUInt8Number* output, CMSREGISTER cmsUInt32Number Stride)
{
    cmsUInt16Number pixel;
    int r = (int) floor((wOut[2] * 31) / 65535.0 + 0.5);
    int g = (int) floor((wOut[1] * 63) / 65535.0 + 0.5);
    int b = (int) floor((wOut[0] * 31) / 65535.0 + 0.5);
    (void) nfo; (void) Stride;
    pixel = (cmsUInt16Number) ((r & 31) | ((g & 63) << 5) | ((b & 31) << 11));
    *(cmsUInt16Number*) output = pixel;
    return output + 2;
}

static cmsFormatter my_FormatterFactory(cmsUInt32Number Type, cmsFormatterDirection Dir, cmsUInt32Number dwFlags)
{
    cmsFormatter Result = { NULL };
    if ((Type == TYPE_RGB_565) && !(dwFlags & CMS_PACK_FLAGS_FLOAT) && (Dir == cmsFormatterInput)) Result.Fmt16 = my_Unroll565;
    return Result;
}

static cmsFormatter my_FormatterFactory2(cmsUInt32Number Type, cmsFormatterDirection Dir, cmsUInt32Number dwFlags)
{
    cmsFormatter Result = { NULL };
    if ((Type == TYPE_RGB_565) && !(dwFlags & CMS_PACK_FLAGS_FLOAT) && (Dir == cmsFormatterOutput)) Result.Fmt16 = my_Pack565;
    return Result;
}

static cmsPluginFormatters FormattersPluginSample = { { cmsPluginMagicNumber, 2060, cmsPluginFormattersSig, NULL }, my_FormatterFactory };
static cmsPluginFormatters FormattersPluginSample2 = { { cmsPluginMagicNumber, 2060, cmsPluginFormattersSig, NULL }, my_FormatterFactory2 };

static void formatter_checks(cmsContext ctx, const char* label)
{
    cmsUInt16Number stream[] = { 0xffffU, 0x1234U, 0x0000U, 0x33ddU };
    cmsUInt16Number result[4];
    cmsHTRANSFORM xform = cmsCreateTransformTHR(ctx, NULL, TYPE_RGB_565, NULL, TYPE_RGB_565, 0, cmsFLAGS_NULLTRANSFORM);
    if (xform == NULL) { printf("%s 565: no transform\n", label); return; }
    cmsDoTransform(xform, stream, result, 4);
    printf("%s 565: %04x %04x %04x %04x\n", label, result[0], result[1], result[2], result[3]);
    cmsDeleteTransform(xform);
}

/* --- tag types and tags -------------------------------------------------- */

#define SigIntType ((cmsTagTypeSignature) 0x74747448)
#define SigInt     ((cmsTagSignature) 0x74747448)
#define SigInt32   ((cmsTagSignature) 0x74747449)
#define SigInt8    ((cmsTagSignature) 0x7474744A)
#define SigInt64   ((cmsTagSignature) 0x7474744B)

static void* Type_int_Read(struct _cms_typehandler_struct* self, cmsIOHANDLER* io, cmsUInt32Number* nItems, cmsUInt32Number SizeOfTag)
{
    cmsUInt32Number* Ptr = (cmsUInt32Number*) _cmsMalloc(self->ContextID, sizeof(cmsUInt32Number));
    (void) SizeOfTag;
    if (Ptr == NULL) return NULL;
    if (!_cmsReadUInt32Number(io, Ptr)) return NULL;
    /* The version comes through self, so it is visible from here. */
    *Ptr += self->ICCVersion >> 24;
    *nItems = 1;
    return Ptr;
}
static cmsBool Type_int_Write(struct _cms_typehandler_struct* self, cmsIOHANDLER* io, void* Ptr, cmsUInt32Number nItems)
{
    (void) self; (void) nItems;
    return _cmsWriteUInt32Number(io, *(cmsUInt32Number*) Ptr);
}
static void* Type_int_Dup(struct _cms_typehandler_struct* self, const void* Ptr, cmsUInt32Number n)
{
    return _cmsDupMem(self->ContextID, Ptr, n * sizeof(cmsUInt32Number));
}
static void Type_int_Free(struct _cms_typehandler_struct* self, void* Ptr)
{
    _cmsFree(self->ContextID, Ptr);
}

static cmsPluginTag HiddenTagPluginSample = { { cmsPluginMagicNumber, 2060, cmsPluginTagSig, NULL }, SigInt, { 1, 1, { SigIntType }, NULL } };
static cmsPluginTag HiddenTagPluginSample2 = { { cmsPluginMagicNumber, 2060, cmsPluginTagSig, (cmsPluginBase*) &HiddenTagPluginSample }, SigInt32, { 1, 1, { cmsSigUInt32ArrayType }, NULL } };
static cmsPluginTag HiddenTagPluginSample3 = { { cmsPluginMagicNumber, 2060, cmsPluginTagSig, (cmsPluginBase*) &HiddenTagPluginSample2 }, SigInt8, { 3, 1, { cmsSigUInt8ArrayType }, NULL } };
static cmsPluginTag HiddenTagPluginSample4 = { { cmsPluginMagicNumber, 2060, cmsPluginTagSig, (cmsPluginBase*) &HiddenTagPluginSample3 }, SigInt64, { 2, 1, { cmsSigUInt64ArrayType }, NULL } };
static cmsPluginTagType TagTypePluginSample = {
    { cmsPluginMagicNumber, 2060, cmsPluginTagTypeSig, (cmsPluginBase*) &HiddenTagPluginSample4 },
    { SigIntType, Type_int_Read, Type_int_Write, Type_int_Dup, Type_int_Free, NULL, 0 }
};

static void tag_checks(cmsContext ctx, const char* label)
{
    cmsUInt32Number myTag = 1234, myTag32 = 5678, clen = 0;
    cmsUInt8Number bytes[3] = { 7, 8, 9 };
    cmsUInt64Number words[2] = { 0x1122334455667788ULL, 0x99AABBCCDDEEFF00ULL };
    cmsHPROFILE h = cmsCreateProfilePlaceholder(ctx);
    char* data;
    cmsUInt32Number* p32;
    cmsUInt8Number* p8;
    cmsUInt64Number* p64;
    printf("%s write: %d %d %d %d\n", label, cmsWriteTag(h, SigInt, &myTag), cmsWriteTag(h, SigInt32, &myTag32), cmsWriteTag(h, SigInt8, bytes), cmsWriteTag(h, SigInt64, words));
    cmsSaveProfileToMem(h, NULL, &clen);
    data = (char*) malloc(clen);
    cmsSaveProfileToMem(h, data, &clen);
    cmsCloseProfile(h);
    printf("%s saved %u bytes\n", label, clen);

    /* Global context does not know the tags. */
    h = cmsOpenProfileFromMem(data, clen);
    printf("%s global read: %p %p\n", label, cmsReadTag(h, SigInt), cmsReadTag(h, SigInt32));
    cmsCloseProfile(h);

    h = cmsOpenProfileFromMemTHR(ctx, data, clen);
    p32 = (cmsUInt32Number*) cmsReadTag(h, SigInt);
    printf("%s int: %u\n", label, p32 ? *p32 : 0);
    p32 = (cmsUInt32Number*) cmsReadTag(h, SigInt32);
    printf("%s int32: %u\n", label, p32 ? *p32 : 0);
    p8 = (cmsUInt8Number*) cmsReadTag(h, SigInt8);
    printf("%s int8: %u %u %u\n", label, p8 ? p8[0] : 0, p8 ? p8[1] : 0, p8 ? p8[2] : 0);
    p64 = (cmsUInt64Number*) cmsReadTag(h, SigInt64);
    printf("%s int64: %llx %llx\n", label, p64 ? (unsigned long long) p64[0] : 0, p64 ? (unsigned long long) p64[1] : 0);
    printf("%s raw sizes: %u %u %u %u\n", label, cmsReadRawTag(h, SigInt, NULL, 0), cmsReadRawTag(h, SigInt32, NULL, 0), cmsReadRawTag(h, SigInt8, NULL, 0), cmsReadRawTag(h, SigInt64, NULL, 0));
    cmsCloseProfile(h);
    free(data);
}

/* --- MPE ---------------------------------------------------------------- */

#define SigNegateType ((cmsStageSignature) 0x6E202020)

static void EvaluateNegate(const cmsFloat32Number In[], cmsFloat32Number Out[], const cmsStage* mpe)
{
    (void) mpe;
    Out[0] = 1.0f - In[0]; Out[1] = 1.0f - In[1]; Out[2] = 1.0f - In[2];
}
static cmsStage* StageAllocNegate(cmsContext ContextID)
{
    return _cmsStageAllocPlaceholder(ContextID, SigNegateType, 3, 3, EvaluateNegate, NULL, NULL, NULL);
}
static void* Type_negate_Read(struct _cms_typehandler_struct* self, cmsIOHANDLER* io, cmsUInt32Number* nItems, cmsUInt32Number SizeOfTag)
{
    cmsUInt16Number Chans;
    (void) SizeOfTag;
    if (!_cmsReadUInt16Number(io, &Chans)) return NULL;
    if (Chans != 3) return NULL;
    *nItems = 1;
    return StageAllocNegate(self->ContextID);
}
static cmsBool Type_negate_Write(struct _cms_typehandler_struct* self, cmsIOHANDLER* io, void* Ptr, cmsUInt32Number nItems)
{
    (void) self; (void) Ptr; (void) nItems;
    return _cmsWriteUInt16Number(io, 3);
}
static cmsPluginMultiProcessElement MPEPluginSample = {
    { cmsPluginMagicNumber, 2060, cmsPluginMultiProcessElementSig, NULL },
    { (cmsTagTypeSignature) SigNegateType, Type_negate_Read, Type_negate_Write, NULL, NULL, NULL, 0 }
};

static void mpe_checks(cmsContext ctx, const char* label)
{
    cmsHPROFILE h = cmsCreateProfilePlaceholder(ctx);
    cmsPipeline* pipe = cmsPipelineAlloc(ctx, 3, 3);
    cmsFloat32Number In[3] = { 0.3f, 0.2f, 0.9f }, Out[3];
    cmsUInt32Number clen = 0;
    char* data;
    cmsPipelineInsertStage(pipe, cmsAT_BEGIN, StageAllocNegate(ctx));
    cmsPipelineEvalFloat(In, Out, pipe);
    printf("%s negate: %.3f %.3f %.3f\n", label, Out[0], Out[1], Out[2]);
    printf("%s write DToB0: %d\n", label, cmsWriteTag(h, cmsSigDToB0Tag, pipe));
    cmsPipelineFree(pipe);
    cmsSaveProfileToMem(h, NULL, &clen);
    data = (char*) malloc(clen);
    cmsSaveProfileToMem(h, data, &clen);
    cmsCloseProfile(h);
    printf("%s saved %u bytes\n", label, clen);
    /* Without the plugin the save above produced nothing, and the
     * reference does not survive cmsReadTag on a NULL profile. */
    if (clen == 0) { free(data); return; }
    h = cmsOpenProfileFromMemTHR(ctx, data, clen);
    pipe = (cmsPipeline*) cmsReadTag(h, cmsSigDToB0Tag);
    if (pipe) {
        cmsPipelineEvalFloat(In, Out, pipe);
        printf("%s reread negate: %.3f %.3f %.3f (stages %u)\n", label, Out[0], Out[1], Out[2], cmsPipelineStageCount(pipe));
    } else printf("%s reread: NULL\n", label);
    cmsCloseProfile(h);
    /* And without the plugin: the global context cannot read it. */
    h = cmsOpenProfileFromMem(data, clen);
    printf("%s global reread: %p\n", label, cmsReadTag(h, cmsSigDToB0Tag));
    cmsCloseProfile(h);
    free(data);
}

/* --- optimization -------------------------------------------------------- */

static int optimize_calls = 0;

static void FastEvaluateCurves(CMSREGISTER const cmsUInt16Number In[], CMSREGISTER cmsUInt16Number Out[], CMSREGISTER const void* Data)
{
    (void) Data;
    Out[0] = In[0];
}
static cmsBool MyOptimize(cmsPipeline** Lut, cmsUInt32Number Intent, cmsUInt32Number* InputFormat, cmsUInt32Number* OutputFormat, cmsUInt32Number* dwFlags)
{
    cmsStage* mpe;
    _cmsStageToneCurvesData* Data;
    (void) Intent; (void) InputFormat; (void) OutputFormat;
    optimize_calls++;
    for (mpe = cmsPipelineGetPtrToFirstStage(*Lut); mpe != NULL; mpe = cmsStageNext(mpe)) {
        if (cmsStageType(mpe) != cmsSigCurveSetElemType) return FALSE;
        Data = (_cmsStageToneCurvesData*) cmsStageData(mpe);
        if (Data->nCurves != 1) return FALSE;
        if (cmsEstimateGamma(Data->TheCurves[0], 0.1) > 1.0) return FALSE;
    }
    *dwFlags |= cmsFLAGS_NOCACHE;
    _cmsPipelineSetOptimizationParameters(*Lut, FastEvaluateCurves, NULL, NULL, NULL);
    return TRUE;
}
static cmsPluginOptimization OptimizationPluginSample = { { cmsPluginMagicNumber, 2060, cmsPluginOptimizationSig, NULL }, MyOptimize };

static void optimization_checks(cmsContext ctx, const char* label)
{
    cmsUInt8Number In[] = { 10, 20, 30, 40 }, Out[4];
    cmsToneCurve* Linear[1];
    cmsHPROFILE h;
    cmsHTRANSFORM xform;
    optimize_calls = 0;
    Linear[0] = cmsBuildGamma(ctx, 1.0);
    h = cmsCreateLinearizationDeviceLinkTHR(ctx, cmsSigGrayData, Linear);
    cmsFreeToneCurve(Linear[0]);
    xform = cmsCreateTransformTHR(ctx, h, TYPE_GRAY_8, h, TYPE_GRAY_8, INTENT_PERCEPTUAL, 0);
    cmsCloseProfile(h);
    cmsDoTransform(xform, In, Out, 4);
    printf("%s optimize: calls=%d flags=%08x out=%u %u %u %u\n", label, optimize_calls, _cmsGetTransformFlags(xform), Out[0], Out[1], Out[2], Out[3]);
    cmsDeleteTransform(xform);
}

/* --- rendering intent --------------------------------------------------- */

#define INTENT_DECEPTIVE 300

static cmsPipeline* MyNewIntent(cmsContext ContextID, cmsUInt32Number nProfiles, cmsUInt32Number TheIntents[], cmsHPROFILE hProfiles[], cmsBool BPC[], cmsFloat64Number AdaptationStates[], cmsUInt32Number dwFlags)
{
    cmsPipeline* Result;
    cmsUInt32Number ICCIntents[256];
    cmsUInt32Number i;
    for (i = 0; i < nProfiles; i++) ICCIntents[i] = (TheIntents[i] == INTENT_DECEPTIVE) ? INTENT_PERCEPTUAL : TheIntents[i];
    if (cmsGetColorSpace(hProfiles[0]) != cmsSigGrayData || cmsGetColorSpace(hProfiles[nProfiles - 1]) != cmsSigGrayData)
        return _cmsDefaultICCintents(ContextID, nProfiles, ICCIntents, hProfiles, BPC, AdaptationStates, dwFlags);
    Result = cmsPipelineAlloc(ContextID, 1, 1);
    if (Result == NULL) return NULL;
    cmsPipelineInsertStage(Result, cmsAT_BEGIN, cmsStageAllocIdentity(ContextID, 1));
    return Result;
}
static cmsPluginRenderingIntent IntentPluginSample = {
    { cmsPluginMagicNumber, 2060, cmsPluginRenderingIntentSig, NULL }, INTENT_DECEPTIVE, MyNewIntent, "bypass gray to gray rendering intent"
};

static void intent_checks(cmsContext ctx, const char* label)
{
    cmsUInt32Number codes[32];
    char* descs[32];
    cmsUInt32Number n = cmsGetSupportedIntentsTHR(ctx, 32, codes, descs), i;
    cmsToneCurve* Linear1 = cmsBuildGamma(ctx, 3.0);
    cmsToneCurve* Linear2 = cmsBuildGamma(ctx, 0.1);
    cmsHPROFILE h1 = cmsCreateLinearizationDeviceLinkTHR(ctx, cmsSigGrayData, &Linear1);
    cmsHPROFILE h2 = cmsCreateLinearizationDeviceLinkTHR(ctx, cmsSigGrayData, &Linear2);
    cmsHPROFILE hsRGB = cmsCreate_sRGBProfileTHR(ctx);
    cmsHTRANSFORM xform;
    cmsUInt8Number In[] = { 10, 20, 30, 40 }, Out[4];
    cmsUInt8Number rgb[3];
    printf("%s intents (%u):", label, n);
    for (i = 0; i < n; i++) printf(" %u='%s'", codes[i], descs[i]);
    printf("\n");
    cmsFreeToneCurve(Linear1);
    cmsFreeToneCurve(Linear2);
    xform = cmsCreateTransformTHR(ctx, h1, TYPE_GRAY_8, h2, TYPE_GRAY_8, INTENT_DECEPTIVE, 0);
    if (xform) {
        cmsDoTransform(xform, In, Out, 4);
        printf("%s deceptive gray: %u %u %u %u\n", label, Out[0], Out[1], Out[2], Out[3]);
        cmsDeleteTransform(xform);
    } else printf("%s deceptive gray: refused\n", label);
    /* Not gray to gray: falls through to perceptual. */
    xform = cmsCreateTransformTHR(ctx, hsRGB, TYPE_RGB_8, h2, TYPE_GRAY_8, INTENT_DECEPTIVE, 0);
    if (xform) {
        rgb[0] = 200; rgb[1] = 100; rgb[2] = 50;
        cmsDoTransform(xform, rgb, Out, 1);
        printf("%s deceptive rgb->gray: %u\n", label, Out[0]);
        cmsDeleteTransform(xform);
    } else printf("%s deceptive rgb->gray: refused\n", label);
    cmsCloseProfile(h1);
    cmsCloseProfile(h2);
    cmsCloseProfile(hsRGB);
}

/* --- full transform ---------------------------------------------------- */

static void TrancendentalTransform(struct _cmstransform_struct* CMMcargo, const void* InputBuffer, void* OutputBuffer, cmsUInt32Number PixelsPerLine, cmsUInt32Number LineCount, const cmsStride* Stride)
{
    cmsUInt32Number i, j;
    (void) CMMcargo; (void) InputBuffer;
    for (j = 0; j < LineCount; j++)
        for (i = 0; i < PixelsPerLine; i++)
            ((cmsUInt8Number*) OutputBuffer)[j * Stride->BytesPerLineOut + i] = (cmsUInt8Number) (0x42 + j);
}

static cmsBool MyTransformFactory(_cmsTransform2Fn* xformPtr, void** UserData, _cmsFreeUserDataFn* FreePrivateDataFn, cmsPipeline** Lut, cmsUInt32Number* InputFormat, cmsUInt32Number* OutputFormat, cmsUInt32Number* dwFlags)
{
    (void) UserData; (void) FreePrivateDataFn;
    if (*InputFormat == TYPE_GRAY_8 && *OutputFormat == TYPE_GRAY_8) {
        cmsPipelineFree(*Lut);
        *Lut = NULL;
        *xformPtr = TrancendentalTransform;
        /* A factory that drops the pipeline must also drop the cache: the
         * reference seeds the cache through the pipeline and does not
         * survive its absence.  The testbed's sample does the same. */
        *dwFlags |= cmsFLAGS_NOCACHE;
        return TRUE;
    }
    return FALSE;
}

/* The pre-2.8 style: one scanline at a time, so the adaptor is exercised. */
static void LegacyTransform(struct _cmstransform_struct* CMMcargo, const void* InputBuffer, void* OutputBuffer, cmsUInt32Number Size, cmsUInt32Number Stride)
{
    cmsUInt32Number i;
    (void) CMMcargo; (void) Stride;
    for (i = 0; i < Size; i++)
        ((cmsUInt8Number*) OutputBuffer)[i] = (cmsUInt8Number) (255 - ((const cmsUInt8Number*) InputBuffer)[i]);
}

static int legacy_freed = 0;
static void FreeLegacyData(cmsContext ContextID, void* Data) { (void) ContextID; (void) Data; legacy_freed++; }

static cmsBool MyLegacyFactory(_cmsTransformFn* xformPtr, void** UserData, _cmsFreeUserDataFn* FreePrivateDataFn, cmsPipeline** Lut, cmsUInt32Number* InputFormat, cmsUInt32Number* OutputFormat, cmsUInt32Number* dwFlags)
{
    if (*InputFormat == TYPE_GRAY_8 && *OutputFormat == TYPE_GRAY_8) {
        cmsPipelineFree(*Lut);
        *Lut = NULL;
        *xformPtr = LegacyTransform;
        *dwFlags |= cmsFLAGS_NOCACHE;
        *UserData = &legacy_freed;
        *FreePrivateDataFn = FreeLegacyData;
        return TRUE;
    }
    return FALSE;
}

static cmsPluginTransform FullTransformPluginSample = { { cmsPluginMagicNumber, 2080, cmsPluginTransformSig, NULL }, { NULL } };
/* Declared against 2.6, so the reference treats its factory as the
 * one-scanline kind and installs its adaptor. */
static cmsPluginTransform LegacyTransformPluginSample = { { cmsPluginMagicNumber, 2060, cmsPluginTransformSig, NULL }, { NULL } };

static void transform_checks(cmsContext ctx, const char* label)
{
    cmsUInt8Number In[] = { 10, 20, 30, 40, 50, 60, 70, 80 }, Out[8];
    cmsHPROFILE h = cmsCreateGrayProfileTHR(ctx, cmsD50_xyY(), cmsBuildGamma(ctx, 2.2));
    cmsHTRANSFORM xform = cmsCreateTransformTHR(ctx, h, TYPE_GRAY_8, h, TYPE_GRAY_8, INTENT_PERCEPTUAL, 0);
    memset(Out, 0, sizeof(Out));
    if (xform) {
        cmsDoTransformLineStride(xform, In, Out, 4, 2, 4, 4, 4, 4);
        printf("%s full: %02x %02x %02x %02x %02x %02x %02x %02x flags=%08x lut=%d\n", label, Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6], Out[7], _cmsGetTransformFlags(xform), _cmsGetTransformUserData(xform) != NULL);
        cmsDeleteTransform(xform);
    }
    /* Not the plugin's shape: the ordinary path. */
    xform = cmsCreateTransformTHR(ctx, h, TYPE_GRAY_16, h, TYPE_GRAY_8, INTENT_PERCEPTUAL, 0);
    if (xform) {
        cmsUInt16Number w[4] = { 1000, 20000, 40000, 65535 };
        cmsDoTransform(xform, w, Out, 4);
        printf("%s ordinary: %u %u %u %u\n", label, Out[0], Out[1], Out[2], Out[3]);
        cmsDeleteTransform(xform);
    }
    /* Optimization off: the plugin is not asked. */
    xform = cmsCreateTransformTHR(ctx, h, TYPE_GRAY_8, h, TYPE_GRAY_8, INTENT_PERCEPTUAL, cmsFLAGS_NOOPTIMIZE);
    if (xform) {
        cmsDoTransform(xform, In, Out, 4);
        printf("%s noopt: %u %u %u %u\n", label, Out[0], Out[1], Out[2], Out[3]);
        cmsDeleteTransform(xform);
    }
    cmsCloseProfile(h);
}

/* --- mutex --------------------------------------------------------------- */

static int mutex_created = 0, mutex_destroyed = 0, mutex_locked = 0, mutex_unlocked = 0;
static void* MyMtxCreate(cmsContext id) { mutex_created++; return _cmsMalloc(id, 8); }
static void MyMtxDestroy(cmsContext id, void* mtx) { mutex_destroyed++; _cmsFree(id, mtx); }
static cmsBool MyMtxLock(cmsContext id, void* mtx) { (void) id; (void) mtx; mutex_locked++; return TRUE; }
static void MyMtxUnlock(cmsContext id, void* mtx) { (void) id; (void) mtx; mutex_unlocked++; }
static cmsPluginMutex MutexPluginSample = { { cmsPluginMagicNumber, 2060, cmsPluginMutexSig, NULL }, MyMtxCreate, MyMtxDestroy, MyMtxLock, MyMtxUnlock };

static void mutex_checks(cmsContext ctx, const char* label)
{
    cmsHPROFILE h;
    cmsHTRANSFORM xform;
    cmsUInt8Number In[3] = { 10, 20, 30 }, Out[3];
    void* m;
    mutex_created = mutex_destroyed = mutex_locked = mutex_unlocked = 0;
    m = _cmsCreateMutex(ctx);
    _cmsLockMutex(ctx, m);
    _cmsUnlockMutex(ctx, m);
    _cmsDestroyMutex(ctx, m);
    h = cmsCreate_sRGBProfileTHR(ctx);
    xform = cmsCreateTransformTHR(ctx, h, TYPE_RGB_8, h, TYPE_RGB_8, INTENT_PERCEPTUAL, 0);
    cmsDoTransform(xform, In, Out, 1);
    cmsDeleteTransform(xform);
    cmsCloseProfile(h);
    printf("%s mutex: created=%d destroyed=%d locked=%d unlocked=%d\n", label, mutex_created, mutex_destroyed, mutex_locked, mutex_unlocked);
}

/* --- parallelization ----------------------------------------------------- */

static int scheduler_calls = 0;
static void MyScheduler(struct _cmstransform_struct* CMMcargo, const void* InputBuffer, void* OutputBuffer, cmsUInt32Number PixelsPerLine, cmsUInt32Number LineCount, const cmsStride* Stride)
{
    _cmsTransform2Fn worker = _cmsGetTransformWorker(CMMcargo);
    scheduler_calls++;
    /* Two halves, one after the other. */
    if (LineCount > 1) {
        cmsUInt32Number half = LineCount / 2;
        worker(CMMcargo, InputBuffer, OutputBuffer, PixelsPerLine, half, Stride);
        worker(CMMcargo, (const cmsUInt8Number*) InputBuffer + half * Stride->BytesPerLineIn, (cmsUInt8Number*) OutputBuffer + half * Stride->BytesPerLineOut, PixelsPerLine, LineCount - half, Stride);
    } else worker(CMMcargo, InputBuffer, OutputBuffer, PixelsPerLine, LineCount, Stride);
}
static cmsPluginParalellization ParallelPluginSample = { { cmsPluginMagicNumber, 2140, cmsPluginParalellizationSig, NULL }, 4, 0, MyScheduler };

static void parallel_checks(cmsContext ctx, const char* label)
{
    cmsHPROFILE h = cmsCreate_sRGBProfileTHR(ctx);
    cmsHPROFILE lab = cmsCreateLab4ProfileTHR(ctx, NULL);
    cmsHTRANSFORM xform = cmsCreateTransformTHR(ctx, h, TYPE_RGB_8, lab, TYPE_Lab_8, INTENT_PERCEPTUAL, 0);
    cmsUInt8Number In[24], Out[24];
    int i;
    scheduler_calls = 0;
    for (i = 0; i < 24; i++) In[i] = (cmsUInt8Number) (i * 10);
    memset(Out, 0, sizeof(Out));
    cmsDoTransformLineStride(xform, In, Out, 2, 4, 6, 6, 6, 6);
    printf("%s parallel: calls=%d workers=%d flags=%u out=", label, scheduler_calls, _cmsGetTransformMaxWorkers(xform), _cmsGetTransformWorkerFlags(xform));
    for (i = 0; i < 24; i++) printf("%02x", Out[i]);
    printf("\n");
    cmsDeleteTransform(xform);
    cmsCloseProfile(h);
    cmsCloseProfile(lab);
}

/* --- driver ------------------------------------------------------------- */

static void everything(cmsContext ctx, const char* label)
{
    interp_checks(ctx, label);
    curve_checks(ctx, label);
    formatter_checks(ctx, label);
    tag_checks(ctx, label);
    mpe_checks(ctx, label);
    optimization_checks(ctx, label);
    intent_checks(ctx, label);
    transform_checks(ctx, label);
    mutex_checks(ctx, label);
    parallel_checks(ctx, label);
}

int main(void)
{
    cmsContext ctx, cpy, cpy2;
    cmsSetLogErrorHandler(logger);

    printf("== without plugins\n");
    everything(NULL, "none");

    FullTransformPluginSample.factories.xform = MyTransformFactory;
    LegacyTransformPluginSample.factories.legacy_xform = MyLegacyFactory;

    printf("== registered\n");
    ctx = cmsCreateContext(NULL, NULL);
    cmsSetLogErrorHandlerTHR(ctx, logger);
    printf("register: %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
        cmsPluginTHR(ctx, &InterpPluginSample),
        cmsPluginTHR(ctx, &Rec709Plugin), cmsPluginTHR(ctx, &CurvePluginSample), cmsPluginTHR(ctx, &CurvePluginSample2),
        cmsPluginTHR(ctx, &FormattersPluginSample), cmsPluginTHR(ctx, &FormattersPluginSample2),
        cmsPluginTHR(ctx, &TagTypePluginSample), cmsPluginTHR(ctx, &MPEPluginSample),
        cmsPluginTHR(ctx, &OptimizationPluginSample), cmsPluginTHR(ctx, &IntentPluginSample),
        cmsPluginTHR(ctx, &FullTransformPluginSample), cmsPluginTHR(ctx, &MutexPluginSample),
        cmsPluginTHR(ctx, &ParallelPluginSample));
    everything(ctx, "ctx");

    printf("== duplicated twice\n");
    cpy = cmsDupContext(ctx, NULL);
    cpy2 = cmsDupContext(cpy, NULL);
    cmsDeleteContext(ctx);
    cmsDeleteContext(cpy);
    everything(cpy2, "cpy2");

    printf("== legacy transform factory on the copy\n");
    printf("register legacy: %d\n", cmsPluginTHR(cpy2, &LegacyTransformPluginSample));
    /* The newest factory is asked first, so it wins over the 2.8 one. */
    transform_checks(cpy2, "legacy");
    printf("legacy freed=%d\n", legacy_freed);

    printf("== unregistered\n");
    cmsUnregisterPluginsTHR(cpy2);
    everything(cpy2, "unreg");
    cmsDeleteContext(cpy2);

    printf("== bad plugins\n");
    {
        cmsPluginBase bad1 = { 0x12345678, 2060, cmsPluginInterpolationSig, NULL };
        cmsPluginBase bad2 = { cmsPluginMagicNumber, 9999, cmsPluginInterpolationSig, NULL };
        cmsPluginBase bad3 = { cmsPluginMagicNumber, 2060, 0x41424344, NULL };
        cmsPluginOptimization bad4 = { { cmsPluginMagicNumber, 2060, cmsPluginOptimizationSig, NULL }, NULL };
        cmsPluginMutex bad5 = { { cmsPluginMagicNumber, 2060, cmsPluginMutexSig, NULL }, MyMtxCreate, NULL, MyMtxLock, MyMtxUnlock };
        printf("bad: %d %d %d %d %d\n", cmsPlugin(&bad1), cmsPlugin(&bad2), cmsPlugin(&bad3), cmsPlugin(&bad4), cmsPlugin(&bad5));
    }
    return 0;
}
