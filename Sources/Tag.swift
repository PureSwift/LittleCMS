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
    
    /// Creates a new profile, replacing all tags with the specified new ones.
    public init(profile: Profile, tags: TagView) {
        
        self.internalReference = profile.internalReference
        self.tags = tags
    }
    
    /// A collection of the profile's tags.
    public var tags: TagView {
        
        get { return TagView(profile: self) }
        
        mutating set {
            
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
        
        // MARK: - Methods
        
        // Returns `true` if a tag with signature sig is found on the profile.
        /// Useful to check if a profile contains a given tag.
        public func contains(_ tag: Tag) -> Bool {
            
            return internalReference.reference.contains(tag)
        }
        
        /// Creates a directory entry on tag sig that points to same location as tag destination.
        /// Using this function you can collapse several tag entries to the same block in the profile.
        public mutating func link(_ tag: Tag, to destination: Tag) -> Bool {
            
            return internalReference.mutatingReference.link(tag, to: destination)
        }
        
        /// Returns the tag linked to, in the case two tags are sharing same resource,
        /// or `nil` if the tag is not linked to any other tag.
        public func tagLinked(to tag: Tag) -> Tag? {
            
            return internalReference.reference.tagLinked(to: tag)
        }
        
        /// Returns the signature of a tag located at the specified index.
        public func tag(at index: Int) -> Tag? {
            
            return internalReference.reference.tag(at: index)
        }
    }
}

// MARK: - Collection

extension Profile.TagView: RandomAccessCollection {
    
    public subscript(index: Int) -> Value {
        
        get {
            
            guard let tag = tag(at: index)
                else { fatalError("No tag at index \(index)") }
            
            guard let buffer = cmsReadTag(internalReference.reference.internalPointer, tag)
                else { fatalError("No value for tag \(tag) at index \(index)") }
            
            // TODO
            fatalError()
        }
    }
    
    public subscript(bounds: Range<Int>) -> RandomAccessSlice<Profile.TagView> {
        
        return RandomAccessSlice<Profile.TagView>(base: self, bounds: bounds)
    }
    
    /// The start `Index`.
    public var startIndex: Int {
        
        return 0
    }
    
    /// The end `Index`.
    ///
    /// This is the "one-past-the-end" position, and will always be equal to the `count`.
    public var endIndex: Int {
        
        return count
    }
    
    public func index(before i: Int) -> Int {
        return i - 1
    }
    
    public func index(after i: Int) -> Int {
        return i + 1
    }
    
    public func makeIterator() -> IndexingIterator<Profile.TagView> {
        
        return IndexingIterator(_elements: self)
    }
}

// MARK: - Supporting Type

public extension Profile.TagView {
    
    public enum Value {
        
        case pointCIEXYZ(cmsCIEXYZ)
        case pipeline(Pipeline)
    }
}

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
