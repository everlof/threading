import CoreGraphics
import Darwin
import Foundation
import ThreadingSimulatorKit

/// The app side of the shared-memory transport: maps the helper's frame buffers read-only and
/// turns the current one into a CGImage with no codec or decode. It copies the buffer's bytes into
/// the image so the helper is free to overwrite the shared buffer the moment the app releases it;
/// that copy is one memcpy, not a decode, which is the whole point of this path.
final class SimulatorSharedMemoryConsumer {
    private var pointers: [UnsafeRawPointer]
    private let bufferByteLength: Int
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private var closed = false

    init?(descriptor: SimulatorSharedSurfaceDescriptor) {
        guard descriptor.bufferCount > 0,
              descriptor.width > 0, descriptor.height > 0,
              descriptor.bytesPerRow >= descriptor.width * 4,
              descriptor.bufferByteLength >= descriptor.bytesPerRow * descriptor.height else {
            return nil
        }
        var pointers: [UnsafeRawPointer] = []
        for index in 0..<descriptor.bufferCount {
            let path = descriptor.name(forBuffer: index)
            guard let handle = FileHandle(forReadingAtPath: path) else {
                Self.unmap(pointers, length: descriptor.bufferByteLength)
                return nil
            }
            let pointer = mmap(
                nil, descriptor.bufferByteLength, PROT_READ, MAP_SHARED, handle.fileDescriptor, 0
            )
            try? handle.close()
            guard pointer != MAP_FAILED, let pointer else {
                Self.unmap(pointers, length: descriptor.bufferByteLength)
                return nil
            }
            pointers.append(UnsafeRawPointer(pointer))
        }
        self.pointers = pointers
        self.bufferByteLength = descriptor.bufferByteLength
        self.width = descriptor.width
        self.height = descriptor.height
        self.bytesPerRow = descriptor.bytesPerRow
    }

    func image(forBuffer index: UInt32) -> CGImage? {
        let position = Int(index)
        guard !closed, position >= 0, position < pointers.count else { return nil }
        let data = Data(bytes: pointers[position], count: bufferByteLength)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    func close() {
        guard !closed else { return }
        closed = true
        Self.unmap(pointers, length: bufferByteLength)
        pointers = []
    }

    private static func unmap(_ pointers: [UnsafeRawPointer], length: Int) {
        for pointer in pointers { munmap(UnsafeMutableRawPointer(mutating: pointer), length) }
    }
}
