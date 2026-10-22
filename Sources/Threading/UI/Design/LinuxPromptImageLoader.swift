#if os(Linux)
import AppKit
import Foundation
import LinuxWindowBridge

/// Bounded native image decoding for the shared PromptView on Linux. A worker calls this;
/// only its small RGBA result crosses back to the UI actor.
enum LinuxPromptImageLoader {
    private static let queue = DispatchQueue(label: "threading.linux.prompt-thumbnails",
                                             qos: .userInitiated)
    struct Thumbnail: Sendable {
        let rgba: [UInt8]
        let width: Int
        let height: Int
    }

    nonisolated static func thumbnail(at path: String) -> Thumbnail? {
        var rgba = [UInt8](repeating: 0, count: 128 * 128 * 4)
        var width: Int32 = 0
        var height: Int32 = 0
        let decoded = path.withCString { pointer in
            rgba.withUnsafeMutableBufferPointer { pixels in
                tw_attachment_thumbnail(pointer, pixels.baseAddress, Int32(pixels.count),
                                        &width, &height) == 0
            }
        }
        guard decoded, width > 0, height > 0,
              width <= 128, height <= 128 else { return nil }
        return Thumbnail(rgba: Array(rgba.prefix(Int(width * height * 4))),
                         width: Int(width), height: Int(height))
    }

    /// The native host owns a synchronous UI loop, so a Swift Task continuation cannot be
    /// relied on to resume there. Its bounded mailbox wakes that loop for the completed frame.
    @MainActor
    static func prepare(at path: String,
                        completion: @escaping @MainActor @Sendable (Thumbnail?) -> Void) {
        queue.async {
            let result = thumbnail(at: path)
            NSWindowWorkerDelivery.shared.deliver { completion(result) }
        }
    }
}
#endif
