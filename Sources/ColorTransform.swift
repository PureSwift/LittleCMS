//
//  ColorTransform.swift
//  LittleCMS
//
//  Created by Alsey Coleman Miller on 6/3/17.
//
//

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
    
    public init(input: (profile: Profile, format: UInt),
                output: (profile: Profile, format: UInt),
                intent: cmsUInt32Number,
                flags: cmsUInt32Number) {
        
        self.internalPointer = cmsCreateTransform(input.profile.internalPointer,
                                                  cmsUInt32Number(input.format),
                                                  output.profile.internalPointer,
                                                  cmsUInt32Number(output.format),
                                                  intent,
                                                  flags)
    }
    
    // MARK: - Accessors
    
    public var context: Context? {
        
        guard let internalPointer = cmsGetTransformContextID(self.internalPointer)
            else { return nil }
        
        return cmsGetSwiftContext(internalPointer)
    }
}
