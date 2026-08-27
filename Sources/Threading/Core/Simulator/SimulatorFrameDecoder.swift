import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ThreadingSimulatorKit
import VideoToolbox

/// VideoToolbox state is owned by `stateQueue`. The output callback touches only the immutable
/// Core Image context and its retained frame context, never the queue-owned session properties.
final class SimulatorFrameDecoder: @unchecked Sendable {
    private final class FrameContext {
        let frame: SimulatorBridgeMediaFrame
        let completion: @Sendable (Result<SimulatorLiveFrame, Error>) -> Void

        init(
            frame: SimulatorBridgeMediaFrame,
            completion: @escaping @Sendable (Result<SimulatorLiveFrame, Error>) -> Void
        ) {
            self.frame = frame
            self.completion = completion
        }
    }

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let stateQueue = DispatchQueue(label: "codes.threading.simulator-frame-decoder")
    private var h264Format: CMVideoFormatDescription?
    private var h264Session: VTDecompressionSession?
    private var isInvalidated = false

    func decode(
        _ frame: SimulatorBridgeMediaFrame,
        completion: @escaping @Sendable (Result<SimulatorLiveFrame, Error>) -> Void
    ) {
        stateQueue.sync {
            guard !isInvalidated else {
                completion(.failure(SimulatorLiveStreamError.disconnected))
                return
            }
            switch frame.codec {
            case .jpeg:
                guard let source = CGImageSourceCreateWithData(frame.bytes as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    completion(.failure(SimulatorLiveStreamError.invalidFrame))
                    return
                }
                completion(.success(SimulatorLiveFrame(
                    sequence: frame.sequence,
                    image: image,
                    codec: .jpeg,
                    presentationTimeNanoseconds: frame.presentationTimeNanoseconds
                )))

            case .h264:
                do { try decodeH264(frame, completion: completion) }
                catch { completion(.failure(error)) }
            }
        }
    }

    func invalidate() {
        stateQueue.sync {
            guard !isInvalidated else { return }
            isInvalidated = true
            retireH264Session()
        }
    }

    deinit { invalidate() }

    private func decodeH264(
        _ frame: SimulatorBridgeMediaFrame,
        completion: @escaping @Sendable (Result<SimulatorLiveFrame, Error>) -> Void
    ) throws {
        if !frame.codecConfiguration.isEmpty {
            try configureH264(frame.codecConfiguration)
        }
        guard let h264Format, let h264Session else {
            throw SimulatorLiveStreamError.invalidFrame
        }
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frame.bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frame.bytes.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr,
        let blockBuffer,
        frame.bytes.withUnsafeBytes({ bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: frame.bytes.count
            )
        }) == kCMBlockBufferNoErr else {
            throw SimulatorLiveStreamError.invalidFrame
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = frame.bytes.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: h264Format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr,
        let sampleBuffer else { throw SimulatorLiveStreamError.invalidFrame }

        let frameContext = FrameContext(frame: frame, completion: completion)
        let status = VTDecompressionSessionDecodeFrame(
            h264Session,
            sampleBuffer: sampleBuffer,
            // Xcode 26 imports the public C constant with an underscored Swift spelling.
            // Keep the documented bit value here so the source remains stable across SDKs.
            flags: VTDecodeFrameFlags(rawValue: 1 << 0),
            frameRefcon: Unmanaged.passRetained(frameContext).toOpaque(),
            infoFlagsOut: nil
        )
        if status != noErr {
            Unmanaged.passUnretained(frameContext).release()
            throw SimulatorLiveStreamError.invalidFrame
        }
    }

    private func configureH264(_ configuration: Data) throws {
        let sets = try SimulatorBridgeH264Configuration.decode(configuration)
        var format: CMFormatDescription?
        let status = sets.sequence.withUnsafeBytes { sequenceBytes in
            sets.picture.withUnsafeBytes { pictureBytes in
                var pointers: [UnsafePointer<UInt8>] = [
                    sequenceBytes.bindMemory(to: UInt8.self).baseAddress!,
                    pictureBytes.bindMemory(to: UInt8.self).baseAddress!,
                ]
                var sizes = [sets.sequence.count, sets.picture.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format
                )
            }
        }
        guard status == noErr, let format else { throw SimulatorLiveStreamError.invalidFrame }
        retireH264Session()
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.outputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
            ] as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        ) == noErr,
        let session else { throw SimulatorLiveStreamError.invalidFrame }
        h264Format = format
        h264Session = session
    }

    /// Waits for every retained frame context to leave VideoToolbox before invalidating the
    /// session or allowing this decoder to deinitialize.
    private func retireH264Session() {
        if let h264Session {
            _ = VTDecompressionSessionWaitForAsynchronousFrames(h264Session)
            VTDecompressionSessionInvalidate(h264Session)
        }
        h264Session = nil
        h264Format = nil
    }

    private static let outputCallback: VTDecompressionOutputCallback = {
        decoderRefCon, frameRefCon, status, _, imageBuffer, _, _ in
        guard let frameRefCon else { return }
        let frameContext = Unmanaged<FrameContext>.fromOpaque(frameRefCon).takeRetainedValue()
        guard status == noErr, let imageBuffer, let decoderRefCon else {
            frameContext.completion(.failure(SimulatorLiveStreamError.invalidFrame))
            return
        }
        let decoder = Unmanaged<SimulatorFrameDecoder>.fromOpaque(decoderRefCon)
            .takeUnretainedValue()
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        guard let image = decoder.context.createCGImage(ciImage, from: ciImage.extent) else {
            frameContext.completion(.failure(SimulatorLiveStreamError.invalidFrame))
            return
        }
        frameContext.completion(.success(SimulatorLiveFrame(
            sequence: frameContext.frame.sequence,
            image: image,
            codec: .h264,
            presentationTimeNanoseconds: frameContext.frame.presentationTimeNanoseconds
        )))
    }
}
