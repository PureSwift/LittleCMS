import CLCMS2
import Testing

@testable import LittleCMS

// The pixel-format word decoded against the header's own constants.
//
// These are the `TYPE_*` macros a client actually writes, so decoding
// them is the whole claim: if `TYPE_BGRA_8` does not come back as four
// channels, one byte each, swapped, with one extra first, then every
// formatter built on it is wrong in the same way.

@Suite struct PixelFormatTests {
    @Test func plainInterleavedLayouts() {
        let rgb8 = PixelFormat(SLCMS_TYPE_RGB_8)
        #expect(rgb8.channels == 3)
        #expect(rgb8.bytes == 1)
        #expect(rgb8.extra == 0)
        #expect(!rgb8.planar)
        #expect(!rgb8.swapped)
        #expect(!rgb8.floatingPoint)
        #expect(rgb8.totalChannels == 3)

        let gray8 = PixelFormat(SLCMS_TYPE_GRAY_8)
        #expect(gray8.channels == 1)
        #expect(gray8.bytes == 1)

        let cmyk16 = PixelFormat(SLCMS_TYPE_CMYK_16)
        #expect(cmyk16.channels == 4)
        #expect(cmyk16.bytes == 2)
    }

    @Test func alphaAndOrdering() {
        let rgba8 = PixelFormat(SLCMS_TYPE_RGBA_8)
        #expect(rgba8.channels == 3)
        #expect(rgba8.extra == 1)
        #expect(rgba8.totalChannels == 4)
        #expect(!rgba8.swapFirst)

        // Blue first and the alpha still last.
        let bgr8 = PixelFormat(SLCMS_TYPE_BGR_8)
        #expect(bgr8.channels == 3)
        #expect(bgr8.swapped)
        #expect(bgr8.extra == 0)

        // Alpha first, which is a different bit from reversing the
        // colour order — ARGB sets both.
        let argb8 = PixelFormat(SLCMS_TYPE_ARGB_8)
        #expect(argb8.channels == 3)
        #expect(argb8.extra == 1)
        #expect(argb8.swapFirst)

        let abgr8 = PixelFormat(SLCMS_TYPE_ABGR_8)
        #expect(abgr8.swapped)
        #expect(abgr8.extra == 1)
    }

    @Test func widthsBeyondTwoBytes() {
        // Eight bytes per channel does not fit in three bits, so the
        // width field carries zero and means eight.
        let labDouble = PixelFormat(SLCMS_TYPE_Lab_DBL)
        #expect(labDouble.channels == 3)
        #expect(labDouble.bytes == 0)
        #expect(labDouble.floatingPoint)

        let rgbFloat = PixelFormat(SLCMS_TYPE_RGB_FLT)
        #expect(rgbFloat.bytes == 4)
        #expect(rgbFloat.floatingPoint)

        let rgbHalf = PixelFormat(SLCMS_TYPE_RGB_HALF_FLT)
        #expect(rgbHalf.bytes == 2)
        #expect(rgbHalf.floatingPoint)
    }

    @Test func planarAndInverted() {
        let planar = PixelFormat(SLCMS_TYPE_RGB_8_PLANAR)
        #expect(planar.planar)
        #expect(planar.channels == 3)

        // Subtractive inks count downwards.
        let inverted = PixelFormat(SLCMS_TYPE_CMYK_8_REV)
        #expect(inverted.inverted)
        #expect(inverted.channels == 4)

        let littleEndian = PixelFormat(SLCMS_TYPE_RGB_16_SE)
        #expect(littleEndian.endianSwapped)
        #expect(littleEndian.bytes == 2)
    }

    @Test func premultipliedAlpha() {
        let premultiplied = PixelFormat(SLCMS_TYPE_RGBA_8_PREMUL)
        #expect(premultiplied.premultiplied)
        #expect(premultiplied.extra == 1)

        #expect(!PixelFormat(SLCMS_TYPE_RGBA_8).premultiplied)
    }

    @Test func aWordThatNamesNothing() {
        // The word can describe layouts no constant names, and decoding
        // one is not an error — it is the tables that decline to match.
        // Assembled the way the header's macros assemble one: seven
        // colour channels, two bytes each, three extra, planar.
        let odd = PixelFormat(7 << 3 | 2 | 3 << 7 | 1 << 12)
        #expect(odd.channels == 7)
        #expect(odd.bytes == 2)
        #expect(odd.extra == 3)
        #expect(odd.planar)
        #expect(odd.totalChannels == 10)
    }
}
