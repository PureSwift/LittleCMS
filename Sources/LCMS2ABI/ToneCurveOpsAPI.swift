import CLCMS2
import LittleCMS

// What can be asked of a curve, and what can be made from one.
//
// These all work through the 16-bit table rather than the segments, which
// is why a reversed curve is an approximation unless the original was
// parametric and can be inverted outright.

/// `GetInterval`: the table cell whose values bracket `target`.
///
/// Walks from whichever end suits the table's overall direction, and
/// accepts a cell that runs the other way — a table need not be monotonic
/// for a value to sit inside one of its steps.
private func interval(
    containing target: cmsFloat64Number,
    table: UnsafePointer<cmsUInt16Number>,
    domain: cmsUInt32Number
) -> Int {
    // A single point spans nothing.
    if domain < 1 { return -1 }

    let last = Int(domain)

    @inline(__always)
    func brackets(_ i: Int) -> Bool {
        let y0 = cmsFloat64Number(table[i])
        let y1 = cmsFloat64Number(table[i + 1])
        if y0 <= y1 { return target >= y0 && target <= y1 }
        return target >= y1 && target <= y0
    }

    if table[0] < table[last] {
        var i = last - 1
        while i >= 0 {
            if brackets(i) { return i }
            i -= 1
        }
    } else {
        for i in 0..<last where brackets(i) {
            return i
        }
    }

    return -1
}

@inline(__always)
private func tableDomain(_ curve: UnsafePointer<cmsToneCurve>) -> cmsUInt32Number {
    let n = curve.pointee.nEntries
    return n > 0 ? n - 1 : 0
}

// -- what a curve is ---------------------------------------------------

@c @implementation
public func cmsIsToneCurveDescending(_ t: UnsafePointer<cmsToneCurve>?) -> cmsBool {
    guard let t, let table = t.pointee.Table16, t.pointee.nEntries > 0 else { return 0 }
    return table[0] > table[Int(t.pointee.nEntries) - 1] ? 1 : 0
}

@c @implementation
public func cmsIsToneCurveLinear(_ Curve: UnsafePointer<cmsToneCurve>?) -> cmsBool {
    guard let Curve, let table = Curve.pointee.Table16 else { return 0 }
    let n = Curve.pointee.nEntries

    for i in 0..<Int(n) {
        // Against the value a linear ramp would hold at this node, with
        // the tolerance the reference allows.
        let expected = quantizeValue(cmsFloat64Number(i), maxSamples: n)
        if abs(Int32(table[i]) - Int32(expected)) > 0x0F { return 0 }
    }
    return 1
}

@c @implementation
public func cmsIsToneCurveMonotonic(_ t: UnsafePointer<cmsToneCurve>?) -> cmsBool {
    guard let t, let table = t.pointee.Table16 else { return 0 }

    // A curve too small to have a direction is allowed through.
    let n = Int(t.pointee.nEntries)
    if n < 2 { return 1 }

    // Some ripple is tolerated; the reference's limit is two codes.
    if cmsIsToneCurveDescending(t) != 0 {
        var last = Int32(table[0])
        for i in 1..<n {
            if Int32(table[i]) - last > 2 { return 0 }
            last = Int32(table[i])
        }
    } else {
        var last = Int32(table[n - 1])
        var i = n - 2
        while i >= 0 {
            if Int32(table[i]) - last > 2 { return 0 }
            last = Int32(table[i])
            i -= 1
        }
    }
    return 1
}

// -- making one from another -------------------------------------------

@c @implementation
public func cmsReverseToneCurveEx(
    _ nResultSamples: cmsUInt32Number,
    _ InCurve: UnsafePointer<cmsToneCurve>?
) -> UnsafeMutablePointer<cmsToneCurve>? {
    guard let InCurve else { return nil }
    let context = InCurve.pointee.InterpParams?.pointee.ContextID

    // A parametric curve inverts exactly, so it is rebuilt rather than
    // resampled.
    if InCurve.pointee.nSegments == 1,
       let segments = InCurve.pointee.Segments,
       segments[0].Type > 0,
       parametricEvaluator(for: segments[0].Type, context: context) != nil {
        return withUnsafePointer(to: segments[0].Params) { params in
            params.withMemoryRebound(to: cmsFloat64Number.self, capacity: 10) {
                cmsBuildParametricToneCurve(context, -segments[0].Type, $0)
            }
        }
    }

    guard let out = cmsBuildTabulatedToneCurve16(context, nResultSamples, nil),
          let outTable = out.pointee.Table16,
          let inTable = InCurve.pointee.Table16
    else { return nil }

    let ascending = cmsIsToneCurveDescending(InCurve) == 0
    let inEntries = InCurve.pointee.nEntries

    // The reference carries the line from the previous sample when a
    // value falls outside every interval, so a and b live outside the
    // loop and are not reset.
    var a: cmsFloat64Number = 0
    var b: cmsFloat64Number = 0

    for i in 0..<Int(nResultSamples) {
        let y = cmsFloat64Number(i) * 65535.0 / cmsFloat64Number(nResultSamples - 1)

        let j = interval(containing: y, table: inTable, domain: tableDomain(InCurve))
        if j >= 0 {
            let x1 = cmsFloat64Number(inTable[j])
            let x2 = cmsFloat64Number(inTable[j + 1])
            let y1 = cmsFloat64Number(j) * 65535.0 / cmsFloat64Number(inEntries - 1)
            let y2 = cmsFloat64Number(j + 1) * 65535.0 / cmsFloat64Number(inEntries - 1)

            if x1 == x2 {
                // A flat step inverts to either end; the direction picks.
                outTable[i] = quickSaturateWord(ascending ? y2 : y1)
                continue
            }
            a = (y2 - y1) / (x2 - x1)
            b = y2 - a * x2
        }

        outTable[i] = quickSaturateWord(a * y + b)
    }

    return out
}

@c @implementation
public func cmsReverseToneCurve(
    _ InGamma: UnsafePointer<cmsToneCurve>?
) -> UnsafeMutablePointer<cmsToneCurve>? {
    cmsReverseToneCurveEx(4096, InGamma)
}

@c @implementation
public func cmsJoinToneCurve(
    _ ContextID: cmsContext?,
    _ X: UnsafePointer<cmsToneCurve>?,
    _ Y: UnsafePointer<cmsToneCurve>?,
    _ nPoints: cmsUInt32Number
) -> UnsafeMutablePointer<cmsToneCurve>? {
    guard let X, let Y else { return nil }

    guard let reversed = cmsReverseToneCurveEx(nPoints, Y) else { return nil }
    defer { cmsFreeToneCurve(reversed) }

    guard let raw = _cmsCalloc(
        ContextID, nPoints, cmsUInt32Number(MemoryLayout<cmsFloat32Number>.stride)
    ) else { return nil }
    let samples = raw.assumingMemoryBound(to: cmsFloat32Number.self)
    defer { _cmsFree(ContextID, raw) }

    for i in 0..<Int(nPoints) {
        let t = cmsFloat32Number(i) / cmsFloat32Number(nPoints - 1)
        samples[i] = cmsEvalToneCurveFloat(reversed, cmsEvalToneCurveFloat(X, t))
    }

    return cmsBuildTabulatedToneCurveFloat(ContextID, nPoints, samples)
}

// -- measuring one ------------------------------------------------------

/// The node count the reference samples a curve at when estimating.
private let maximumNodesInCurve = 4097

@c @implementation
public func cmsEstimateGamma(
    _ t: UnsafePointer<cmsToneCurve>?,
    _ Precision: cmsFloat64Number
) -> cmsFloat64Number {
    guard let t else { return -1.0 }

    var sum = 0.0
    var sumSquares = 0.0
    var n = 0.0

    for i in 1..<(maximumNodesInCurve - 1) {
        let x = cmsFloat64Number(i) / cmsFloat64Number(maximumNodesInCurve - 1)
        let y = cmsFloat64Number(cmsEvalToneCurveFloat(t, cmsFloat32Number(x)))

        // The bottom of the range is skipped: a linear ramp there would
        // drag the estimate towards a gamma the curve does not have.
        if y > 0.0 && y < 1.0 && x > 0.07 {
            let gamma = log(y) / log(x)
            sum += gamma
            sumSquares += gamma * gamma
            n += 1
        }
    }

    if n <= 1 { return -1.0 }

    // A curve that is not a power law at all shows up as a wide spread.
    let deviation = ((n * sumSquares - sum * sum) / (n * (n - 1))).squareRoot()
    if deviation > Precision { return -1.0 }

    return sum / n
}

// -- smoothing ----------------------------------------------------------

/// `smooth2`: the banded solve behind Whittaker smoothing.
///
/// Works on one-based slices, as the reference does, because the
/// recurrences reach two entries back and the arrays are allocated with
/// the extra element that makes that safe.
private func whittakerSmooth(
    _ context: cmsContext?,
    weights w: UnsafeMutablePointer<cmsFloat32Number>,
    values y: UnsafeMutablePointer<cmsFloat32Number>,
    result z: UnsafeMutablePointer<cmsFloat32Number>,
    lambda: cmsFloat32Number,
    count m: Int
) -> Bool {
    if m < 4 || cmsFloat64Number(lambda) < smallestMeaningfulValue { return false }

    let bytes = cmsUInt32Number(maximumNodesInCurve)
    let stride = cmsUInt32Number(MemoryLayout<cmsFloat32Number>.stride)
    guard let cRaw = _cmsCalloc(context, bytes, stride),
          let dRaw = _cmsCalloc(context, bytes, stride),
          let eRaw = _cmsCalloc(context, bytes, stride)
    else { return false }

    let c = cRaw.assumingMemoryBound(to: cmsFloat32Number.self)
    let d = dRaw.assumingMemoryBound(to: cmsFloat32Number.self)
    let e = eRaw.assumingMemoryBound(to: cmsFloat32Number.self)
    defer {
        _cmsFree(context, cRaw)
        _cmsFree(context, dRaw)
        _cmsFree(context, eRaw)
    }

    d[1] = w[1] + lambda
    c[1] = -2 * lambda / d[1]
    e[1] = lambda / d[1]
    z[1] = w[1] * y[1]
    d[2] = w[2] + 5 * lambda - d[1] * c[1] * c[1]
    c[2] = (-4 * lambda - d[1] * c[1] * e[1]) / d[2]
    e[2] = lambda / d[2]
    z[2] = w[2] * y[2] - c[1] * z[1]

    if m > 4 {
        for i in 3..<(m - 1) {
            let i1 = i - 1, i2 = i - 2
            d[i] = w[i] + 6 * lambda - c[i1] * c[i1] * d[i1] - e[i2] * e[i2] * d[i2]
            c[i] = (-4 * lambda - d[i1] * c[i1] * e[i1]) / d[i]
            e[i] = lambda / d[i]
            z[i] = w[i] * y[i] - c[i1] * z[i1] - e[i2] * z[i2]
        }
    }

    var i1 = m - 2, i2 = m - 3
    d[m - 1] = w[m - 1] + 5 * lambda - c[i1] * c[i1] * d[i1] - e[i2] * e[i2] * d[i2]
    c[m - 1] = (-2 * lambda - d[i1] * c[i1] * e[i1]) / d[m - 1]
    z[m - 1] = w[m - 1] * y[m - 1] - c[i1] * z[i1] - e[i2] * z[i2]

    i1 = m - 1
    i2 = m - 2
    d[m] = w[m] + lambda - c[i1] * c[i1] * d[i1] - e[i2] * e[i2] * d[i2]
    z[m] = (w[m] * y[m] - c[i1] * z[i1] - e[i2] * z[i2]) / d[m]
    z[m - 1] = z[m - 1] / d[m - 1] - c[m - 1] * z[m]

    var i = m - 2
    while i >= 1 {
        z[i] = z[i] / d[i] - c[i] * z[i + 1] - e[i] * z[i + 2]
        i -= 1
    }

    return true
}

@c @implementation
public func cmsSmoothToneCurve(
    _ Tab: UnsafeMutablePointer<cmsToneCurve>?,
    _ lambda: cmsFloat64Number
) -> cmsBool {
    // The reference cannot report this one: with no curve there is no
    // context to report through.
    guard let Tab, let params = Tab.pointee.InterpParams else { return 0 }
    let context = params.pointee.ContextID

    // Only a curve that bends needs smoothing.
    if cmsIsToneCurveLinear(Tab) != 0 { return 1 }

    let items = Int(Tab.pointee.nEntries)
    if items >= maximumNodesInCurve {
        report(cmsUInt32Number(cmsERROR_RANGE), "cmsSmoothToneCurve: Too many points.", to: context)
        return 0
    }

    let stride = cmsUInt32Number(MemoryLayout<cmsFloat32Number>.stride)
    let count = cmsUInt32Number(items + 1)
    guard let wRaw = _cmsCalloc(context, count, stride),
          let yRaw = _cmsCalloc(context, count, stride),
          let zRaw = _cmsCalloc(context, count, stride)
    else {
        report(
            cmsUInt32Number(cmsERROR_RANGE),
            "cmsSmoothToneCurve: Could not allocate memory.",
            to: context
        )
        return 0
    }
    let w = wRaw.assumingMemoryBound(to: cmsFloat32Number.self)
    let y = yRaw.assumingMemoryBound(to: cmsFloat32Number.self)
    let z = zRaw.assumingMemoryBound(to: cmsFloat32Number.self)
    defer {
        _cmsFree(context, zRaw)
        _cmsFree(context, yRaw)
        _cmsFree(context, wRaw)
    }

    guard let table = Tab.pointee.Table16 else { return 0 }
    for i in 0..<items {
        y[i + 1] = cmsFloat32Number(table[i])
        w[i + 1] = 1.0
    }

    // A negative lambda asks for the smoothing without the sanity checks
    // that would otherwise reject the result.
    var l = lambda
    var unchecked = false
    if l < 0 {
        unchecked = true
        l = -l
    }

    guard whittakerSmooth(
        context, weights: w, values: y, result: z,
        lambda: cmsFloat32Number(l), count: items
    ) else {
        report(
            cmsUInt32Number(cmsERROR_RANGE),
            "cmsSmoothToneCurve: Function smooth2 failed.",
            to: context
        )
        return 0
    }

    var succeeded = true
    var zeros = 0
    var poles = 0
    var i = items
    while i > 1 {
        if z[i] == 0.0 { zeros += 1 }
        if z[i] >= 65535.0 { poles += 1 }
        if z[i] < z[i - 1] {
            report(cmsUInt32Number(cmsERROR_RANGE), "cmsSmoothToneCurve: Non-Monotonic.", to: context)
            succeeded = unchecked
            break
        }
        i -= 1
    }

    if succeeded && zeros > (items / 3) {
        report(
            cmsUInt32Number(cmsERROR_RANGE),
            "cmsSmoothToneCurve: Degenerated, mostly zeros.",
            to: context
        )
        succeeded = unchecked
    }
    if succeeded && poles > (items / 3) {
        report(
            cmsUInt32Number(cmsERROR_RANGE),
            "cmsSmoothToneCurve: Degenerated, mostly poles.",
            to: context
        )
        succeeded = unchecked
    }

    if succeeded {
        for i in 0..<items {
            table[i] = quickSaturateWord(cmsFloat64Number(z[i + 1]))
        }
    }

    return succeeded ? 1 : 0
}
