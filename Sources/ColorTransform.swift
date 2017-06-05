//
//  ColorTransform.swift
//  LittleCMS
//
//  Created by Alsey Coleman Miller on 6/3/17.
//
//

import struct Foundation.Data
import CLCMS

public final class ColorTransform {
    
    // MARK: - Properties
    
    internal let internalPointer: cmsHTRANSFORM
    
    // MARK: - Initialization
    
    deinit {
        
        cmsDeleteTransform(internalPointer)
    }
    
    internal init(_ internalPointer: cmsHTRANSFORM) {
        
        self.internalPointer = internalPointer
    }
    
    /*
    /// Creates a color transform for translating bitmaps.
    public init?(input: (profile: Profile, format: UInt),
                output: (profile: Profile, format: UInt),
                intent: cmsUInt32Number,
                flags: cmsUInt32Number,
                context: Context? = nil) {
        
        // TODO: cmsCreateExtendedTransform
        
        guard let internalPointer = cmsCreateTransformTHR(context?.internalPointer,
                                                     input.profile.internalPointer,
                                                     cmsUInt32Number(input.format),
                                                     output.profile.internalPointer,
                                                     cmsUInt32Number(output.format),
                                                     intent,
                                                     flags)
            else { return nil }
        
        self.internalPointer = internalPointer
    }*/
    
    // MARK: - Methods
    
    /// Translates bitmaps according of parameters setup when creating the color transform.
    public func transform(_ bitmap: Data) -> Data {
        
        // FIXME
        return Data()
    }
}

extension ColorTransform: ContextualHandle {
    static var cmsGetContextID: cmsGetContextIDFunction { return cmsGetTransformContextID }
}
