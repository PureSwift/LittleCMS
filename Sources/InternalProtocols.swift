//
//  InternalProtocols.swift
//  LittleCMS
//
//  Created by Alsey Coleman Miller on 6/4/17.
//
//

import CLCMS

/// The Swift class is a wrapper for a LittleCMS opaque type.
internal protocol HandleObject {
    
    associatedtype InternalPointer
    
    init(_ internalPointer: InternalPointer)
    
    var internalPointer: InternalPointer { get }
}

/// The cms handle can be duplicated with a function.
internal protocol CopyableHandle: HandleObject {
    
    typealias cmsDuplicateFunction = (InternalPointer!) -> InternalPointer!

    /// The Little CMS Function that creates a duplicate of the handler.
    static var cmsDuplicate: cmsDuplicateFunction { get }
}

extension CopyableHandle {
    
    // Protocol Oriented Programming implementation
    @inline(__always)
    func _copy() -> Self? {
        
        guard let newInternalPointer = Self.cmsDuplicate(self.internalPointer)
            else { return nil }
        
        return Self(newInternalPointer)
    }
}

/// CMS handle that has a context attached
internal protocol ContextualHandle: HandleObject {
    
    typealias cmsGetContextIDFunction = (InternalPointer!) -> cmsContext!
    
    /// The Little CMS Function that gets the cms context ID of the handler.
    static var cmsGetContextID: cmsGetContextIDFunction { get }
}

extension ContextualHandle {
    
    @inline(__always)
    func _context() -> Context? {
        
        guard let internalPointer = Self.cmsGetContextID(self.internalPointer)
            else { return nil }
        
        return cmsGetSwiftContext(internalPointer)
    }
}

// Swift struct wrapper for `HandleObject`
internal protocol ReferenceConvertible {
    
    associatedtype Reference: HandleObject
    
    var internalReference: Reference { get }
    
    init(_ internalReference: Reference)
}

private protocol ReferenceConvertiblePrivate: ReferenceConvertible {
    
    associatedtype Reference: CopyableHandle
    
    var internalReference: Reference { get set }
}

private extension ReferenceConvertiblePrivate {
    
    private mutating func ensureUnique() {
        
        if !isKnownUniquelyReferenced(&internalReference) {
            
            guard let copy = internalReference._copy()
                else { fatalError("Coult not duplicate internal reference type") }
            
            internalReference = copy
        }
    }
}
