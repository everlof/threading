import Darwin
import Foundation
import IOSurface
import ThreadingSimulatorKit

/// Copies each captured simulator surface into one of a small pool of memory-mapped buffers that
/// the app maps read-only, so frames reach the pane with no codec, encode, or decode — the
/// shared-memory transport. The buffers are `mmap`ed temp files under a per-stream random
/// directory (Swift cannot call the variadic `shm_open`, and a mapped temp file shares memory just
/// as well); the directory is removed on teardown. Passing the buffers as inherited file
/// descriptors instead of paths is a planned hardening that removes the (same-user) path-guess
/// surface.
final class SimulatorSharedMemoryProvider {
    /// BGRA is the only format the app's zero-decode image path assumes; anything else declines
    /// here and the helper falls back to the codec path.
    private static let expectedPixelFormat: UInt32 = 0x42_47_52_41 // 'BGRA'

    let descriptor: SimulatorSharedSurfaceDescriptor
    private let directory: URL
    private let pointers: [UnsafeMutableRawPointer]
    private let bufferByteLength: Int
    private var ring: SimulatorSharedFrameRing

    init?(surface: IOSurface, bufferCount: Int) {
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let pixelFormat = IOSurfaceGetPixelFormat(surface)
        guard width > 0, height > 0, bytesPerRow >= width * 4, bufferCount > 0,
              pixelFormat == Self.expectedPixelFormat else { return nil }
        let bufferByteLength = bytesPerRow * height

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-sim-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )) != nil else { return nil }
        // `name(forBuffer:)` concatenates this prefix with the index, so buffer i is this exact
        // file path.
        let namePrefix = directory.path + "/"

        var pointers: [UnsafeMutableRawPointer] = []
        for index in 0..<bufferCount {
            let path = "\(namePrefix)\(index)"
            guard FileManager.default.createFile(atPath: path, contents: nil),
                  let handle = FileHandle(forUpdatingAtPath: path) else {
                Self.teardown(pointers: pointers, length: bufferByteLength, directory: directory)
                return nil
            }
            let fd = handle.fileDescriptor
            let truncated = ftruncate(fd, off_t(bufferByteLength)) == 0
            let pointer = truncated
                ? mmap(nil, bufferByteLength, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
                : MAP_FAILED
            try? handle.close() // The mapping survives the descriptor being closed.
            guard truncated, pointer != MAP_FAILED, let pointer else {
                Self.teardown(pointers: pointers, length: bufferByteLength, directory: directory)
                return nil
            }
            pointers.append(pointer)
        }

        self.directory = directory
        self.pointers = pointers
        self.bufferByteLength = bufferByteLength
        self.ring = SimulatorSharedFrameRing(bufferCount: bufferCount)
        self.descriptor = SimulatorSharedSurfaceDescriptor(
            namePrefix: namePrefix,
            bufferCount: bufferCount,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelFormat: pixelFormat,
            bufferByteLength: bufferByteLength
        )
    }

    /// Copies the current surface into a free buffer and returns its index, or nil when the app
    /// still holds every buffer (the capture is dropped, latest-frame-wins).
    func write(surface: IOSurface) -> UInt32? {
        guard let index = ring.claim() else { return nil }
        guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else {
            ring.release(index)
            return nil
        }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface)
        let count = min(bufferByteLength, IOSurfaceGetAllocSize(surface))
        memcpy(pointers[Int(index)], base, count)
        return index
    }

    func release(_ index: UInt32) { ring.release(index) }

    func teardown() {
        Self.teardown(pointers: pointers, length: bufferByteLength, directory: directory)
    }

    private static func teardown(
        pointers: [UnsafeMutableRawPointer],
        length: Int,
        directory: URL
    ) {
        for pointer in pointers { munmap(pointer, length) }
        try? FileManager.default.removeItem(at: directory)
    }
}
