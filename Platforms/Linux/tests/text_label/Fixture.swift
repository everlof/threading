import AppKit
import Foundation
import Dispatch
#if os(Linux)
import AppKitTextBridge
#endif

// Environment facts only. ControlRow.swift is a symlink to unchanged production Design code.
@MainActor public enum Design {
    public enum Size {
        static let choiceHeight: CGFloat = 26
        static let fieldHeight: CGFloat = 34
    }
    public enum Spacing {
        static let tight: CGFloat = 4
        static let hairline: CGFloat = 1
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let inset: CGFloat = 12
    }
    public enum Symbol {
        public enum Role { case compact
            public var pointSize: CGFloat { 12 }
        }
        static func slot(inControlOfHeight height: CGFloat) -> CGFloat { height - 4 }
        static func role(forSlot slot: CGFloat) -> Role { .compact }
    }
    public enum Text {
        static let label = NSColor(white: 0.08, alpha: 1)
        static let secondary = NSColor(white: 0.15, alpha: 0.85)
        static let tertiary = NSColor(white: 0.18, alpha: 0.8)
    }
    public enum Status {
        static let negative = NSColor(red: 0.82, green: 0.1, blue: 0.12, alpha: 1)
    }
    public enum Surface {
        static let floating = NSColor(white: 0.97, alpha: 1)
        static let elevated = NSColor(white: 0.91, alpha: 1)
    }
    @MainActor public enum Chart {
        enum Series { case primary }
        static func color(for series: Series) -> NSColor {
            NSAppearance.currentDrawing().name == .darkAqua
                ? NSColor(red: 0.95, green: 0.55, blue: 0.12, alpha: 1)
                : NSColor(red: 0.1, green: 0.35, blue: 0.8, alpha: 1)
        }
    }
    @MainActor public enum Typography {
        static func compactCode() -> NSFont { .monospacedSystemFont(ofSize: 11) }
        static func numericDetail() -> NSFont { .monospacedSystemFont(ofSize: 11) }
        static func numericControl(weight: NSFont.Weight) -> NSFont {
            .monospacedSystemFont(ofSize: 14, weight: weight)
        }
        static func lineHeight(of font: NSFont) -> CGFloat { font.pointSize + 4 }
    }
    @MainActor public enum FontRole {
        case heading, emphasizedBody, caption, body, numericBody, numeric
        static var scale: CGFloat = 1
        static func numericDetail() -> Self { .numeric }
        func resolved() -> NSFont {
            switch self {
            case .heading: return .systemFont(ofSize: 20 * Self.scale, weight: .semibold)
            case .emphasizedBody: return .systemFont(ofSize: 15 * Self.scale, weight: .semibold)
            case .caption: return .systemFont(ofSize: 11 * Self.scale)
            case .body: return .systemFont(ofSize: 13 * Self.scale)
            case .numericBody: return .monospacedSystemFont(ofSize: 13 * Self.scale)
            case .numeric: return .monospacedSystemFont(ofSize: 11 * Self.scale)
            }
        }
    }
}
struct StorageCleanupOutline {
    struct Row {
        let depth: Int
        let label: String
        let byteCount: Int64
        let note: String?
        let isDirectory: Bool
    }
    struct Section {
        let heading: String
        let subheading: String
        let byteCount: Int64
        let rows: [Row]
    }
    let sections: [Section]
    func plainText() -> String {
        sections.map { section in
            ([section.heading] + section.rows.map(\.label)).joined(separator: "\n")
        }.joined(separator: "\n")
    }
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
@MainActor protocol ThemedComponent {}
@MainActor protocol SystemChromeBoundary: AnyObject {
    func permitsSystemChrome(_ view: NSView) -> Bool
}
@MainActor class ThemedControl: NSView {
    var isEnabled = true
    var isHovered = false
    func performPrimaryAction() -> Bool { false }
    func drawKeyboardFocus(around shape: NSBezierPath, color: NSColor) {}
}
@MainActor enum ThemedSurface {
    static func draw(_ rect: NSRect, fill: NSColor, border: NSColor,
                     radius: CGFloat, borderWidth: CGFloat) -> NSBezierPath {
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        shape.fill()
        border.setStroke()
        shape.lineWidth = borderWidth
        shape.stroke()
        return shape
    }
}
enum L10n {
    static func string(_ text: String) -> String { text }
    static func format(_ format: String, _ value: String) -> String {
        String(format: format, value)
    }
}
@MainActor final class ThemeRedraw {
    init(_ view: NSView) {}
}
extension NSTextField {
    // The fixture supplies only the production role resolution needed by this unchanged view.
    // The Mac app's FontRole.swift owns recording and live theme reapplication.
    func applyFont(_ role: Design.FontRole) {
        font = role.resolved()
    }
}
struct AppThemeDidChange {}
@MainActor final class AppEventObservations {
    func observe<Event>(_ event: Event.Type, _ handler: @escaping (Event) -> Void) {}
}

#if os(Linux)
private func measured(_ text: String, scale: CGFloat = 1) -> TATMetrics {
    var metric = TATMetrics(width: 0, height: 0, baseline: 0, glyphs: 0)
    let bytes = Array(text.utf8)
    let success = bytes.withUnsafeBufferPointer {
        tat_measure($0.baseAddress, Int32($0.count), 0, 0, Double(13 * scale), &metric)
    }
    precondition(success == 1)
    return metric
}

@MainActor private func render(_ label: NSTextField, width: Int = 100, height: Int = 40) -> Bitmap {
    let bitmap = Bitmap(width: width, height: height, background: (1, 1, 1, 1))
    let context = NSGraphicsContext(bitmap: bitmap, scale: 1)
    label.render(in: context)
    return bitmap
}

@MainActor private final class FlippedRoot: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class AppearanceProbe: NSView {
    private(set) var changes = 0
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        changes += 1
    }
}

@MainActor private final class WindowMoveLog {
    var entries: [String] = []
    var first: NSWindow?
    var second: NSWindow?

    func name(_ window: NSWindow?) -> String {
        if window === first { return "first" }
        if window === second { return "second" }
        return "nil"
    }
}

@MainActor private final class WindowMoveProbe: NSView {
    let name: String
    let log: WindowMoveLog

    init(_ name: String, log: WindowMoveLog) {
        self.name = name
        self.log = log
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        log.entries.append("\(name):will:\(log.name(window))->\(log.name(newWindow))")
    }

    override func viewDidMoveToWindow() {
        log.entries.append("\(name):did:\(log.name(window))")
    }
}

@MainActor private final class SuperviewMoveProbe: NSView {
    var parents: [NSView?] = []

    override func viewDidMoveToSuperview() {
        parents.append(superview)
    }
}

@MainActor private final class DynamicColorProbe: NSView {
    let named = NSColor(name: NSColor.Name("fixture.appearance")) { appearance in
        appearance.name == .darkAqua
            ? NSColor(red: 0.1, green: 0.35, blue: 0.9, alpha: 1)
            : NSColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)
    }
    lazy var halfAlpha = named.withAlphaComponent(0.5)
    lazy var mixed = named.blended(withFraction: 0.5, of: .white)!

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        for (index, color) in [named, halfAlpha, mixed, NSColor.labelColor].enumerated() {
            color.setFill()
            NSRect(x: CGFloat(index * 60 + 10), y: 10, width: 44, height: 44).fill()
        }
    }
}

@MainActor private final class PointEvent: NSEvent {
    private let point: NSPoint
    init(_ point: NSPoint) {
        self.point = point
        super.init()
    }
    override var locationInWindow: NSPoint { point }
}

@MainActor private final class FocusProbe: NSView {
    var allowsBecome = true
    var allowsResign = true
    var became = 0
    var resigned = 0
    override func becomeFirstResponder() -> Bool {
        became += 1
        return allowsBecome
    }
    override func resignFirstResponder() -> Bool {
        resigned += 1
        return allowsResign
    }
}

private func inkCount(_ bitmap: Bitmap, x: Range<Int>, y: Range<Int>) -> Int {
    var count = 0
    for row in y where row >= 0 && row < bitmap.height {
        for column in x where column >= 0 && column < bitmap.width {
            let index = (row * bitmap.width + column) * 4
            if bitmap.pixels[index] < 245 { count += 1 }
        }
    }
    return count
}

private func storageOutline(rowCount: Int) -> StorageCleanupOutline {
    let rows = (0..<rowCount).map { index in
        StorageCleanupOutline.Row(
            depth: index % 4,
            label: "pkg/Ångström/module-\(index)/node_modules",
            byteCount: Int64(1_000_000 + index * 8192),
            note: index.isMultiple(of: 17) ? "in use" : nil,
            isDirectory: !index.isMultiple(of: 10)
        )
    }
    return StorageCleanupOutline(sections: [
        .init(heading: "app · main", subheading: "~/repo/app", byteCount: 2_400_000_000,
              rows: rows)
    ])
}

@MainActor private func renderOutline(_ view: StorageProposalOutlineView,
                                      offset: CGFloat, width: Int = 360,
                                      viewportHeight: Int = 180) -> Bitmap {
    let bitmap = Bitmap(width: width, height: viewportHeight, background: (1, 1, 1, 1))
    let context = NSGraphicsContext(bitmap: bitmap, scale: 1)
    context.saveGraphicsState()
    context.flipVertically(in: CGFloat(viewportHeight))
    context.translateBy(x: 0, y: -offset)
    NSGraphicsContext.current = context
    view.draw(NSRect(x: 0, y: offset, width: CGFloat(width), height: CGFloat(viewportHeight)))
    NSGraphicsContext.current = nil
    context.restoreGraphicsState()
    return bitmap
}

private struct InkPolicy: Decodable {
    struct Sample: Decodable {
        let name: String
        let ground: [Double]
        let label: [Double]
        let secondary: [Double]
        let tertiary: [Double]
        let quaternary: [Double]
    }
    let readingRatio: Double
    let glanceRatio: Double
    let cases: [Sample]
}

@MainActor private func checkNeutralInkLabels(at path: String) throws {
    let policy = try JSONDecoder().decode(InkPolicy.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    precondition(policy.readingRatio == 4.5 && policy.glanceRatio == 3 && policy.cases.count == 8)
    func luminance(_ values: [Double]) -> Double {
        let linear = values.prefix(3).map { value in
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
    func contrast(_ first: [Double], _ second: [Double]) -> Double {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    for sample in policy.cases {
        let background = sample.ground.prefix(3).map { Int(($0 * 255).rounded()) }
        let roles = [sample.label, sample.secondary, sample.tertiary, sample.quaternary]
        for (index, ink) in roles.enumerated() {
            let composite = (0..<3).map { channel in
                ink[channel] * ink[3] + sample.ground[channel] * (1 - ink[3])
            }
            precondition(contrast(composite, sample.ground) >=
                         (index == 3 ? policy.glanceRatio : policy.readingRatio),
                         "neutral ink contrast fell below its measured floor")
        }
        for ink in roles.prefix(2) {
            let label = NSTextField(labelWithString: "MMMMMMMM")
            label.frame = NSRect(x: 8, y: 8, width: 176, height: 30)
            label.font = .systemFont(ofSize: 17)
            label.textColor = NSColor(red: ink[0], green: ink[1], blue: ink[2], alpha: ink[3])
            let bitmap = Bitmap(width: 200, height: 50,
                                background: (sample.ground[0], sample.ground[1], sample.ground[2], 1))
            label.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
            let expected = (0..<3).map { channel in
                Int((ink[channel] * ink[3] * 255 + Double(background[channel]) * (1 - ink[3])).rounded())
            }
            var closest = 255
            for y in 0..<50 {
                for x in 0..<200 {
                    let offset = (y * 200 + x) * 4
                    if (8..<184).contains(x) && (12..<42).contains(y) {
                        closest = min(closest, (0..<3).map { channel in
                            abs(Int(bitmap.pixels[offset + channel]) - expected[channel])
                        }.max()!)
                    } else {
                        precondition((0..<3).allSatisfy { Int(bitmap.pixels[offset + $0]) == background[$0] },
                                     "label escaped its mounted rectangle")
                    }
                }
            }
            precondition(closest <= 2, "shaped label did not reach resolved \(sample.name) ink")
        }
    }
    print("PASS shared neutral ink floors and Pango label pixels on eight grounds")
}

@MainActor private func benchmarkNavigatorLabels() {
    func makeRoot() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 450))
        for index in 0..<18 {
            for run in 0..<3 {
                let label = NSTextField(labelWithString:
                    run == 0 ? "Angström Claude 日本語 — session \(index)" :
                    run == 1 ? "Claude Code · 92F3A121 · project" : "Retained")
                label.font = NSFont.systemFont(ofSize: run == 0 ? 9 : 7,
                                               weight: run == 0 ? .semibold : .regular)
                label.textColor = NSColor(white: 0, alpha: run == 0 ? 1 : 0.7)
                label.lineBreakMode = .byTruncatingTail
                label.frame = NSRect(x: run == 2 ? 250 : 32,
                                     y: CGFloat(450 - 28 - index * 24),
                                     width: run == 2 ? 60 : 190, height: 11)
                root.addSubview(label)
            }
        }
        return root
    }
    var times: [Double] = []
    for index in 0..<9 {
        let before = DispatchTime.now().uptimeNanoseconds
        let root = makeRoot()
        let bitmap = Bitmap(width: 640, height: 900, background: (1, 1, 1, 1))
        let context = NSGraphicsContext(bitmap: bitmap, scale: 2)
        root.render(in: context)
        if index > 0 {
            times.append(Double(DispatchTime.now().uptimeNanoseconds - before) / 1_000_000)
        }
    }
    let sorted = times.sorted()
    print("NAVIGATOR_LABEL_BENCHMARK mounted=54 rebuiltFrames=8 medianMs=\(sorted[4]) maxMs=\(sorted[7])")
}

@MainActor private func benchmarkCompoundReadings() {
    var times: [Double] = []
    for frame in 0..<9 {
        let started = DispatchTime.now().uptimeNanoseconds
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 450))
        for index in 0..<18 {
            let reading = CompoundValueLabel()
            reading.segments = ["12%", "248 MB", "3 files"]
            reading.translatesAutoresizingMaskIntoConstraints = true
            reading.frame = NSRect(x: 26, y: CGFloat(index * 24 + 10), width: 260, height: 18)
            root.addSubview(reading)
        }
        let bitmap = Bitmap(width: 640, height: 900, background: (1, 1, 1, 1))
        root.render(in: NSGraphicsContext(bitmap: bitmap, scale: 2))
        if frame > 0 {
            times.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
    }
    let sorted = times.sorted()
    print("COMPOUND_READING_BENCHMARK mounted=18 rebuiltFrames=8 medianMs=\(sorted[4]) maxMs=\(sorted[7])")
}

@MainActor private func benchmarkStorageOutline() {
    for rowCount in [170, 1700] {
        let outline = StorageProposalOutlineView(
            outline: storageOutline(rowCount: rowCount), accessibilityLabel: "cleanup"
        )
        let height = outline.fittingHeight()
        outline.frame = NSRect(x: 0, y: 0, width: 360, height: height)
        let offset = max(0, height - 180)
        _ = renderOutline(outline, offset: offset)
        var times: [Double] = []
        for _ in 0..<8 {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = renderOutline(outline, offset: offset)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        let sorted = times.sorted()
        print("STORAGE_OUTLINE_BENCHMARK totalRows=\(rowCount) visibleHeight=180 " +
              "repaints=8 medianMs=\(sorted[4]) maxMs=\(sorted[7])")
    }
}
#endif

@main struct TextLabelFixture {
    @MainActor static func main() throws {
        #if os(Linux)
        if CommandLine.arguments.contains("--benchmark") {
            benchmarkNavigatorLabels()
            benchmarkCompoundReadings()
            benchmarkStorageOutline()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--ink-json") {
            precondition(CommandLine.arguments.indices.contains(index + 1))
            try checkNeutralInkLabels(at: CommandLine.arguments[index + 1])
        }
        let composed = measured("é")
        let decomposed = measured("e\u{301}")
        precondition(composed.glyphs == 1 && decomposed.glyphs == 1,
                     "Pango must shape combining accent as one glyph")
        precondition(composed.width == decomposed.width && composed.height == decomposed.height)
        let arabic = measured("لا")
        precondition(arabic.glyphs == 1, "Pango must shape the lam-alef ligature")
        precondition(arabic.width > 0 && arabic.baseline > 0 && arabic.baseline < arabic.height)

        let longText = "Unicode مرحبا café — a long status that needs truncation"
        let label = NSTextField(labelWithString: longText)
        precondition(label.accessibilityLabel() == longText)
        label.frame = NSRect(x: 10, y: 10, width: 66, height: 24)
        label.lineBreakMode = .byClipping
        let clipped = render(label)
        label.lineBreakMode = .byTruncatingTail
        let truncated = render(label)
        try FileManager.default.createDirectory(atPath: "out", withIntermediateDirectories: true)
        try PNGWriter.write(clipped, to: URL(fileURLWithPath: "out/text-clipped.png"))
        try PNGWriter.write(truncated, to: URL(fileURLWithPath: "out/text-truncated.png"))
        print("label pixels clipped=\(inkCount(clipped, x: 0..<100, y: 0..<40)) truncated=\(inkCount(truncated, x: 0..<100, y: 0..<40)) frame=\(label.frame)")
        precondition(clipped.pixels != truncated.pixels, "tail ellipsis must change visible glyphs")
        precondition(inkCount(truncated, x: 10..<76, y: 6..<30) > 20,
                     "truncated label must draw glyphs")
        precondition(inkCount(truncated, x: 0..<10, y: 0..<40) == 0 &&
                     inkCount(truncated, x: 76..<100, y: 0..<40) == 0,
                     "glyphs escaped the label's visible bounds")
        let measuredLabel = NSTextField(labelWithString: "café لا")
        let emptyLabel = NSTextField(labelWithString: "")
        precondition(emptyLabel.intrinsicContentSize.width == 0 &&
                     emptyLabel.intrinsicContentSize.height >= 10,
                     "empty label should retain a font line height")
        let intrinsic = measuredLabel.intrinsicContentSize
        let metric = measured("café لا")
        precondition(intrinsic.width == CGFloat(metric.width) && intrinsic.height == CGFloat(metric.height))
        let baseline = measuredLabel.firstBaselineMetric
        precondition(baseline.heightFraction == 0.5 &&
                     baseline.offset == CGFloat(metric.baseline) - CGFloat(metric.height) / 2)
        let scaleLabel = NSTextField(labelWithString: "WaylandProject")
        let detachedSize = scaleLabel.intrinsicContentSize
        let scaleRoot = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        scaleRoot.addSubview(scaleLabel)
        let scaleWindow = NSWindow(backingScaleFactor: 2)
        scaleWindow.contentView = scaleRoot
        let scaledMetric = measured("WaylandProject", scale: 2)
        precondition(scaleLabel.intrinsicContentSize == NSSize(
            width: CGFloat(scaledMetric.width) / 2, height: CGFloat(scaledMetric.height) / 2),
            "attached label must measure at the same scale as Pango drawing")
        scaleWindow.contentView = nil
        precondition(scaleLabel.intrinsicContentSize == detachedSize,
                     "detaching must restore the default-scale intrinsic size")
        let wrapping = NSTextField(wrappingLabelWithString: longText)
        precondition(wrapping.firstBaselineMetric.heightFraction == 0)
        let naturalWrapSize = wrapping.intrinsicContentSize
        wrapping.preferredMaxLayoutWidth = 100
        let narrowWrapSize = wrapping.intrinsicContentSize
        precondition(narrowWrapSize.width <= 101 && narrowWrapSize.height > naturalWrapSize.height,
                     "preferred width must remeasure a wrapping label's line count")
        wrapping.preferredMaxLayoutWidth = 220
        let wideWrapSize = wrapping.intrinsicContentSize
        precondition(wideWrapSize.height < narrowWrapSize.height,
                     "expanding preferred width must reduce the measured line count")
        wrapping.preferredMaxLayoutWidth = 0
        precondition(wrapping.intrinsicContentSize == naturalWrapSize,
                     "clearing preferred width must restore natural text measurement")
        let attributedWrap = NSTextField(wrappingLabelWithString: "")
        attributedWrap.attributedStringValue = NSAttributedString(
            string: longText, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let attributedNaturalHeight = attributedWrap.intrinsicContentSize.height
        attributedWrap.preferredMaxLayoutWidth = 100
        precondition(attributedWrap.intrinsicContentSize.height > attributedNaturalHeight &&
                     attributedWrap.intrinsicContentSize.width <= 101,
                     "preferred width must also remeasure attributed labels")
        attributedWrap.maximumNumberOfLines = 2
        precondition(attributedWrap.intrinsicContentSize.height < narrowWrapSize.height,
                     "visible-line limit must bound preferred-width measurement")
        let emptyWrapping = NSTextField(wrappingLabelWithString: "")
        precondition(emptyWrapping.intrinsicContentSize.width == 0 &&
                     emptyWrapping.intrinsicContentSize.height >= 10,
                     "empty wrapping label must keep line height without claiming width")
        let authored = "Threading\non Linux"
        let multiline = NSTextField(wrappingLabelWithString: authored)
        multiline.font = .systemFont(ofSize: 20, weight: .semibold)
        let firstLine = NSTextField(labelWithString: "Threading")
        firstLine.font = multiline.font
        precondition(multiline.intrinsicContentSize.height >= firstLine.intrinsicContentSize.height * 1.8,
                     "authored line break collapsed in intrinsic measurement")
        multiline.maximumNumberOfLines = 1
        precondition(multiline.intrinsicContentSize.height <= firstLine.intrinsicContentSize.height + 2,
                     "line limit did not bound intrinsic measurement")
        multiline.maximumNumberOfLines = 0

        let productionTitle = ThemedMultilineTitleLabel()
        productionTitle.stringValue = authored
        productionTitle.applyFont(.heading)
        precondition(productionTitle.accessibilityRole() == .staticText &&
                     productionTitle.accessibilityLabel() == "Threading. on Linux")
        precondition(productionTitle.intrinsicContentSize.height >= firstLine.intrinsicContentSize.height * 1.8)
        let titleRoot = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        titleRoot.addSubview(productionTitle)
        NSLayoutConstraint.activate([
            productionTitle.leadingAnchor.constraint(equalTo: titleRoot.leadingAnchor, constant: 12),
            productionTitle.topAnchor.constraint(equalTo: titleRoot.topAnchor, constant: 12),
            productionTitle.widthAnchor.constraint(equalToConstant: 296),
            productionTitle.heightAnchor.constraint(equalToConstant: 76),
        ])
        let titleBitmap = Bitmap(width: 320, height: 100, background: (1, 1, 1, 1))
        titleRoot.render(in: NSGraphicsContext(bitmap: titleBitmap, scale: 1))
        try PNGWriter.write(titleBitmap, to: URL(fileURLWithPath: "out/text-label-multiline-title.png"))
        precondition(abs(productionTitle.frame.minX - 12) < 0.1 &&
                     abs(productionTitle.frame.minY - 12) < 0.1)
        precondition(inkCount(titleBitmap, x: 0..<12, y: 0..<100) == 0 &&
                     inkCount(titleBitmap, x: 12..<308, y: 0..<12) == 0,
                     "production title escaped its constrained rectangle")
        let occupiedRows = (0..<100).filter { inkCount(titleBitmap, x: 12..<308, y: $0..<($0 + 1)) > 2 }
        precondition((occupiedRows.last ?? 0) - (occupiedRows.first ?? 0) >= 28,
                     "production multiline title did not paint two distinct lines")
        print("PASS unchanged production multiline title: authored breaks, intrinsic size, pixels and accessibility")

        let attributed = NSMutableAttributedString(
            string: "Café لا ready",
            attributes: [.font: NSFont.systemFont(ofSize: 16),
                         .foregroundColor: NSColor(white: 0.1, alpha: 1)]
        )
        let arabicRange = (attributed.string as NSString).range(of: "لا")
        attributed.addAttributes([
            .font: NSFont.systemFont(ofSize: 21, weight: .semibold),
            .foregroundColor: NSColor(red: 0.8, green: 0.08, blue: 0.08, alpha: 1),
            .backgroundColor: NSColor(red: 1, green: 0.88, blue: 0.36, alpha: 1),
            .underlineStyle: NSNumber(value: 1)
        ], range: arabicRange)
        precondition(attributed.size().height >= 21 && attributed.size().width > 50)
        let attributedBitmap = Bitmap(width: 220, height: 65, background: (1, 1, 1, 1))
        NSGraphicsContext.current = NSGraphicsContext(bitmap: attributedBitmap, scale: 1)
        attributed.draw(at: NSPoint(x: 8, y: 12))
        NSGraphicsContext.current = nil
        try PNGWriter.write(attributedBitmap, to: URL(fileURLWithPath: "out/text-label-attributed.png"))
        var redPixels = 0, yellowPixels = 0, darkPixels = 0
        for offset in stride(from: 0, to: attributedBitmap.pixels.count, by: 4) {
            let red = Int(attributedBitmap.pixels[offset])
            let green = Int(attributedBitmap.pixels[offset + 1])
            let blue = Int(attributedBitmap.pixels[offset + 2])
            if red > green + 65 && red > blue + 65 { redPixels += 1 }
            if red > 190 && green > 150 && blue < 150 { yellowPixels += 1 }
            if red < 100 && green < 100 && blue < 100 { darkPixels += 1 }
        }
        precondition(redPixels > 15 && yellowPixels > 15 && darkPixels > 40,
                     "mixed shaped runs lost foreground, background or ordinary text")

        let translucent = NSAttributedString(
            string: "MMMM",
            attributes: [.font: NSFont.systemFont(ofSize: 17),
                         .foregroundColor: NSColor(red: 1, green: 0, blue: 0, alpha: 0.5)]
        )
        let clearAttributed = Bitmap(width: 100, height: 40)
        NSGraphicsContext.current = NSGraphicsContext(bitmap: clearAttributed, scale: 1)
        translucent.draw(at: NSPoint(x: 5, y: 5))
        NSGraphicsContext.current = nil
        let whiteAttributed = Bitmap(width: 100, height: 40, background: (1, 1, 1, 1))
        NSGraphicsContext.current = NSGraphicsContext(bitmap: whiteAttributed, scale: 1)
        translucent.draw(at: NSPoint(x: 5, y: 5))
        NSGraphicsContext.current = nil
        try PNGWriter.write(clearAttributed, to: URL(fileURLWithPath: "out/text-label-attributed-alpha-clear.png"))
        try PNGWriter.write(whiteAttributed, to: URL(fileURLWithPath: "out/text-label-attributed-alpha-white.png"))
        var translucentPixels = 0, clearError = 0, opaqueError = 0
        for offset in stride(from: 0, to: clearAttributed.pixels.count, by: 4) {
            let alpha = Int(clearAttributed.pixels[offset + 3])
            guard alpha > 0 else { continue }
            translucentPixels += 1
            let error = max(abs(Int(clearAttributed.pixels[offset]) - 255),
                            Int(clearAttributed.pixels[offset + 1]),
                            Int(clearAttributed.pixels[offset + 2]))
            clearError = max(clearError, error)
            opaqueError = max(opaqueError, abs(Int(whiteAttributed.pixels[offset]) - 255),
                              abs(Int(whiteAttributed.pixels[offset + 1]) - (255 - alpha)),
                              abs(Int(whiteAttributed.pixels[offset + 2]) - (255 - alpha)))
        }
        precondition(translucentPixels > 20 && clearError <= 1 && opaqueError <= 1,
                     "attributed ink must composite consistently on clear and opaque bitmaps")

        let shortText = "Café لا" as NSString
        let shortAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17),
            .foregroundColor: NSColor(red: 0.12, green: 0.2, blue: 0.75, alpha: 1)
        ]
        precondition(shortText.size(withAttributes: shortAttributes) ==
                     NSAttributedString(string: shortText as String,
                                        attributes: shortAttributes).size())
        let stringAt = Bitmap(width: 170, height: 65, background: (1, 1, 1, 1))
        NSGraphicsContext.current = NSGraphicsContext(bitmap: stringAt, scale: 1)
        shortText.draw(at: NSPoint(x: 9, y: 11), withAttributes: shortAttributes)
        NSGraphicsContext.current = nil
        let attributedAt = Bitmap(width: 170, height: 65, background: (1, 1, 1, 1))
        NSGraphicsContext.current = NSGraphicsContext(bitmap: attributedAt, scale: 1)
        NSAttributedString(string: shortText as String, attributes: shortAttributes)
            .draw(at: NSPoint(x: 9, y: 11))
        NSGraphicsContext.current = nil
        precondition(stringAt.pixels == attributedAt.pixels,
                     "NSString and attributed drawing must share exact glyph pixels")

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .right
        var rectangleAttributes = shortAttributes
        rectangleAttributes[.paragraphStyle] = paragraph
        let rectangle = Bitmap(width: 170, height: 65, background: (1, 1, 1, 1))
        NSGraphicsContext.current = NSGraphicsContext(bitmap: rectangle, scale: 1)
        ("Unicode مرحبا café status" as NSString).draw(
            in: NSRect(x: 12, y: 12, width: 76, height: 26),
            withAttributes: rectangleAttributes
        )
        NSGraphicsContext.current = nil
        try PNGWriter.write(rectangle, to: URL(fileURLWithPath: "out/text-label-string-rect.png"))
        var rectangleInk = 0
        for y in 0..<rectangle.height {
            for x in 0..<rectangle.width {
                let offset = (y * rectangle.width + x) * 4
                guard rectangle.pixels[offset] < 245 else { continue }
                precondition((12..<88).contains(x) && (27..<53).contains(y),
                             "rectangular NSString drawing escaped its slot")
                rectangleInk += 1
            }
        }
        precondition(rectangleInk > 20, "right-aligned truncated NSString drew no text")

        let wrappingParagraph = NSMutableParagraphStyle()
        wrappingParagraph.lineBreakMode = .byWordWrapping
        var wrappingAttributes = shortAttributes
        wrappingAttributes[.paragraphStyle] = wrappingParagraph
        let wrappedString = Bitmap(width: 130, height: 90, background: (1, 1, 1, 1))
        NSGraphicsContext.current = NSGraphicsContext(bitmap: wrappedString, scale: 1)
        ("Alpha Beta Gamma" as NSString).draw(
            in: NSRect(x: 9, y: 9, width: 58, height: 66),
            withAttributes: wrappingAttributes
        )
        NSGraphicsContext.current = nil
        precondition(inkCount(wrappedString, x: 9..<67, y: 42..<61) > 5 &&
                     inkCount(wrappedString, x: 9..<67, y: 61..<81) > 5,
                     "word wrapping must paint more than one line inside its slot")
        try PNGWriter.write(wrappedString, to: URL(fileURLWithPath: "out/text-label-string-wrap.png"))

        let runLimited = NSMutableAttributedString(
            string: String(repeating: "A", count: 4033) + String(repeating: "B", count: 63),
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        )
        for index in 4033..<4096 {
            runLimited.addAttribute(.foregroundColor,
                                    value: index.isMultiple(of: 2)
                                        ? NSColor(red: 1, green: 0, blue: 0, alpha: 1)
                                        : NSColor(red: 0, green: 0, blue: 1, alpha: 1),
                                    range: NSRange(location: index, length: 1))
        }
        precondition(runLimited.size().width > 0,
                     "style-run truncation must stay inside the UTF-8 bridge cap")
        let longNSString = String(repeating: "🙂", count: 50_000) as NSString
        precondition(longNSString.size(withAttributes: shortAttributes).width > 0,
                     "NSString convenience measurement must admit a bounded Unicode prefix")
        let longAttributed = NSAttributedString(
            string: String(repeating: "A", count: 50_000), attributes: shortAttributes
        )
        precondition(longAttributed.size().width > 0,
                     "attributed measurement must admit a bounded source prefix")

        func compoundFrame(_ segments: [String], width: CGFloat) -> (CompoundValueLabel, Bitmap) {
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 48))
            let reading = CompoundValueLabel()
            reading.segments = segments
            root.addSubview(reading)
            NSLayoutConstraint.activate([
                reading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
                reading.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
                reading.widthAnchor.constraint(equalToConstant: width),
                reading.heightAnchor.constraint(equalToConstant: 26)
            ])
            let bitmap = Bitmap(width: 290, height: 48, background: (1, 1, 1, 1))
            root.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
            return (reading, bitmap)
        }
        let fullReading = ["12%", "248 MB", "3 files"]
        let twoWidth = ceil(NSAttributedString(
            string: "12% · 248 MB",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11)]).size().width)
        let (narrowReading, narrowPixels) = compoundFrame(fullReading, width: twoWidth)
        let (_, twoPixels) = compoundFrame(Array(fullReading.prefix(2)), width: twoWidth)
        precondition(narrowReading.drawableSegmentCount(in: twoWidth) == 2)
        precondition(narrowReading.accessibilityValue() as? String == "12% · 248 MB · 3 files")
        precondition(narrowPixels.pixels == twoPixels.pixels,
                     "production reading must omit a whole trailing segment")
        precondition(inkCount(narrowPixels, x: 12..<Int(twoWidth + 12), y: 8..<34) > 30)
        try PNGWriter.write(narrowPixels, to: URL(fileURLWithPath: "out/text-label-compound.png"))
        print("PASS mixed Pango attributed runs and unchanged production compound reading")
        let badgeRoot = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 72))
        let badge = SimulatorRecordingBadge(frame: .zero)
        badge.phase = .recording(elapsedSeconds: 67)
        badge.frame = NSRect(x: 14, y: 18,
                             width: badge.intrinsicContentSize.width,
                             height: badge.intrinsicContentSize.height)
        badgeRoot.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: badgeRoot.leadingAnchor, constant: 14),
            badge.topAnchor.constraint(equalTo: badgeRoot.topAnchor, constant: 18),
            badge.widthAnchor.constraint(equalToConstant: badge.intrinsicContentSize.width),
            badge.heightAnchor.constraint(equalToConstant: badge.intrinsicContentSize.height)
        ])
        precondition(badge.title == "REC 1:07" &&
                     badge.accessibilityValue() as? String == badge.title &&
                     badge.accessibilityIdentifier() == "simulator.recording")
        var badgePresses = 0
        badge.onPress = { badgePresses += 1 }
        precondition(badge.accessibilityPerformPress() && badgePresses == 1)
        let badgeBitmap = Bitmap(width: 220, height: 72, background: (1, 1, 1, 1))
        badgeRoot.render(in: NSGraphicsContext(bitmap: badgeBitmap, scale: 1))
        precondition(abs(badge.frame.minX - 14) < 0.5 &&
                     abs(badgeRoot.bounds.height - badge.frame.maxY - 18) < 0.5,
                     "production badge escaped its constrained slot: \(badge.frame)")
        let badgeLocal = badge.convert(NSPoint(x: badge.frame.minX + 8,
                                               y: badge.frame.minY + 8), from: nil)
        precondition(badgeLocal == NSPoint(x: 8, y: 8),
                     "window-to-badge point conversion lost its frame offset")
        let coordinateRoot = FlippedRoot(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let coordinateChild = NSView(frame: NSRect(x: 20, y: 10, width: 60, height: 30))
        coordinateRoot.addSubview(coordinateChild)
        precondition(coordinateChild.convert(NSPoint(x: 4, y: 5), to: nil) ==
                     NSPoint(x: 24, y: 65) &&
                     coordinateChild.convert(NSPoint(x: 24, y: 65), from: nil) ==
                     NSPoint(x: 4, y: 5),
                     "window point conversion lost a nested flipped boundary")
        let badgeInside = PointEvent(badge.convert(NSPoint(x: 8, y: 8), to: nil))
        badge.mouseDown(with: badgeInside)
        badge.mouseUp(with: badgeInside)
        precondition(badgePresses == 2, "inside badge release missed the production action")
        badge.mouseDown(with: badgeInside)
        badge.mouseUp(with: PointEvent(NSPoint(x: 200, y: 60)))
        precondition(badgePresses == 2, "outside badge release fired the production action")
        try PNGWriter.write(badgeBitmap, to: URL(fileURLWithPath: "out/text-label-recording-badge.png"))
        var badgeRed = 0, badgeDark = 0
        for offset in stride(from: 0, to: badgeBitmap.pixels.count, by: 4) {
            let red = Int(badgeBitmap.pixels[offset])
            let green = Int(badgeBitmap.pixels[offset + 1])
            let blue = Int(badgeBitmap.pixels[offset + 2])
            if red > green + 70 && red > blue + 70 { badgeRed += 1 }
            if red < 115 && green < 115 && blue < 115 { badgeDark += 1 }
        }
        precondition(badgeRed > 15 && badgeDark > 20,
                     "production badge lost its live mark or NSString title")
        badge.phase = .finishing
        precondition(badge.title == "Saving…" &&
                     badge.accessibilityValue() as? String == "Saving…" &&
                     !badge.accessibilityPerformPress() && badgePresses == 2)
        let finishingBitmap = Bitmap(width: 220, height: 72, background: (1, 1, 1, 1))
        badgeRoot.render(in: NSGraphicsContext(bitmap: finishingBitmap, scale: 1))
        try PNGWriter.write(finishingBitmap,
                            to: URL(fileURLWithPath: "out/text-label-recording-finishing.png"))
        precondition(badgeBitmap.pixels != finishingBitmap.pixels,
                     "production badge did not redraw its finishing state")
        print("PASS unchanged production recording badge: measured title, pixels and action states")
        let fontBounds = NSFont.systemFont(ofSize: 13).boundingRectForFont
        precondition(fontBounds.height > 13 && fontBounds.width > 0 &&
                     fontBounds.minY < 0, "Pango font bounds lost ascent or descent")
        let cleanup = storageOutline(rowCount: 170)
        let storageView = StorageProposalOutlineView(
            outline: cleanup, accessibilityLabel: "170 cleanup entries"
        )
        let storageHeight = storageView.fittingHeight()
        Design.FontRole.scale = 1.5
        let enlargedStorageHeight = storageView.fittingHeight()
        Design.FontRole.scale = 1
        precondition(enlargedStorageHeight > storageHeight &&
                     storageView.fittingHeight() == storageHeight,
                     "outline must remeasure on a live font change")
        precondition(storageHeight > 180 && storageView.isAccessibilityElement() &&
                     storageView.accessibilityRole() == .group &&
                     (storageView.accessibilityValue() as? String)?.contains("module-169") == true,
                     "the full cleanup decision must remain accessible beyond the viewport")
        storageView.frame = NSRect(x: 0, y: 0, width: 360, height: storageHeight)
        let firstStorage = renderOutline(storageView, offset: 0)
        let lastStorage = renderOutline(storageView, offset: storageHeight - 180)
        precondition(inkCount(firstStorage, x: 0..<360, y: 0..<180) > 60 &&
                     inkCount(lastStorage, x: 0..<360, y: 0..<180) > 60 &&
                     firstStorage.pixels != lastStorage.pixels,
                     "visible cleanup slices must paint distinct real rows")
        try PNGWriter.write(firstStorage,
                            to: URL(fileURLWithPath: "out/text-label-storage-first.png"))
        try PNGWriter.write(lastStorage,
                            to: URL(fileURLWithPath: "out/text-label-storage-last.png"))
        print("PASS unchanged production storage outline: 170 rows, viewport pixels and full accessibility")

        let lightAppearance = NSAppearance(named: .aqua)
        let darkAppearance = NSAppearance(named: .darkAqua)
        let appearanceRoot = NSView(frame: .zero)
        let appearanceProbe = AppearanceProbe(frame: .zero)
        let descendantProbe = AppearanceProbe(frame: .zero)
        appearanceProbe.addSubview(descendantProbe)
        appearanceRoot.addSubview(appearanceProbe)
        appearanceRoot.appearance = darkAppearance
        precondition(appearanceProbe.changes == 1 && descendantProbe.changes == 1 &&
                     appearanceProbe.effectiveAppearance.name == .darkAqua,
                     "effective appearance did not reach inherited descendants")
        let explicitProbe = AppearanceProbe(frame: .zero)
        explicitProbe.appearance = lightAppearance
        appearanceRoot.addSubview(explicitProbe)
        appearanceRoot.appearance = lightAppearance
        precondition(appearanceProbe.changes == 2 && descendantProbe.changes == 2 &&
                     explicitProbe.changes == 0,
                     "an explicit child appearance must be isolated from its parent")
        let otherRoot = NSView(frame: .zero)
        otherRoot.appearance = darkAppearance
        otherRoot.addSubview(appearanceProbe)
        precondition(appearanceProbe.changes == 3 && descendantProbe.changes == 3,
                     "reparenting into a different appearance must notify descendants once")
        let originalDrawing = NSAppearance.currentDrawing().name
        darkAppearance.performAsCurrentDrawingAppearance {
            precondition(NSAppearance.currentDrawing().name == .darkAqua)
            lightAppearance.performAsCurrentDrawingAppearance {
                precondition(NSAppearance.currentDrawing().name == .aqua)
            }
            precondition(NSAppearance.currentDrawing().name == .darkAqua)
        }
        precondition(NSAppearance.currentDrawing().name == originalDrawing)

        let windowLog = WindowMoveLog()
        let firstWindow = NSWindow(backingScaleFactor: 2), secondWindow = NSWindow()
        windowLog.first = firstWindow
        windowLog.second = secondWindow
        let windowRoot = WindowMoveProbe("root", log: windowLog)
        let windowParent = WindowMoveProbe("parent", log: windowLog)
        let windowChild = WindowMoveProbe("child", log: windowLog)
        windowRoot.addSubview(windowParent)
        windowParent.addSubview(windowChild)
        precondition(windowLog.entries.isEmpty && windowChild.window == nil,
                     "detached view construction must not announce a window")
        firstWindow.contentView = windowRoot
        precondition(windowLog.entries == [
            "root:will:nil->first", "parent:will:nil->first", "child:will:nil->first",
            "child:did:first", "parent:did:first", "root:did:first"
        ] && windowChild.window?.backingScaleFactor == 2)
        windowLog.entries.removeAll()
        let sameWindowParent = WindowMoveProbe("sibling", log: windowLog)
        windowRoot.addSubview(sameWindowParent)
        windowLog.entries.removeAll()
        sameWindowParent.addSubview(windowChild)
        precondition(windowLog.entries == ["child:will:first->first", "child:did:first"],
                     "same-window reparent must not announce an intermediate detach")
        windowLog.entries.removeAll()
        let secondRoot = WindowMoveProbe("other", log: windowLog)
        secondWindow.contentView = secondRoot
        windowLog.entries.removeAll()
        secondRoot.addSubview(windowChild)
        precondition(windowLog.entries == ["child:will:first->second", "child:did:second"] &&
                     windowChild.window === secondWindow,
                     "cross-window reparent must report its direct destination")
        windowLog.entries.removeAll()
        windowChild.removeFromSuperview()
        precondition(windowLog.entries == ["child:will:second->nil", "child:did:nil"] &&
                     windowChild.window == nil)
        windowLog.entries.removeAll()
        firstWindow.contentView = nil
        precondition(windowLog.entries == [
            "root:will:first->nil", "parent:will:first->nil", "sibling:will:first->nil",
            "parent:did:nil", "sibling:did:nil", "root:did:nil"
        ] && windowRoot.window == nil)
        windowLog.entries.removeAll()
        firstWindow.contentView = windowRoot
        windowLog.entries.removeAll()
        secondWindow.contentView = windowRoot
        precondition(windowLog.entries == [
            "other:will:second->nil", "other:did:nil",
            "root:will:first->second", "parent:will:first->second",
            "sibling:will:first->second", "parent:did:second",
            "sibling:did:second", "root:did:second"
        ] && firstWindow.contentView == nil && secondWindow.contentView === windowRoot &&
            windowRoot.window?.backingScaleFactor == 1)
        windowLog.entries.removeAll()
        secondWindow.contentView = windowRoot
        precondition(windowLog.entries.isEmpty, "assigning the same content root must be inert")
        let firstParent = NSView(frame: .zero)
        let secondParent = NSView(frame: .zero)
        let superviewProbe = SuperviewMoveProbe(frame: .zero)
        firstParent.addSubview(superviewProbe)
        secondParent.addSubview(superviewProbe)
        superviewProbe.removeFromSuperview()
        precondition(superviewProbe.parents.count == 4 &&
                     superviewProbe.parents[0] === firstParent &&
                     superviewProbe.parents[1] == nil &&
                     superviewProbe.parents[2] === secondParent &&
                     superviewProbe.parents[3] == nil,
                     "superview callbacks must observe attach, reparent and detach")
        print("PASS content-window attachment, subtree callback order and direct reparenting")

        // The production scope must answer chords only for its own focused subtree, including
        // a field editor whose delegate is the owning view. These transitions were measured
        // against macOS AppKit: direct focus ignores acceptsFirstResponder, a vetoed resign
        // keeps focus, a vetoed become falls back to the window, and detach clears focus.
        let focusWindow = NSWindow()
        let focusRoot = NSView()
        let scope = KeyEquivalentScopeView()
        let sibling = FocusProbe(), leaf = FocusProbe(), refusing = FocusProbe()
        let editor = NSText()
        let event = NSEvent()
        var chords = 0
        scope.onKeyEquivalent = { _ in chords += 1; return true }
        focusRoot.addSubview(scope)
        focusRoot.addSubview(sibling)
        focusRoot.addSubview(editor)
        scope.addSubview(leaf)
        scope.addSubview(refusing)
        focusWindow.contentView = focusRoot
        precondition(focusWindow.firstResponder === focusWindow)
        precondition(!focusRoot.performKeyEquivalent(with: event) && chords == 0)
        precondition(focusWindow.makeFirstResponder(leaf) && leaf.became == 1)
        precondition(focusRoot.performKeyEquivalent(with: event) && chords == 1)
        precondition(focusWindow.makeFirstResponder(leaf) && leaf.became == 1)
        leaf.allowsResign = false
        precondition(!focusWindow.makeFirstResponder(sibling) && focusWindow.firstResponder === leaf)
        leaf.allowsResign = true
        refusing.allowsBecome = false
        precondition(focusWindow.makeFirstResponder(refusing) &&
                     focusWindow.firstResponder === focusWindow && !scope.containsKeyboardFocus)
        precondition(focusWindow.makeFirstResponder(editor))
        editor.delegate = leaf
        precondition(focusRoot.performKeyEquivalent(with: event) && chords == 2)
        editor.delegate = sibling
        precondition(!focusRoot.performKeyEquivalent(with: event) && chords == 2)
        precondition(focusWindow.makeFirstResponder(leaf))
        sibling.addSubview(leaf)
        precondition(focusWindow.firstResponder === leaf && !scope.containsKeyboardFocus)
        let resignedBeforeDetach = leaf.resigned
        leaf.removeFromSuperview()
        precondition(focusWindow.firstResponder === focusWindow &&
                     leaf.resigned == resignedBeforeDetach,
                     "detaching a focused view clears focus without a resign callback")
        precondition(focusWindow.makeFirstResponder(leaf) &&
                     focusWindow.firstResponder === focusWindow,
                     "a detached view cannot become this window's responder")
        precondition(focusWindow.makeFirstResponder(sibling))
        let otherFocusWindow = NSWindow()
        let otherFocusRoot = NSView()
        otherFocusWindow.contentView = otherFocusRoot
        otherFocusRoot.addSubview(sibling)
        precondition(focusWindow.firstResponder === focusWindow &&
                     otherFocusWindow.firstResponder === otherFocusWindow,
                     "cross-window reparenting must clear the source without stealing target focus")
        precondition(focusWindow.makeFirstResponder(scope))
        focusWindow.contentView = NSView()
        precondition(focusWindow.firstResponder === focusWindow)
        print("PASS first-responder lifecycle and production scoped key equivalents")

        let workerDone = DispatchSemaphore(value: 0)
        darkAppearance.performAsCurrentDrawingAppearance {
            Thread.detachNewThread {
                precondition(NSAppearance.currentDrawing().name == .aqua,
                             "drawing appearance leaked across threads")
                lightAppearance.performAsCurrentDrawingAppearance {
                    precondition(NSAppearance.currentDrawing().name == .aqua)
                }
                workerDone.signal()
            }
            precondition(workerDone.wait(timeout: .now() + 3) == .success)
            precondition(NSAppearance.currentDrawing().name == .darkAqua)
        }

        let pluginBoundary = NativePluginPresentationBoundaryView(frame: NSRect(
            x: 0, y: 0, width: 200, height: 80
        ))
        let hostSibling = NSView(frame: .zero)
        let pluginContent = NSView(frame: .zero)
        let pluginChild = NSView(frame: .zero)
        pluginBoundary.addSubview(hostSibling)
        pluginBoundary.install(pluginContent)
        pluginContent.addSubview(pluginChild)
        pluginBoundary.layoutSubtreeIfNeeded()
        precondition(pluginContent.frame == pluginBoundary.bounds &&
                     pluginChild.isDescendant(of: pluginContent) &&
                     pluginChild.isDescendant(of: pluginChild) &&
                     !hostSibling.isDescendant(of: pluginContent) &&
                     pluginBoundary.permitsSystemChrome(pluginContent) &&
                     pluginBoundary.permitsSystemChrome(pluginChild) &&
                     !pluginBoundary.permitsSystemChrome(hostSibling) &&
                     !pluginBoundary.permitsSystemChrome(pluginBoundary),
                     "native plugin boundary must permit only its installed presentation")
        pluginContent.isHidden = true
        precondition(pluginChild.isHiddenOrHasHiddenAncestor &&
                     !hostSibling.isHiddenOrHasHiddenAncestor)
        pluginContent.isHidden = false
        hostSibling.addSubview(pluginChild)
        precondition(!pluginBoundary.permitsSystemChrome(pluginChild) &&
                     !pluginChild.isHiddenOrHasHiddenAncestor,
                     "reparented host content must not retain plugin chrome permission")
        print("PASS unchanged production native-plugin containment and inherited visibility")

        let colorProbe = DynamicColorProbe(frame: NSRect(x: 0, y: 0, width: 250, height: 64))
        let colorRoot = NSView(frame: colorProbe.bounds)
        colorRoot.addSubview(colorProbe)
        let retainedColor = colorProbe.named
        let retainedHash = retainedColor.hashValue
        func renderColors() -> Bitmap {
            let bitmap = Bitmap(width: 250, height: 64, background: (0, 0, 0, 0))
            colorRoot.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
            return bitmap
        }
        colorRoot.appearance = lightAppearance
        let lightColors = renderColors()
        lightAppearance.performAsCurrentDrawingAppearance {
            precondition(retainedColor.redComponent == 0.9 &&
                         colorProbe.halfAlpha.alphaComponent == 0.5 &&
                         abs(colorProbe.mixed.redComponent - 0.95) < 0.001 &&
                         NSColor.labelColor.redComponent == 0 &&
                         NSColor.labelColor.alphaComponent == 216.0 / 255 &&
                         NSColor.secondaryLabelColor.alphaComponent == 127.0 / 255 &&
                         NSColor.tertiaryLabelColor.alphaComponent == 66.0 / 255 &&
                         NSColor.separatorColor.redComponent == 0 &&
                         NSColor.separatorColor.alphaComponent == 25.0 / 255 &&
                         NSColor.controlAccentColor.greenComponent == 122.0 / 255 &&
                         NSColor.windowBackgroundColor.redComponent == 1)
        }
        colorRoot.appearance = darkAppearance
        let darkColors = renderColors()
        darkAppearance.performAsCurrentDrawingAppearance {
            precondition(retainedColor.blueComponent == 0.9 &&
                         colorProbe.halfAlpha.alphaComponent == 0.5 &&
                         abs(colorProbe.mixed.blueComponent - 0.55) < 0.001 &&
                         NSColor.labelColor.redComponent == 1 &&
                         NSColor.secondaryLabelColor.alphaComponent == 140.0 / 255 &&
                         NSColor.tertiaryLabelColor.alphaComponent == 63.0 / 255 &&
                         NSColor.separatorColor.redComponent == 1 &&
                         NSColor.windowBackgroundColor.redComponent == 30.0 / 255)
            let snapshot = retainedColor.usingColorSpace(.sRGB)!
            lightAppearance.performAsCurrentDrawingAppearance {
                precondition(snapshot.blueComponent == 0.9 && retainedColor.redComponent == 0.9,
                             "converted colors should freeze while named colors remain dynamic")
            }
        }
        precondition(retainedColor.hashValue == retainedHash && lightColors.pixels != darkColors.pixels,
                     "retained color recipe failed to redraw on appearance change")
        try PNGWriter.write(lightColors, to: URL(fileURLWithPath: "out/text-label-dynamic-light.png"))
        try PNGWriter.write(darkColors, to: URL(fileURLWithPath: "out/text-label-dynamic-dark.png"))
        print("PASS retained named colors, dynamic alpha, fixed blend and system ink across appearance switches")

        let sparkline = ThemedBarSparklineView(
            values: [1, 3, 0, 5, 2, 4, 7],
            accessibilityLabel: "Commits by week"
        )
        let sparklineRoot = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 70))
        sparklineRoot.addSubview(sparkline)
        NSLayoutConstraint.activate([
            sparkline.leadingAnchor.constraint(equalTo: sparklineRoot.leadingAnchor, constant: 16),
            sparkline.trailingAnchor.constraint(equalTo: sparklineRoot.trailingAnchor, constant: -16),
            sparkline.bottomAnchor.constraint(equalTo: sparklineRoot.bottomAnchor, constant: -16),
            sparkline.heightAnchor.constraint(equalToConstant: 28)
        ])
        func renderSparkline() -> Bitmap {
            let dark = sparklineRoot.effectiveAppearance.name == .darkAqua
            let ground: (CGFloat, CGFloat, CGFloat, CGFloat) = dark
                ? (0.08, 0.09, 0.12, 1) : (1, 1, 1, 1)
            let bitmap = Bitmap(width: 360, height: 70, background: ground)
            sparklineRoot.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
            return bitmap
        }
        sparklineRoot.appearance = lightAppearance
        let lightSparkline = renderSparkline()
        sparkline.needsDisplay = false
        sparklineRoot.appearance = darkAppearance
        precondition(sparkline.needsDisplay &&
                     sparkline.effectiveAppearance.name == .darkAqua,
                     "production sparkline did not invalidate on a parent appearance switch")
        let darkSparkline = renderSparkline()
        func coloredPixels(_ bitmap: Bitmap, accepts: (UInt8, UInt8, UInt8) -> Bool) -> Int {
            stride(from: 0, to: bitmap.pixels.count, by: 4).reduce(0) { count, index in
                count + (accepts(bitmap.pixels[index], bitmap.pixels[index + 1],
                                 bitmap.pixels[index + 2]) ? 1 : 0)
            }
        }
        precondition(coloredPixels(lightSparkline, accepts: { Int($2) > Int($0) + 45 }) > 100 &&
                     coloredPixels(darkSparkline, accepts: { Int($0) > Int($2) + 45 }) > 100 &&
                     sparkline.accessibilityRole() == .group &&
                     sparkline.accessibilityLabel() == "Commits by week",
                     "production sparkline lost appearance-specific ink or accessibility")
        try PNGWriter.write(lightSparkline,
                            to: URL(fileURLWithPath: "out/text-label-sparkline-light.png"))
        try PNGWriter.write(darkSparkline,
                            to: URL(fileURLWithPath: "out/text-label-sparkline-dark.png"))
        sparkline.setValues([0, 4, 1], accessibilityLabel: "Three recent weeks")
        precondition(sparkline.accessibilityLabel() == "Three recent weeks" && sparkline.needsDisplay)
        print("PASS unchanged production sparkline: inherited appearance, distinct pixels and accessibility")
        precondition(NSFont.monospacedSystemFont(ofSize: 13, weight: .bold).familyName?.contains("Bold") == true)
        precondition(NSFont.systemFont(ofSize: 13, weight: .semibold).familyName?.contains("Semibold") == true)
        precondition(NSFont.systemFont(ofSize: 13, weight: .medium).weight == .medium)
        let weightLabel = NSTextField(labelWithString: "Typography")
        weightLabel.frame = NSRect(x: 6, y: 6, width: 110, height: 28)
        weightLabel.font = .systemFont(ofSize: 17, weight: .regular)
        let regularPixels = render(weightLabel, width: 125)
        weightLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        let semiboldPixels = render(weightLabel, width: 125)
        weightLabel.font = .systemFont(ofSize: 17, weight: .bold)
        let boldPixels = render(weightLabel, width: 125)
        print("font-weight pixels regular/semibold=\(regularPixels.pixels == semiboldPixels.pixels) semibold/bold=\(semiboldPixels.pixels == boldPixels.pixels)")
        precondition(regularPixels.pixels != semiboldPixels.pixels,
                     "Pango semibold must change the regular glyph ink")

        let alphaLabel = NSTextField(labelWithString: "MMMM")
        alphaLabel.frame = NSRect(x: 5, y: 5, width: 90, height: 27)
        alphaLabel.font = .systemFont(ofSize: 17)
        alphaLabel.textColor = NSColor(red: 1, green: 0, blue: 0, alpha: 0.5)
        let clearBitmap = Bitmap(width: 100, height: 40)
        alphaLabel.render(in: NSGraphicsContext(bitmap: clearBitmap, scale: 1))
        let whiteBitmap = render(alphaLabel)
        var covered = 0
        for offset in stride(from: 0, to: clearBitmap.pixels.count, by: 4) {
            let alpha = Int(clearBitmap.pixels[offset + 3])
            guard alpha > 0 else { continue }
            covered += 1
            precondition(clearBitmap.pixels[offset] == 255 &&
                         clearBitmap.pixels[offset + 1] == 0 &&
                         clearBitmap.pixels[offset + 2] == 0,
                         "transparent destination lost straight-alpha red")
            precondition(whiteBitmap.pixels[offset] == 255 &&
                         abs(Int(whiteBitmap.pixels[offset + 1]) - (255 - alpha)) <= 2 &&
                         abs(Int(whiteBitmap.pixels[offset + 2]) - (255 - alpha)) <= 2,
                         "opaque destination differs from the same coverage")
        }
        precondition(covered > 20, "alpha label drew too little ink")

        // Independent label views keep an ellipsized title out of adjacent identity/status ink.
        let fragments = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        let titleFragment = NSTextField(labelWithString: "A long project title that must truncate")
        titleFragment.frame = NSRect(x: 8, y: 30, width: 100, height: 24)
        titleFragment.lineBreakMode = .byTruncatingTail
        let detailFragment = NSTextField(labelWithString: "Retained")
        detailFragment.frame = NSRect(x: 114, y: 30, width: 80, height: 24)
        fragments.addSubview(titleFragment)
        fragments.addSubview(detailFragment)
        func fragmentPixels() -> Bitmap {
            let bitmap = Bitmap(width: 200, height: 60, background: (1, 1, 1, 1))
            fragments.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
            return bitmap
        }
        let firstFragments = fragmentPixels()
        titleFragment.stringValue = "An entirely different project name"
        let renamedFragments = fragmentPixels()
        precondition(firstFragments.pixels != renamedFragments.pixels)
        for y in 0..<60 {
            for x in 114..<194 {
                let offset = (y * 200 + x) * 4
                precondition(firstFragments.pixels[offset..<(offset + 4)]
                             .elementsEqual(renamedFragments.pixels[offset..<(offset + 4)]),
                             "title change altered the independent detail fragment")
            }
        }

        var oversized = [UInt8](repeating: 65, count: 4097)
        var rejected = TATMetrics(width: 0, height: 0, baseline: 0, glyphs: 0)
        precondition(oversized.withUnsafeMutableBufferPointer {
            tat_measure($0.baseAddress, Int32($0.count), 0, 0, 13, &rejected)
        } == 0, "bridge must reject overlong UTF-8")

        // Unchanged production ControlRowView lays out two real shaped labels.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 70))
        let leading = NSTextField(labelWithString: "Café workspace")
        let trailing = NSTextField(labelWithString: "جاهز")
        leading.translatesAutoresizingMaskIntoConstraints = false
        trailing.translatesAutoresizingMaskIntoConstraints = false
        leading.widthAnchor.constraint(equalToConstant: 128).isActive = true
        trailing.widthAnchor.constraint(equalToConstant: 70).isActive = true
        leading.lineBreakMode = .byTruncatingTail
        let row = ControlRowView(leading: [leading], trailing: [trailing])
        root.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            row.topAnchor.constraint(equalTo: root.topAnchor)
        ])
        root.layoutSubtreeIfNeeded()
        precondition(abs(row.frame.height - 26) < 0.1)
        let bitmap = Bitmap(width: 320, height: 70, background: (1, 1, 1, 1))
        root.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
        precondition(inkCount(bitmap, x: 0..<135, y: 0..<35) > 25)
        precondition(inkCount(bitmap, x: 240..<320, y: 0..<35) > 10)
        try FileManager.default.createDirectory(atPath: "out", withIntermediateDirectories: true)
        try PNGWriter.write(bitmap, to: URL(fileURLWithPath: "out/text-label-control-row.png"))

        // Both parent and label use top-down coordinates. A second unconditional flip at the
        // label boundary makes the matrix y-up and used to silently drop every glyph.
        let flippedRoot = FlippedRoot(frame: NSRect(x: 0, y: 0, width: 120, height: 60))
        let nestedLabel = NSTextField(labelWithString: "Flipped café")
        nestedLabel.frame = NSRect(x: 10, y: 10, width: 95, height: 24)
        flippedRoot.addSubview(nestedLabel)
        let flippedBitmap = Bitmap(width: 120, height: 60, background: (1, 1, 1, 1))
        flippedRoot.render(in: NSGraphicsContext(bitmap: flippedBitmap, scale: 1))
        precondition(inkCount(flippedBitmap, x: 10..<105, y: 10..<34) > 20,
                     "flipped descendant label did not render in its top-down bounds")
        precondition(inkCount(flippedBitmap, x: 10..<105, y: 34..<60) == 0 &&
                     inkCount(flippedBitmap, x: 0..<10, y: 0..<60) == 0,
                     "flipped descendant label escaped its bounds")
        try PNGWriter.write(flippedBitmap, to: URL(fileURLWithPath: "out/text-label-flipped.png"))
        print("Pango Unicode, bounds, truncation, baseline, and production ControlRow labels pass")
        #endif
    }
}
