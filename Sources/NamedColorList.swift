//
//  NamedColorList.swift
//  LittleCMS
//
//  Created by Alsey Coleman Miller on 6/3/17.
//
//

import struct Foundation.Data
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
    
    public var count: Int {
        
        return Int(cmsNamedColorCount(internalPointer))
    }
    
    // MARK: - Methods
    
    /// Adds a new spot color to the list. 
    ///
    /// If the number of elements in the list exceeds the initial storage,
    /// the list is realloc’ed to accommodate things.
    @discardableResult
    public func append(name: String, profileColorSpace pcs: ProfileColorSpace, colorant: Colorant) -> Bool {
        
        var colorant = colorant.rawValue
        
        var pcs = [pcs.0, pcs.1, pcs.2]
        
        precondition(Colorant.validate(colorant), "Invalid Colorant array")
        
        return cmsAppendNamedColor(internalPointer, name, &pcs, &colorant) > 0
    }
    
    @inline(__always)
    public func append(_ element: Element) {
        
        guard append(name: element.name, profileColorSpace: element.profileColorSpace, colorant: element.colorant)
            else { fatalError("Could not append element \(element)") }
    }
    
    /// Performs a look-up in the dictionary and returns an index on the given color name.
    public func index(of name: String) -> Int? {
        
        // Index on name, or -1 if the spot color is not found.
        let index = Int(cmsNamedColorIndex(internalPointer, name))
        
        guard index != -1 else { return nil }
        
        return index
    }
    
    // MARK: - Subscript
    
    public subscript (name: String) -> Element? {
        
        guard let index = self.index(of: name)
            else { return nil }
        
        return self[index]
    }
    
    public subscript (index: Int) -> Element {
        
        var colorantValue = Colorant().rawValue
        
        var pcsBuffer = [cmsUInt16Number](repeating: 0, count: 3)
        
        var nameBytes = [CChar](repeating: 0, count: 256)
        
        let status = cmsNamedColorInfo(internalPointer,
                                       cmsUInt32Number(index),
                                       &nameBytes,
                                       nil, nil,
                                       &pcsBuffer,
                                       &colorantValue)
        
        assert(status > 0, "Invalid index")
        
        // get swift values
        
        let colorant = Colorant(rawValue: colorantValue)!
        
        let pcs = (pcsBuffer[0], pcsBuffer[1], pcsBuffer[2])
        
        let nameData = Data(bytes: unsafeBitCast(nameBytes, to: Array<UInt8>.self))
        
        let name = String(data: nameData, encoding: String.Encoding.utf8) ?? ""
        
        let element: Element = (name, pcs, colorant)
        
        return element
    }
}

// MARK: - Supporting Types

public extension NamedColorList {
    
    public typealias Element = (name: String, profileColorSpace: ProfileColorSpace, colorant: Colorant)
    
    public typealias ProfileColorSpace = (cmsUInt16Number, cmsUInt16Number, cmsUInt16Number)
    
    public struct Colorant: RawRepresentable {
        
        public let rawValue: [cmsUInt16Number]
        
        @inline(__always)
        public init?(rawValue: [cmsUInt16Number]) {
            
            guard Colorant.validate(rawValue)
                else { return nil }
            
            self.rawValue = rawValue
        }
        
        public init() {
            
            self.rawValue = [cmsUInt16Number](repeating: 0, count: Int(cmsMAXCHANNELS))
            
            assert(Colorant.validate(rawValue))
        }
        
        @inline(__always)
        public static func validate(_ rawValue: RawValue) -> Bool {
            
            // Maximum number of channels in ICC is 16
            return rawValue.count == Int(cmsMAXCHANNELS)
        }
    }
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
