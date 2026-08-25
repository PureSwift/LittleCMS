import CLCMS2
import LittleCMSCore

// The CIECAM02 handle: a model set up once for its viewing conditions.

final class CIECAM02Box {
    let context: cmsContext?
    let model: CIECAM02
    init(context: cmsContext?, model: CIECAM02) {
        self.context = context
        self.model = model
    }
}

@inline(__always)
private func box(_ h: cmsHANDLE?) -> CIECAM02Box? {
    guard let h else { return nil }
    return Unmanaged<CIECAM02Box>.fromOpaque(h).takeUnretainedValue()
}

@c @implementation
public func cmsCIECAM02Init(_ ContextID: cmsContext?, _ pVC: UnsafePointer<cmsViewingConditions>?) -> cmsHANDLE? {
    guard let pVC else { return nil }
    let vc = pVC.pointee
    let conditions = ViewingConditions(
        whitePoint: engine(vc.whitePoint), yb: vc.Yb, la: vc.La, surround: vc.surround, d: vc.D_value
    )
    return Unmanaged.passRetained(CIECAM02Box(context: ContextID, model: CIECAM02(conditions))).toOpaque()
}

@c @implementation
public func cmsCIECAM02Done(_ hModel: cmsHANDLE?) {
    guard let hModel else { return }
    _ = Unmanaged<CIECAM02Box>.fromOpaque(hModel).takeRetainedValue()
}

@c @implementation
public func cmsCIECAM02Forward(_ hModel: cmsHANDLE?, _ pIn: UnsafePointer<cmsCIEXYZ>?, _ pOut: UnsafeMutablePointer<cmsJCh>?) {
    guard let b = box(hModel), let pIn, let pOut else { return }
    let jch = b.model.forward(engine(pIn.pointee))
    pOut.pointee = cmsJCh(J: jch.j, C: jch.c, h: jch.h)
}

@c @implementation
public func cmsCIECAM02Reverse(_ hModel: cmsHANDLE?, _ pIn: UnsafePointer<cmsJCh>?, _ pOut: UnsafeMutablePointer<cmsCIEXYZ>?) {
    guard let b = box(hModel), let pIn, let pOut else { return }
    let xyz = b.model.reverse(CIEJCh(j: pIn.pointee.J, c: pIn.pointee.C, h: pIn.pointee.h))
    pOut.pointee = abi(xyz)
}
