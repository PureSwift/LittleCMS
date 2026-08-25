// Errors.
//
// The C surface reports through a logger and answers NULL; this module
// throws instead.  Every wrapper object owns a private context whose
// logger captures the report, so the text the reference would have
// logged becomes the error's message.

/// A color-management failure.
public struct CMSError: Error, Sendable, CustomStringConvertible {
    /// The reference's `cmsERROR_*` classification.
    public enum Code: UInt32, Sendable {
        case undefined = 0
        case file = 1
        case range = 2
        case internalError = 3
        case null = 4
        case read = 5
        case seek = 6
        case write = 7
        case unknownExtension = 8
        case colorspaceCheck = 9
        case alreadyDefined = 10
        case badSignature = 11
        case corruptionDetected = 12
        case notSuitable = 13
    }

    public let code: Code
    /// What the library reported, verbatim.
    public let message: String

    public var description: String { message }
}
