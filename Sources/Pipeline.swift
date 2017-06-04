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
    
    init(channels: (input: UInt, output: UInt), context: Context? = nil) {
        
        guard let internalPointer = cmsPipelineAlloc(context?.internalPointer, cmsUInt32Number(channels.input), cmsUInt32Number(channels.output))
            else { return }
        
        self.internalPointer = internalPointer
    }
    
    // MARK: - Accessors
    
    public var copy: Pipeline? {
        
        guard let newInternalPointer = cmsPipelineDup(internalPointer)
            else { return nil }
        
        return Pipeline(newInternalPointer)
    }
}
