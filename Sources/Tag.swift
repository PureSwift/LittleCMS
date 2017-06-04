//
//  Tag.swift
//  LittleCMS
//
//  Created by Alsey Coleman Miller on 6/4/17.
//
//

import struct Foundation.Data
import CLCMS

public typealias Tag = cmsTagSignature

public extension Tag {
    
    var isValid: Bool {
        
        return self.rawValue != 0
    }
}

public protocol TagValue {
    
    associatedtype Value
    
    static var tag: Tag { get }
    
    init(data: Data)
    
    var value: Value { get }
}

/// Parses `cmsCIEXYZ` tag value.
public protocol CIEXYZTag {
    
    
}

public extension Tag {
    
    
}
