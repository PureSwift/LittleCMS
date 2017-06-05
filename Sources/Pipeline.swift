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
    
    public let context: Context?
    
    // MARK: - Initialization
    
    deinit {
        
        // deallocate profile
        cmsPipelineFree(internalPointer)
    }
    
    internal init(_ internalPointer: OpaquePointer) {
        
        self.internalPointer = internalPointer
        self.context = Pipeline.context(for: internalPointer) // get swift object from internal pointer
    }
    
    init?(channels: (input: UInt, output: UInt), context: Context? = nil) {
        
        guard let internalPointer = cmsPipelineAlloc(context?.internalPointer,
                                                     cmsUInt32Number(channels.input),
                                                     cmsUInt32Number(channels.output))
            else { return  nil}
        
        self.internalPointer = internalPointer
        self.context = context
    }
}

// MARK: - Internal Protocols

extension Pipeline: DuplicableHandle {
    static var cmsDuplicate: cmsDuplicateFunction { return cmsPipelineDup }
}

extension Pipeline: ContextualHandle {
    static var cmsGetContextID: cmsGetContextIDFunction { return cmsGetPipelineContextID }
}
