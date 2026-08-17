// The C math functions, in one place.
//
// The colour transforms need pow, the trigonometric pair, and the
// logarithms, and where those come from differs by platform.  Hosted
// builds import the platform's C library.  Embedded Swift has no C library
// to import, so they are declared and left for the link to resolve —
// which is the same bargain the engine already makes for its allocator:
// the firmware brings a libm (newlib's, usually) exactly as it brings a
// malloc, and these appear as ordinary undefined symbols until it does.
//
// Not reimplemented as series approximations, deliberately.  The values
// these produce are compared against the reference bit for bit, and the
// reference calls libm; anything else would be a different library that
// happened to be close.

#if hasFeature(Embedded)

@_extern(c) @usableFromInline func pow(_ x: Double, _ y: Double) -> Double
@_extern(c) @usableFromInline func cos(_ x: Double) -> Double
@_extern(c) @usableFromInline func sin(_ x: Double) -> Double
@_extern(c) @usableFromInline func atan2(_ y: Double, _ x: Double) -> Double
@_extern(c) @usableFromInline func exp(_ x: Double) -> Double
@_extern(c) @usableFromInline func log(_ x: Double) -> Double
@_extern(c) @usableFromInline func log10(_ x: Double) -> Double

#elseif canImport(Darwin)
@_exported import func Darwin.pow
@_exported import func Darwin.cos
@_exported import func Darwin.sin
@_exported import func Darwin.atan2
@_exported import func Darwin.exp
@_exported import func Darwin.log
@_exported import func Darwin.log10
#elseif canImport(Glibc)
@_exported import func Glibc.pow
@_exported import func Glibc.cos
@_exported import func Glibc.sin
@_exported import func Glibc.atan2
@_exported import func Glibc.exp
@_exported import func Glibc.log
@_exported import func Glibc.log10
#elseif canImport(Musl)
@_exported import func Musl.pow
@_exported import func Musl.cos
@_exported import func Musl.sin
@_exported import func Musl.atan2
@_exported import func Musl.exp
@_exported import func Musl.log
@_exported import func Musl.log10
#endif
