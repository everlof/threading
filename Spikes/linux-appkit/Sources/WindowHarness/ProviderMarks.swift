import AppKit
import Foundation
@testable import CoreSlice
#if os(Linux)
import LinuxWindowBridge

/// Exactly two fixed assets, decoded once before the native event loop. Navigation only reads
/// cached images; neither session cardinality nor repaint frequency causes IO or codec work.
enum ProviderMarks {
    struct Pixels: Sendable {
        let kind: AgentKind
        let bytes: [UInt8]
        let width: Int
        let height: Int
    }

    @MainActor private static var images: [AgentKind: (normal: NSImage, selected: NSImage)] = [:]

    static func decode() -> [Pixels] {
        // Resolve from the executable, never cwd or a build-machine absolute resource path.
        // A missing resource directory is ordinary fallback, unlike Bundle.module's fatalError.
        guard let executable = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        else { return [] }
        let directory = URL(fileURLWithPath: executable).deletingLastPathComponent()
            .appendingPathComponent("LinuxAppKitSpike_WindowHarness.resources/ProviderMarks")
        return [(AgentKind.claude, "Claude"), (.codex, "Codex")].compactMap { kind, name in
            let url = directory.appendingPathComponent("AgentIcon\(name).png")
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 65537), !data.isEmpty, data.count <= 65536
            else { return nil }
            var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
            var width: Int32 = 0, height: Int32 = 0
            let result = data.withUnsafeBytes { input in
                bytes.withUnsafeMutableBufferPointer { output in
                    tw_decode_provider_png(input.bindMemory(to: UInt8.self).baseAddress,
                        Int32(data.count), output.baseAddress, Int32(output.count), &width, &height)
                }
            }
            guard result == 0 else { return nil }
            bytes.removeLast(bytes.count - Int(width * height * 4))
            return Pixels(kind: kind, bytes: bytes, width: Int(width), height: Int(height))
        }
    }

    @MainActor static func install(_ decoded: [Pixels]) {
        for pixels in decoded {
            guard let normal = NSImage(rgba: pixels.bytes, width: pixels.width, height: pixels.height),
                  let selected = NSImage(rgba: pixels.bytes, width: pixels.width, height: pixels.height)
            else { continue }
            normal.isTemplate = pixels.kind == .codex
            selected.isTemplate = true
            images[pixels.kind] = (normal, selected)
        }
        print("PROVIDER_MARKS cached=\(images.count) expected=2")
    }

    @MainActor static func image(for kind: AgentKind?, selected: Bool) -> NSImage? {
        guard let kind, let pair = images[kind] else { return nil }
        return selected ? pair.selected : pair.normal
    }
}
#endif
