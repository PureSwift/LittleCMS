import CLCMS2
import LCMS2ABI
import LittleCMSCore

/// A conversion between pixel encodings through one or more profiles.
///
/// Everything a transform needs is captured at creation, so `convert`
/// may be called from any number of threads at once.
public final class Transform: @unchecked Sendable {
    let context: CaptureContext
    let handle: cmsHTRANSFORM

    public let inputFormat: PixelFormat
    public let outputFormat: PixelFormat

    private init(
        context: CaptureContext, handle: cmsHTRANSFORM,
        inputFormat: PixelFormat, outputFormat: PixelFormat
    ) {
        self.context = context
        self.handle = handle
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
    }

    deinit {
        cmsDeleteTransform(handle)
    }

    /// The everyday case: one profile to another.  The profiles are
    /// fully captured and may be discarded afterwards.
    public convenience init(
        from input: Profile, format inputFormat: PixelFormat,
        to output: Profile, format outputFormat: PixelFormat,
        intent: Intent = .perceptual, options: Options = []
    ) throws {
        let context = CaptureContext()
        guard let handle = cmsCreateTransformTHR(
            context.raw,
            input.handle, inputFormat.rawValue,
            output.handle, outputFormat.rawValue,
            cmsUInt32Number(intent.rawValue), options.rawValue
        ) else { throw context.take(or: "couldn't build transform") }
        self.init(context: context, handle: handle, inputFormat: inputFormat, outputFormat: outputFormat)
    }

    /// A chain of profiles, PCS to PCS between each pair.
    public convenience init(
        chain profiles: [Profile],
        inputFormat: PixelFormat, outputFormat: PixelFormat,
        intent: Intent = .perceptual, options: Options = []
    ) throws {
        let context = CaptureContext()
        var handles: [cmsHPROFILE?] = profiles.map { $0.handle }
        guard let handle = cmsCreateMultiprofileTransformTHR(
            context.raw, &handles, cmsUInt32Number(handles.count),
            inputFormat.rawValue, outputFormat.rawValue,
            cmsUInt32Number(intent.rawValue), options.rawValue
        ) else { throw context.take(or: "couldn't build transform") }
        self.init(context: context, handle: handle, inputFormat: inputFormat, outputFormat: outputFormat)
    }

    /// A transform that renders as `output` would while showing what
    /// `proofing` will do to it.  Pass `.softProofing` and `.gamutCheck`
    /// in the options to switch those behaviours on.
    public convenience init(
        from input: Profile, format inputFormat: PixelFormat,
        to output: Profile, format outputFormat: PixelFormat,
        proofing: Profile,
        intent: Intent = .perceptual, proofingIntent: Intent = .absoluteColorimetric,
        options: Options = [.softProofing]
    ) throws {
        let context = CaptureContext()
        guard let handle = cmsCreateProofingTransformTHR(
            context.raw,
            input.handle, inputFormat.rawValue,
            output.handle, outputFormat.rawValue,
            proofing.handle,
            cmsUInt32Number(intent.rawValue), cmsUInt32Number(proofingIntent.rawValue),
            options.rawValue
        ) else { throw context.take(or: "couldn't build transform") }
        self.init(context: context, handle: handle, inputFormat: inputFormat, outputFormat: outputFormat)
    }

    // -- converting ----------------------------------------------------

    /// Converts `pixelCount` pixels from `source` into `destination`.
    /// The buffers are read and written as the transform's formats lay
    /// them out; the caller owns the arithmetic that sized them.
    public func convert(
        from source: UnsafeRawBufferPointer,
        to destination: UnsafeMutableRawBufferPointer,
        pixelCount: Int
    ) {
        cmsDoTransform(
            handle, source.baseAddress, destination.baseAddress, cmsUInt32Number(pixelCount)
        )
    }

    /// Converts a contiguous buffer of pixels, sized by the formats.
    public func convert(_ source: [UInt8]) throws -> [UInt8] {
        let inSize = inputFormat.bytesPerPixel
        let outSize = outputFormat.bytesPerPixel
        guard inSize > 0, source.count % inSize == 0 else {
            throw CMSError(
                code: .range,
                message: "buffer of \(source.count) bytes is not whole \(inSize)-byte pixels"
            )
        }
        let pixels = source.count / inSize
        var result = [UInt8](repeating: 0, count: pixels * outSize)
        source.withUnsafeBytes { input in
            result.withUnsafeMutableBytes { output in
                cmsDoTransform(handle, input.baseAddress, output.baseAddress, cmsUInt32Number(pixels))
            }
        }
        return result
    }
}

extension PixelFormat {
    /// The bytes one pixel occupies, extra channels included.  Planar
    /// layouts occupy the same total, arranged plane by plane.
    public var bytesPerPixel: Int {
        (bytes == 0 ? 8 : bytes) * totalChannels
    }
}
