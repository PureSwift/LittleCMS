extension CIELab {
    /// Clips this colour into the a/b prism, moving it along its own hue.
    ///
    /// Returns false when the colour cannot be brought in: a negative
    /// lightness takes the whole colour to black, and a hue that falls in
    /// none of the four zones is refused.  L above 100 is clamped rather
    /// than refused, because the ICC specification gives no meaning to a
    /// highlight above white.
    @discardableResult
    public mutating func desaturate(
        aMax: Double, aMin: Double,
        bMax: Double, bMin: Double
    ) -> Bool {
        if l < 0 {
            l = 0
            a = 0
            b = 0
            return false
        }

        if l > 100 { l = 100 }

        guard a < aMin || a > aMax || b < bMin || b > bMax else { return true }

        // Exactly on the neutral axis in a, the slope is not defined, so
        // the clip is along b alone.
        if a == 0.0 {
            b = b < 0 ? bMin : bMax
            return true
        }

        let slope = b / a
        let h = cylindrical.h

        switch h {
        case 0..<45, 315...360:
            a = aMax
            b = aMax * slope
        case 45..<135:
            b = bMax
            a = bMax / slope
        case 135..<225:
            a = aMin
            b = aMin * slope
        case 225..<315:
            b = bMin
            a = bMin / slope
        default:
            return false
        }
        return true
    }
}
