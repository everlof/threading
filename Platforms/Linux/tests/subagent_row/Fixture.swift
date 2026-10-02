import AppKit
import Foundation

@MainActor private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("Subagent row contract: \(message)") }
}

@MainActor private final class GroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Specimen.headerGround.setFill()
        bounds.fill()
    }
}

@MainActor private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
    root.subviews.flatMap { child in
        let own = (child as? T).map { [$0] } ?? []
        return own + descendants(child, of: type)
    }
}

@MainActor private func capture(_ root: NSView, at url: URL) throws {
#if os(Linux)
    let bitmap = Bitmap(width: 376, height: 350, background: (1, 1, 1, 1))
    root.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
    try PNGWriter.write(bitmap, to: url)
#else
    root.layoutSubtreeIfNeeded()
    guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
        fatalError("macOS AppKit did not allocate row bitmap")
    }
    root.cacheDisplay(in: root.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("macOS AppKit did not encode row PNG")
    }
    try data.write(to: url)
#endif
}

@main struct SubagentRowHarness {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("usage: SubagentRowHarness OUTPUT_DIRECTORY")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let root = GroundView(frame: NSRect(x: 0, y: 0, width: 376, height: 350))
#if os(Linux)
        let window = NSWindow()
#else
        _ = NSApplication.shared
        let window = NSWindow(contentRect: root.bounds, styleMask: .borderless,
                              backing: .buffered, defer: false)
#endif
        window.contentView = root

        let transcript = URL(fileURLWithPath: "/tmp/threading-child-transcript.jsonl")
        let selectedItem = SubagentSummaryItem(
            id: "child-a", title: "Review the Linux port", subtitle: "Check app UI parity",
            role: "Explore", configurationDetail: "Codex fast", state: .working,
            statusDetail: "3 of 5 files", usageDetail: "1.2k tokens",
            detailLines: ["Inspected the project sidebar"], transcriptAvailability: .onDisk(transcript)
        )
        let unavailableItem = SubagentSummaryItem(
            id: "child-b", title: "Investigate shortcut", subtitle: "Map the event path",
            role: "default", state: .completed, statusDetail: nil,
            detailLines: [], transcriptAvailability: .unavailable
        )
        let plainItem = SubagentSummaryItem(
            id: "child-c", title: "Write a focused fixture", subtitle: nil,
            state: .pending, statusDetail: nil, detailLines: [],
            transcriptAvailability: .openable
        )
        let rows = [SubagentNavigatorRowView(), SubagentNavigatorRowView(),
                    SubagentNavigatorRowView()]
        for (index, row) in rows.enumerated() {
            root.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
                row.topAnchor.constraint(equalTo: root.topAnchor, constant: CGFloat(12 + index * 112)),
                row.widthAnchor.constraint(equalToConstant: 348),
                row.heightAnchor.constraint(equalToConstant: 104)
            ])
        }
        rows[0].show(selectedItem, isSelected: true)
        rows[1].show(unavailableItem, isSelected: false)
        rows[2].show(plainItem, isSelected: false)

        var selected = [String]()
        rows[0].onSelect = { selected.append("a") }
        rows[1].onSelect = { selected.append("b") }
        rows[2].onSelect = { selected.append("c") }
        var revealed: URL?
        rows[0].onRevealTranscript = { revealed = $0 }

        try capture(root, at: output.appendingPathComponent("rows.png"))
        for (index, row) in rows.enumerated() {
            let positions = descendants(row, of: NSTextField.self)
                .map { label in
                    let global = root.convert(label.bounds, from: label)
                    return "\(label.stringValue):\(Int(global.minY)),\(Int(global.height))"
                }
            print("ROW_GEOMETRY \(index) \(positions.joined(separator: " | "))")
            let title = descendants(row, of: NSTextField.self)
                .first { $0.stringValue == [selectedItem.title, unavailableItem.title,
                                             plainItem.title][index] }!
            let rowTop = root.convert(row.bounds, from: row).maxY
            let inkTop = root.convert(title.bounds, from: title).maxY
            require(rowTop - inkTop <= 12,
                    "top-gravity stack left \(Int(rowTop - inkTop))pt above row title")
        }
        require(rows.allSatisfy { $0.frame.width == 348 && $0.frame.height == 104 },
                "fixed row geometry did not resolve")
        require(rows[0].selectionGround != nil && rows[1].selectionGround == nil,
                "selected fill ground did not follow selection")
        require(rows[0].accessibilityRole() == .button, "row role is not a button")
        require(rows[0].accessibilityTitle() == selectedItem.title, "row name was lost")
        require(rows[0].accessibilityValue() as? Bool == true,
                "selected accessible value was lost")
        require(rows[0].accessibilityHelp() == selectedItem.subtitle,
                "selected row help omitted its delegated task")
        require(rows[1].accessibilityHelp() == "No transcript recorded.",
                "unavailable row did not explain why it cannot open")
        require(!rows[1].isEnabled && !rows[1].accessibilityPerformPress(),
                "unavailable row accepted a press")
        require(rows[0].accessibilityPerformPress() && selected == ["a"],
                "selected row accessibility press missed selection")
        require(rows[2].accessibilityPerformPress() && selected == ["a", "c"],
                "plain row accessibility press missed selection")

        let labels = descendants(rows[0], of: NSTextField.self).map(\.stringValue)
        require(labels.contains("Review the Linux port") && labels.contains("Working"),
                "production heading/state labels were not mounted")
        require(labels.contains("Explore · Codex fast · 3 of 5 files · 1.2k tokens"),
                "production metadata projection was not mounted")
        require(labels.contains("Check app UI parity")
                && labels.contains("Inspected the project sidebar"),
                "task/activity detail was not mounted")
        let folder = descendants(rows[0], of: ThemedIconButton.self)
        require(folder.count == 1 && !folder[0].isHidden, "file-backed child lacks reveal control")
        require(folder[0].accessibilityPerformPress() && revealed == transcript,
                "folder accessibility press did not reveal exact transcript")
        require(descendants(rows[1], of: ThemedIconButton.self).allSatisfy(\.isHidden),
                "unavailable child showed a folder mark")

        rows[0].show(selectedItem, isSelected: false)
        rows[2].show(plainItem, isSelected: true)
        try capture(root, at: output.appendingPathComponent("selection-moved.png"))
        require(rows[0].selectionGround == nil && rows[2].selectionGround != nil,
                "selection did not move with the selected transcript")
        print("PASS SubagentRowHarness: unchanged production row renders selectable, unavailable and file-backed states; accessibility, labels and selection/reveal actions verified")
    }
}
