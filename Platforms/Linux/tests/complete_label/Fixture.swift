import Foundation
import AppKit

@main
struct CompleteLabelFixture {
    @MainActor
    static func main() async throws {
        let text = await Task.detached {
            "FIRST é 👩🏽‍🚀\n" + (0..<700).map { "Row \($0) é العربية 👩🏽‍🚀\n" }.joined() + "TAIL UNIQUE 日本語\n"
        }.value
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        let scroll = NSScrollView(frame: root.bounds)
        root.addSubview(scroll)
        let label = NSTextField(wrappingLabelWithString: text)
        label.isSelectable = true
        label.font = .systemFont(ofSize: 13)
        label.textColor = .black
        label.preferredMaxLayoutWidth = 360
        label.frame = NSRect(x: 0, y: 0, width: 360, height: 128)
        scroll.documentView = label
        let owner = NSWindow()
        owner.contentView = root
        _ = owner.makeFirstResponder(label)

        func paint() -> Bitmap {
            label.frame.size.height = label.intrinsicContentSize.height
            let bitmap = Bitmap(width: 360, height: 180, background: (1, 1, 1, 1))
            root.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
            return bitmap
        }
        func settle(_ reason: String, _ ready: () -> Bool) async throws -> Bitmap {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                let frame = paint()
                if ready() { return frame }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            fatalError("complete label did not settle: \(reason)")
        }
        let head = try await settle("head", { label.isCompleteTextLayoutReady && label.isCompleteTextViewportReady })
        precondition(label.intrinsicContentSize.height > 10_000, "complete label height still stops at eight lines")
        let revision = owner.displayRevision
        scroll.contentView.scroll(to: CGPoint(x: 0, y: label.frame.height - 180))
        let tail = try await settle("tail", { label.isCompleteTextViewportReady })
        precondition(head.pixels != tail.pixels)
        let ink = stride(from: 0, to: tail.pixels.count, by: 4).filter { tail.pixels[$0] < 200 }.count
        precondition(ink > 100, "the complete document tail was not painted")
        precondition(owner.displayRevision > revision, "worker deliveries did not invalidate native display")
        try FileManager.default.createDirectory(atPath: "out/complete-label", withIntermediateDirectories: true)
        try PNGWriter.write(head, to: URL(fileURLWithPath: "out/complete-label/head.png"))
        try PNGWriter.write(tail, to: URL(fileURLWithPath: "out/complete-label/tail.png"))

        var copied: String?
        NSPasteboard.general.writeString = { copied = $0; return true }
        label.selectAll(nil)
        label.copy(nil)
        _ = try await settle("whole copy", { copied != nil })
        precondition(copied == text, "copy must retain the complete source, including the tail")
        label.keyDown(with: NSEvent(type: .keyDown, keyCode: 115))
        for _ in 0..<8 { label.keyDown(with: NSEvent(type: .keyDown, keyCode: 124)) }
        label.keyDown(with: NSEvent(type: .keyDown, modifierFlags: .shift, keyCode: 124))
        copied = nil
        label.copy(nil)
        _ = try await settle("grapheme copy", { copied != nil })
        precondition(copied == "👩🏽‍🚀", "queued navigation split or lost the grapheme")

        for width in [330.0, 280, 350, 245] {
            label.preferredMaxLayoutWidth = width
            label.frame.size.width = width
            _ = paint()
        }
        _ = try await settle("rapid resize", { label.isCompleteTextLayoutReady && label.isCompleteTextViewportReady })
        precondition(label.selectedTextRange == NSRange(location: 8, length: 7), "reflow lost the selected source range")
        label.maximumNumberOfLines = 8
        precondition(label.intrinsicContentSize.height < 200, "collapse kept complete layout height")
        label.maximumNumberOfLines = 0
        _ = try await settle("reexpand", { label.isCompleteTextLayoutReady && label.isCompleteTextViewportReady })
        precondition(label.intrinsicContentSize.height > 10_000)
        precondition(label.selectedTextRange == NSRange(location: 8, length: 7), "collapse/expand lost the selected source range")

        let plainHeight = label.intrinsicContentSize.height
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3.75
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor(red: 0.8, green: 0.1, blue: 0.15, alpha: 1),
            .paragraphStyle: paragraph
        ])
        scroll.contentView.scroll(to: .zero)
        let styled = try await settle("uniform attributed prose", {
            label.isCompleteTextLayoutReady && label.isCompleteTextViewportReady
        })
        precondition(label.intrinsicContentSize.height > plainHeight,
                     "uniform prose lost its larger reading font or line spacing")
        var redInk = 0
        for offset in stride(from: 0, to: styled.pixels.count, by: 4) {
            let red = Int(styled.pixels[offset])
            let green = Int(styled.pixels[offset + 1])
            if red > green * 2 && green < 100 { redInk += 1 }
        }
        precondition(redInk > 100, "uniform prose lost its attributed ink")
        try PNGWriter.write(styled, to: URL(fileURLWithPath: "out/complete-label/styled-head.png"))
        copied = nil
        label.selectAll(nil)
        label.copy(nil)
        _ = try await settle("styled whole copy", { copied != nil })
        precondition(copied == text)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: label.frame.height - 180))
        _ = try await settle("styled tail", { label.isCompleteTextViewportReady })
        let measuredHeight = label.intrinsicContentSize.height
        let tailOffset = scroll.contentView.bounds.minY
        let restyled = NSMutableAttributedString(attributedString: label.attributedStringValue)
        restyled.addAttribute(.foregroundColor, value: NSColor.black,
                             range: NSRange(location: 0, length: restyled.length))
        label.attributedStringValue = restyled
        precondition(label.intrinsicContentSize.height == measuredHeight,
                     "restyling must retain measured geometry until worker delivery")
        _ = try await settle("restyled tail", {
            label.isCompleteTextLayoutReady && label.isCompleteTextViewportReady
        })
        precondition(scroll.contentView.bounds.minY == tailOffset, "restyling jumped away from the tail")
        let mixed = NSMutableAttributedString(attributedString: label.attributedStringValue)
        mixed.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: 5))
        label.attributedStringValue = mixed
        _ = paint()
        precondition(!label.isCompleteTextLayoutReady, "mixed runs must not silently become one uniform style")
        NSPasteboard.general.writeString = nil
        print("PASS complete selectable label: head/tail pixels, whole copy, grapheme selection, resize, collapse/expand and uniform attributed prose")
    }
}
