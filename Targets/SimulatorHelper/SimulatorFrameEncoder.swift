import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import IOSurface
import ThreadingSimulatorKit
import UniformTypeIdentifiers
import VideoToolbox

protocol SimulatorFrameEncoding: AnyObject {
    var codec: SimulatorBridgeCodec { get }
    func encode(
        surface: IOSurface,
        sequence: UInt64,
        presentationTimeNanoseconds: UInt64,
        completion: @escaping @Sendable (Result<SimulatorBridgeMediaFrame, Error>) -> Void
    )
    func finish()
}

enum SimulatorFrameEncoderError: LocalizedError {
    case pixelBuffer(OSStatus)
    case compressionSession(OSStatus)
    case holdsFrames(reportedDelay: Int?)
    case encode(OSStatus)
    case missingSample
    case missingFormat
    case missingParameterSet
    case jpegEncoding

    var errorDescription: String? {
        switch self {
        case .pixelBuffer(let status): return "The Simulator surface could not become a pixel buffer (\(status))."
        case .compressionSession(let status): return "The H.264 encoder is unavailable (\(status))."
        case .holdsFrames(let reportedDelay):
            let delay = reportedDelay.map(String.init) ?? "an unknown number of"
            return "The H.264 encoder would hold \(delay) frames before emitting one."
        case .encode(let status): return "The H.264 encoder refused a frame (\(status))."
        case .missingSample: return "The H.264 encoder returned no sample."
        case .missingFormat: return "The H.264 key frame has no format description."
        case .missingParameterSet: return "The H.264 key frame has no parameter sets."
        case .jpegEncoding: return "The Simulator frame could not be encoded as JPEG."
        }
    }
}

final class SimulatorJPEGFrameEncoder: SimulatorFrameEncoding {
    let codec = SimulatorBridgeCodec.jpeg
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    func encode(
        surface: IOSurface,
        sequence: UInt64,
        presentationTimeNanoseconds: UInt64,
        completion: @escaping @Sendable (Result<SimulatorBridgeMediaFrame, Error>) -> Void
    ) {
        do {
            let pixelBuffer = try Self.pixelBuffer(for: surface)
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = context.createCGImage(
                image,
                from: image.extent,
                format: .BGRA8,
                colorSpace: colorSpace
            ) else {
                throw SimulatorFrameEncoderError.jpegEncoding
            }
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                bytes,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else { throw SimulatorFrameEncoderError.jpegEncoding }
            CGImageDestinationAddImage(
                destination,
                cgImage,
                [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else {
                throw SimulatorFrameEncoderError.jpegEncoding
            }
            completion(.success(SimulatorBridgeMediaFrame(
                sequence: sequence,
                presentationTimeNanoseconds: presentationTimeNanoseconds,
                width: UInt32(IOSurfaceGetWidth(surface)),
                height: UInt32(IOSurfaceGetHeight(surface)),
                codec: .jpeg,
                isKeyFrame: true,
                bytes: bytes as Data
            )))
        } catch {
            completion(.failure(error))
        }
    }

    func finish() {}

    static func pixelBuffer(for surface: IOSurface) throws -> CVPixelBuffer {
        var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            surface,
            nil,
            &unmanagedPixelBuffer
        )
        guard status == kCVReturnSuccess, let unmanagedPixelBuffer else {
            throw SimulatorFrameEncoderError.pixelBuffer(status)
        }
        return unmanagedPixelBuffer.takeRetainedValue()
    }
}

final class SimulatorH264FrameEncoder: SimulatorFrameEncoding, @unchecked Sendable {
    let codec = SimulatorBridgeCodec.h264

    private final class FrameContext {
        let sequence: UInt64
        let timestamp: UInt64
        let completion: @Sendable (Result<SimulatorBridgeMediaFrame, Error>) -> Void

        init(
            sequence: UInt64,
            timestamp: UInt64,
            completion: @escaping @Sendable (Result<SimulatorBridgeMediaFrame, Error>) -> Void
        ) {
            self.sequence = sequence
            self.timestamp = timestamp
            self.completion = completion
        }
    }

    enum Configuration {
        static let averageBitRate = 6_000_000
        static let keyFrameIntervalSeconds = 2
        /// Zero: every frame must be emitted before the next one is accepted.
        static let maximumFrameDelay = 0
    }

    private let width: Int32
    private let height: Int32
    private var session: VTCompressionSession?

    init(width: Int, height: Int, framesPerSecond: Int) throws {
        self.width = Int32(width)
        self.height = Int32(height)
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw SimulatorFrameEncoderError.compressionSession(status)
        }
        self.session = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Main_AutoLevel
        )
        let fps = framesPerSecond as CFNumber
        let keyFrameInterval = max(1, framesPerSecond * Configuration.keyFrameIntervalSeconds) as CFNumber
        let bitrate = Configuration.averageBitRate as CFNumber
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyFrameInterval)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate)
        // The helper keeps exactly one frame inside the encoder and captures the next only after
        // that one has come back. An encoder that is allowed to reorder frames holds the second
        // frame for lookahead and never emits it, so the stream freezes on its first picture
        // while every process involved sits idle. Immediate output is therefore part of this
        // encoder's contract, and it is verified below rather than assumed.
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxFrameDelayCount,
            value: Configuration.maximumFrameDelay as CFNumber
        )
        let prepare = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepare == noErr else {
            VTCompressionSessionInvalidate(session)
            self.session = nil
            throw SimulatorFrameEncoderError.compressionSession(prepare)
        }
        do {
            try Self.verifyImmediateOutput(of: session)
        } catch {
            VTCompressionSessionInvalidate(session)
            self.session = nil
            throw error
        }
    }

    /// Refuses a session that would hold frames, so codec negotiation falls through to JPEG
    /// instead of adopting an encoder the one-frame-in-flight helper cannot drive.
    private static func verifyImmediateOutput(of session: VTCompressionSession) throws {
        // CFBoolean and CFNumber both bridge to NSNumber, so one reading covers whichever
        // representation VideoToolbox hands back.
        guard let reordering = copyProperty(kVTCompressionPropertyKey_AllowFrameReordering, of: session)
                as? NSNumber, !reordering.boolValue else {
            throw SimulatorFrameEncoderError.holdsFrames(reportedDelay: nil)
        }
        guard let delay = copyProperty(kVTCompressionPropertyKey_MaxFrameDelayCount, of: session)
                as? NSNumber else {
            throw SimulatorFrameEncoderError.holdsFrames(reportedDelay: nil)
        }
        guard delay.intValue == Configuration.maximumFrameDelay else {
            throw SimulatorFrameEncoderError.holdsFrames(reportedDelay: delay.intValue)
        }
    }

    private static func copyProperty(_ key: CFString, of session: VTCompressionSession) -> CFTypeRef? {
        let value = UnsafeMutablePointer<CFTypeRef?>.allocate(capacity: 1)
        value.initialize(to: nil)
        defer {
            value.deinitialize(count: 1)
            value.deallocate()
        }
        let status = VTSessionCopyProperty(
            session,
            key: key,
            allocator: kCFAllocatorDefault,
            valueOut: UnsafeMutableRawPointer(value)
        )
        guard status == noErr else { return nil }
        return value.pointee
    }

    func encode(
        surface: IOSurface,
        sequence: UInt64,
        presentationTimeNanoseconds: UInt64,
        completion: @escaping @Sendable (Result<SimulatorBridgeMediaFrame, Error>) -> Void
    ) {
        guard let session else {
            completion(.failure(SimulatorFrameEncoderError.compressionSession(kVTInvalidSessionErr)))
            return
        }
        do {
            let pixelBuffer = try SimulatorJPEGFrameEncoder.pixelBuffer(for: surface)
            let frameContext = FrameContext(
                sequence: sequence,
                timestamp: presentationTimeNanoseconds,
                completion: completion
            )
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(
                    value: CMTimeValue(presentationTimeNanoseconds),
                    timescale: 1_000_000_000
                ),
                duration: .invalid,
                frameProperties: nil,
                sourceFrameRefcon: Unmanaged.passRetained(frameContext).toOpaque(),
                infoFlagsOut: nil
            )
            if status != noErr {
                Unmanaged.passUnretained(frameContext).release()
                completion(.failure(SimulatorFrameEncoderError.encode(status)))
            }
        } catch {
            completion(.failure(error))
        }
    }

    func finish() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    deinit { finish() }

    private static let outputCallback: VTCompressionOutputCallback = {
        _, sourceFrameRefCon, status, _, sampleBuffer in
        guard let sourceFrameRefCon else { return }
        let context = Unmanaged<FrameContext>.fromOpaque(sourceFrameRefCon).takeRetainedValue()
        guard status == noErr, let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else {
            context.completion(.failure(SimulatorFrameEncoderError.encode(status)))
            return
        }
        do {
            let notSynchronized = (CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[CFString: Any]])?
                .first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            let keyFrame = !notSynchronized
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                throw SimulatorFrameEncoderError.missingSample
            }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            var bytes = Data(count: byteCount)
            let copyStatus = bytes.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: buffer.baseAddress!
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else {
                throw SimulatorFrameEncoderError.missingSample
            }

            var configuration = Data()
            if keyFrame {
                guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                    throw SimulatorFrameEncoderError.missingFormat
                }
                var sequencePointer: UnsafePointer<UInt8>?
                var sequenceSize = 0
                var parameterSetCount = 0
                var nalHeaderLength: Int32 = 0
                var picturePointer: UnsafePointer<UInt8>?
                var pictureSize = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: &sequencePointer,
                    parameterSetSizeOut: &sequenceSize,
                    parameterSetCountOut: &parameterSetCount,
                    nalUnitHeaderLengthOut: &nalHeaderLength
                ) == noErr,
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: 1,
                    parameterSetPointerOut: &picturePointer,
                    parameterSetSizeOut: &pictureSize,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                ) == noErr,
                let sequencePointer,
                let picturePointer else {
                    throw SimulatorFrameEncoderError.missingParameterSet
                }
                configuration = try SimulatorBridgeH264Configuration.encode(
                    sequenceParameterSet: Data(bytes: sequencePointer, count: sequenceSize),
                    pictureParameterSet: Data(bytes: picturePointer, count: pictureSize)
                )
            }
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                throw SimulatorFrameEncoderError.missingFormat
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            context.completion(.success(SimulatorBridgeMediaFrame(
                sequence: context.sequence,
                presentationTimeNanoseconds: context.timestamp,
                width: UInt32(dimensions.width),
                height: UInt32(dimensions.height),
                codec: .h264,
                isKeyFrame: keyFrame,
                codecConfiguration: configuration,
                bytes: bytes
            )))
        } catch {
            context.completion(.failure(error))
        }
    }
}
