import AppKit
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private func yellowPixels(_ bitmap: Bitmap, in rect: NSRect) -> Int {
    let left = max(0, Int(rect.minX)), right = min(bitmap.width, Int(rect.maxX))
    let top = max(0, Int(rect.minY)), bottom = min(bitmap.height, Int(rect.maxY))
    var count = 0
    for y in top..<bottom {
        for x in left..<right {
            let offset = (y * bitmap.width + x) * 4
            if bitmap.pixels[offset] > 180 && bitmap.pixels[offset + 1] > 125 &&
                bitmap.pixels[offset + 2] < 120 { count += 1 }
        }
    }
    return count
}

@MainActor private func render(_ root: NSView) -> Bitmap {
    let bitmap = Bitmap(width: 240, height: 70, background: (1, 1, 1, 1))
    root.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
    return bitmap
}

@main struct SearchMatchFixture {
    @MainActor static func main() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 70))
        let label = SearchMatchLabel()
        root.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            label.widthAnchor.constraint(equalToConstant: 178),
            label.heightAnchor.constraint(equalToConstant: 24)
        ])

        let sentence = "Motión café — Unicode search highlighting continues"
        label.show(sentence, matching: "motion")
        require(label.markedTextForTesting == ["Motión"], "diacritic-insensitive match changed")
        require(label.accessibilityValue() as? String == sentence, "full accessible value lost")
        guard let field = label.subviews.first as? NSTextField else {
            preconditionFailure("production label did not mount an NSTextField")
        }
        require(field.usesSingleLineMode && field.lineBreakMode == .byTruncatingTail,
                "production one-line truncation contract changed")
        require(field.cell?.truncatesLastVisibleLine == true,
                "field cell did not retain last-line truncation")
        require(!field.isAccessibilityElement(), "container must remain the only accessible element")
        require(field.intrinsicContentSize.width > 178,
                "full attributed line should remain wider than the visible row")

        let truncated = render(root)
        let yellow = yellowPixels(truncated, in: NSRect(x: 12, y: 10, width: 68, height: 24))
        require(yellow > 25, "matched run background did not render")
        require(yellowPixels(truncated, in: NSRect(x: 190, y: 10, width: 50, height: 24)) == 0,
                "highlight escaped the label width")
        field.lineBreakMode = .byClipping
        let clipped = render(root)
        require(clipped.pixels != truncated.pixels, "attributed tail ellipsis did not change pixels")

        let wrappingField = NSTextField(labelWithString: "")
        wrappingField.attributedStringValue = NSAttributedString(
            string: "A long highlighted status continues beyond this narrow field",
            attributes: [.font: NSFont.systemFont(ofSize: 13),
                         .foregroundColor: NSColor.black]
        )
        wrappingField.frame = NSRect(x: 0, y: 0, width: 72, height: 22)
        wrappingField.lineBreakMode = .byWordWrapping
        wrappingField.maximumNumberOfLines = 1
        let plainWrap = Bitmap(width: 72, height: 22, background: (1, 1, 1, 1))
        wrappingField.render(in: NSGraphicsContext(bitmap: plainWrap, scale: 1))
        wrappingField.cell?.truncatesLastVisibleLine = true
        let ellipsizedWrap = Bitmap(width: 72, height: 22, background: (1, 1, 1, 1))
        wrappingField.render(in: NSGraphicsContext(bitmap: ellipsizedWrap, scale: 1))
        require(plainWrap.pixels != ellipsizedWrap.pixels,
                "cell last-line truncation must change attributed wrapping pixels")

        try FileManager.default.createDirectory(atPath: "out", withIntermediateDirectories: true)
        try PNGWriter.write(truncated, to: URL(fileURLWithPath: "out/search-match.png"))
        print("SearchMatchLabel production text, highlight, truncation, and accessibility pass")
    }
}
