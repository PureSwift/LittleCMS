import CLCMS2

/// A rendering intent.
public enum Intent: UInt32, Sendable, CaseIterable {
    case perceptual = 0
    case relativeColorimetric = 1
    case saturation = 2
    case absoluteColorimetric = 3
    /// Little CMS extensions: the ICC intents with black ink or the
    /// whole black plane held fixed through the conversion.
    case preserveKOnlyPerceptual = 10
    case preserveKOnlyRelativeColorimetric = 11
    case preserveKOnlySaturation = 12
    case preserveKPlanePerceptual = 13
    case preserveKPlaneRelativeColorimetric = 14
    case preserveKPlaneSaturation = 15
}

extension Transform {
    /// Behaviour switches for a transform, `cmsFLAGS_*`.
    public struct Options: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let blackPointCompensation = Options(rawValue: UInt32(cmsFLAGS_BLACKPOINTCOMPENSATION))
        /// Keep full precision: no pipeline rewriting.
        public static let noOptimization = Options(rawValue: UInt32(cmsFLAGS_NOOPTIMIZE))
        /// No one-entry result cache; required for a transform shared
        /// across threads that must not serialize on it.
        public static let noCache = Options(rawValue: UInt32(cmsFLAGS_NOCACHE))
        /// Move pixels without converting them.
        public static let nullTransform = Options(rawValue: UInt32(cmsFLAGS_NULLTRANSFORM))
        /// Mark out-of-gamut colors with the alarm color (proofing).
        public static let gamutCheck = Options(rawValue: UInt32(cmsFLAGS_GAMUTCHECK))
        /// Proof colors on the emulated device (proofing).
        public static let softProofing = Options(rawValue: UInt32(cmsFLAGS_SOFTPROOFING))
        public static let highResolutionPrecalculation = Options(rawValue: UInt32(cmsFLAGS_HIGHRESPRECALC))
        public static let lowResolutionPrecalculation = Options(rawValue: UInt32(cmsFLAGS_LOWRESPRECALC))
        /// Copy the extra (alpha) channels through unchanged.
        public static let copyAlpha = Options(rawValue: UInt32(cmsFLAGS_COPY_ALPHA))
    }
}
