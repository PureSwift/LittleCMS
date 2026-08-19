import CLCMS2
import LittleCMS

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// The gamut boundary descriptor: a sphere around Lab (50, 0, 0) cut
// into 16 by 16 sectors, each holding the farthest point seen in it.
// Points are added, the empty sectors are filled in from their
// neighbours, and a colour is then in gamut when it lies within its
// sector's radius.

private let sectors = 16
private let determinantTolerance = 0.0001

private struct Spherical {
    var r = 0.0
    var alpha = 0.0
    var theta = 0.0
}

private enum PointType { case empty, specified, modeled }

private struct GBDPoint {
    var type: PointType = .empty
    var p = Spherical()
}

private struct Line {
    var a: Vector3
    var u: Vector3
}

final class GamutBoundaryBox {
    let context: cmsContext?
    fileprivate var gamut = [[GBDPoint]](repeating: [GBDPoint](repeating: GBDPoint(), count: sectors), count: sectors)
    init(context: cmsContext?) { self.context = context }
}

@inline(__always)
private func gbd(_ h: cmsHANDLE?) -> GamutBoundaryBox? {
    guard let h else { return nil }
    return Unmanaged<GamutBoundaryBox>.fromOpaque(h).takeUnretainedValue()
}

/// atan2 in degrees, 0..360.
private func atan2Positive(_ y: Double, _ x: Double) -> Double {
    if x == 0.0 && y == 0.0 { return 0 }
    var a = (atan2(y, x) * 180.0) / Double.pi
    while a < 0 { a += 360 }
    return a
}

private func toSpherical(_ v: Vector3) -> Spherical {
    let l = v.x, a = v.y, b = v.z
    var sp = Spherical()
    sp.r = (l * l + a * a + b * b).squareRoot()
    if sp.r == 0 { return sp }
    sp.alpha = atan2Positive(a, b)
    sp.theta = atan2Positive((a * a + b * b).squareRoot(), l)
    return sp
}

private func toCartesian(_ sp: Spherical) -> Vector3 {
    let sinAlpha = sin((Double.pi * sp.alpha) / 180.0)
    let cosAlpha = cos((Double.pi * sp.alpha) / 180.0)
    let sinTheta = sin((Double.pi * sp.theta) / 180.0)
    let cosTheta = cos((Double.pi * sp.theta) / 180.0)
    let a = sp.r * sinTheta * sinAlpha
    let b = sp.r * sinTheta * cosAlpha
    let l = sp.r * cosTheta
    return Vector3(l, a, b)
}

private func quantizeToSector(_ sp: Spherical) -> (alpha: Int, theta: Int) {
    var alpha = Int(((sp.alpha * Double(sectors)) / 360.0).rounded(.down))
    var theta = Int(((sp.theta * Double(sectors)) / 180.0).rounded(.down))
    if alpha >= sectors { alpha = sectors - 1 }
    if theta >= sectors { theta = sectors - 1 }
    return (alpha, theta)
}

private func lineOf2Points(_ a: Vector3, _ b: Vector3) -> Line {
    Line(a: a, u: Vector3(b.x - a.x, b.y - a.y, b.z - a.z))
}

private func pointOfLine(_ line: Line, _ t: Double) -> Vector3 {
    Vector3(line.a.x + t * line.u.x, line.a.y + t * line.u.y, line.a.z + t * line.u.z)
}

/// The closest point on segment `line1` to segment `line2` — the
/// softSurfer algorithm the reference uses, kept in its arithmetic.
private func closestLineToLine(_ line1: Line, _ line2: Line) -> Vector3 {
    let w0 = line1.a - line2.a
    let a = line1.u.dot(line1.u)
    let b = line1.u.dot(line2.u)
    let c = line2.u.dot(line2.u)
    let d = line1.u.dot(w0)
    let e = line2.u.dot(w0)
    let D = a * c - b * b
    var sN: Double, sD = D
    var tN: Double, tD = D

    if D < determinantTolerance {
        sN = 0.0
        sD = 1.0
        tN = e
        tD = c
    } else {
        sN = (b * e - c * d)
        tN = (a * e - b * d)
        if sN < 0.0 {
            sN = 0.0
            tN = e
            tD = c
        } else if sN > sD {
            sN = sD
            tN = e + b
            tD = c
        }
    }

    if tN < 0.0 {
        tN = 0.0
        if -d < 0.0 {
            sN = 0.0
        } else if -d > a {
            sN = sD
        } else {
            sN = -d
            sD = a
        }
    } else if tN > tD {
        tN = tD
        if (-d + b) < 0.0 {
            sN = 0
        } else if (-d + b) > a {
            sN = sD
        } else {
            sN = (-d + b)
            sD = a
        }
    }
    let sc = sN.magnitude < determinantTolerance ? 0.0 : sN / sD
    return pointOfLine(line1, sc)
}

@c @implementation
public func cmsGBDAlloc(_ ContextID: cmsContext?) -> cmsHANDLE? {
    Unmanaged.passRetained(GamutBoundaryBox(context: ContextID)).toOpaque()
}

@c @implementation
public func cmsGBDFree(_ hGBD: cmsHANDLE?) {
    guard let hGBD else { return }
    _ = Unmanaged<GamutBoundaryBox>.fromOpaque(hGBD).takeRetainedValue()
}

extension GamutBoundaryBox {
    /// The sector a Lab value falls in, and its spherical form around
    /// the centre.
    fileprivate func locate(_ lab: cmsCIELab) -> (alpha: Int, theta: Int, sp: Spherical)? {
        let sp = toSpherical(Vector3(lab.L - 50.0, lab.a, lab.b))
        if sp.r < 0 || sp.alpha < 0 || sp.theta < 0 {
            report(cmsUInt32Number(cmsERROR_RANGE), "spherical value out of range", to: context)
            return nil
        }
        let (alpha, theta) = quantizeToSector(sp)
        if alpha < 0 || theta < 0 || alpha >= sectors || theta >= sectors {
            report(cmsUInt32Number(cmsERROR_RANGE), " quadrant out of range", to: context)
            return nil
        }
        return (alpha, theta, sp)
    }
}

@c @implementation
public func cmsGDBAddPoint(_ hGBD: cmsHANDLE?, _ Lab: UnsafePointer<cmsCIELab>?) -> cmsBool {
    guard let box = gbd(hGBD), let Lab, let (alpha, theta, sp) = box.locate(Lab.pointee) else { return 0 }
    var point = box.gamut[theta][alpha]
    if point.type == .empty {
        point.type = .specified
        point.p = sp
    } else if sp.r > point.p.r {
        point.type = .specified
        point.p = sp
    }
    box.gamut[theta][alpha] = point
    return 1
}

@c @implementation
public func cmsGDBCheckPoint(_ hGBD: cmsHANDLE?, _ Lab: UnsafePointer<cmsCIELab>?) -> cmsBool {
    guard let box = gbd(hGBD), let Lab, let (alpha, theta, sp) = box.locate(Lab.pointee) else { return 0 }
    let point = box.gamut[theta][alpha]
    if point.type == .empty { return 0 }
    return sp.r <= point.p.r ? 1 : 0
}

/// The neighbourhood walked outward, in the reference's order.
private let spiral: [(Int, Int)] = [
    (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1),
    (-1, 0), (-1, -1), (-1, -2), (0, -2), (1, -2), (2, -2),
    (2, -1), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2),
    (-1, 2), (-2, 2), (-2, 1), (-2, 0), (-2, -1), (-2, -2),
]

extension GamutBoundaryBox {
    fileprivate func nearSectors(_ alpha: Int, _ theta: Int) -> [GBDPoint] {
        var close: [GBDPoint] = []
        for (dx, dy) in spiral {
            var a = (alpha + dx) % sectors
            var t = (theta + dy) % sectors
            if a < 0 { a = sectors + a }
            if t < 0 { t = sectors + t }
            let pt = gamut[t][a]
            if pt.type != .empty { close.append(pt) }
        }
        return close
    }

    /// An empty sector takes the farthest point at which a ray through
    /// its centre meets an edge between two of its neighbours, within
    /// the sector's own bounds.
    fileprivate func interpolateMissingSector(_ alpha: Int, _ theta: Int) {
        if gamut[theta][alpha].type != .empty { return }
        let close = nearSectors(alpha, theta)

        var sp = Spherical()
        sp.alpha = (Double(alpha) + 0.5) * 360.0 / Double(sectors)
        sp.theta = (Double(theta) + 0.5) * 180.0 / Double(sectors)
        sp.r = 50.0
        let lab = toCartesian(sp)
        let centre = Vector3(50.0, 0, 0)
        let ray = lineOf2Points(lab, centre)

        var closel = Spherical()
        for k in 0..<close.count {
            for m in (k + 1)..<close.count {
                let a1 = toCartesian(close[k].p)
                let a2 = toCartesian(close[m].p)
                let edge = lineOf2Points(a1, a2)
                let temp = closestLineToLine(ray, edge)
                let templ = toSpherical(temp)
                if templ.r > closel.r
                    && templ.theta >= (Double(theta) * 180.0 / Double(sectors))
                    && templ.theta <= (Double(theta + 1) * 180.0 / Double(sectors))
                    && templ.alpha >= (Double(alpha) * 360.0 / Double(sectors))
                    && templ.alpha <= (Double(alpha + 1) * 360.0 / Double(sectors))
                {
                    closel = templ
                }
            }
        }
        gamut[theta][alpha].p = closel
        gamut[theta][alpha].type = .modeled
    }
}

@c @implementation
public func cmsGDBCompute(_ hGBD: cmsHANDLE?, _ dwFlags: cmsUInt32Number) -> cmsBool {
    guard let box = gbd(hGBD) else { return 0 }
    // The poles first, then everything between.
    for alpha in 0..<sectors { box.interpolateMissingSector(alpha, 0) }
    for alpha in 0..<sectors { box.interpolateMissingSector(alpha, sectors - 1) }
    for theta in 1..<sectors {
        for alpha in 0..<sectors { box.interpolateMissingSector(alpha, theta) }
    }
    return 1
}
