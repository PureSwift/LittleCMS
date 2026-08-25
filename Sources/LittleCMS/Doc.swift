// LittleCMS: the Swift face of the library.
//
// The C surface in LCMS2ABI is a contract with existing binaries; this
// module is the API a Swift program wants instead: profiles, tone
// curves and transforms as managed objects, errors thrown rather than
// logged, and no TYPE_ macros.  It is a thin layer — every operation
// lands in the same engine the C entry points use.
//
// The colorimetry value types live in the engine and are re-exported
// here, so `import LittleCMS` is the whole vocabulary.

@_exported import struct LittleCMSCore.CIEXYZ
@_exported import struct LittleCMSCore.CIExyY
@_exported import struct LittleCMSCore.CIELab
@_exported import struct LittleCMSCore.CIELCh
@_exported import struct LittleCMSCore.CIEJCh
@_exported import struct LittleCMSCore.ViewingConditions
@_exported import enum LittleCMSCore.Surround
@_exported import struct LittleCMSCore.CIECAM02
@_exported import struct LittleCMSCore.RGBPrimaries
@_exported import struct LittleCMSCore.PixelFormat
@_exported import struct LittleCMSCore.NamedColor
