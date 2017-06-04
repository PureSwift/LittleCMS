//
//  Pipeline.swift
//  LittleCMS
//
//  Created by Alsey Coleman Miller on 6/4/17.
//
//

import CLCMS

public final class Pipeline {
    
    // MARK: - Properties
    
    internal let internalPointer: OpaquePointer
    
    // MARK: - Initialization
    
    deinit {
        
        // deallocate profile
        cmsPipelineFree(internalPointer)
    }
    
    internal init(_ internalPointer: OpaquePointer) {
        
        self.internalPointer = internalPointer
    }
    
    init?(channels: (input: UInt, output: UInt), context: Context? = nil) {
        
        guard let internalPointer = cmsPipelineAlloc(context?.internalPointer,
                                                     cmsUInt32Number(channels.input),
                                                     cmsUInt32Number(channels.output))
            else { return  nil}
        
        self.internalPointer = internalPointer
    }
    
    // MARK: - Accessors
    
    public var context: Context? {
        
        return _context()
    }
    
    public var copy: Pipeline? {
        
        return _copy()
    }
}

// MARK: - Internal Protocols

extension Pipeline: CopyableHandle {
    static var cmsDuplicate: cmsDuplicateFunction { return cmsPipelineDup }
}

extension Pipeline: ContextualHandle {
    static var cmsGetContextID: cmsGetContextIDFunction { return cmsGetPipelineContextID }
}
