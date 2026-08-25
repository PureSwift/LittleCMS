import LittleCMSCore

// The common pixel layouts, named.  Each is the corresponding TYPE_*
// constant of the C API, built from the same bit fields; the test suite
// pins them to the macros so they cannot drift.

extension PixelFormat {
    /// Builds a format from its fields, mirroring the TYPE_* macros.
    init(
        space: UInt32, channels: UInt32, bytes: UInt32,
        extra: UInt32 = 0, float: Bool = false, swap: Bool = false,
        swapFirst: Bool = false, planar: Bool = false, reversed: Bool = false,
        bigEndian: Bool = false
    ) {
        var value: UInt32 = space << 16 | channels << 3 | bytes | extra << 7
        if float { value |= 1 << 22 }
        if swap { value |= 1 << 10 }
        if swapFirst { value |= 1 << 14 }
        if planar { value |= 1 << 12 }
        if reversed { value |= 1 << 13 }
        if bigEndian { value |= 1 << 11 }
        self.init(value)
    }

    // Gray.
    public static let gray8 = PixelFormat(space: 3, channels: 1, bytes: 1)
    public static let gray16 = PixelFormat(space: 3, channels: 1, bytes: 2)
    public static let grayFloat = PixelFormat(space: 3, channels: 1, bytes: 4, float: true)

    // RGB, 8 bits.
    public static let rgb8 = PixelFormat(space: 4, channels: 3, bytes: 1)
    public static let rgba8 = PixelFormat(space: 4, channels: 3, bytes: 1, extra: 1)
    public static let argb8 = PixelFormat(space: 4, channels: 3, bytes: 1, extra: 1, swapFirst: true)
    public static let bgr8 = PixelFormat(space: 4, channels: 3, bytes: 1, swap: true)
    public static let bgra8 = PixelFormat(
        space: 4, channels: 3, bytes: 1, extra: 1, swap: true, swapFirst: true
    )
    public static let rgb8Planar = PixelFormat(space: 4, channels: 3, bytes: 1, planar: true)

    // RGB, deeper.
    public static let rgb16 = PixelFormat(space: 4, channels: 3, bytes: 2)
    public static let rgba16 = PixelFormat(space: 4, channels: 3, bytes: 2, extra: 1)
    public static let rgbHalf = PixelFormat(space: 4, channels: 3, bytes: 2, float: true)
    public static let rgbFloat = PixelFormat(space: 4, channels: 3, bytes: 4, float: true)
    public static let rgbaFloat = PixelFormat(space: 4, channels: 3, bytes: 4, extra: 1, float: true)
    public static let rgbDouble = PixelFormat(space: 4, channels: 3, bytes: 0, float: true)

    // CMYK.
    public static let cmyk8 = PixelFormat(space: 6, channels: 4, bytes: 1)
    public static let cmyk16 = PixelFormat(space: 6, channels: 4, bytes: 2)
    public static let cmykFloat = PixelFormat(space: 6, channels: 4, bytes: 4, float: true)

    // The connection spaces.
    public static let lab8 = PixelFormat(space: 10, channels: 3, bytes: 1)
    public static let lab16 = PixelFormat(space: 10, channels: 3, bytes: 2)
    public static let labFloat = PixelFormat(space: 10, channels: 3, bytes: 4, float: true)
    public static let labDouble = PixelFormat(space: 10, channels: 3, bytes: 0, float: true)
    public static let xyz16 = PixelFormat(space: 9, channels: 3, bytes: 2)
    public static let xyzFloat = PixelFormat(space: 9, channels: 3, bytes: 4, float: true)
    public static let xyzDouble = PixelFormat(space: 9, channels: 3, bytes: 0, float: true)
}
