//
//  NamedColorList.swift
//  LittleCMS
//
//  Created by Alsey Coleman Miller on 6/3/17.
//
//

import CLCMS

/// Specialized dictionaries for dealing with named color profiles.
public final class NamedColorList {
        
    // MARK: - Properties
    
    internal let internalPointer: OpaquePointer
    
    // MARK: - Initialization
    
    deinit {
        
        // deallocate profile
        cmsFreeNamedColorList(internalPointer)
    }
    
    internal init(_ internalPointer: OpaquePointer) {
        
        self.internalPointer = internalPointer
    }
    
    /// Allocates an empty named color dictionary.
    public init?(count: Int, colorantCount: Int, prefix: String, suffix: String, context: Context? = nil) {
        
        guard let internalPointer = cmsAllocNamedColorList(context?.internalPointer,
                                                           cmsUInt32Number(count),
                                                           cmsUInt32Number(colorantCount),
                                                           prefix, suffix)
            else { return nil }
        
        self.internalPointer = internalPointer
    }
    
    /// Retrieve a named color list from a given color transform.
    public init?(transform: ColorTransform) {
        
        guard let internalPointer = cmsGetNamedColorList(transform.internalPointer)
            else { return nil }
        
        self.internalPointer = internalPointer
    }
    
    // MARK: - Accessors
    
    public var copy: NamedColorList? {
        
        return _copy()
    }
    
    // MARK: - Methods
    
    /// Adds a new spot color to the list. 
    ///
    /// If the number of elements in the list exceeds the initial storage,
    /// the list is realloc’ed to accommodate things.
    public func append(name: String, pcs: (UInt16, UInt16, UInt16), colorant: [UInt16]) -> Bool {
        
        precondition(colorant.count <= Int(cmsMAXCHANNELS), "")
        
        var pcs = [pcs.0, pcs.1, pcs.2]
        
        var colorant = colorant
        
        return cmsAppendNamedColor(internalPointer, name, &pcs, &colorant) > 0
    }
    
    // MARK: - Subscript
    
    
}

// MARK: - Collection

/*
extension NamedColorList: ExpressibleByArrayLiteral {
    
    public init(arrayLiteral elements: Self.Element...) {
        
        
    }
}*/

/*
extension NamedColorList: RandomAccessCollection, MutableCollection {

    public var count: Int {
        
        return Int(cmsNamedColorCount(internalPointer))
    }
    
    public subscript (index: Int) -> Image {
        
        guard let image = createImage(at: index)
            else { fatalError("No image at index \(index)") }
        
        return image
    }
    
    public subscript(bounds: Range<Self.Index>) -> RandomAccessSlice<Self> {
        
        return RandomAccessSlice<Self>(base: self, bounds: bounds)
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
    
    public func makeIterator() -> IndexingIterator<Self> {
        
        return IndexingIterator(_elements: self)
    }
}
 */

// MARK: - Internal Protocols

extension NamedColorList: CopyableHandle {
    static var cmsDuplicate: cmsDuplicateFunction { return cmsDupNamedColorList }
}
