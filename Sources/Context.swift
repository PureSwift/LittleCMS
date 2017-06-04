//
//  Context.swift
//  LittleCMS
//
//  Created by Alsey Coleman Miller on 6/3/17.
//
//

import CLCMS

/// Keeps track of all plug-ins and static data needed by the THR corresponding function.
///
/// There are situations where several instances of Little CMS engine have to coexist but on different conditions. 
/// For example, when the library is used as a DLL or a shared object, diverse applications may want to use
/// different plug-ins. Another example is when multiple threads are being used in same task and the
/// user wants to pass thread-dependent information to the memory allocators or the logging system. 
/// For all this use, Little CMS 2.6 and above implements context handling functions.
public final class Context {
    
    public typealias ErrorLog = (String, LittleCMSError?) -> ()
    
    // MARK: - Properties
    
    internal let internalPointer: cmsContext
    
    // MARK: - Initialization
    
    deinit {
        
        cmsDeleteContext(internalPointer)
    }
    
    internal init(_ internalPointer: cmsContext) {
        
        self.internalPointer = internalPointer
    }
    
    /// Creates a new context with optional associated plug-ins. 
    /// Caller may specify an optional pointer to user-defined data 
    /// that will be forwarded to plug-ins and logger.
    public init(plugin: UnsafeMutableRawPointer? = nil, userData: UnsafeMutableRawPointer? = nil) {
        
        self.internalPointer = cmsCreateContext(plugin, userData)
    }
    
    // MARK: - Methods
    
    /// Duplicates a context with all associated plug-ins. 
    /// Caller may specify an optional pointer to user-defined data 
    /// that will be forwarded to plug-ins and logger.
    public func copy(with userData: UnsafeMutableRawPointer? = nil) -> Context? {
        
        guard let internalPointer = cmsDupContext(self.internalPointer, userData)
            else { return nil }
        
        return Context(internalPointer)
    }
    
    // MARK: - Accessors
    
    /// Returns the user data associated to the given `Context`,
    /// or `nil` if no user data was attached on context creation.
    private var userData: UnsafeMutableRawPointer? {
        
        return cmsGetContextUserData(internalPointer)
    }
    
    public var errorLog: ErrorLog? {
        
        didSet {
            
            let log: cmsLogErrorHandlerFunction?
            
            if let newValue = errorLog {
                
                log = logErrorHandler
                
            } else {
                
                log = nil
            }
            
            // set new error handler
            cmsSetLogErrorHandlerTHR(internalPointer, log)
        }
    }
}

// MARK: - Private Functions

private func logErrorHandler(_ internalPointer: cmsContext?, _ error: cmsUInt32Number, message: UnsafePointer<Int8>?) {
    
    
}
