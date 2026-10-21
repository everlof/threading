#if os(Linux)
import AppKit
import Foundation
import LinuxWindowBridge

/// The Linux prompt's image rail. The host owns submission; this Design component owns the
/// bounded preview work, presentation and removal gesture for both composers.
@MainActor
final class LinuxPromptAttachmentStrip: PromptAttachmentStripView {
    struct AccessibleTile {
        let id: String
        let name: String
        let bounds: NSRect
        let removeBounds: NSRect
    }

    private struct Prepared: Sendable {
        let generation: Int
        let path: String
        let pixels: [UInt8]?
        let width: Int
        let height: Int
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var currentGeneration = 0
        private var values: [Prepared] = []
        func isCurrent(_ generation: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return currentGeneration == generation
        }
        func append(_ value: Prepared) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard currentGeneration == value.generation else { return false }
            values.append(value)
            return true
        }
        func reset(to generation: Int) {
            lock.lock()
            currentGeneration = generation
            values.removeAll(keepingCapacity: true)
            lock.unlock()
        }
        func take() -> [Prepared] {
            lock.lock()
            defer { lock.unlock() }
            let taken = values
            values.removeAll(keepingCapacity: true)
            return taken
        }
    }

    private let queue = DispatchQueue(label: "threading.linux.composer-attachments",
                                      qos: .userInitiated)
    private let results = Results()
    private var generation = 0
    private var preparingCount = 0
    private var clipboardReads = 0
    private var tiles: [PromptAttachmentThumbnail] = []
    var onChange: (() -> Void)?
    var onLiteralPath: ((String) -> Void)?

    var isPreparing: Bool { preparingCount > 0 || clipboardReads > 0 }
    var pasteGeneration: Int { generation }

    func beginClipboardRead() -> Int? {
        guard clipboardReads < 4 else { return nil }
        clipboardReads += 1
        onChange?()
        return generation
    }

    func finishClipboardRead(generation: Int) {
        guard self.generation == generation else { return }
        clipboardReads = max(0, clipboardReads - 1)
        onChange?()
    }
    var hasImages: Bool { !tiles.isEmpty }
    /// Nonmedia paths remain literal editor text, as on macOS. Decode one media path at a time;
    /// no file read or image codec runs on the window's UI thread.
    @discardableResult
    func addDroppedPath(_ path: String, wakeIdentity: UInt64) -> Bool {
        let mediaExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "avif"]
        guard mediaExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
            onLiteralPath?(path)
            return true
        }
        guard tiles.count + preparingCount < 32 else {
            onLiteralPath?(path)
            return true
        }
        preparingCount += 1
        onChange?()
        let generation = generation
        let results = results
        queue.async {
            guard results.isCurrent(generation) else { return }
            var rgba = [UInt8](repeating: 0, count: 128 * 128 * 4)
            var width: Int32 = 0
            var height: Int32 = 0
            let success = path.withCString { pointer in
                rgba.withUnsafeMutableBufferPointer { pixels in
                    tw_attachment_thumbnail(pointer, pixels.baseAddress, Int32(pixels.count),
                                            &width, &height) == 0
                }
            }
            let pixels = success ? Array(rgba.prefix(Int(width * height * 4))) : nil
            if results.append(Prepared(generation: generation, path: path, pixels: pixels,
                                       width: Int(width), height: Int(height))) {
                _ = tw_worker_wake(wakeIdentity)
            }
        }
        return true
    }

    func drainPrepared() {
        for prepared in results.take() where prepared.generation == generation {
            preparingCount -= 1
            if let pixels = prepared.pixels,
               let image = NSImage(rgba: pixels, width: prepared.width, height: prepared.height) {
                let attachment = PromptMediaAttachment(path: prepared.path, kind: .image, image: image)
                let tile = PromptAttachmentThumbnail(attachment: attachment)
                tile.onRemove = { [weak self, weak tile] in
                    guard let self, let tile else { return }
                    self.remove(tile)
                }
                appendTile(tile)
                tiles.append(tile)
            } else {
                onLiteralPath?(prepared.path)
            }
            onChange?()
        }
    }

    func clear() {
        generation &+= 1
        results.reset(to: generation)
        preparingCount = 0
        clipboardReads = 0
        clearTiles()
        tiles.removeAll(keepingCapacity: true)
        onChange?()
    }

    func submissionText(_ text: String) -> String {
        let paths = tiles.map(\.path)
        guard !paths.isEmpty else { return text }
        let addition = paths.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        guard !text.isEmpty else { return addition }
        return text + ((text.hasSuffix(" ") || text.hasSuffix("\n")) ? "" : " ") + addition
    }

    func accessibleTiles(in root: NSView) -> [AccessibleTile] {
        tiles.compactMap { tile in
            let visible = tile.visibleRect
            guard !visible.isEmpty else { return nil }
            let removeVisible = tile.removeVisibleRect.intersection(visible)
            guard !removeVisible.isEmpty else { return nil }
            return AccessibleTile(id: tile.id.uuidString,
                                  name: URL(fileURLWithPath: tile.path).lastPathComponent,
                                  bounds: tile.convert(visible, to: root),
                                  removeBounds: tile.convert(removeVisible, to: root))
        }
    }

    @discardableResult
    func removeAttachment(id: String) -> Bool {
        guard let tile = tiles.first(where: { $0.id.uuidString == id }) else { return false }
        remove(tile)
        return true
    }

    private func remove(_ tile: PromptAttachmentThumbnail) {
        guard let index = tiles.firstIndex(where: { $0 === tile }) else { return }
        tiles.remove(at: index)
        removeTile(tile)
        onChange?()
    }
}
#endif
