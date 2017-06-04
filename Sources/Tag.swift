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

internal extension Profile {
    
    /// Reads the tag value and attempts to get value from pointer.
    func readCasting<Value>(_ tag: Tag) -> Value? {
        
        guard let buffer = cmsReadTag(internalPointer, tag)
            else { return nil }
        
        let pointer = buffer.assumingMemoryBound(to: Value.self)
        
        return pointer[0]
    }
    
    /// Get the object internal handle and returns a duplicated object.
    func readObject<Value: CopyableHandle>(_ tag: Tag) -> Value? {
        
        guard let internalPointer = readCasting(tag) as Value.InternalPointer?, // get internal pointer / handle
            let newInternalPointer = Value.cmsDuplicate(internalPointer) // create copy to not corrupt handle internals
            else { return nil }
        
        return Value(newInternalPointer)
    }
}

// MARK: - Tag List

public extension Profile {
    
    public var aToB0: Pipeline? {
        
        return readObject(cmsSigAToB0Tag)
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
