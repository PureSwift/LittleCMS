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
    
    public init() {
        
        //self.internalPointer = cmsCreateTransform(<#T##Input: cmsHPROFILE!##cmsHPROFILE!#>, <#T##InputFormat: cmsUInt32Number##cmsUInt32Number#>, <#T##Output: cmsHPROFILE!##cmsHPROFILE!#>, <#T##OutputFormat: cmsUInt32Number##cmsUInt32Number#>, <#T##Intent: cmsUInt32Number##cmsUInt32Number#>, <#T##dwFlags: cmsUInt32Number##cmsUInt32Number#>)
    }
    
    // MARK: - Accessors
    
    public var context: Context? {
        
        guard let internalPointer = cmsGetTransformContextID(self.internalPointer)
            else { return nil }
        
        return cmsGetSwiftContext(internalPointer)
    }
}
