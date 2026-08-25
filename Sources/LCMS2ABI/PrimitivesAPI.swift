import CLCMS2
import LittleCMSCore

// The arithmetic primitives.  Pure functions with no context, no
// allocation, and no failure mode, so each is a direct forward to the
// engine — the boundary's error conventions have nothing to do here.

// -- fixed point -------------------------------------------------------

@c @implementation
public func _cms15Fixed16toDouble(_ fix32: cmsS15Fixed16Number) -> cmsFloat64Number {
    S15Fixed16.toDouble(fix32)
}

@c @implementation
public func _cmsDoubleTo15Fixed16(_ v: cmsFloat64Number) -> cmsS15Fixed16Number {
    S15Fixed16.fromDouble(v)
}

@c @implementation
public func _cms8Fixed8toDouble(_ fixed8: cmsUInt16Number) -> cmsFloat64Number {
    U8Fixed8.toDouble(fixed8)
}

@c @implementation
public func _cmsDoubleTo8Fixed8(_ val: cmsFloat64Number) -> cmsUInt16Number {
    U8Fixed8.fromDouble(val)
}

@c @implementation
public func _cmsQuantizeVal(_ i: cmsFloat64Number, _ MaxSamples: cmsUInt32Number) -> cmsUInt16Number {
    quantizeValue(i, maxSamples: MaxSamples)
}

// -- byte order --------------------------------------------------------

@c @implementation
public func _cmsAdjustEndianess16(_ Word: cmsUInt16Number) -> cmsUInt16Number {
    adjustEndianness(Word)
}

@c @implementation
public func _cmsAdjustEndianess32(_ Value: cmsUInt32Number) -> cmsUInt32Number {
    adjustEndianness(Value)
}

@c @implementation
public func _cmsAdjustEndianess64(
    _ Result: UnsafeMutablePointer<cmsUInt64Number>?,
    _ QWord: UnsafeMutablePointer<cmsUInt64Number>?
) {
    // The reference asserts on a null destination and reads the source
    // unguarded; it also takes the source by non-const pointer despite
    // only reading it, which the declaration preserves.
    //
    // cmsUInt64Number is `unsigned long` in the vendored header, so it
    // imports as UInt rather than UInt64.  The platform spelling belongs
    // here, at the boundary, and not in the engine.
    guard let Result, let QWord else { return }
    Result.pointee = cmsUInt64Number(adjustEndianness(UInt64(QWord.pointee)))
}

// -- half precision ----------------------------------------------------

@c @implementation
public func _cmsHalf2Float(_ h: cmsUInt16Number) -> cmsFloat32Number {
    halfToFloat(h)
}

@c @implementation
public func _cmsFloat2Half(_ flt: cmsFloat32Number) -> cmsUInt16Number {
    floatToHalf(flt)
}
