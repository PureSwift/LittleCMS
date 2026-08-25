import CLCMS2
import LittleCMSCore

// Vectors and matrices.
//
// cmsVEC3 and cmsMAT3 are declared in the plugin header and callers
// construct them, so their layout is contract.  The engine's Vector3 and
// Matrix3 mirror it, and every function here rebinds memory between the
// two — which is only sound while the layouts agree.  That agreement is
// checked against the imported C types in Tests/LittleCMSTests/
// LayoutTests.swift, which runs on every platform CI builds for.

extension UnsafePointer<cmsVEC3> {
    @inline(__always)
    var vector: Vector3 {
        withMemoryRebound(to: Vector3.self, capacity: 1) { $0.pointee }
    }
}

extension UnsafeMutablePointer<cmsVEC3> {
    @inline(__always)
    var vector: Vector3 {
        get { withMemoryRebound(to: Vector3.self, capacity: 1) { $0.pointee } }
        nonmutating set {
            withMemoryRebound(to: Vector3.self, capacity: 1) { $0.pointee = newValue }
        }
    }
}

extension UnsafePointer<cmsMAT3> {
    @inline(__always)
    var matrix: Matrix3 {
        withMemoryRebound(to: Matrix3.self, capacity: 1) { $0.pointee }
    }
}

extension UnsafeMutablePointer<cmsMAT3> {
    @inline(__always)
    var matrix: Matrix3 {
        get { withMemoryRebound(to: Matrix3.self, capacity: 1) { $0.pointee } }
        nonmutating set {
            withMemoryRebound(to: Matrix3.self, capacity: 1) { $0.pointee = newValue }
        }
    }
}

// -- vectors -----------------------------------------------------------

@c @implementation
public func _cmsVEC3init(
    _ r: UnsafeMutablePointer<cmsVEC3>?,
    _ x: cmsFloat64Number, _ y: cmsFloat64Number, _ z: cmsFloat64Number
) {
    guard let r else { return }
    r.vector = Vector3(x, y, z)
}

@c @implementation
public func _cmsVEC3minus(
    _ r: UnsafeMutablePointer<cmsVEC3>?,
    _ a: UnsafePointer<cmsVEC3>?,
    _ b: UnsafePointer<cmsVEC3>?
) {
    guard let r, let a, let b else { return }
    r.vector = a.vector - b.vector
}

@c @implementation
public func _cmsVEC3cross(
    _ r: UnsafeMutablePointer<cmsVEC3>?,
    _ u: UnsafePointer<cmsVEC3>?,
    _ v: UnsafePointer<cmsVEC3>?
) {
    guard let r, let u, let v else { return }
    r.vector = u.vector.cross(v.vector)
}

@c @implementation
public func _cmsVEC3dot(
    _ u: UnsafePointer<cmsVEC3>?,
    _ v: UnsafePointer<cmsVEC3>?
) -> cmsFloat64Number {
    guard let u, let v else { return 0 }
    return u.vector.dot(v.vector)
}

@c @implementation
public func _cmsVEC3length(_ a: UnsafePointer<cmsVEC3>?) -> cmsFloat64Number {
    guard let a else { return 0 }
    return a.vector.length
}

@c @implementation
public func _cmsVEC3distance(
    _ a: UnsafePointer<cmsVEC3>?,
    _ b: UnsafePointer<cmsVEC3>?
) -> cmsFloat64Number {
    guard let a, let b else { return 0 }
    return a.vector.distance(to: b.vector)
}

// -- matrices ----------------------------------------------------------

@c @implementation
public func _cmsMAT3identity(_ a: UnsafeMutablePointer<cmsMAT3>?) {
    guard let a else { return }
    a.matrix = .identity
}

@c @implementation
public func _cmsMAT3isIdentity(_ a: UnsafePointer<cmsMAT3>?) -> cmsBool {
    guard let a else { return 0 }
    return a.matrix.isIdentity ? 1 : 0
}

@c @implementation
public func _cmsMAT3per(
    _ r: UnsafeMutablePointer<cmsMAT3>?,
    _ a: UnsafePointer<cmsMAT3>?,
    _ b: UnsafePointer<cmsMAT3>?
) {
    guard let r, let a, let b else { return }
    r.matrix = a.matrix * b.matrix
}

@c @implementation
public func _cmsMAT3inverse(
    _ a: UnsafePointer<cmsMAT3>?,
    _ b: UnsafeMutablePointer<cmsMAT3>?
) -> cmsBool {
    guard let a, let b, let inverse = a.matrix.inverse else { return 0 }
    b.matrix = inverse
    return 1
}

@c @implementation
public func _cmsMAT3solve(
    _ x: UnsafeMutablePointer<cmsVEC3>?,
    _ a: UnsafeMutablePointer<cmsMAT3>?,
    _ b: UnsafeMutablePointer<cmsVEC3>?
) -> cmsBool {
    // The reference takes `a` and `b` mutable although it only reads them,
    // and copies `a` before inverting; the declaration keeps that shape.
    guard let x, let a, let b, let solution = a.matrix.solve(b.vector) else { return 0 }
    x.vector = solution
    return 1
}

@c @implementation
public func _cmsMAT3eval(
    _ r: UnsafeMutablePointer<cmsVEC3>?,
    _ a: UnsafePointer<cmsMAT3>?,
    _ v: UnsafePointer<cmsVEC3>?
) {
    guard let r, let a, let v else { return }
    r.vector = a.matrix.evaluate(v.vector)
}
