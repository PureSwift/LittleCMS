//
//  Tag.swift
//  LittleCMS
//
//  Created by Alsey Coleman Miller on 6/4/17.
//
//

import struct Foundation.Data
import CLCMS

// MARK: - Tag Signature

public typealias Tag = cmsTagSignature

public extension Tag {
    
    var isValid: Bool {
        
        return self.rawValue != 0
    }
}

// MARK: - Tag View

public extension Profile {
    
    /// A collection of the profile's tags.
    public var tags: TagView {
        
        get { return TagView(profile: self) }
        
        set {
            
            // set new tags
            
        }
    }
    
    /// A representation of the profile's contents as a collection of tags.
    public struct TagView {
        
        // MARK: - Properties
        
        internal private(set) var internalReference: CopyOnWrite<Profile.Reference>
        
        // MARK: - Initialization
        
        internal init(_ internalReference: Profile.Reference) {
            
            self.internalReference = CopyOnWrite(internalReference)
        }
        
        /// Create from the specified profile.
        public init(profile: Profile) {
            
            self.init(profile.internalReference.reference)
        }
        
        // MARK: - Accessors
        
        public var count: Int {
            
            return internalReference.reference.tagCount
        }
    }
}

// MARK: - Collection

// MARK: - Supporting Type

// MARK: - Parsing

internal extension Profile.TagView {
    
    /// Reads the tag value and attempts to get value from pointer.
    func readCasting<Value>(_ tag: Tag) -> Value? {
        
        let internalPointer = self.internalReference.reference.internalPointer
        
        guard let buffer = cmsReadTag(internalPointer, tag)
            else { return nil }
        
        let pointer = buffer.assumingMemoryBound(to: Value.self)
        
        return pointer[0]
    }
    
    /// Get the object internal handle and return a duplicated object.
    func readObject<Value: DuplicableHandle>(_ tag: Tag) -> Value? {
        
        guard let internalPointer = readCasting(tag) as Value.InternalPointer?, // get internal pointer / handle
            let newInternalPointer = Value.cmsDuplicate(internalPointer) // create copy to not corrupt handle internals
            else { return nil }
        
        return Value(newInternalPointer)
    }
    
    /// Get the object internal handle and return a reference-backed value type.
    func readStruct<Value>(_ tag: Tag) -> Value?
        where Value: ReferenceConvertible, Value.Reference: DuplicableHandle {
        
        guard let internalReference = readObject(tag) as Value.Reference? // get internal reference type
            else { return nil }
        
        return Value(internalReference)
    }
}

// MARK: - Tag List

public extension Profile.TagView {
    
    // TODO: implement all tags
    
    public var aToB0: Pipeline? {
        
        return readObject(cmsSigAToB0Tag)
    }
    
    public var blueColorant: cmsCIEXYZ? {
        
        return readCasting(cmsSigBlueColorantTag)
    }
}
