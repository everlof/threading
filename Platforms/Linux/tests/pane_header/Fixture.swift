import AppKit
import Foundation

@MainActor private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), "Pane header contract: \(message)")
}

@MainActor private final class HeaderGround: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Specimen.headerGround.setFill()
        bounds.fill()
    }
}

@MainActor private func capture(_ root: NSView, to url: URL) throws {
#if os(Linux)
    let bitmap = Bitmap(width: Int(root.bounds.width), height: Int(root.bounds.height),
                        background: (1, 1, 1, 1))
    root.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
    try PNGWriter.write(bitmap, to: url)
    let ruleY = Int(PaneHeaderView.bandHeight) - 1
    let ground = Array(bitmap.pixels[0..<4])
    for x in [0, bitmap.width / 2, bitmap.width - 1] {
        let offset = (ruleY * bitmap.width + x) * 4
        require(Array(bitmap.pixels[offset..<(offset + 4)]) != ground,
                "production separator did not reach the full band width")
    }
#else
    guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
        fatalError("AppKit did not allocate the pane header image")
    }
    root.cacheDisplay(in: root.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("AppKit did not encode the pane header image")
    }
    try png.write(to: url)
#endif
}

@MainActor private func constraintCount(_ view: NSView) -> Int {
    view.constraints.count + view.subviews.reduce(0) { $0 + constraintCount($1) }
}

@MainActor private func alignmentFrame(_ view: NSView) -> NSRect {
#if os(Linux)
    view.frame
#else
    // AppKit text fields include invisible frame padding outside their layout rectangle.
    view.alignmentRect(forFrame: view.frame)
#endif
}

@main struct PaneHeaderHarness {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("usage: PaneHeaderHarness OUTPUT_DIRECTORY")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = HeaderGround(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
#if os(Linux)
        let window = NSWindow()
#else
        _ = NSApplication.shared
        let window = NSWindow(contentRect: root.bounds, styleMask: .borderless,
                              backing: .buffered, defer: false)
#endif
        window.contentView = root
        let width = root.widthAnchor.constraint(equalToConstant: 400)
        NSLayoutConstraint.activate([width, root.heightAnchor.constraint(equalToConstant: 100)])

        let title = NSTextField(labelWithString: "Projects with a long readable title")
        title.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        title.textColor = Specimen.Ink(on: Specimen.headerGround).label
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let add = ThemedIconButton(symbolName: "plus", accessibility: "Add Project",
                                   target: .inline, inkSource: .chrome)
        let actions = ThemedIconButton(symbolName: "ellipsis", accessibility: "Actions",
                                       target: .inline, inkSource: .chrome)
        var activations = [String]()
        add.onPress = { activations.append("add") }
        actions.onPress = { activations.append("actions") }
        let header = PaneHeaderView(leading: [title], trailing: [add, actions])
        root.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])

        var geometries = [[String: Any]]()
        var initialConstraintCount: Int?
        for (name, size) in [("wide", CGFloat(400)), ("narrow", 160), ("resized", 400)] {
            width.constant = size
            root.frame.size.width = size
            root.layoutSubtreeIfNeeded()
            require(abs(header.frame.height - 41) < 0.1, "production default band height changed")
            require(abs(header.frame.width - size) < 0.1, "band did not follow the host width")
            require(abs(add.frame.width - 20) < 0.1 && abs(actions.frame.width - 20) < 0.1,
                    "narrow title squeezed a control target")
            let titleLayout = alignmentFrame(title)
            let addLayout = alignmentFrame(add)
            let actionsLayout = alignmentFrame(actions)
            require(titleLayout.maxX <= addLayout.minX - PaneHeaderView.itemSpacing + 0.1,
                    "title overlaps the trailing controls")
            require(abs(add.frame.midY - actions.frame.midY) < 0.1,
                    "controls lost their shared centerline")
            // The real 1x AppKit field snaps its odd-height text rectangle by half a point.
            require(abs(titleLayout.midY - actionsLayout.midY) <= 0.5,
                    "loose title did not center in the control band: title \(titleLayout), actions \(actionsLayout)")
            require(abs(actions.frame.maxX + PaneHeaderView.contentInset
                        - actions.opticalHorizontalInset - size) < 0.1,
                    "trailing margin is not measured from visible ink")
            if let count = initialConstraintCount {
                require(constraintCount(root) == count, "resize accumulated header constraints")
            } else {
                initialConstraintCount = constraintCount(root)
            }
            func rect(_ view: NSView) -> [Double] {
                let frame = root.convert(view.bounds, from: view)
                return [Double(frame.minX), Double(root.bounds.maxY - frame.maxY),
                        Double(frame.width), Double(frame.height)]
            }
            geometries.append(["name": name, "title": rect(title), "add": rect(add),
                               "actions": rect(actions), "header": rect(header)])
            try capture(root, to: output.appendingPathComponent(name + ".png"))
        }
        require(add.accessibilityPerformPress() && actions.accessibilityPerformPress(),
                "mounted production controls refused accessibility activation")
        require(activations == ["add", "actions"], "mounted actions reached the wrong callback")
        actions.isSelected = true
        try capture(root, to: output.appendingPathComponent("open.png"))
        add.isEnabled = false
        require(!add.accessibilityPerformPress() && activations == ["add", "actions"],
                "disabled header control admitted an operation")
        try capture(root, to: output.appendingPathComponent("disabled.png"))
        let json = try JSONSerialization.data(withJSONObject: geometries, options: [.sortedKeys])
        try json.write(to: output.appendingPathComponent("geometry.json"))
        print("PASS production pane header width, optical margins, title compression, resize, separator and control actions")
    }
}
