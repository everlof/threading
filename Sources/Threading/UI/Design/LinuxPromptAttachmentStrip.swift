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
    private var tiles: [LinuxPromptAttachmentTile] = []
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
                let tile = LinuxPromptAttachmentTile(path: prepared.path, image: image)
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

    private func remove(_ tile: LinuxPromptAttachmentTile) {
        guard let index = tiles.firstIndex(where: { $0 === tile }) else { return }
        tiles.remove(at: index)
        removeTile(tile)
        onChange?()
    }
}

@MainActor
private final class LinuxPromptAttachmentTile: NSView {
    let id = UUID()
    let path: String
    private let image: NSImage
    private let remove = LinuxPromptAttachmentRemoveButton()
    var onRemove: (() -> Void)?
    var removeVisibleRect: NSRect { convert(remove.visibleRect, from: remove) }

    init(path: String, image: NSImage) {
        self.path = path
        self.image = image
        super.init(frame: .zero)
        setAccessibilityElement(true)
        remove.accessibilityName = "Remove \(URL(fileURLWithPath: path).lastPathComponent)"
        remove.setAccessibilityIdentifier("composer.attachment.remove")
        remove.onPress = { [weak self] in self?.onRemove?() }
        remove.translatesAutoresizingMaskIntoConstraints = false
        addSubview(remove)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Design.Size.promptAttachmentThumbnail),
            heightAnchor.constraint(equalToConstant: Design.Size.promptAttachmentThumbnail),
            remove.widthAnchor.constraint(equalToConstant: Design.Size.inlineButtonTarget),
            remove.heightAnchor.constraint(equalToConstant: Design.Size.inlineButtonTarget),
            remove.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.tight),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor,
                                             constant: -Design.Spacing.tight)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let radius = Design.Radius.control
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let destination = NSRect(x: bounds.midX - image.size.width * scale / 2,
                                 y: bounds.midY - image.size.height * scale / 2,
                                 width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: radius, yRadius: radius)
        Design.Surface.border.setStroke()
        border.lineWidth = 1
        border.stroke()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { URL(fileURLWithPath: path).lastPathComponent }
}

@MainActor
private final class LinuxPromptAttachmentRemoveButton: ThemedControl {
    var accessibilityName = "Remove attachment"
    var onPress: (() -> Void)?
    private var isPressed = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let panel = Design.Surface.panel.composited(over: Design.Surface.ground)
        let resting = Design.Surface.elevated.composited(over: panel)
        let fill = isPressed || isHovered
            ? Design.Surface.controlHover.composited(over: resting) : resting
        let ink = Design.Text.on(fill)
        let plate = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        fill.setFill()
        plate.fill()
        ink.border.setStroke()
        plate.lineWidth = 1
        plate.stroke()
        let mark = NSBezierPath()
        let inset = bounds.width * 0.34
        mark.move(to: NSPoint(x: inset, y: inset))
        mark.line(to: NSPoint(x: bounds.maxX - inset, y: bounds.maxY - inset))
        mark.move(to: NSPoint(x: inset, y: bounds.maxY - inset))
        mark.line(to: NSPoint(x: bounds.maxX - inset, y: inset))
        ink.label.setStroke()
        mark.lineWidth = 1.5
        mark.lineCapStyle = .round
        mark.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        window?.makeFirstResponder(self)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldPress = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if shouldPress { _ = performPrimaryAction() }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityTitle() -> String? { accessibilityName }
    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }
    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }
}
#endif
