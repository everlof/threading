import XCTest
import AppKit
@testable import Threading

/// The comment sheet's two affirmatives, the chords that reach them, and the plain prose a
/// terminal session is handed instead of the typed envelope.
@MainActor
final class ContextHandoffTests: XCTestCase {

    // MARK: - The Sheet

    func testCommentSheetOffersHoldAndSend() {
        let request = ContextCommentAlert.makeRequest(for: Self.attachmentReference)

        XCTAssertEqual(
            TextPromptAlert.affirmatives(for: request),
            [L10n.string("Add to Chat"), L10n.string("Send")],
            "A comment is either parked beside the prompt or sent as its own turn, and both "
                + "have to be reachable from the sheet that collected it."
        )
    }

    func testCommentSheetNamesWhatItIsCommentingOn() {
        let request = ContextCommentAlert.makeRequest(for: Self.attachmentReference)

        XCTAssertTrue(
            request.title.contains("chart.png"),
            "The sheet is opened from a menu that has already closed, so the title is the only "
                + "thing left saying which of eight attachments this is about."
        )
        XCTAssertEqual(request.message, "docs/chart.png")
    }

    func testCommentFieldIsSizedForProseRatherThanForAName() {
        let request = ContextCommentAlert.makeRequest(for: Self.attachmentReference)

        XCTAssertGreaterThan(
            request.fieldSize.width,
            TextPromptDefaults.fieldWidth,
            "A comment is a sentence. The box a branch name lives in scrolls one out of sight "
                + "while it is being written."
        )
    }

    func testPreviewKeepsNeighboursAndMarksEverySelectedLine() throws {
        let preview = try XCTUnwrap(CodeContextPreview.make(
            totalLineCount: 8,
            target: 3...5
        ) { index in
            CodeContextPreview.SourceLine(
                number: index + 10,
                change: index == 4 ? .added : .context,
                text: "line \(index)"
            )
        })

        let lines = preview.rows.compactMap { row -> (Int?, Bool)? in
            guard case .line(let line, let isTarget) = row else { return nil }
            return (line.number, isTarget)
        }
        XCTAssertEqual(lines.map { $0.0 }, [11, 12, 13, 14, 15, 16, 17])
        XCTAssertEqual(
            lines.filter { $0.1 }.map { $0.0 },
            [13, 14, 15],
            "A multi-line comment must light every selected row, not only its first anchor."
        )
    }

    func testHugePreviewKeepsBothEndsBehindOneExplicitGap() throws {
        var requestedIndices: [Int] = []
        let preview = try XCTUnwrap(CodeContextPreview.make(
            totalLineCount: 100,
            target: 1...98
        ) { index in
            requestedIndices.append(index)
            return CodeContextPreview.SourceLine(
                number: index + 1,
                change: .context,
                text: "line \(index)"
            )
        })

        XCTAssertEqual(requestedIndices, [0, 1, 2, 3, 4, 95, 96, 97, 98, 99])
        XCTAssertEqual(preview.rows.count, 11, "Ten code rows and one omission row.")
        XCTAssertTrue(preview.rows.contains(.omission(90)))

        let targets = preview.rows.compactMap { row -> Int? in
            guard case .line(let line, true) = row else { return nil }
            return line.number
        }
        XCTAssertEqual(targets, [2, 3, 4, 5, 96, 97, 98, 99])
    }

    func testCommentRequestUsesCodePreviewInsteadOfRepeatingTheExcerpt() throws {
        let preview = try XCTUnwrap(Self.codePreview)
        let request = ContextCommentAlert.makeRequest(
            for: Self.codeReference,
            preview: preview
        )

        XCTAssertNil(
            request.message,
            "The highlighted code surface replaces the old plain-text excerpt above the field."
        )
        XCTAssertEqual(
            ContextCommentAlert.makeRequest(for: Self.codeReference).message,
            Self.codeReference.excerpt,
            "Non-diff comments still need their ordinary informative copy."
        )
    }

    func testPromptKeepsTheCommentFieldFocusedBelowItsCodeContext() throws {
        let field = ThemedTextField(frame: NSRect(
            origin: .zero,
            size: NSSize(
                width: TextPromptDefaults.commentFieldWidth,
                height: TextPromptDefaults.fieldHeight
            )
        ))
        let previewView = CodeContextPreviewView(preview: try XCTUnwrap(Self.codePreview))
        let alert = TextPromptAlert.makeAlert(
            ContextCommentAlert.makeRequest(for: Self.codeReference, preview: Self.codePreview),
            field: field,
            supportingView: previewView
        )

        XCTAssertTrue(alert.initialFirstResponder === field)
        let accessory = try XCTUnwrap(alert.accessoryView)
        XCTAssertTrue(accessory.subviews.contains { $0 === field })
        XCTAssertTrue(accessory.subviews.contains { $0 === previewView })
        XCTAssertGreaterThan(accessory.frame.height, field.frame.height)
    }

    /// The production sheet, not a stand-in: this leaves reviewable fixtures when a render
    /// output directory is supplied and makes every run prove the new surface draws in native,
    /// light-retro, and dark palettes.
    func testCommentSheetPreviewRendersUnderSystemAndTwoStyledThemes() throws {
        let previous = AppThemeLibrary.current
        defer {
            AppThemePalette.set(previous)
            NotificationCenter.default.post(AppThemeDidChange(themeID: previous.id))
        }

        let directory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
                ?? NSTemporaryDirectory()
        ).appendingPathComponent("ThreadingRenders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let preview = try XCTUnwrap(Self.codePreview)
        let themes = [AppTheme.system, AppThemeStyles.platinum, AppThemeStyles.cyberpunk]
        for theme in themes {
            AppThemePalette.set(theme)
            NotificationCenter.default.post(AppThemeDidChange(themeID: theme.id))

            let field = ThemedTextField(frame: NSRect(
                origin: .zero,
                size: NSSize(
                    width: TextPromptDefaults.commentFieldWidth,
                    height: TextPromptDefaults.fieldHeight
                )
            ))
            field.placeholderString = L10n.string("What should change?")
            let alert = TextPromptAlert.makeAlert(
                ContextCommentAlert.makeRequest(for: Self.codeReference, preview: preview),
                field: field,
                supportingView: CodeContextPreviewView(preview: preview)
            )
            let content = alert.makeContentView()
            content.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            content.layoutSubtreeIfNeeded()
            content.frame = NSRect(origin: .zero, size: content.fittingSize)
            AppThemeRefresh.repaint(content)
            content.layoutSubtreeIfNeeded()

            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            XCTAssertFalse(data.isEmpty)
            try data.write(to: directory.appendingPathComponent(
                "comment-code-context-\(theme.id.rawValue).png"
            ))
        }
    }

    // MARK: - The Chords

    func testReturnHoldsAndCommandReturnSends() {
        let request = ContextCommentAlert.makeRequest(for: Self.attachmentReference)
        let alert = TextPromptAlert.makeAlert(request, field: NSView())
        let chords = ThemedAlert.resolvedChords(for: alert.buttons)

        XCTAssertEqual(alert.buttons.count, 3, "Add to Chat, Send, Cancel.")
        XCTAssertEqual(
            chords[0].shortcut,
            KeyboardShortcut(key: "\r", modifiers: []),
            "The default answers a *bare* Return once ⌘Return is also on offer — a plain key "
                + "equivalent matches its character whatever is held with it, and would eat both."
        )
        XCTAssertTrue(chords[0].keyEquivalent.isEmpty)
        XCTAssertEqual(chords[1].shortcut, KeyboardShortcut(key: "\r", modifiers: .command))
        XCTAssertNil(chords[2].shortcut, "Cancel is reached by Escape or by the mouse.")
    }

    func testBothChordsAreDrawnOnTheButtonsThatAnswerThem() {
        let request = ContextCommentAlert.makeRequest(for: Self.attachmentReference)
        let alert = TextPromptAlert.makeAlert(request, field: NSView())
        let chords = ThemedAlert.resolvedChords(for: alert.buttons)

        XCTAssertEqual(chords[0].shortcut?.displayString, "↩")
        XCTAssertEqual(
            chords[1].shortcut?.displayString,
            "⌘↩",
            "A shortcut nobody can see is a shortcut nobody finds, and this pair is the whole "
                + "reason the sheet is cheaper than copying the path by hand."
        )
    }

    func testAnOrdinarySheetKeepsItsPlainReturn() {
        let alert = ThemedAlert()
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let chords = ThemedAlert.resolvedChords(for: alert.buttons)
        XCTAssertEqual(
            chords[0].keyEquivalent,
            "\r",
            "Nothing else claims Return here, so the five sheets that came before this change "
                + "must be untouched by it."
        )
        XCTAssertNil(chords[0].shortcut)
    }

    func testAButtonAnswersReturnUnderEitherSpelling() {
        let plain = ThemedButton(title: "OK", target: nil, action: nil)
        plain.keyEquivalent = "\r"
        XCTAssertTrue(plain.answersReturn)

        let exact = ThemedButton(title: "OK", target: nil, action: nil)
        exact.shortcut = KeyboardShortcut(key: "\r", modifiers: [])
        XCTAssertTrue(
            exact.answersReturn,
            "The sheet focuses its default by asking this. Reading `keyEquivalent` alone put "
                + "the focus ring on Cancel the moment a sibling took ⌘Return."
        )

        let accelerated = ThemedButton(title: "Send", target: nil, action: nil)
        accelerated.shortcut = KeyboardShortcut(key: "\r", modifiers: .command)
        XCTAssertFalse(accelerated.answersReturn)
    }

    func testCommandReturnReachesSendAndNotTheDefault() {
        let request = ContextCommentAlert.makeRequest(for: Self.attachmentReference)
        let alert = TextPromptAlert.makeAlert(request, field: NSView())
        let chords = ThemedAlert.resolvedChords(for: alert.buttons)

        let hold = ThemedButton(title: alert.buttons[0].title, target: nil, action: nil)
        hold.keyEquivalent = chords[0].keyEquivalent
        hold.shortcut = chords[0].shortcut

        let send = ThemedButton(title: alert.buttons[1].title, target: nil, action: nil)
        send.keyEquivalent = chords[1].keyEquivalent
        send.shortcut = chords[1].shortcut

        // Hosted so `performKeyEquivalent`'s on-screen guard passes, and never ordered front.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        host.addSubview(hold)
        host.addSubview(send)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView?.addSubview(host)

        XCTAssertFalse(
            hold.performKeyEquivalent(with: Self.returnEvent(modifiers: .command)),
            "The half of this that is easy to get wrong: a plain `keyEquivalent` on the "
                + "default would swallow ⌘Return and Send would be unreachable."
        )
        XCTAssertTrue(send.performKeyEquivalent(with: Self.returnEvent(modifiers: .command)))
        XCTAssertTrue(hold.performKeyEquivalent(with: Self.returnEvent(modifiers: [])))
        XCTAssertFalse(send.performKeyEquivalent(with: Self.returnEvent(modifiers: [])))
    }

    // MARK: - Plain Prose For A Terminal

    func testACodeAnchorFoldsItsLineRangeBackOn() {
        let line = ConversationContextAttachment(
            kind: .reference,
            source: .code,
            title: "PromptView.swift:42",
            excerpt: "let x = 1",
            locator: "Sources/Threading/UI/Design/PromptView.swift",
            lineStart: 42,
            lineEnd: 42
        )
        XCTAssertEqual(
            line.plainAnchor,
            "Sources/Threading/UI/Design/PromptView.swift:42",
            "The transport carries the range in its own fields; a terminal has only the line."
        )

        let range = ConversationContextAttachment(
            kind: .reference,
            source: .code,
            title: "PromptView.swift",
            locator: "PromptView.swift",
            lineStart: 42,
            lineEnd: 49
        )
        XCTAssertEqual(range.plainAnchor, "PromptView.swift:42-49")
    }

    func testAMessageAnchorIsItsTitleRatherThanATimelineRow() {
        let message = ConversationContextAttachment(
            kind: .reference,
            source: .message,
            title: "Agent response",
            excerpt: "I renamed the file.",
            locator: "conversation-row:3"
        )
        XCTAssertEqual(
            message.plainAnchor,
            "Agent response",
            "`conversation-row:3` names a row in Threading's own timeline and nothing the agent "
                + "can open, so pasting it into a TUI would be pasting a private id."
        )
    }

    func testTerminalProseQuotesTheExcerptAndThenTheComment() {
        let comment = ConversationContextAttachment(
            kind: .comment,
            source: .code,
            title: "DiffView.swift:12",
            excerpt: "let color = NSColor.red",
            comment: "take this from the theme",
            locator: "DiffView.swift",
            lineStart: 12,
            lineEnd: 12
        )
        XCTAssertEqual(
            comment.plainText(),
            "DiffView.swift:12\n> let color = NSColor.red\n\ntake this from the theme"
        )
    }

    func testTerminalProseSkipsAnAnchorTheCallerAlreadyPasted() {
        let comment = Self.attachmentReference.commenting("the axis labels are too small")

        XCTAssertEqual(
            comment.plainText(omittingAnchor: true),
            "the axis labels are too small",
            "The attachments pane pastes the file's real path first and alone, because that is "
                + "the only form Claude and Codex read as an attached image. Repeating it as "
                + "prose would put the path in twice."
        )
        XCTAssertEqual(
            comment.plainText(),
            "docs/chart.png\n\nthe axis labels are too small",
            "The excerpt is the same relative path, so it is not quoted back a second time."
        )
    }

    func testAReferenceWithoutACommentIsStillWorthPasting() {
        XCTAssertEqual(Self.attachmentReference.plainText(), "docs/chart.png")
        XCTAssertEqual(Self.attachmentReference.plainText(omittingAnchor: true), "")
    }

    // MARK: - Routing

    func testASessionWithNoSurfaceIsHandedNothing() {
        let sessionID = SessionID()

        XCTAssertNil(SessionContextHandoff.destination(for: sessionID))
        XCTAssertFalse(
            SessionContextHandoff.canReceiveContext(for: sessionID),
            "A dormant session's pane must not draw a Chat button that does nothing — which is "
                + "exactly what the Attachments pane did for every terminal session."
        )
    }

    // MARK: - Fixtures

    private static let attachmentReference = ConversationContextAttachment(
        kind: .reference,
        source: .attachment,
        title: "chart.png",
        excerpt: "docs/chart.png",
        locator: "docs/chart.png"
    )

    private static let codeReference = ConversationContextAttachment(
        kind: .reference,
        source: .code,
        title: "SidebarArrangementMenuTests.swift:68-69",
        excerpt: "defer { reset() }\nXCTAssertEqual(order, expected)",
        locator: "Tests/ThreadingTests/SidebarArrangementMenuTests.swift",
        lineStart: 68,
        lineEnd: 69
    )

    private static var codePreview: CodeContextPreview? {
        let copy: [(Int, CodeContextPreview.Change, String)] = [
            (66, .context, "let defaults = UserDefaults.standard"),
            (67, .context, "defaults.set(order, forKey: key)"),
            (68, .removed, "defer { defaults.removeObject(forKey: key) }"),
            (69, .added, "XCTAssertEqual(result, expected)"),
            (70, .context, "}"),
        ]
        return CodeContextPreview.make(totalLineCount: copy.count, target: 2...3) { index in
            let line = copy[index]
            return CodeContextPreview.SourceLine(
                number: line.0,
                change: line.1,
                text: line.2
            )
        }
    }

    private static func returnEvent(modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )!
    }
}
