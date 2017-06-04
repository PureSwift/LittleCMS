//
//  Profile.swift
//  LittleCMS
//
//  Created by Alsey Coleman Miller on 6/3/17.
//
//

import struct Foundation.Data
import CLCMS

/// A profile that specifies how to interpret a color value for display.
public final class Profile {
    
    // MARK: - Properties
    
    internal let internalPointer: cmsHPROFILE
    
    // MARK: - Initialization
    
    deinit {
        
        // deallocate profile
        cmsCloseProfile(internalPointer)
    }
    
    internal init(_ internalPointer: cmsHPROFILE) {
        
        self.internalPointer = internalPointer
    }
    
    public init?(file: String, access: FileAccess) {
        
        guard let internalPointer = cmsOpenProfileFromFile(file, access.rawValue)
            else { return nil }
        
        self.internalPointer = internalPointer
    }
    
    public init?(data: Data) {
        
        guard let internalPointer = data.withUnsafeBytes({ cmsOpenProfileFromMem($0, cmsUInt32Number(data.count)) })
            else { return nil }
        
        self.internalPointer = internalPointer
    }
    
    /// Creates a gray profile based on White point and transfer function. 
    /// It populates following tags:
    /// - `cmsSigProfileDescriptionTag`
    /// - `cmsSigMediaWhitePointTag`
    /// - `cmsSigGrayTRCTag`
    ///
    /// - Parameter whitePoint: The white point of the gray device or space.
    /// - Parameter transferFunction: tone curve describing the device or space gamma.
    /// - Returns: An ICC profile object on success, `nil` on error.
    public init?(grey whitePoint: cmsCIExyY, toneCurve: ToneCurve, context: Context? = nil) {
        
        var whiteCIExyY = whitePoint
        
        let table = toneCurve.internalPointer
        
        if let context = context {
            
            guard let internalPointer = cmsCreateGrayProfileTHR(context.internalPointer, &whiteCIExyY, table)
                else { return nil }
            
            self.internalPointer = internalPointer
            
        } else {
            
            guard let internalPointer = cmsCreateGrayProfile(&whiteCIExyY, table)
                else { return nil }
            
            self.internalPointer = internalPointer
        }
    }
    
    // MARK: - Accessors
    
    public var context: Context? {
        
        guard let internalPointer = cmsGetProfileContextID(self.internalPointer)
            else { return nil }
        
        return cmsGetSwiftContext(internalPointer)
    }
    
    public var signature: ColorSpaceSignature {
        
        return cmsGetColorSpace(internalPointer)
    }
    
    /// Profile connection space used by the given profile, using the ICC convention.
    public var connectionSpace: ColorSpaceSignature {
        
        get { return cmsGetPCS(internalPointer) }
        
        set { cmsSetPCS(internalPointer, newValue) }
    }
    
    /// Returns the number of tags present in a given profile.
    public var tagCount: Int {
        
        return Int(cmsGetTagCount(internalPointer))
    }
    
    // MARK: - Methods
    
    /// Saves the contents of a profile to `Data`.
    public func save() -> Data? {
        
        var length: cmsUInt32Number = 0
        
        guard cmsSaveProfileToMem(internalPointer, nil, &length) != 0
            else { return nil }
        
        var data = Data(count: Int(length))
        
        guard data.withUnsafeMutableBytes({ cmsSaveProfileToMem(self.internalPointer, $0, nil) }) != 0
            else { return nil }
        
        return data
    }
    
    // MARK: Tag Methods
    
    // Returns `true` if a tag with signature sig is found on the profile. 
    /// Useful to check if a profile contains a given tag.
    public func contains(_ tag: cmsTagSignature) -> Bool {
        
        return cmsIsTag(internalPointer, tag) != 0
    }
    
    /// Creates a directory entry on tag sig that points to same location as tag destination.
    /// Using this function you can collapse several tag entries to the same block in the profile.
    public func link(_ tag: cmsTagSignature, to destination: cmsTagSignature) -> Bool {
        
        cmsLinkTag(internalPointer, tag, destination)
    }
    
    /// Returns the tag linked to, in the case two tags are sharing same resource,
    /// or `nil` if the tag is not linked to any other tag.
    public func tagLinked(to tag: cmsTagSignature) -> cmsTagSignature? {
        
        let tag = cmsTagLinkedTo(internalPointer, tag)
        
        guard tag.rawValue != 0 else { return nil }
        
        return tag
    }
    
    /// Attempt to get the LittleCMS value for the tag
    private func read <T> (_ tag: cmsTagSignature) -> T? {
        
        guard let buffer = cmsReadTag(internalPointer, tag)
            else { return nil }
        
        
    }
    
    // MARK: - Subscript
    
    public subscript (infoType: Info) -> String? {
        
        return self[infoType, (cmsNoLanguage, cmsNoCountry)]
    }
    
    /// Get the string for the specified profile info.
    public subscript (infoType: Info, locale: (languageCode: String, countryCode: String)) -> String? {
        
        let info = cmsInfoType(infoType)
        
        // get buffer size
        let bufferSize = cmsGetProfileInfo(internalPointer, info, locale.languageCode, locale.countryCode, nil, 0)
        
        guard bufferSize > 0 else { return nil }
        
        // allocate buffer and get data
        var data = Data(repeating: 0, count: Int(bufferSize))
        
        guard data.withUnsafeMutableBytes({ cmsGetProfileInfo(internalPointer, info, locale.languageCode, locale.countryCode, UnsafeMutablePointer<wchar_t>($0), bufferSize) }) != 0 else { fatalError("Cannot get data for \(infoType)") }
        
        assert(wchar_t.self == Int32.self, "wchar_t is \(wchar_t.self)")
        
        return String(littleCMS: data)
    }
    
    /// Get the tag at the specified index
    public subscript (index: UInt) -> cmsTagSignature? {
        
        let tag = cmsGetTagSignature(internalPointer, cmsUInt32Number(tag))
        
        guard tag.rawValue != 0 else { return nil }
        
        return tag
    }
    
    
}

// MARK: - Equatable

extension Profile: Equatable {
    
    public static func == (lhs: Profile, rhs: Profile) -> Bool {
        
        // FIXME
        return lhs.internalPointer == rhs.internalPointer
    }
}

// MARK: - Supporting Types

public extension Profile {
    
    public enum Info {
        
        case description
        case manufacturer
        case model
        case copyright
    }
    
    public enum FileAccess: String {
        
        case read = "r"
        case write = "w"
    }
}

// MARK: - Little CMS Extensions / Helpers

fileprivate extension String {
    
    init?(littleCMS data: Data) {
        
        // try to decode data into string
        let possibleEncodings: [String.Encoding] = [.utf32, .utf32LittleEndian, .utf32BigEndian]
        
        var value: String?
        
        for encoding in possibleEncodings {
            
            guard let string = String(data: data, encoding: encoding)
                else { continue }
            
            value = string
        }
        
        if let value = value {
            
            self = value
            
        } else {
            
            return nil
        }
    }
}

public extension cmsInfoType {
    
    init(_ info: Profile.Info) {
        
        switch info {
        case .description:  self = cmsInfoDescription
        case .manufacturer: self = cmsInfoManufacturer
        case .model:        self = cmsInfoModel
        case .copyright:    self = cmsInfoCopyright
        }
    }
}
