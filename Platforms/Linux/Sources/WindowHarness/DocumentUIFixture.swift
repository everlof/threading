#if os(Linux)
import AppKit
import Foundation
import LinuxWindowBridge
import NativeDiffAppKit
@testable import CoreSlice

private struct DocumentFixtureReply: Sendable {
    let markdown: String
    let timelineRows: Int
    let streamingCleared: Bool
    let blocks: [String]
}

private struct DiffFixtureReply: Sendable {
    let lines: [DiffLine]
    let timelineRows: Int
}

private func prepareDiffFixtureReply() throws -> DiffFixtureReply {
    let old = """
    func greeting() -> String {
        let count = 1
        // Keep this shared context line.
        return "Hello"
    }
    """
    let new = """
    func greeting() -> String {
        let count = 42
        // Keep this shared context line.
        // Unicode é, räksmörgås, 中文 and 👩🏽‍🚀 stays selectable across the complete line while the native diff row wraps with the pane.
        return "Hello, Linux"
    }
    """
    let envelopes: [[String: Any]] = [
        ["type": "assistant", "message": ["content": [NSNull(), [
            "type": "tool_use", "id": "diff-fixture", "name": "Edit",
            "input": ["file_path": "/tmp/greeting.swift", "old_string": old, "new_string": new]
        ]]]],
        ["type": "user", "message": ["content": [[
            "type": "tool_result", "tool_use_id": "diff-fixture", "content": "Applied edit", "is_error": false
        ]]]]
    ]
    var timeline = ConversationTimeline(sessionID: SessionID(), chartDecoder: { _, _ in nil })
    _ = timeline.apply(.userMessage("Inspect the shared edit renderer."))
    for envelope in envelopes {
        let data = try JSONSerialization.data(withJSONObject: envelope)
        guard case .events(let events) = StreamEvent.parse(String(decoding: data, as: UTF8.self)) else {
            throw WindowFailure("diff fixture provider envelope was refused")
        }
        for event in events { _ = timeline.apply(event) }
    }
    _ = timeline.apply(.turnFinished(text: nil, outcome: .completed, metrics: .empty))
    guard case .toolCall(let call) = timeline.rows.last, let lines = call.diff,
          call.result?.outcome == .succeeded else {
        throw WindowFailure("diff fixture lost its authoritative successful edit")
    }
    return DiffFixtureReply(lines: lines, timelineRows: timeline.rows.count)
}

/// This fixture's deliberately malformed sibling exercises the production wire-to-timeline
/// path before the shared Markdown renderer receives the authoritative assistant message.
private func prepareDocumentFixtureReply(_ source: String) throws -> DocumentFixtureReply {
    let message: [String: Any] = ["type": "assistant", "message": ["content": [
        NSNull(), ["type": "text", "text": source]
    ]]]
    let data = try JSONSerialization.data(withJSONObject: message)
    guard case .events(let events) = StreamEvent.parse(String(decoding: data, as: UTF8.self)) else {
        throw WindowFailure("document fixture provider envelope was refused")
    }
    var timeline = ConversationTimeline(sessionID: SessionID(), chartDecoder: { _, _ in nil })
    _ = timeline.apply(.userMessage("Inspect the shared document renderer."))
    _ = timeline.apply(.textDelta("An incomplete fixture reply"))
    for event in events { _ = timeline.apply(event) }
    _ = timeline.apply(.turnFinished(text: nil, outcome: .completed, metrics: .empty))
    guard case .assistant(let markdown) = timeline.rows.last else {
        throw WindowFailure("document fixture lost its assistant message")
    }
    return DocumentFixtureReply(markdown: markdown, timelineRows: timeline.rows.count,
                                streamingCleared: timeline.streamingText.isEmpty,
                                blocks: Markdown.sourceBlocks(markdown))
}

/// The production document view in the native preview shell. This diagnostic does not invent
/// provider state or claim native conversation transport support.
@MainActor
enum DocumentUIFixture {
    private struct Control: Codable, Sendable {
        let title: String
        let x: Int, y: Int, width: Int, height: Int
        let enabled: Bool
        let selectedStart: Int, selectedLength: Int
        let completeTextReady: Bool
        let completeViewportReady: Bool
    }
    private struct State: Codable, Sendable {
        let serial: Int
        let dark: Bool
        let documentHeight: Double, scrollY: Double
        let documentY: Double, viewportHeight: Double
        let controls: [Control]
        let timelineRows: Int
        let streamingCleared: Bool
        let totalRows: Int
        let mountedRows: Int
        let constructedCells: Int
        let configuredCells: Int
        let releasedCells: Int
        let liveContents: Int
        let navigationActions: Int
        let diffLines: Int
        let addedWash: [Double]
        let removedWash: [Double]
        let appDiffViews: Int
        let contextReference: String?
        let contextPreviewRows: Int
        let stream: StreamState?
    }
    private struct StreamState: Codable, Sendable {
        let lines: Int
        let malformedLines: Int
        let settledTurns: Int
        let streamingUpdates: Int
        let longestStreamingText: Int
        let streaming: Bool
        let markdownBlocks: Int
        let diffRows: Int
        let outcome: String?
        let model: String?
        let failure: String?
        let exitStatus: Int32?
        let diagnostic: String?
    }
    private static let streamPrompts = [
        "Stream a reply and an edit through the shared transport.",
        "Keep the same process for a second turn: é, 中文, 👩🏽‍🚀.",
    ]

    static func run(output: String, automaticRows: Bool = false, diffMode: Bool = false,
                    userBubbleMode: Bool = false,
                    userBubbleText: String? = nil,
                    streamAgent: [String]? = nil,
                    keyEvent: (TWEvent) -> NSEvent) async throws {
        let source = userBubbleMode ? await Task.detached {
            userBubbleText ?? "FIRST user message é 👩🏽‍🚀\n" + (0..<300).map { "User line \($0): Unicode 日本語 العربية 👩🏽‍🚀\n" }.joined() + "TAIL USER MESSAGE é 👩🏽‍🚀"
        }.value : sample
        let reply = try await Task.detached {
            if userBubbleMode {
                var timeline = ConversationTimeline(sessionID: SessionID(), chartDecoder: { _, _ in nil })
                _ = timeline.apply(.userMessage(source))
                guard case .userMessage(let message) = timeline.rows.last else { throw WindowFailure("user fixture lost its message") }
                return DocumentFixtureReply(markdown: message.text, timelineRows: timeline.rows.count, streamingCleared: true, blocks: [message.text])
            }
            return try prepareDocumentFixtureReply(source)
        }.value
        let diffReply = diffMode ? try await Task.detached { try prepareDiffFixtureReply() }.value : nil
        let directory = URL(fileURLWithPath: output)
        try await Task.detached { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }.value
        guard let native = tw_open("Threading document renderer", 1120, 900) else {
            throw WindowFailure(String(cString: tw_error()))
        }
        defer { tw_close(native) }
        NativeCursorBoundary.install(for: native)
        defer { NativeCursorBoundary.uninstall() }
        tw_workspace_mode(native, 320, 0)
        tw_workspace_placeholder_mode(native, 1)
        _ = tw_workspace_composer_mode(native, 1)
        NSPasteboard.general.writeString = { value in
            let bytes = Array(value.utf8)
            return bytes.withUnsafeBufferPointer { tw_clipboard_write($0.baseAddress, Int32($0.count)) == 0 }
        }
        defer { NSPasteboard.general.writeString = nil }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 450))
        root.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
        let sidebar = Specimen.Window(frame: NSRect(x: 0, y: 0, width: 160, height: 450))
        sidebar.title = "Renderer evidence"
        root.addSubview(sidebar)
        let owner = NSWindow(backingScaleFactor: 2)
        owner.contentView = root
        let title = PageTitleView(symbolName: "doc.text", inkSource: .chrome)
        title.update(title: streamAgent != nil ? "Conversation stream"
                        : diffMode ? "Conversation diff" : "Conversation document",
                     symbolName: "doc.text", identity: "document-fixture")
        title.actionsAnchor.isHidden = true
        let header = PaneHeaderView(leading: [title])
        header.translatesAutoresizingMaskIntoConstraints = true
        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        scroll.verticalScrollElasticity = .none
        let rows = streamAgent != nil ? DocumentRowSource()
            : userBubbleMode ? DocumentRowSource(userMessage: reply.markdown)
            : diffReply.map { DocumentRowSource(diffLines: $0.lines) }
            ?? (automaticRows ? DocumentRowSource(sources: reply.blocks) : nil)
        let table: NSTableView? = rows.map { source in
            let table = NSTableView()
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ConversationContent"))
            column.width = 368
            table.addTableColumn(column)
            table.rowHeight = 48
            table.usesAutomaticRowHeights = true
            table.dataSource = source
            table.delegate = source
            return table
        }
        let document: NSView = table ?? MarkdownView(markdown: reply.markdown)
        let stream = try streamAgent.map { arguments -> StreamConversationDriver in
            guard let rows, let table else { throw WindowFailure("stream fixture has no table") }
            return try StreamConversationDriver(arguments: arguments, rows: rows, table: table)
        }
        var renderedRevision = -1
        var sentPrompts = 0
        scroll.documentView = document
        root.addSubview(header)
        root.addSubview(scroll)
        let width = table == nil ? document.widthAnchor.constraint(equalToConstant: 368) : nil
        width?.isActive = true
        var pixelWidth = 1120, pixelHeight = 900, serial = 0
        var pageStart = ""
        var laidOutWidth: CGFloat = 0
        var dirty = true
        var insertedPrefix = false, appendedTail = false
        var navigationActions = 0
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func layout() {
            let wasAtTop = scroll.contentView.bounds.maxY >= document.frame.maxY - 1
            root.frame.size = NSSize(width: CGFloat(pixelWidth) / 2, height: CGFloat(pixelHeight) / 2)
            sidebar.frame.size.height = root.bounds.height
            let paneWidth = root.bounds.width - 160
            header.frame = NSRect(x: 160, y: root.bounds.height - PaneHeaderView.bandHeight,
                                  width: paneWidth, height: PaneHeaderView.bandHeight)
            scroll.frame = NSRect(x: 176, y: 8, width: max(1, paneWidth - 32),
                                 height: max(1, root.bounds.height - PaneHeaderView.bandHeight - 16))
            width?.constant = scroll.bounds.width
            if let table {
                table.tableColumns.first?.width = scroll.bounds.width
                table.frame.size.width = scroll.bounds.width
                if table.numberOfRows == 0 { table.reloadData() }
                if scroll.bounds.width != laidOutWidth {
                    ConversationVirtualRowHost.stateColumnWidth(in: table)
                    table.noteHeightOfRows(withIndexesChanged: table.visibleRowIndexes)
                }
            } else {
                document.frame = NSRect(x: 0, y: 0, width: scroll.bounds.width, height: document.fittingSize.height)
            }
            _ = document.layoutSubtreeIfNeeded()
            _ = header.layoutSubtreeIfNeeded()
            _ = root.layoutSubtreeIfNeeded()
            let start = views(document).compactMap { ($0 as? NSTextField)?.stringValue }.first ?? ""
            if table == nil, start != pageStart || (scroll.bounds.width != laidOutWidth && wasAtTop) {
                pageStart = start
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.bounds.height)))
            }
            laidOutWidth = scroll.bounds.width
            let controls = views(document).filter {
                ($0 as? NSTextField)?.isSelectable == true || ($0 as? ThemedButton)?.isEnabled == true
            }
            if controls.count > 1 {
                for (index, control) in controls.enumerated() {
                    control.nextKeyView = controls[(index + 1) % controls.count]
                }
            }
            owner.initialFirstResponder = controls.first
            if owner.firstResponder === owner, let first = controls.first { _ = owner.makeFirstResponder(first) }
        }
        var renderedDisplayRevision: UInt64 = 0
        while true {
            if owner.displayRevision != renderedDisplayRevision { dirty = true }
            if dirty {
                // Read before building the frame: deliveries can run during the awaited state
                // write below, and must leave the next frame owed rather than marked drawn.
                let revisionBeingRendered = stream?.revision
                layout()
                let bitmap = Bitmap(width: pixelWidth, height: pixelHeight, background: LinuxTheme.components("surface"))
                root.render(in: NSGraphicsContext(bitmap: bitmap, scale: 2))
                let displayRevisionBeingRendered = owner.displayRevision
                for (origin, paneWidth, sidebar) in [(0, 320, Int32(1)), (320, pixelWidth - 320, Int32(0))] {
                    var pane = [UInt8]()
                    pane.reserveCapacity(paneWidth * pixelHeight * 4)
                    for row in 0..<pixelHeight {
                        let start = (row * pixelWidth + origin) * 4
                        pane.append(contentsOf: bitmap.pixels[start..<(start + paneWidth * 4)])
                    }
                    let result = pane.withUnsafeBufferPointer {
                        tw_present_pane(native, $0.baseAddress, Int32(paneWidth), Int32(pixelHeight), sidebar)
                    }
                    guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
                }
                serial += 1
                let controls = views(document).compactMap { view -> Control? in
                    let text: String, enabled: Bool, selection: NSRange
                    if let field = view as? NSTextField {
                        text = field.stringValue; enabled = field.isSelectable; selection = field.selectedTextRange
                    } else if let button = view as? ThemedButton {
                        text = button.title; enabled = button.isEnabled; selection = NSRange(location: 0, length: 0)
                    } else { return nil }
                    let rect = view.convert(view.bounds, to: root)
                    return Control(title: text, x: Int(rect.minX * 2), y: Int((root.bounds.height - rect.maxY) * 2),
                        width: Int(rect.width * 2), height: Int(rect.height * 2), enabled: enabled,
                        selectedStart: selection.location, selectedLength: selection.length,
                        completeTextReady: (view as? NSTextField)?.isCompleteTextLayoutReady ?? false,
                        completeViewportReady: (view as? NSTextField)?.isCompleteTextViewportReady ?? false)
                }
                var addedWash: [Double] = [], removedWash: [Double] = []
                if diffMode {
                    LinuxTheme.appearance.performAsCurrentDrawingAppearance {
                        let palette = DiffAppKitTheme.threading()
                        for (color, added) in [(palette.addedBackground, true), (palette.removedBackground, false)] {
                            let channels = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map(Double.init)
                            if added { addedWash = channels } else { removedWash = channels }
                        }
                    }
                }
                let state = State(serial: serial, dark: LinuxTheme.isDark,
                    documentHeight: Double(document.frame.height), scrollY: Double(scroll.contentView.bounds.minY),
                    documentY: Double(document.frame.minY), viewportHeight: Double(scroll.contentView.bounds.height),
                    controls: controls,
                    timelineRows: stream?.timelineRows ?? diffReply?.timelineRows ?? reply.timelineRows,
                    streamingCleared: reply.streamingCleared,
                    totalRows: table?.numberOfRows ?? 0, mountedRows: table?.mountedViewCount ?? 0,
                    constructedCells: rows?.constructed ?? 0,
                    configuredCells: rows?.configured ?? 0, releasedCells: rows?.released ?? 0,
                    liveContents: rows?.live.count ?? 0, navigationActions: navigationActions,
                    diffLines: diffReply?.lines.count ?? 0, addedWash: addedWash, removedWash: removedWash,
                    appDiffViews: rows?.appDiffViewCount ?? 0, contextReference: rows?.contextReference,
                    contextPreviewRows: rows?.contextPreviewRows ?? 0,
                    stream: stream.map { driver in
                        StreamState(lines: driver.lines, malformedLines: driver.malformedLines,
                            settledTurns: driver.settledTurns, streamingUpdates: driver.streamingUpdates,
                            longestStreamingText: driver.longestStreamingText, streaming: driver.isStreaming,
                            markdownBlocks: rows?.markdownBlocks ?? 0, diffRows: rows?.diffRows ?? 0,
                            outcome: driver.lastOutcome, model: driver.model, failure: driver.failure,
                            exitStatus: driver.exitStatus, diagnostic: driver.diagnostic)
                    })
                try await Task.detached {
                    // Publish pixels before their state. Readers use state as the ready marker.
                    try PNGWriter.write(bitmap, to: directory.appendingPathComponent("frame.png"))
                    try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("state.json"), options: .atomic)
                }.value
                dirty = false
                renderedDisplayRevision = displayRevisionBeingRendered
                if let stream, let revisionBeingRendered {
                    renderedRevision = revisionBeingRendered
                    if sentPrompts == 0 {
                        stream.send(streamPrompts[0])
                        sentPrompts = 1
                    }
                }
            }
            var event = TWEvent()
            await Task.yield()
            if let stream {
                // Transport deliveries run on the main queue, so the loop polls and yields the
                // main actor instead of blocking in the native wait.
                // Yield after every poll, not only after a quiet one: a steady native event
                // stream would otherwise hold deliveries back until the next frame write.
                let received = tw_next_timeout(native, &event, 16)
                guard received >= 0 else { throw WindowFailure(String(cString: tw_error())) }
                try? await Task.sleep(nanoseconds: 1_000_000)
                if stream.revision != renderedRevision {
                    if let table, table.numberOfRows > 0 { table.scrollRowToVisible(table.numberOfRows - 1) }
                    dirty = true
                }
                if received == 0 { continue }
            } else {
                let received = tw_next_timeout(native, &event, 16)
                guard received >= 0 else { throw WindowFailure(String(cString: tw_error())) }
                try? await Task.sleep(nanoseconds: 1_000_000)
                if received == 0 { continue }
            }
            // F11 ends a stream session the way closing the window does, without relying on a
            // window manager to deliver the close request.
            let endsStream = stream != nil && event.kind == 48 && event.action != 3
                && Int(event.key) == TW_KEY_F11
            if event.kind == 5 || endsStream {
                guard let stream else { return }
                await stream.close()
                renderedRevision = -1
                dirty = true
                let final = State(serial: serial + 1, dark: LinuxTheme.isDark, documentHeight: 0, scrollY: 0,
                    documentY: 0, viewportHeight: 0, controls: [], timelineRows: stream.timelineRows,
                    streamingCleared: !stream.isStreaming, totalRows: table?.numberOfRows ?? 0,
                    mountedRows: table?.mountedViewCount ?? 0, constructedCells: rows?.constructed ?? 0,
                    configuredCells: rows?.configured ?? 0, releasedCells: rows?.released ?? 0,
                    liveContents: rows?.live.count ?? 0, navigationActions: navigationActions, diffLines: 0,
                    addedWash: [], removedWash: [], appDiffViews: rows?.appDiffViewCount ?? 0,
                    contextReference: nil, contextPreviewRows: 0,
                    stream: StreamState(lines: stream.lines, malformedLines: stream.malformedLines,
                        settledTurns: stream.settledTurns, streamingUpdates: stream.streamingUpdates,
                        longestStreamingText: stream.longestStreamingText, streaming: stream.isStreaming,
                        markdownBlocks: rows?.markdownBlocks ?? 0, diffRows: rows?.diffRows ?? 0,
                        outcome: stream.lastOutcome, model: stream.model, failure: stream.failure,
                        exitStatus: stream.exitStatus, diagnostic: stream.diagnostic))
                try await Task.detached {
                    try JSONEncoder().encode(final).write(to: directory.appendingPathComponent("final.json"), options: .atomic)
                }.value
                return
            }
            if event.kind == 1 {
                pixelWidth = Int(event.width); pixelHeight = Int(event.height); dirty = true
            } else if event.kind == 44, event.action == 0 {
                LinuxTheme.setDark(!LinuxTheme.isDark)
                root.appearance = LinuxTheme.appearance
                sidebar.setThemeAppearance()
                LinuxTheme.appearance.performAsCurrentDrawingAppearance {
                    NotificationCenter.default.post(AppThemeDidChange())
                }
                table?.noteHeightOfRows(withIndexesChanged: table?.visibleRowIndexes ?? [])
                dirty = true
            } else if event.kind == 39 {
                let type: NSEvent.EventType
                switch event.action {
                case 1: type = .leftMouseDown
                case 2: type = .leftMouseDragged
                case 3: type = .leftMouseUp
                case 7: type = .scrollWheel
                default: type = .mouseMoved
                }
                _ = owner.dispatchToContent(NSEvent(type: type,
                    locationInWindow: NSPoint(x: 160 + CGFloat(event.x) / 2, y: root.bounds.height - CGFloat(event.y) / 2),
                    scrollingDeltaX: CGFloat(event.scrollingDeltaX), scrollingDeltaY: CGFloat(event.scrollingDeltaY)))
                dirty = true
            } else if event.kind == 48, event.action != 3 {
                // Opt-in diagnostic mutations drive the same incremental table API used by
                // the production transcript. These keys exist only in this fixture.
                if userBubbleMode, Int(event.key) == TW_KEY_F9 {
                    scroll.contentView.scroll(to: NSPoint(x: 0,
                        y: max(0, document.frame.height - scroll.contentView.bounds.height)))
                    dirty = true
                    continue
                }
                if let stream, Int(event.key) == TW_KEY_F10 {
                    if sentPrompts == 1 {
                        stream.send(streamPrompts[1])
                        sentPrompts = 2
                    }
                    continue
                }
                if let rows, let table, (TW_KEY_F6...TW_KEY_F9).contains(Int(event.key)) {
                    switch Int(event.key) {
                    case TW_KEY_F6 where !insertedPrefix:
                        rows.insert("Inserted assistant block: Unicode é 👩🏽‍🚀.", at: 0, in: table)
                        insertedPrefix = true
                    case TW_KEY_F7 where insertedPrefix:
                        rows.remove(at: 0, in: table)
                        insertedPrefix = false
                    case TW_KEY_F8 where !appendedTail:
                        rows.insert("Appended assistant block: Unicode é 👩🏽‍🚀.", at: table.numberOfRows, in: table)
                        appendedTail = true
                    case TW_KEY_F9 where appendedTail:
                        rows.remove(at: table.numberOfRows - 1, in: table)
                        appendedTail = false
                    default: break
                    }
                    dirty = true
                    continue
                }
                let key = keyEvent(event)
                if key.keyCode == 48 {
                    if key.modifierFlags.contains(.shift) { owner.selectPreviousKeyView(nil) }
                    else { owner.selectNextKeyView(nil) }
                } else if key.keyCode == 116 || key.keyCode == 121 {
                    navigationActions += 1
                    let direction: CGFloat = key.keyCode == 116 ? -1 : 1
                    let delta = scroll.bounds.height * direction * (scroll.contentView.isFlipped ? 1 : -1)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY + delta))
                } else { _ = owner.dispatchToContent(key) }
                dirty = true
            }
        }
    }

    private static let sample = """
    # A shared conversation document

    Select this **bold** and *italic* paragraph. Unicode stays whole: é, räksmörgås, 中文 and 👩🏽‍🚀. The same Markdown view runs on macOS and Linux.

    - The first item wraps onto its own hanging indent when the pane becomes narrow.
    - The second item keeps `inline code` styled.

    ```swift
    let greeting = "Hello, Linux"
    print(greeting)
    ```

    > A quote remains part of the document, with its own quiet ink and rule.

    | Item | State | Count |
    | :--- | :--- | ---: |
    | Text | Selectable | 3 |
    | Document | Shared | 2 |

    """ + (1...60).map { "Paragraph \($0). A bounded page keeps the complete document reachable.\n\n" }.joined()
}
#endif
