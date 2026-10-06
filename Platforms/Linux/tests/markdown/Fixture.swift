import AppKit
import Foundation
#if os(Linux)
import AppKitTextBridge
#endif

@main
@MainActor
enum Fixture {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "out/markdown-linux")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        verifyFontConversion()
        let snapshots = verifyGrammar()
        try JSONSerialization.data(withJSONObject: snapshots, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("grammar.json"))
        try render(to: output)
        #if os(Linux)
        verifyBridge()
        try verifySelection(to: output)
        verifyClipGeometry()
        verifyCursorLifecycle()
        #endif
        print("PASS unchanged Markdown grammar, nested traits, URL policy, and text rendering")
    }

    private static func verifyFontConversion() {
        let manager = NSFontManager.shared
        for base in [NSFont.systemFont(ofSize: 17),
                     NSFont.monospacedSystemFont(ofSize: 17, weight: .regular)] {
            let bold = manager.convert(base, toHaveTrait: .boldFontMask)
            let both = manager.convert(bold, toHaveTrait: .italicFontMask)
            let reverse = manager.convert(manager.convert(base, toHaveTrait: .italicFontMask),
                                          toHaveTrait: .boldFontMask)
            for font in [both, reverse] {
                precondition(manager.traits(of: font).contains([.boldFontMask, .italicFontMask]))
                precondition(font.pointSize == base.pointSize)
                precondition(manager.traits(of: font).contains(.fixedPitchFontMask)
                             == manager.traits(of: base).contains(.fixedPitchFontMask))
                let resized = NSFont(descriptor: font.fontDescriptor, size: 23)!
                precondition(manager.traits(of: resized).contains([.boldFontMask, .italicFontMask]))
                precondition(resized.pointSize == 23)
            }
            let upright = manager.convert(both, toHaveTrait: .unitalicFontMask)
            precondition(manager.traits(of: upright).contains(.boldFontMask))
            precondition(!manager.traits(of: upright).contains(.italicFontMask))
            let regular = manager.convert(upright, toHaveTrait: .unboldFontMask)
            precondition(!manager.traits(of: regular).contains(.boldFontMask))
        }
    }

    private static func verifyGrammar() -> [[String: Any]] {
        let cases = [
            "Plain Swedish: räksmörgås · 中文 · 👩🏽‍🚀",
            "**bold with *italic* inside** and `file_name.swift`",
            "*italic **bold** italic* and ***both***",
            "**[PR 12](https://example.com/pull/12)** shipped",
            "**[local](file:///tmp/private)** [custom](threading://launch) [web](http://example.com)",
            "a_b_c and a * b * c and _emphasis_",
            "Unfinished **bold and [unfinished](https://example.com",
            "# Heading\n\nA **strong** paragraph.\n\n```swift\nlet files = \"*.swift\"\n```\n\n> - quoted\n\n- first\n- second\n\n1. one\n2. two\n\n| Name | Count |\n| :--- | ---: |\n| alpha | 2 |"
        ]
        let style = MarkdownStyle.assistant
        var snapshots: [[String: Any]] = []
        for source in cases {
            let blocks = Markdown.parse(source, style: style)
            let split = Markdown.sourceBlocks(source).flatMap { Markdown.parse($0, style: style) }
            let direct = blocks.map(snapshot)
            let paged = split.map(snapshot)
            let directJSON = try! JSONSerialization.data(withJSONObject: direct, options: [.sortedKeys])
            let pagedJSON = try! JSONSerialization.data(withJSONObject: paged, options: [.sortedKeys])
            precondition(directJSON == pagedJSON, "source block paging changed grammar")
            snapshots.append(["source": source, "blocks": direct])
        }

        let nested = Markdown.inline(cases[1], style: style)
        precondition(nested.string == "bold with italic inside and file_name.swift")
        let italicOffset = (nested.string as NSString).range(of: "italic").location
        let nestedFont = nested.attribute(.font, at: italicOffset, effectiveRange: nil) as! NSFont
        precondition(NSFontManager.shared.traits(of: nestedFont)
                     .contains([.boldFontMask, .italicFontMask]))
        let links = Markdown.inline(cases[4], style: style)
        for word in ["local", "custom"] {
            let offset = (links.string as NSString).range(of: word).location
            precondition(links.attribute(.link, at: offset, effectiveRange: nil) == nil)
            precondition(links.attribute(.underlineStyle, at: offset, effectiveRange: nil) == nil)
        }
        let webOffset = (links.string as NSString).range(of: "web").location
        precondition((links.attribute(.link, at: webOffset, effectiveRange: nil) as? URL)?.scheme == "http")

        // A literal identifier produces many scanner tokens but only one equivalent style.
        // Without value equality on the shim font, these consume the 64-span raster budget.
        let identifier = String(repeating: "a_b_c ", count: 170)
        let literal = Markdown.inline(identifier, style: style)
        var runCount = 0
        literal.enumerateAttributes(in: NSRange(location: 0, length: literal.length)) { _, _, _ in
            runCount += 1
        }
        precondition(literal.string == identifier && runCount == 1,
                     "equivalent font attributes fragmented a literal paragraph")

        var deep = "leaf"
        for index in 0..<80 { deep = index.isMultiple(of: 2) ? "**outer \(deep)**" : "*inner \(deep)*" }
        let bounded = Markdown.inline(deep, style: style)
        precondition(bounded.string.contains("leaf") && bounded.string.contains("*"),
                     "nesting ceiling lost the literal remainder")
        return snapshots
    }

    private static func snapshot(_ block: MarkdownBlock) -> [String: Any] {
        switch block {
        case .paragraph(let text): return ["kind": "paragraph", "runs": runs(text)]
        case .heading(let text): return ["kind": "heading", "runs": runs(text)]
        case .quote(let text): return ["kind": "quote", "runs": runs(text)]
        case .code(let text): return ["kind": "code", "text": text]
        case .bullets(let items): return ["kind": "bullets", "items": items.map(runs)]
        case .ordered(let items): return ["kind": "ordered", "items": items.map(runs)]
        case .table(let table):
            return ["kind": "table", "headers": table.headers.map(runs),
                    "rows": table.rows.map { $0.map(runs) },
                    "alignments": table.alignments.map(\.rawValue)]
        }
    }

    private static func runs(_ text: NSAttributedString) -> [[String: Any]] {
        var values: [[String: Any]] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let font = attributes[.font] as! NSFont
            let traits = NSFontManager.shared.traits(of: font)
            values.append([
                "text": (text.string as NSString).substring(with: range),
                "bold": traits.contains(.boldFontMask), "italic": traits.contains(.italicFontMask),
                "mono": traits.contains(.fixedPitchFontMask), "size": Double(font.pointSize),
                "link": (attributes[.link] as? URL)?.absoluteString ?? "",
                "underline": (attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0,
                "codeBackground": attributes[.backgroundColor] != nil
            ])
        }
        return values
    }

    private static func render(to output: URL) throws {
        let style = MarkdownStyle.assistant
        let sources = [
            "Regular typography · räksmörgås",
            "**Bold typography · räksmörgås**",
            "*Italic typography · räksmörgås*",
            "***Bold and italic typography***",
            "**Bold with *italic* inside** · `code.swift` · **`bold code`**",
            "*[Web link](https://example.com)* · [Local label](file:///tmp/private)",
            "Unicode: 中文 · 👩🏽‍🚀 · **強調** · *café*"
        ]
        let texts = sources.map { Markdown.inline($0, style: style) }
        for scale: CGFloat in [1, 2] {
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 330))
            let owner = NSWindow()
            #if os(macOS)
            owner.setContentSize(root.bounds.size)
            #endif
            owner.contentView = root
            for (index, text) in texts.enumerated() {
                let label = NSTextField(labelWithAttributedString: text)
                label.frame = NSRect(x: 18, y: 290 - CGFloat(index) * 42, width: 644, height: 32)
                root.addSubview(label)
            }
            let file = output.appendingPathComponent("inline-\(Int(scale))x.png")
            #if os(Linux)
            let bitmap = Bitmap(width: Int(root.bounds.width * scale),
                                height: Int(root.bounds.height * scale), background: (1, 1, 1, 1))
            root.render(in: NSGraphicsContext(bitmap: bitmap, scale: scale))
            try PNGWriter.write(bitmap, to: file)
            #else
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(root.bounds.width * scale), pixelsHigh: Int(root.bounds.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = root.bounds.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.white.setFill()
            root.bounds.fill()
            for label in root.subviews {
                NSGraphicsContext.saveGraphicsState()
                let translation = AffineTransform(translationByX: label.frame.minX, byY: label.frame.minY)
                (translation as NSAffineTransform).concat()
                label.draw(label.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: file)
            #endif
        }
    }

    #if os(Linux)
    private static func verifyCursorLifecycle() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let owner = NSWindow()
        owner.contentView = root
        let label = NSTextField(labelWithString: "Selectable")
        label.isSelectable = true
        label.frame = NSRect(x: 10, y: 10, width: 80, height: 20)
        root.addSubview(label)
        var shapes: [NSCursor.Kind] = []
        NSCursor.platformUpdate = { shapes.append($0) }
        defer { NSCursor.platformUpdate = nil }
        owner.dispatchToContent(NSEvent(type: .mouseMoved, locationInWindow: NSPoint(x: 15, y: 15)))
        precondition(shapes.last == .iBeam)
        label.frame.origin.x = 200
        root.render(in: NSGraphicsContext(bitmap: Bitmap(width: 100, height: 100)))
        precondition(shapes.last == .arrow, "stationary pointer retained a moved label's claim")

        let otherRoot = NSView(frame: root.frame)
        let otherOwner = NSWindow()
        otherOwner.contentView = otherRoot
        otherOwner.dispatchToContent(NSEvent(type: .mouseMoved, locationInWindow: NSPoint(x: 15, y: 15)))
        let before = shapes.count
        label.frame.origin.x = 10
        root.render(in: NSGraphicsContext(bitmap: Bitmap(width: 100, height: 100)))
        precondition(shapes.count == before, "painting another pane overwrote the physical pointer owner")
        owner.dispatchToContent(NSEvent(type: .mouseMoved, locationInWindow: NSPoint(x: 15, y: 15)))
        precondition(shapes.last == .iBeam)
        root.frame.size.height = 120
        root.render(in: NSGraphicsContext(bitmap: Bitmap(width: 100, height: 120)))
        precondition(shapes.last == .arrow, "height change kept the old bottom-origin pointer coordinate")
        label.frame.origin.y = 30
        root.render(in: NSGraphicsContext(bitmap: Bitmap(width: 100, height: 120)))
        precondition(shapes.last == .iBeam, "label did not reclaim the stationary pointer after resize")
        print("PASS cursor lifecycle: stationary geometry changes, height rebasing and separate pane ownership")
    }

    private static func verifyClipGeometry() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalToConstant: 200),
            document.heightAnchor.constraint(equalToConstant: 500)
        ])
        _ = scroll.layoutSubtreeIfNeeded()
        precondition(scroll.contentView.frame.size == scroll.bounds.size)
        precondition(document.frame.origin == .zero && document.frame.height == 500,
                     "clip document floated in root coordinates")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        _ = scroll.layoutSubtreeIfNeeded()
        precondition(document.frame.origin == .zero && scroll.contentView.bounds.minY == 400,
                     "layout changed the document origin or lost the scroll offset")
        scroll.scrollWheel(with: NSEvent(type: .scrollWheel, scrollingDeltaY: -1))
        precondition(scroll.contentView.bounds.minY == 390,
                     "unflipped document wheel direction is wrong")
        print("PASS Auto Layout document origin, viewport size and unflipped wheel direction")
    }

    private static func verifySelection(to output: URL) throws {
        let source = "é👩🏽‍🚀Z · **bold** and `code` · العربية"
        let value = Markdown.inline(source, style: .assistant)
        let field = NSTextField(labelWithAttributedString: value)
        field.isSelectable = true
        field.frame = NSRect(x: 0, y: 0, width: 540, height: 38)
        let owner = NSWindow()
        owner.contentView = field
        precondition(owner.makeFirstResponder(field))
        var copied = ""
        NSPasteboard.general.writeString = { copied = $0; return true }
        defer { NSPasteboard.general.writeString = nil }
        func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String? = nil) {
            _ = owner.dispatchToContent(NSEvent(type: .keyDown, modifierFlags: modifiers,
                keyCode: code, charactersIgnoringModifiers: characters))
        }
        key(115)
        key(124, .shift)
        key(124, .shift)
        key(0, .control, "c")
        precondition(copied == "é👩🏽‍🚀", "selection split a grapheme or copied markup")
        key(0, .control, "a")
        key(0, .control, "c")
        precondition(copied == value.string && field.attributedStringValue.string == value.string)
        key(51)
        precondition(field.attributedStringValue.string == value.string, "a selectable label edited its source")
        let bitmap = Bitmap(width: 540, height: 38, background: (1, 1, 1, 1))
        field.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
        try PNGWriter.write(bitmap, to: output.appendingPathComponent("selected-inline.png"))
        let selectionPixels = stride(from: 0, to: bitmap.pixels.count, by: 4).filter {
            bitmap.pixels[$0] < 50 && bitmap.pixels[$0 + 2] > 200
        }.count
        precondition(selectionPixels > 500, "selection background was not painted")

        // Pointer geometry uses the same Pango layout, including mixed-direction runs.
        _ = owner.dispatchToContent(NSEvent(type: .leftMouseDown, locationInWindow: NSPoint(x: 0, y: 18)))
        _ = owner.dispatchToContent(NSEvent(type: .leftMouseDragged, locationInWindow: NSPoint(x: 65, y: 18)))
        _ = owner.dispatchToContent(NSEvent(type: .leftMouseUp, locationInWindow: NSPoint(x: 65, y: 18)))
        precondition(field.selectedTextRange.length > 0)
        let selected = (value.string as NSString).substring(with: field.selectedTextRange)
        precondition(!selected.contains("�"))
        let lines = NSTextField(wrappingLabelWithString: (1...8).map { "Line \($0) · Unicode é" }.joined(separator: "\n"))
        lines.isSelectable = true
        lines.font = .systemFont(ofSize: 17)
        lines.maximumNumberOfLines = 8
        lines.preferredMaxLayoutWidth = 260
        let scaledOwner = NSWindow(backingScaleFactor: 2)
        scaledOwner.contentView = lines
        lines.frame = NSRect(x: 0, y: 0, width: 260, height: lines.intrinsicContentSize.height)
        precondition(lines.frame.height > 128, "complete logical label height was truncated")
        let tall = Bitmap(width: 520, height: Int(ceil(lines.frame.height * 2)), background: (1, 1, 1, 1))
        lines.render(in: NSGraphicsContext(bitmap: tall, scale: 2))
        let lastLine = stride(from: (tall.height - 35) * tall.width * 4, to: tall.pixels.count, by: 4)
            .filter { tall.pixels[$0] < 200 }.count
        precondition(lastLine > 30, "eighth line did not render beyond the first raster tile")
        try PNGWriter.write(tall, to: output.appendingPathComponent("selected-eight-lines-2x.png"))
        print("PASS selectable production Markdown label: grapheme keys, exact copy, readonly source and pointer range")
    }

    private static func verifyBridge() {
        // The stress remains capped independently of source size: 4096 bytes, 64 spans,
        // eight lines, and a 2048 × 128 raster. Reject an invalid trait before Pango allocation.
        let bytes = Array("Italic fi ffi räksmörgås".utf8)
        let font = NSFontManager.shared.convert(.systemFont(ofSize: 17), toHaveTrait: .italicFontMask)
        let label = NSTextField(labelWithString: String(decoding: bytes, as: UTF8.self))
        label.font = font
        precondition(label.intrinsicContentSize.width > 0)
        var span = TATStyleSpan()
        span.start_byte = 0
        span.end_byte = Int32(bytes.count)
        span.pixel_size = 17
        span.foreground_alpha = 1
        span.italic = 2
        var metrics = TATMetrics()
        let refused = bytes.withUnsafeBufferPointer { text in
            tat_attributed_measure(text.baseAddress, Int32(text.count), &span, 1, &metrics)
        }
        precondition(refused == 0)
        span.italic = 1
        let accepted = bytes.withUnsafeBufferPointer { text in
            tat_attributed_measure(text.baseAddress, Int32(text.count), &span, 1, &metrics)
        }
        precondition(accepted == 1 && metrics.width > 0)
        let invalidPlain = bytes.withUnsafeBufferPointer { text in
            tat_measure(text.baseAddress, Int32(text.count), 0, 0, 2, 17, &metrics)
        }
        precondition(invalidPlain == 0)

        func pixels(italic: Bool, attributed: Bool) -> [UInt8] {
            let source = "Italic fi ffi räksmörgås"
            let chosen = italic ? font : NSFont.systemFont(ofSize: 17)
            let field = attributed
                ? NSTextField(labelWithAttributedString: NSAttributedString(string: source,
                    attributes: [.font: chosen, .foregroundColor: NSColor.black]))
                : NSTextField(labelWithString: source)
            field.font = chosen
            field.textColor = .black
            field.frame = NSRect(x: 0, y: 0, width: 320, height: 32)
            let bitmap = Bitmap(width: 320, height: 32, background: (1, 1, 1, 1))
            field.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
            return bitmap.pixels
        }
        precondition(pixels(italic: true, attributed: false) != pixels(italic: false, attributed: false),
                     "plain labels ignored the italic font trait")
        precondition(pixels(italic: true, attributed: true) != pixels(italic: false, attributed: true),
                     "attributed labels ignored the italic font trait")
    }
    #endif
}
