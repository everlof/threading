#if os(Linux)
import Foundation
import AppKitTextBridge

struct CompleteTextRecipe: Equatable, Sendable {
    let generation: UInt64
    let width: Int
    let scale: Double
    let size: Double
    let monospace: Int32
    let weight: Int32
    let italic: Int32
    let characterWrapping: Int32
    let alignment: Int32
}

struct CompleteTextViewport: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let selection: NSRange
    let ordinary: CompleteTextInk
    let selected: CompleteTextInk
}

struct CompleteTextInk: Equatable, Sendable {
    let red: Double, green: Double, blue: Double, alpha: Double
}

struct CompleteTextMetrics: Sendable {
    let width: Int
    let height: Int
    let baseline: Int
    let utf16Length: Int
}

enum CompleteTextAction: Sendable {
    case pointer(start: CGPoint, end: CGPoint, anchor: Int?)
    case arrow(left: Bool, edge: Bool, extends: Bool)
    case selectAll
    case copy
}

struct CompleteTextCommand: Sendable {
    let serial: UInt64
    let action: CompleteTextAction
}

struct CompleteTextRaster: Sendable {
    let viewport: CompleteTextViewport
    let glyphs: [UInt8]
    let selectedGlyphs: [UInt8]
    let selection: [UInt8]
}

struct CompleteTextResult: Sendable {
    let sequence: UInt64
    let recipe: CompleteTextRecipe
    let metrics: CompleteTextMetrics?
    let raster: CompleteTextRaster?
    let selectedRange: NSRange
    let anchor: Int?
    let commandSerial: UInt64
    let copied: String?
}

/// Pango handles, complete UTF conversion, grapheme indexing and rasterization stay on this
/// serial owner. At most one job is active and one latest job per visible label is pending.
/// Plan retention is capped by 8 MiB of source and 64 owners; one larger document may stand alone.
final class CompletePlainTextWorker: @unchecked Sendable {
    static let shared = CompletePlainTextWorker()
    private static let maximumOwners = 64
    private static let sourceBudget = 8 * 1_024 * 1_024

    struct Job: Sendable {
        let owner: UUID
        let sequence: UInt64
        let recipe: CompleteTextRecipe
        let text: String
        let viewport: CompleteTextViewport?
        let commands: [CompleteTextCommand]
        let selectedRange: NSRange
        let anchor: Int?
        let acknowledgedSerial: UInt64
        let completion: @MainActor @Sendable (CompleteTextResult) -> Void
    }

    private final class Plan {
        let recipe: CompleteTextRecipe
        let handle: OpaquePointer
        let source: NSString
        let boundaries: [(byte: Int, utf16: Int)]
        let byteCount: Int
        let metrics: CompleteTextMetrics
        var selectedRange = NSRange(location: 0, length: 0)
        var anchor: Int?
        var commandSerial: UInt64 = 0
        var used: UInt64 = 0

        init?(recipe: CompleteTextRecipe, text: String) {
            let bytes = Array(text.utf8)
            guard !bytes.isEmpty, bytes.count <= Int(Int32.max) else { return nil }
            var metric = TATMetrics()
            var lines: Int32 = 0
            let created = bytes.withUnsafeBufferPointer {
                tat_document_create($0.baseAddress, Int32($0.count), recipe.monospace,
                    recipe.weight, recipe.italic, recipe.size, Int32(recipe.width),
                    recipe.characterWrapping, recipe.alignment, 1, &metric, &lines)
            }
            guard let created else { return nil }
            handle = created
            self.recipe = recipe
            byteCount = bytes.count
            source = text as NSString
            var values: [(byte: Int, utf16: Int)] = [(0, 0)]
            var byte = 0, utf16 = 0
            for character in text {
                let value = String(character)
                byte += value.utf8.count
                utf16 += value.utf16.count
                values.append((byte, utf16))
            }
            boundaries = values
            metrics = CompleteTextMetrics(width: Int(metric.width), height: Int(metric.height),
                baseline: Int(metric.baseline), utf16Length: utf16)
        }

        deinit { tat_document_destroy(handle) }

        private func boundary(_ value: Int, utf16: Bool) -> Int {
            var low = 0, high = boundaries.count - 1
            while low < high {
                let middle = low + (high - low) / 2
                let offset = utf16 ? boundaries[middle].utf16 : boundaries[middle].byte
                if offset < value { low = middle + 1 } else { high = middle }
            }
            return low
        }

        private func hit(_ point: CGPoint) -> Int {
            let byte = Int(tat_document_hit(handle, Double(point.x), Double(point.y)))
            return boundaries[boundary(max(0, byte), utf16: false)].utf16
        }

        func apply(_ command: CompleteTextCommand) -> String? {
            guard command.serial > commandSerial else { return nil }
            commandSerial = command.serial
            switch command.action {
            case .pointer(let start, let end, let statedAnchor):
                let first = statedAnchor ?? hit(start)
                let last = hit(end)
                anchor = first
                selectedRange = NSRange(location: min(first, last), length: abs(last - first))
            case .arrow(let left, let edge, let extends):
                let cursor = anchor == selectedRange.location ? NSMaxRange(selectedRange) : selectedRange.location
                let next: Int
                if edge { next = left ? 0 : metrics.utf16Length }
                else if !extends && selectedRange.length > 0 {
                    next = left ? selectedRange.location : NSMaxRange(selectedRange)
                } else {
                    let index = boundary(cursor, utf16: true)
                    next = boundaries[min(boundaries.count - 1, max(0, index + (left ? -1 : 1)))].utf16
                }
                let first = extends ? anchor ?? cursor : next
                selectedRange = NSRange(location: min(first, next), length: abs(next - first))
                anchor = extends ? first : nil
            case .selectAll:
                anchor = 0
                selectedRange = NSRange(location: 0, length: metrics.utf16Length)
            case .copy:
                guard selectedRange.length > 0, selectedRange.length <= 65_536 else { return nil }
                return source.substring(with: selectedRange)
            }
            return nil
        }

        func raster(_ viewport: CompleteTextViewport) -> CompleteTextRaster? {
            guard viewport.width > 0, viewport.height > 0,
                  viewport.width <= 8192, viewport.height <= 8192,
                  viewport.width * viewport.height <= 8 * 1_024 * 1_024 else { return nil }
            var glyphs = [UInt8](repeating: 0, count: viewport.width * viewport.height * 4)
            var selectedGlyphs = glyphs
            var selection = [UInt8](repeating: 0, count: viewport.width * viewport.height)
            let first = boundaries[boundary(viewport.selection.location, utf16: true)].byte
            let last = boundaries[boundary(NSMaxRange(viewport.selection), utf16: true)].byte
            for y in stride(from: 0, to: viewport.height, by: 128) {
                let height = min(128, viewport.height - y)
                for x in stride(from: 0, to: viewport.width, by: 2048) {
                    let width = min(2048, viewport.width - x)
                    var ink = [UInt8](repeating: 0, count: width * height * 4)
                    var selectedInk = ink
                    var selected = [UInt8](repeating: 0, count: width * height)
                    guard ink.withUnsafeMutableBufferPointer({
                        tat_document_render_rgba(handle, $0.baseAddress, Int32($0.count), Int32(width),
                            Int32(height), Int32(viewport.x + x), Int32(viewport.y + y),
                            viewport.ordinary.red, viewport.ordinary.green, viewport.ordinary.blue, viewport.ordinary.alpha)
                    }) == 1 else { return nil }
                    if last > first {
                        guard selectedInk.withUnsafeMutableBufferPointer({
                            tat_document_render_rgba(handle, $0.baseAddress, Int32($0.count), Int32(width),
                                Int32(height), Int32(viewport.x + x), Int32(viewport.y + y),
                                viewport.selected.red, viewport.selected.green, viewport.selected.blue, viewport.selected.alpha)
                        }) == 1 else { return nil }
                        guard selected.withUnsafeMutableBufferPointer({
                            tat_document_selection(handle, $0.baseAddress, Int32($0.count), Int32(width),
                                Int32(height), Int32(viewport.x + x), Int32(viewport.y + y), Int32(first), Int32(last))
                        }) == 1 else { return nil }
                    }
                    for row in 0..<height {
                        let target = (y + row) * viewport.width + x
                        glyphs.replaceSubrange((target * 4)..<((target + width) * 4), with: ink[(row * width * 4)..<((row + 1) * width * 4)])
                        selectedGlyphs.replaceSubrange((target * 4)..<((target + width) * 4), with: selectedInk[(row * width * 4)..<((row + 1) * width * 4)])
                        selection.replaceSubrange(target..<(target + width), with: selected[(row * width)..<((row + 1) * width)])
                    }
                }
            }
            return CompleteTextRaster(viewport: viewport, glyphs: glyphs, selectedGlyphs: selectedGlyphs, selection: selection)
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "threading.shim.complete-text", qos: .userInitiated)
    private var pending: [UUID: Job] = [:]
    private var order: [UUID] = []
    private var removals: Set<UUID> = []
    private var cachedOwners: Set<UUID> = []
    private var activeOwner: UUID?
    private var draining = false
    // These values are touched only by the serial queue.
    private var plans: [UUID: Plan] = [:]
    private var clock: UInt64 = 0

    @discardableResult
    func submit(_ job: Job) -> Bool {
        let admission = lock.withLock { () -> (accepted: Bool, start: Bool) in
            if pending[job.owner] == nil {
                guard order.count < Self.maximumOwners else { return (false, false) }
                order.append(job.owner)
            }
            pending[job.owner] = job
            removals.remove(job.owner)
            guard !draining else { return (true, false) }
            draining = true
            return (true, true)
        }
        if admission.start { queue.async { self.drain() } }
        return admission.accepted
    }

    func release(_ owner: UUID) {
        let start = lock.withLock { () -> Bool in
            pending[owner] = nil
            order.removeAll { $0 == owner }
            guard cachedOwners.contains(owner) || activeOwner == owner else { return false }
            removals.insert(owner)
            guard !draining else { return false }
            draining = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            let next = lock.withLock { () -> (Job?, Set<UUID>) in
                let remove = removals
                removals.removeAll()
                if order.isEmpty { draining = false; return (nil, remove) }
                let owner = order.removeFirst()
                activeOwner = owner
                return (pending.removeValue(forKey: owner), remove)
            }
            for owner in next.1 { plans[owner] = nil }
            let job = next.0
            guard let job else { return }
            if plans[job.owner]?.recipe != job.recipe {
                let previous = plans[job.owner]
                plans[job.owner] = nil
                plans[job.owner] = Plan(recipe: job.recipe, text: job.text)
                if let plan = plans[job.owner] {
                    let preserves = previous?.recipe.generation == job.recipe.generation
                    plan.selectedRange = preserves ? previous!.selectedRange : job.selectedRange
                    plan.anchor = preserves ? previous!.anchor : job.anchor
                    plan.commandSerial = preserves ? previous!.commandSerial : job.acknowledgedSerial
                }
            }
            let plan = plans[job.owner]
            clock &+= 1
            plan?.used = clock
            var copied: String?
            for command in job.commands { if let value = plan?.apply(command) { copied = value } }
            let result = CompleteTextResult(sequence: job.sequence, recipe: job.recipe,
                metrics: plan?.metrics, raster: job.viewport.flatMap { plan?.raster($0) },
                selectedRange: plan?.selectedRange ?? NSRange(location: 0, length: 0),
                anchor: plan?.anchor, commandSerial: plan?.commandSerial ?? 0, copied: copied)
            trimPlans(keeping: job.owner)
            let deliver = lock.withLock { () -> Bool in
                activeOwner = nil
                cachedOwners = Set(plans.keys)
                return !removals.contains(job.owner)
            }
            if deliver { Task { @MainActor in job.completion(result) } }
        }
    }

    private func trimPlans(keeping owner: UUID) {
        var bytes = plans.values.reduce(0) { $0 + $1.byteCount }
        while (bytes > Self.sourceBudget || plans.count > Self.maximumOwners), plans.count > 1 {
            guard let oldest = plans.filter({ $0.key != owner }).min(by: { $0.value.used < $1.value.used }) else { return }
            bytes -= oldest.value.byteCount
            plans[oldest.key] = nil
        }
    }
}
#endif
