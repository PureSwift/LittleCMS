// Multi-dimensional interpolation: how a colour is read out of a lookup
// table.
//
// This is the hottest code in the library and the least forgiving.  Every
// kernel is transcribed rather than unified, because the reference's own
// variants disagree with each other in ways that are load-bearing: the
// 16-bit tetrahedral keeps its second cell offset as a delta from a moved
// base pointer while the float one keeps it absolute, the float bilinear
// floors with the fast floor while the float trilinear and tetrahedral
// use the real one, and the four-input evaluator's tetrahedron selection
// is spelled differently from the three-input one though it decides the
// same thing.  Tidying any of that would change pixels.
//
// The grid is addressed through `opta`: opta[0] is the output channel
// count, and opta[i] the stride of the i-th input counting from the last.

/// The most output channels a stage can have, `MAX_STAGE_CHANNELS`.
public let maximumStageChannels = 128

/// Everything a lookup needs to know about a table's shape.
///
/// Mirrors the published `cmsInterpParams` field for field; the boundary
/// hands one of these straight across.
public struct InterpolationGrid {
    /// Nodes per input, minus one.  Borrowed: points into the caller's
    /// parameters for the duration of the call, so that no evaluation
    /// allocates.
    public var domain: UnsafePointer<UInt32>
    /// Strides, `opta[0]` being the output channel count.  Borrowed as above.
    public var opta: UnsafePointer<UInt32>
    public var inputs: Int
    public var outputs: Int

    public init(domain: UnsafePointer<UInt32>, opta: UnsafePointer<UInt32>, inputs: Int, outputs: Int) {
        self.domain = domain
        self.opta = opta
        self.inputs = inputs
        self.outputs = outputs
    }

    /// The grid seen from one input further in, which is what the
    /// recursive evaluators hand down: the domains shift left by one and
    /// everything else stays — the strides in particular, since the
    /// inner grid's strides are the outer's first ones.
    @inline(__always)
    func droppingFirstInput() -> InterpolationGrid {
        var next = self
        next.domain = domain + 1
        return next
    }
}

/// `ROUND_FIXED_TO_INT` applied to a lerp, which is the reference's LERP
/// macro for the 16-bit kernels.
@inline(__always)
func lerp16(_ a: Int32, _ low: Int32, _ high: Int32) -> UInt16 {
    UInt16(truncatingIfNeeded: low &+ (((high &- low) &* a &+ 0x8000) >> 16))
}

/// The rounding the tetrahedral kernels use instead.
///
/// The reference explains itself here: the exact form would be
/// `ROUND_FIXED_TO_INT(_cmsToFixedDomain(Rest))`, and this replaces it
/// "at the cost of being off by one at 7fff and 17ffe".  Those two
/// values are why this is copied rather than corrected.
@inline(__always)
func tetrahedralRound(_ c0: Int32, _ rest: Int32) -> UInt16 {
    UInt16(truncatingIfNeeded: c0 &+ ((rest &+ (rest >> 16)) >> 16))
}

public enum Interpolation {
    // -- one input ------------------------------------------------------

    /// `Eval1Input`: one input, any number of outputs.
    public static func eval1(
        _ input: UnsafePointer<UInt16>,
        _ output: UnsafeMutablePointer<UInt16>,
        _ table: UnsafePointer<UInt16>,
        _ grid: InterpolationGrid
    ) {
        if input[0] == 0xFFFF || grid.domain[0] == 0 {
            let y0 = Int(grid.domain[0] &* grid.opta[0])
            for channel in 0..<grid.outputs {
                output[channel] = table[y0 + channel]
            }
            return
        }

        let fk = toFixedDomain(Int32(input[0]) &* Int32(grid.domain[0]))
        let k0 = fk >> 16
        let rk = fk & 0xFFFF
        let k1 = k0 + (input[0] != 0xFFFF ? 1 : 0)

        let K0 = Int(grid.opta[0]) * Int(k0)
        let K1 = Int(grid.opta[0]) * Int(k1)

        for channel in 0..<grid.outputs {
            output[channel] = linearInterpolate(
                rk, Int32(table[K0 + channel]), Int32(table[K1 + channel])
            )
        }
    }

    /// `Eval1InputFloat`.
    public static func eval1(
        _ input: UnsafePointer<Float>,
        _ output: UnsafeMutablePointer<Float>,
        _ table: UnsafePointer<Float>,
        _ grid: InterpolationGrid
    ) {
        var value = clampInterpolationInput(input[0])

        if value == 1.0 || grid.domain[0] == 0 {
            let start = Int(grid.domain[0] &* grid.opta[0])
            for channel in 0..<grid.outputs {
                output[channel] = table[start + channel]
            }
            return
        }

        value *= Float(grid.domain[0])
        var cell0 = Int(value.rounded(.down))
        var cell1 = Int(value.rounded(.up))
        let rest = value - Float(cell0)

        cell0 *= Int(grid.opta[0])
        cell1 *= Int(grid.opta[0])

        for channel in 0..<grid.outputs {
            let y0 = table[cell0 + channel]
            let y1 = table[cell1 + channel]
            output[channel] = y0 + (y1 - y0) * rest
        }
    }

    // -- two inputs ------------------------------------------------------

    /// `BilinearInterp16`.
    public static func bilinear(
        _ input: UnsafePointer<UInt16>,
        _ output: UnsafeMutablePointer<UInt16>,
        _ table: UnsafePointer<UInt16>,
        _ grid: InterpolationGrid
    ) {
        let fx = toFixedDomain(Int32(input[0]) &* Int32(grid.domain[0]))
        let x0 = Int(fx >> 16), rx = fx & 0xFFFF

        let fy = toFixedDomain(Int32(input[1]) &* Int32(grid.domain[1]))
        let y0 = Int(fy >> 16), ry = fy & 0xFFFF

        let X0 = Int(grid.opta[1]) * x0
        let X1 = X0 + (input[0] == 0xFFFF ? 0 : Int(grid.opta[1]))
        let Y0 = Int(grid.opta[0]) * y0
        let Y1 = Y0 + (input[1] == 0xFFFF ? 0 : Int(grid.opta[0]))

        for channel in 0..<grid.outputs {
            @inline(__always) func dens(_ i: Int, _ j: Int) -> Int32 {
                Int32(table[i + j + channel])
            }
            let dx0 = Int32(lerp16(rx, dens(X0, Y0), dens(X1, Y0)))
            let dx1 = Int32(lerp16(rx, dens(X0, Y1), dens(X1, Y1)))
            output[channel] = lerp16(ry, dx0, dx1)
        }
    }

    /// `BilinearInterpFloat`.  Floors with the fast floor, where the
    /// three-input float kernels use the real one.
    public static func bilinear(
        _ input: UnsafePointer<Float>,
        _ output: UnsafeMutablePointer<Float>,
        _ table: UnsafePointer<Float>,
        _ grid: InterpolationGrid
    ) {
        let px = clampInterpolationInput(input[0]) * Float(grid.domain[0])
        let py = clampInterpolationInput(input[1]) * Float(grid.domain[1])

        let x0 = Int(quickFloor(Double(px))), fx = px - Float(Int(quickFloor(Double(px))))
        let y0 = Int(quickFloor(Double(py))), fy = py - Float(Int(quickFloor(Double(py))))

        let X0 = Int(grid.opta[1]) * x0
        let X1 = X0 + (clampInterpolationInput(input[0]) >= 1.0 ? 0 : Int(grid.opta[1]))
        let Y0 = Int(grid.opta[0]) * y0
        let Y1 = Y0 + (clampInterpolationInput(input[1]) >= 1.0 ? 0 : Int(grid.opta[0]))

        for channel in 0..<grid.outputs {
            @inline(__always) func dens(_ i: Int, _ j: Int) -> Float {
                table[i + j + channel]
            }
            @inline(__always) func lerp(_ a: Float, _ l: Float, _ h: Float) -> Float {
                l + (h - l) * a
            }
            let dx0 = lerp(fx, dens(X0, Y0), dens(X1, Y0))
            let dx1 = lerp(fx, dens(X0, Y1), dens(X1, Y1))
            output[channel] = lerp(fy, dx0, dx1)
        }
    }

    // -- three inputs ----------------------------------------------------

    /// `TrilinearInterp16`.
    public static func trilinear(
        _ input: UnsafePointer<UInt16>,
        _ output: UnsafeMutablePointer<UInt16>,
        _ table: UnsafePointer<UInt16>,
        _ grid: InterpolationGrid
    ) {
        let fx = toFixedDomain(Int32(input[0]) &* Int32(grid.domain[0]))
        let fy = toFixedDomain(Int32(input[1]) &* Int32(grid.domain[1]))
        let fz = toFixedDomain(Int32(input[2]) &* Int32(grid.domain[2]))

        let rx = fx & 0xFFFF, ry = fy & 0xFFFF, rz = fz & 0xFFFF

        let X0 = Int(grid.opta[2]) * Int(fx >> 16)
        let X1 = X0 + (input[0] == 0xFFFF ? 0 : Int(grid.opta[2]))
        let Y0 = Int(grid.opta[1]) * Int(fy >> 16)
        let Y1 = Y0 + (input[1] == 0xFFFF ? 0 : Int(grid.opta[1]))
        let Z0 = Int(grid.opta[0]) * Int(fz >> 16)
        let Z1 = Z0 + (input[2] == 0xFFFF ? 0 : Int(grid.opta[0]))

        for channel in 0..<grid.outputs {
            @inline(__always) func dens(_ i: Int, _ j: Int, _ k: Int) -> Int32 {
                Int32(table[i + j + k + channel])
            }
            let dx00 = Int32(lerp16(rx, dens(X0, Y0, Z0), dens(X1, Y0, Z0)))
            let dx01 = Int32(lerp16(rx, dens(X0, Y0, Z1), dens(X1, Y0, Z1)))
            let dx10 = Int32(lerp16(rx, dens(X0, Y1, Z0), dens(X1, Y1, Z0)))
            let dx11 = Int32(lerp16(rx, dens(X0, Y1, Z1), dens(X1, Y1, Z1)))

            let dxy0 = Int32(lerp16(ry, dx00, dx10))
            let dxy1 = Int32(lerp16(ry, dx01, dx11))

            output[channel] = lerp16(rz, dxy0, dxy1)
        }
    }

    /// `TrilinearInterpFloat`.
    public static func trilinear(
        _ input: UnsafePointer<Float>,
        _ output: UnsafeMutablePointer<Float>,
        _ table: UnsafePointer<Float>,
        _ grid: InterpolationGrid
    ) {
        let px = clampInterpolationInput(input[0]) * Float(grid.domain[0])
        let py = clampInterpolationInput(input[1]) * Float(grid.domain[1])
        let pz = clampInterpolationInput(input[2]) * Float(grid.domain[2])

        // The real floor here, which the reference calls out.
        let x0 = Int(px.rounded(.down)), fx = px - Float(Int(px.rounded(.down)))
        let y0 = Int(py.rounded(.down)), fy = py - Float(Int(py.rounded(.down)))
        let z0 = Int(pz.rounded(.down)), fz = pz - Float(Int(pz.rounded(.down)))

        let X0 = Int(grid.opta[2]) * x0
        let X1 = X0 + (clampInterpolationInput(input[0]) >= 1.0 ? 0 : Int(grid.opta[2]))
        let Y0 = Int(grid.opta[1]) * y0
        let Y1 = Y0 + (clampInterpolationInput(input[1]) >= 1.0 ? 0 : Int(grid.opta[1]))
        let Z0 = Int(grid.opta[0]) * z0
        let Z1 = Z0 + (clampInterpolationInput(input[2]) >= 1.0 ? 0 : Int(grid.opta[0]))

        for channel in 0..<grid.outputs {
            @inline(__always) func dens(_ i: Int, _ j: Int, _ k: Int) -> Float {
                table[i + j + k + channel]
            }
            @inline(__always) func lerp(_ a: Float, _ l: Float, _ h: Float) -> Float {
                l + (h - l) * a
            }
            let dx00 = lerp(fx, dens(X0, Y0, Z0), dens(X1, Y0, Z0))
            let dx01 = lerp(fx, dens(X0, Y0, Z1), dens(X1, Y0, Z1))
            let dx10 = lerp(fx, dens(X0, Y1, Z0), dens(X1, Y1, Z0))
            let dx11 = lerp(fx, dens(X0, Y1, Z1), dens(X1, Y1, Z1))

            let dxy0 = lerp(fy, dx00, dx10)
            let dxy1 = lerp(fy, dx01, dx11)

            output[channel] = lerp(fz, dxy0, dxy1)
        }
    }

    /// `TetrahedralInterp16`.
    ///
    /// The table pointer is moved to the base cell and the second offsets
    /// are kept as deltas, which is how the reference walks the output
    /// channels with a single incrementing pointer.
    public static func tetrahedral(
        _ input: UnsafePointer<UInt16>,
        _ output: UnsafeMutablePointer<UInt16>,
        _ table: UnsafePointer<UInt16>,
        _ grid: InterpolationGrid
    ) {
        let fx = toFixedDomain(Int32(input[0]) &* Int32(grid.domain[0]))
        let fy = toFixedDomain(Int32(input[1]) &* Int32(grid.domain[1]))
        let fz = toFixedDomain(Int32(input[2]) &* Int32(grid.domain[2]))

        let rx = fx & 0xFFFF, ry = fy & 0xFFFF, rz = fz & 0xFFFF

        let X0 = Int(grid.opta[2]) * Int(fx >> 16)
        var X1 = input[0] == 0xFFFF ? 0 : Int(grid.opta[2])
        let Y0 = Int(grid.opta[1]) * Int(fy >> 16)
        var Y1 = input[1] == 0xFFFF ? 0 : Int(grid.opta[1])
        let Z0 = Int(grid.opta[0]) * Int(fz >> 16)
        var Z1 = input[2] == 0xFFFF ? 0 : Int(grid.opta[0])

        var lut = table + (X0 + Y0 + Z0)

        // Six tetrahedra, each with its own accumulation order.  The
        // differences are taken between neighbours in the order the
        // chosen tetrahedron visits them, which is why every branch
        // subtracts a different pair.
        @inline(__always)
        func run(_ order: (Int32, Int32, Int32, Int32) -> (Int32, Int32, Int32)) {
            for channel in 0..<grid.outputs {
                let c1raw = Int32(lut[X1])
                let c2raw = Int32(lut[Y1])
                let c3raw = Int32(lut[Z1])
                let c0 = Int32(lut[0])
                lut += 1

                let (c1, c2, c3) = order(c0, c1raw, c2raw, c3raw)
                let rest = c1 &* rx &+ c2 &* ry &+ c3 &* rz &+ 0x8001
                output[channel] = tetrahedralRound(c0, rest)
            }
        }

        if rx >= ry {
            if ry >= rz {
                Y1 += X1
                Z1 += Y1
                run { c0, c1, c2, c3 in (c1 &- c0, c2 &- c1, c3 &- c2) }
            } else if rz >= rx {
                X1 += Z1
                Y1 += X1
                run { c0, c1, c2, c3 in (c1 &- c3, c2 &- c1, c3 &- c0) }
            } else {
                Z1 += X1
                Y1 += Z1
                run { c0, c1, c2, c3 in (c1 &- c0, c2 &- c3, c3 &- c1) }
            }
        } else {
            if rx >= rz {
                X1 += Y1
                Z1 += X1
                run { c0, c1, c2, c3 in (c1 &- c2, c2 &- c0, c3 &- c1) }
            } else if ry >= rz {
                Z1 += Y1
                X1 += Z1
                run { c0, c1, c2, c3 in (c1 &- c3, c2 &- c0, c3 &- c2) }
            } else {
                Y1 += Z1
                X1 += Y1
                run { c0, c1, c2, c3 in (c1 &- c2, c2 &- c3, c3 &- c0) }
            }
        }
    }

    /// The tetrahedron selection the float and four-input kernels share,
    /// written as differences between named corners rather than as an
    /// accumulation — the reference spells it this way in both places.
    @inline(__always)
    static func tetrahedralCorners<T: Comparable & SignedNumeric>(
        rx: T, ry: T, rz: T,
        c0: T,
        dens: (Int, Int, Int) -> T,
        _ X0: Int, _ X1: Int, _ Y0: Int, _ Y1: Int, _ Z0: Int, _ Z1: Int
    ) -> (T, T, T) {
        if rx >= ry && ry >= rz {
            return (
                dens(X1, Y0, Z0) - c0,
                dens(X1, Y1, Z0) - dens(X1, Y0, Z0),
                dens(X1, Y1, Z1) - dens(X1, Y1, Z0)
            )
        }
        if rx >= rz && rz >= ry {
            return (
                dens(X1, Y0, Z0) - c0,
                dens(X1, Y1, Z1) - dens(X1, Y0, Z1),
                dens(X1, Y0, Z1) - dens(X1, Y0, Z0)
            )
        }
        if rz >= rx && rx >= ry {
            return (
                dens(X1, Y0, Z1) - dens(X0, Y0, Z1),
                dens(X1, Y1, Z1) - dens(X1, Y0, Z1),
                dens(X0, Y0, Z1) - c0
            )
        }
        if ry >= rx && rx >= rz {
            return (
                dens(X1, Y1, Z0) - dens(X0, Y1, Z0),
                dens(X0, Y1, Z0) - c0,
                dens(X1, Y1, Z1) - dens(X1, Y1, Z0)
            )
        }
        if ry >= rz && rz >= rx {
            return (
                dens(X1, Y1, Z1) - dens(X0, Y1, Z1),
                dens(X0, Y1, Z0) - c0,
                dens(X0, Y1, Z1) - dens(X0, Y1, Z0)
            )
        }
        if rz >= ry && ry >= rx {
            return (
                dens(X1, Y1, Z1) - dens(X0, Y1, Z1),
                dens(X0, Y1, Z1) - dens(X0, Y0, Z1),
                dens(X0, Y0, Z1) - c0
            )
        }
        // The reference keeps this branch though the six above cover
        // every ordering; a NaN would reach it.
        return (0, 0, 0)
    }

    /// `TetrahedralInterpFloat`.
    public static func tetrahedral(
        _ input: UnsafePointer<Float>,
        _ output: UnsafeMutablePointer<Float>,
        _ table: UnsafePointer<Float>,
        _ grid: InterpolationGrid
    ) {
        let px = clampInterpolationInput(input[0]) * Float(grid.domain[0])
        let py = clampInterpolationInput(input[1]) * Float(grid.domain[1])
        let pz = clampInterpolationInput(input[2]) * Float(grid.domain[2])

        let x0 = Int(px.rounded(.down)), rx = px - Float(Int(px.rounded(.down)))
        let y0 = Int(py.rounded(.down)), ry = py - Float(Int(py.rounded(.down)))
        let z0 = Int(pz.rounded(.down)), rz = pz - Float(Int(pz.rounded(.down)))

        let X0 = Int(grid.opta[2]) * x0
        let X1 = X0 + (clampInterpolationInput(input[0]) >= 1.0 ? 0 : Int(grid.opta[2]))
        let Y0 = Int(grid.opta[1]) * y0
        let Y1 = Y0 + (clampInterpolationInput(input[1]) >= 1.0 ? 0 : Int(grid.opta[1]))
        let Z0 = Int(grid.opta[0]) * z0
        let Z1 = Z0 + (clampInterpolationInput(input[2]) >= 1.0 ? 0 : Int(grid.opta[0]))

        for channel in 0..<grid.outputs {
            @inline(__always) func dens(_ i: Int, _ j: Int, _ k: Int) -> Float {
                table[i + j + k + channel]
            }
            let c0 = dens(X0, Y0, Z0)
            let (c1, c2, c3) = tetrahedralCorners(
                rx: rx, ry: ry, rz: rz, c0: c0, dens: dens, X0, X1, Y0, Y1, Z0, Z1
            )
            output[channel] = c0 + c1 * rx + c2 * ry + c3 * rz
        }
    }

    // -- four inputs and beyond -------------------------------------------

    /// `Eval4Inputs`: a tetrahedral read at two planes of the first
    /// input, then a lerp between them.
    public static func eval4(
        _ input: UnsafePointer<UInt16>,
        _ output: UnsafeMutablePointer<UInt16>,
        _ table: UnsafePointer<UInt16>,
        _ grid: InterpolationGrid
    ) {
        let fk = toFixedDomain(Int32(input[0]) &* Int32(grid.domain[0]))
        let fx = toFixedDomain(Int32(input[1]) &* Int32(grid.domain[1]))
        let fy = toFixedDomain(Int32(input[2]) &* Int32(grid.domain[2]))
        let fz = toFixedDomain(Int32(input[3]) &* Int32(grid.domain[3]))

        let rk = fk & 0xFFFF
        let rx = fx & 0xFFFF, ry = fy & 0xFFFF, rz = fz & 0xFFFF

        let K0 = Int(grid.opta[3]) * Int(fk >> 16)
        let K1 = K0 + (input[0] == 0xFFFF ? 0 : Int(grid.opta[3]))

        let X0 = Int(grid.opta[2]) * Int(fx >> 16)
        let X1 = X0 + (input[1] == 0xFFFF ? 0 : Int(grid.opta[2]))
        let Y0 = Int(grid.opta[1]) * Int(fy >> 16)
        let Y1 = Y0 + (input[2] == 0xFFFF ? 0 : Int(grid.opta[1]))
        let Z0 = Int(grid.opta[0]) * Int(fz >> 16)
        let Z1 = Z0 + (input[3] == 0xFFFF ? 0 : Int(grid.opta[0]))

        var first = [UInt16](repeating: 0, count: grid.outputs)
        var second = [UInt16](repeating: 0, count: grid.outputs)

        for (plane, buffer) in [(K0, 0), (K1, 1)] {
            let lut = table + plane
            for channel in 0..<grid.outputs {
                @inline(__always) func dens(_ i: Int, _ j: Int, _ k: Int) -> Int32 {
                    Int32(lut[i + j + k + channel])
                }
                let c0 = dens(X0, Y0, Z0)
                // Selected in fixed point, as the reference does here —
                // the float form of this lives in the float kernel.
                let (c1, c2, c3) = tetrahedralCorners(
                    rx: rx, ry: ry, rz: rz, c0: c0, dens: dens,
                    X0, X1, Y0, Y1, Z0, Z1
                )
                let rest = c1 &* rx &+ c2 &* ry &+ c3 &* rz &+ 0x8001
                let value = tetrahedralRound(c0, rest)
                if buffer == 0 { first[channel] = value } else { second[channel] = value }
            }
        }

        for i in 0..<grid.outputs {
            output[i] = linearInterpolate(rk, Int32(first[i]), Int32(second[i]))
        }
    }

    /// `Eval4InputsFloat`.
    public static func eval4(
        _ input: UnsafePointer<Float>,
        _ output: UnsafeMutablePointer<Float>,
        _ table: UnsafePointer<Float>,
        _ grid: InterpolationGrid
    ) {
        let clamped = clampInterpolationInput(input[0])
        let pk = clamped * Float(grid.domain[0])
        let k0 = Int(quickFloor(Double(pk)))
        let rest = pk - Float(k0)

        let K0 = Int(grid.opta[3]) * k0
        let K1 = K0 + (clamped >= 1.0 ? 0 : Int(grid.opta[3]))

        let inner = grid.droppingFirstInput()
        var first = [Float](repeating: 0, count: grid.outputs)
        var second = [Float](repeating: 0, count: grid.outputs)

        first.withUnsafeMutableBufferPointer {
            tetrahedral(input + 1, $0.baseAddress!, table + K0, inner)
        }
        second.withUnsafeMutableBufferPointer {
            tetrahedral(input + 1, $0.baseAddress!, table + K1, inner)
        }

        for i in 0..<grid.outputs {
            output[i] = first[i] + (second[i] - first[i]) * rest
        }
    }

    /// The evaluator for five inputs and up, which the reference writes
    /// once as a macro and expands eleven times: split on the first
    /// input, evaluate the remainder twice, and lerp.
    public static func evalMany(
        _ input: UnsafePointer<UInt16>,
        _ output: UnsafeMutablePointer<UInt16>,
        _ table: UnsafePointer<UInt16>,
        _ grid: InterpolationGrid
    ) {
        let fk = toFixedDomain(Int32(input[0]) &* Int32(grid.domain[0]))
        let k0 = Int(fk >> 16)
        let rk = fk & 0xFFFF

        let stride = Int(grid.opta[grid.inputs - 1])
        let K0 = stride * k0
        let K1 = stride * (k0 + (input[0] != 0xFFFF ? 1 : 0))

        var inner = grid.droppingFirstInput()
        inner.inputs = grid.inputs - 1

        var first = [UInt16](repeating: 0, count: grid.outputs)
        var second = [UInt16](repeating: 0, count: grid.outputs)

        first.withUnsafeMutableBufferPointer {
            evaluate(input + 1, $0.baseAddress!, table + K0, inner)
        }
        second.withUnsafeMutableBufferPointer {
            evaluate(input + 1, $0.baseAddress!, table + K1, inner)
        }

        for i in 0..<grid.outputs {
            output[i] = linearInterpolate(rk, Int32(first[i]), Int32(second[i]))
        }
    }

    /// The float counterpart.
    public static func evalMany(
        _ input: UnsafePointer<Float>,
        _ output: UnsafeMutablePointer<Float>,
        _ table: UnsafePointer<Float>,
        _ grid: InterpolationGrid
    ) {
        let clamped = clampInterpolationInput(input[0])
        let pk = clamped * Float(grid.domain[0])
        let k0 = Int(quickFloor(Double(pk)))
        let rest = pk - Float(k0)

        let stride = Int(grid.opta[grid.inputs - 1])
        let K0 = stride * k0
        let K1 = K0 + (clamped >= 1.0 ? 0 : stride)

        var inner = grid.droppingFirstInput()
        inner.inputs = grid.inputs - 1

        var first = [Float](repeating: 0, count: grid.outputs)
        var second = [Float](repeating: 0, count: grid.outputs)

        first.withUnsafeMutableBufferPointer {
            evaluate(input + 1, $0.baseAddress!, table + K0, inner)
        }
        second.withUnsafeMutableBufferPointer {
            evaluate(input + 1, $0.baseAddress!, table + K1, inner)
        }

        for i in 0..<grid.outputs {
            output[i] = first[i] + (second[i] - first[i]) * rest
        }
    }

    // -- the dispatch -----------------------------------------------------

    /// Chooses a kernel the way `DefaultInterpolatorsFactory` does.  A
    /// combination it will not serve answers false, and the caller then
    /// has no interpolation at all.
    public static func isSupported(inputs: Int, outputs: Int, trilinear: Bool) -> Bool {
        // The reference's own guard against a grid too large to address.
        if inputs >= 4 && outputs >= maximumStageChannels { return false }
        return inputs >= 1 && inputs <= 15
    }

    /// The 16-bit entry point, dispatching on the grid's shape.
    public static func evaluate(
        _ input: UnsafePointer<UInt16>,
        _ output: UnsafeMutablePointer<UInt16>,
        _ table: UnsafePointer<UInt16>,
        _ grid: InterpolationGrid,
        trilinear useTrilinear: Bool = false
    ) {
        switch grid.inputs {
        case 1:
            if grid.outputs == 1 {
                output[0] = Interpolation1D.lookup(input[0], table: table, domain: grid.domain[0])
            } else {
                eval1(input, output, table, grid)
            }
        case 2:
            bilinear(input, output, table, grid)
        case 3:
            if useTrilinear {
                self.trilinear(input, output, table, grid)
            } else {
                tetrahedral(input, output, table, grid)
            }
        case 4:
            eval4(input, output, table, grid)
        default:
            evalMany(input, output, table, grid)
        }
    }

    /// The float entry point.
    public static func evaluate(
        _ input: UnsafePointer<Float>,
        _ output: UnsafeMutablePointer<Float>,
        _ table: UnsafePointer<Float>,
        _ grid: InterpolationGrid,
        trilinear useTrilinear: Bool = false
    ) {
        switch grid.inputs {
        case 1:
            if grid.outputs == 1 {
                output[0] = Interpolation1D.lookup(input[0], table: table, domain: grid.domain[0])
            } else {
                eval1(input, output, table, grid)
            }
        case 2:
            bilinear(input, output, table, grid)
        case 3:
            if useTrilinear {
                self.trilinear(input, output, table, grid)
            } else {
                tetrahedral(input, output, table, grid)
            }
        case 4:
            eval4(input, output, table, grid)
        default:
            evalMany(input, output, table, grid)
        }
    }
}
