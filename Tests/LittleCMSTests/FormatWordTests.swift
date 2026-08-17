import CLCMS2
import Testing

// The `*_SH` shifts, checked by reconstruction.
//
// Every formatter table entry is spelled with these, so a wrong shift
// would mis-select formatters for a whole family of layouts and nothing
// else would notice. Reconstructing named constants is the check: the
// compiler computed those from the header's own macros, so agreement
// means the shifts are the header's shifts.
//
// These live in the test rather than the engine because the tables are
// boundary code; what is being pinned is arithmetic, and arithmetic is
// cheap to state twice and expensive to get wrong once.

@Suite struct FormatWordTests {
    // The same shifts the boundary uses.
    func bytesSH(_ v: UInt32) -> UInt32 { v }
    func channelsSH(_ v: UInt32) -> UInt32 { v << 3 }
    func extraSH(_ v: UInt32) -> UInt32 { v << 7 }
    func doSwapSH(_ v: UInt32) -> UInt32 { v << 10 }
    func endian16SH(_ v: UInt32) -> UInt32 { v << 11 }
    func planarSH(_ v: UInt32) -> UInt32 { v << 12 }
    func flavorSH(_ v: UInt32) -> UInt32 { v << 13 }
    func swapFirstSH(_ v: UInt32) -> UInt32 { v << 14 }
    func colorSpaceSH(_ v: UInt32) -> UInt32 { v << 16 }
    func floatSH(_ v: UInt32) -> UInt32 { v << 22 }
    func premulSH(_ v: UInt32) -> UInt32 { v << 23 }

    @Test func reconstructsTheSimpleLayouts() {
        #expect(
            colorSpaceSH(UInt32(PT_RGB)) | channelsSH(3) | bytesSH(1) == SLCMS_TYPE_RGB_8
        )
        #expect(
            colorSpaceSH(UInt32(PT_GRAY)) | channelsSH(1) | bytesSH(1) == SLCMS_TYPE_GRAY_8
        )
        #expect(
            colorSpaceSH(UInt32(PT_CMYK)) | channelsSH(4) | bytesSH(2) == SLCMS_TYPE_CMYK_16
        )
    }

    @Test func reconstructsTheOrderingBits() {
        #expect(
            colorSpaceSH(UInt32(PT_RGB)) | extraSH(1) | channelsSH(3) | bytesSH(1)
                == SLCMS_TYPE_RGBA_8
        )
        #expect(
            colorSpaceSH(UInt32(PT_RGB)) | channelsSH(3) | bytesSH(1) | doSwapSH(1)
                == SLCMS_TYPE_BGR_8
        )
        #expect(
            colorSpaceSH(UInt32(PT_RGB)) | extraSH(1) | channelsSH(3) | bytesSH(1)
                | swapFirstSH(1) == SLCMS_TYPE_ARGB_8
        )
        #expect(
            colorSpaceSH(UInt32(PT_RGB)) | extraSH(1) | channelsSH(3) | bytesSH(1)
                | doSwapSH(1) == SLCMS_TYPE_ABGR_8
        )
    }

    @Test func reconstructsTheRest() {
        #expect(
            floatSH(1) | colorSpaceSH(UInt32(PT_Lab)) | channelsSH(3) | bytesSH(0)
                == SLCMS_TYPE_Lab_DBL
        )
        #expect(
            floatSH(1) | colorSpaceSH(UInt32(PT_RGB)) | channelsSH(3) | bytesSH(4)
                == SLCMS_TYPE_RGB_FLT
        )
        #expect(
            colorSpaceSH(UInt32(PT_RGB)) | channelsSH(3) | bytesSH(1) | planarSH(1)
                == SLCMS_TYPE_RGB_8_PLANAR
        )
        #expect(
            colorSpaceSH(UInt32(PT_CMYK)) | channelsSH(4) | bytesSH(1) | flavorSH(1)
                == SLCMS_TYPE_CMYK_8_REV
        )
        #expect(
            colorSpaceSH(UInt32(PT_RGB)) | channelsSH(3) | bytesSH(2) | endian16SH(1)
                == SLCMS_TYPE_RGB_16_SE
        )
        #expect(
            colorSpaceSH(UInt32(PT_RGB)) | extraSH(1) | channelsSH(3) | bytesSH(1)
                | premulSH(1) == SLCMS_TYPE_RGBA_8_PREMUL
        )
    }

    @Test func maskingIsWhatSelectionDoes() {
        // An entry standing for "three bytes, any colour space" matches
        // an RGB buffer and a Lab one alike, but not a four-channel one.
        let type = channelsSH(3) | bytesSH(1)
        let mask = colorSpaceSH(31)

        #expect((SLCMS_TYPE_RGB_8 & ~mask) == type)
        #expect((SLCMS_TYPE_CMYK_8 & ~mask) != type)
        // Swapped order is a different entry, not the same one.
        #expect((SLCMS_TYPE_BGR_8 & ~mask) != type)
    }
}
