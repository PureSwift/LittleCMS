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

// MARK: - Parsing

/// Swift objects that can be parse as tag values
internal protocol TagObjectConvertible: class {
    
    associatedtype InternalPointer
    
    init(_ internalPointer: InternalPointer)
    
    associatedtype InternalPointer
}

internal extension Profile {
    
    func readCasting<Value>(_ tag: Tag) -> Value? {
        
        guard let buffer = cmsReadTag(internalPointer, tag)
            else { return nil }
        
        let pointer = buffer.assumingMemoryBound(to: Value.self)
        
        return pointer[0]
    }
    
    func readCopying<Value: TagObjectConvertible>(_ tag: Tag) -> Value? {
        
        guard let internalPointer = readCasting(tag) as Value
            else { return nil }
        
        return Value(internalPointer).copy
    }
}

// MARK: - Tag List

public extension Profile {
    
    public var aToB0: Pipeline? {
        
        
    }
    
    /// Tag: `cmsSigBlueColorantTag`
    ///
    /// Identifier: `0x6258595A` `'bXYZ'`
    ///
    /// Value: `cmsCIEXYZ`
    public var blueColorant: cmsCIEXYZ? {
        
        return readCasting(cmsSigBlueColorantTag)
    }
}
