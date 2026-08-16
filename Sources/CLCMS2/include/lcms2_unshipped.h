/*
 * Declarations for the 18 functions the reference liblcms2 exports but
 * declares in no header it installs.  They live in the reference's private
 * lcms2_internal.h (marked CMSCHECKPOINT — exported so its own testbed can
 * reach them), yet they have default visibility in the shipped library, so
 * existing binaries may already bind them: they are ABI whether or not they
 * were meant to be.
 *
 * Transcribed from lcms2_internal.h at tag lcms2.19, spelled with the same
 * CMSAPI/CMSEXPORT macros as the vendored headers so the extraction and
 * type-checking machinery treats them exactly like the public surface.
 * This header is not installed.
 *
 * Requires lcms2.h and lcms2_plugin.h to be included first.
 */

#ifndef _lcms2_unshipped_H
#define _lcms2_unshipped_H

#ifndef CMS_USE_CPP_API
#   ifdef __cplusplus
extern "C" {
#   endif
#endif

// Interpolation (cmsintrp.c)
CMSAPI cmsInterpParams*  CMSEXPORT _cmsComputeInterpParams(cmsContext ContextID, cmsUInt32Number nSamples, cmsUInt32Number InputChan, cmsUInt32Number OutputChan, const void* Table, cmsUInt32Number dwFlags);
CMSAPI void              CMSEXPORT _cmsFreeInterpParams(cmsInterpParams* p);

// Half-precision conversion (cmshalf.c)
CMSAPI cmsUInt16Number   CMSEXPORT _cmsFloat2Half(cmsFloat32Number flt);
CMSAPI cmsFloat32Number  CMSEXPORT _cmsHalf2Float(cmsUInt16Number h);

// Pixel formatters (cmspack.c)
CMSAPI cmsFormatter      CMSEXPORT _cmsGetFormatter(cmsContext ContextID, cmsUInt32Number Type, cmsFormatterDirection Dir, cmsUInt32Number dwFlags);

// Pipeline optimization (cmsopt.c)
CMSAPI cmsBool           CMSEXPORT _cmsOptimizePipeline(cmsContext ContextID, cmsPipeline** Lut, cmsUInt32Number Intent, cmsUInt32Number* InputFormat, cmsUInt32Number* OutputFormat, cmsUInt32Number* dwFlags);

// Quantization (cmslut.c)
CMSAPI cmsUInt16Number   CMSEXPORT _cmsQuantizeVal(cmsFloat64Number i, cmsUInt32Number MaxSamples);

// Profile LUT readers (cmsio1.c)
CMSAPI cmsPipeline*      CMSEXPORT _cmsReadInputLUT(cmsHPROFILE hProfile, cmsUInt32Number Intent);
CMSAPI cmsPipeline*      CMSEXPORT _cmsReadOutputLUT(cmsHPROFILE hProfile, cmsUInt32Number Intent);
CMSAPI cmsPipeline*      CMSEXPORT _cmsReadDevicelinkLUT(cmsHPROFILE hProfile, cmsUInt32Number Intent);

// Grid-point heuristic (cmsxform.c)
CMSAPI cmsUInt32Number   CMSEXPORT _cmsReasonableGridpointsByColorspace(cmsColorSpaceSignature Colorspace, cmsUInt32Number dwFlags);

// Stage constructors (cmslut.c)
CMSAPI cmsStage*         CMSEXPORT _cmsStageAllocIdentityCLut(cmsContext ContextID, cmsUInt32Number nChan);
CMSAPI cmsStage*         CMSEXPORT _cmsStageAllocIdentityCurves(cmsContext ContextID, cmsUInt32Number nChannels);
CMSAPI cmsStage*         CMSEXPORT _cmsStageAllocLab2XYZ(cmsContext ContextID);
CMSAPI cmsStage*         CMSEXPORT _cmsStageAllocXYZ2Lab(cmsContext ContextID);
CMSAPI cmsStage*         CMSEXPORT _cmsStageAllocLabV2ToV4(cmsContext ContextID);
CMSAPI cmsStage*         CMSEXPORT _cmsStageAllocLabV4ToV2(cmsContext ContextID);
CMSAPI cmsStage*         CMSEXPORT _cmsStageAllocNamedColor(cmsNAMEDCOLORLIST* NamedColorList, cmsBool UsePCS);

#ifndef CMS_USE_CPP_API
#   ifdef __cplusplus
}
#   endif
#endif

#endif  // _lcms2_unshipped_H
