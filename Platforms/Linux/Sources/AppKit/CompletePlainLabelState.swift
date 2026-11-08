#if os(Linux)
import Foundation

/// Main-actor ownership is limited to the current recipe, selection and viewport pixels.
/// Complete source preparation and all Pango access belong to CompletePlainTextWorker.
@MainActor
final class CompletePlainLabelState {
    private struct CachedRaster {
        let recipe: CompleteTextRecipe
        let raster: CompleteTextRaster
        let used: UInt64
    }
    private static var rasters: [UUID: CachedRaster] = [:]
    private static var cacheClock: UInt64 = 0
    private static let rasterBudget = 16 * 1_024 * 1_024

    private let owner = UUID()
    private let changed: (Bool) -> Void
    private var recipe: CompleteTextRecipe?
    private var sourceGeneration: UInt64?
    private var text = ""
    private var viewport: CompleteTextViewport?
    private var sequence: UInt64 = 0
    private var commandSerial: UInt64 = 0
    private var acknowledgedSerial: UInt64 = 0
    private var commands: [CompleteTextCommand] = []
    private var queued = false
    private var failed = false
    private(set) var metrics: CompleteTextMetrics?
    private var metricsRecipe: CompleteTextRecipe?
    private(set) var selectedRange = NSRange(location: 0, length: 0)
    private(set) var anchor: Int?

    init(changed: @escaping (Bool) -> Void) { self.changed = changed }

    func update(_ desired: CompleteTextRecipe, text: String) {
        guard recipe != desired else { return }
        if sourceGeneration != desired.generation {
            // Keep the last measured geometry until the worker replaces it. Restyling
            // attributed prose creates a new source generation even when only its ink
            // changed; falling back to eight lines here clamps a deep scroll to the top.
            // Pixels and selection still belong exclusively to the new source.
            commands.removeAll()
            selectedRange = NSRange(location: 0, length: 0)
            anchor = nil
            Self.rasters[owner] = nil
        }
        sourceGeneration = desired.generation
        recipe = desired
        self.text = text
        viewport = nil
        queued = false
        failed = false
        request()
    }

    var isReady: Bool { metrics != nil && metricsRecipe == recipe && !failed }
    var isViewportReady: Bool {
        guard let cached = Self.rasters[owner] else { return false }
        return cached.recipe == recipe && cached.raster.viewport == viewport
    }

    func suspend() {
        sequence &+= 1
        recipe = nil
        viewport = nil
        queued = false
        metrics = nil
        metricsRecipe = nil
        Self.rasters[owner] = nil
        CompletePlainTextWorker.shared.release(owner)
    }

    func action(_ action: CompleteTextAction) {
        commandSerial &+= 1
        let command = CompleteTextCommand(serial: commandSerial, action: action)
        if case .pointer = action, let last = commands.last, case .pointer = last.action {
            commands[commands.count - 1] = command
        } else {
            commands.append(command)
        }
        request(force: true)
    }

    private func request(force: Bool = false) {
        guard let recipe, !failed, force || !queued else { return }
        sequence &+= 1
        let serial = sequence
        queued = CompletePlainTextWorker.shared.submit(.init(owner: owner, sequence: serial,
            recipe: recipe, text: text, viewport: viewport, commands: commands,
            selectedRange: selectedRange, anchor: anchor, acknowledgedSerial: acknowledgedSerial,
            completion: { [weak self] result in self?.receive(result) }))
    }

    private func receive(_ result: CompleteTextResult) {
        guard sourceGeneration == result.recipe.generation else { return }
        var selectionChanged = false
        if result.commandSerial > acknowledgedSerial {
            acknowledgedSerial = result.commandSerial
            commands.removeAll { $0.serial <= acknowledgedSerial }
            selectedRange = result.selectedRange
            anchor = result.anchor
            selectionChanged = true
        }
        // Copy is an explicit action, independent of a later viewport or resize request.
        if let copied = result.copied { _ = NSPasteboard.general.setString(copied, forType: .string) }
        guard result.sequence == sequence, result.recipe == recipe else {
            if selectionChanged { changed(false) }
            return
        }
        queued = false
        let heightChanged = metrics?.height != result.metrics?.height || metrics?.width != result.metrics?.width
        metrics = result.metrics
        metricsRecipe = result.recipe
        failed = result.metrics == nil
        if let raster = result.raster { cache(raster, recipe: result.recipe) }
        changed(heightChanged)
    }

    private func cache(_ raster: CompleteTextRaster, recipe: CompleteTextRecipe) {
        Self.cacheClock &+= 1
        Self.rasters[owner] = CachedRaster(recipe: recipe, raster: raster, used: Self.cacheClock)
        var bytes = Self.rasters.values.reduce(0) { $0 + $1.raster.glyphs.count + $1.raster.selectedGlyphs.count + $1.raster.selection.count }
        while bytes > Self.rasterBudget, Self.rasters.count > 1 {
            guard let oldest = Self.rasters.filter({ $0.key != owner }).min(by: { $0.value.used < $1.value.used }) else { break }
            bytes -= oldest.value.raster.glyphs.count + oldest.value.raster.selectedGlyphs.count + oldest.value.raster.selection.count
            Self.rasters[oldest.key] = nil
        }
    }

    func draw(in context: NSGraphicsContext, rect: NSRect, color: NSColor,
              selection: NSRange, attributes: [NSAttributedString.Key: Any]) -> Bool {
        guard let recipe else { return false }
        let scale = recipe.scale
        let matrix = context.transform
        guard matrix.b == 0, matrix.c == 0, matrix.a > 0, matrix.d == matrix.a,
              matrix.a.isFinite, matrix.tx.isFinite, matrix.ty.isFinite,
              rect.width > 0, rect.height > 0, rect.minX >= 0, rect.minY >= 0,
              rect.maxX.isFinite, rect.maxY.isFinite,
              rect.maxX * scale < Double(Int32.max), rect.maxY * scale < Double(Int32.max) else { return false }
        let selectedBackground = (attributes[.backgroundColor] as? NSColor) ?? .controlAccentColor
        let selectedForeground = (attributes[.foregroundColor] as? NSColor) ?? .white
        func ink(_ color: NSColor) -> CompleteTextInk {
            CompleteTextInk(red: Double(color.redComponent), green: Double(color.greenComponent),
                            blue: Double(color.blueComponent), alpha: Double(color.alphaComponent))
        }
        let desired = CompleteTextViewport(x: Int(floor(rect.minX * scale)), y: Int(floor(rect.minY * scale)),
            width: Int(ceil(rect.maxX * scale)) - Int(floor(rect.minX * scale)),
            height: Int(ceil(rect.maxY * scale)) - Int(floor(rect.minY * scale)), selection: selection,
            ordinary: ink(color), selected: ink(selectedForeground))
        if viewport != desired {
            viewport = desired
            request(force: true)
        } else if Self.rasters[owner]?.raster.viewport != desired { request() }
        guard let cached = Self.rasters[owner], cached.recipe.generation == recipe.generation else { return false }
        let raster = cached.raster
        let origin = matrix.apply(to: CGPoint(x: Double(raster.viewport.x) / scale,
                                            y: Double(raster.viewport.y) / scale))
        guard origin.x.isFinite, origin.y.isFinite,
              abs(origin.x) < Double(Int32.max), abs(origin.y) < Double(Int32.max) else { return false }
        let left = Int(floor(origin.x)), top = Int(floor(origin.y))
        let highlight = (selectedBackground.redComponent, selectedBackground.greenComponent,
                         selectedBackground.blueComponent, selectedBackground.alphaComponent * context.alpha)
        for row in 0..<raster.viewport.height {
            for column in 0..<raster.viewport.width {
                let index = row * raster.viewport.width + column
                let mask = CGFloat(raster.selection[index]) / 255
                let offset = index * 4
                if mask > 0 { context.composite(x: left + column, y: top + row, color: highlight, coverage: mask) }
                if raster.glyphs[offset + 3] > 0 {
                    context.composite(x: left + column, y: top + row,
                        color: (CGFloat(raster.glyphs[offset]) / 255, CGFloat(raster.glyphs[offset + 1]) / 255,
                                CGFloat(raster.glyphs[offset + 2]) / 255, CGFloat(raster.glyphs[offset + 3]) / 255 * context.alpha),
                        coverage: 1 - mask)
                }
                if mask > 0, raster.selectedGlyphs[offset + 3] > 0 {
                    context.composite(x: left + column, y: top + row,
                        color: (CGFloat(raster.selectedGlyphs[offset]) / 255, CGFloat(raster.selectedGlyphs[offset + 1]) / 255,
                                CGFloat(raster.selectedGlyphs[offset + 2]) / 255, CGFloat(raster.selectedGlyphs[offset + 3]) / 255 * context.alpha),
                        coverage: mask)
                }
            }
        }
        return true
    }

    deinit {
        CompletePlainTextWorker.shared.release(owner)
        let id = owner
        Task { @MainActor in Self.rasters[id] = nil }
    }
}
#endif
