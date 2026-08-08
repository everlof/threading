import AppKit
import XCTest
@testable import Threading

/// The composer's prompt is the app's primary input. These tests drive it the way a user does —
/// focus it, then send real key events through the responder chain — because every layer between
/// the key and the string can fail without failing anything a layout or rendering test would
/// notice: a text view with no text network draws its box, takes focus, shows its focus ring, and
/// swallows every keystroke in silence.
@MainActor
final class PromptInputTests: XCTestCase {

    // MARK: - Setup

    /// What the Return key does is now a setting, so every test below that presses Return is
    /// asserting against a value the developer could have changed. The class pins it and puts
    /// the old one back.
    ///
    /// Restoring is not tidiness. `AppSettings` is a behavioural store and therefore writes
    /// `UserDefaults.standard`, which under a hosted test bundle is the developer's own
    /// preferences — a value left behind here would change the app they are running next, which
    /// is the exact shape of the bug `PreferenceStore` was written for.
    private var savedReturnKey: PromptReturnKey?

    override func setUp() {
        super.setUp()
        savedReturnKey = AppSettings.shared.promptReturnKey
        AppSettings.shared.promptReturnKey = .matchesComposer
    }

    override func tearDown() {
        if let savedReturnKey {
            AppSettings.shared.promptReturnKey = savedReturnKey
        }
        savedReturnKey = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Built, never shown: an unshown window still lays out and still takes a first responder,
    /// which is everything typing needs.
    private func makeWindow(hosting content: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func promptTextView(in prompt: PromptView) throws -> NSTextView {
        try XCTUnwrap(
            descendants(of: prompt).compactMap { $0 as? NSTextView }.first,
            "The prompt has to hold a text view"
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Every control a composer owns, whether or not it is currently drawn.
    ///
    /// An `NSStackView` with `detachesHiddenViews` takes a hidden arranged view **out of the
    /// view hierarchy**, so a plain subview walk cannot find a control that is merely switched
    /// off — the usage line before a reading has arrived, a chip a runtime does not offer.
    private func controls(in view: NSView) -> [NSView] {
        let subtree = [view] + descendants(of: view)
        return subtree + subtree
            .compactMap { $0 as? NSStackView }
            .flatMap(\.arrangedSubviews)
    }

    /// The two halves of every image fixture, named once so the generated files remain visually
    /// recognisable in rendered-state tests.
    private enum FixtureSwatch {
        static let leading = NSColor.systemTeal
        static let trailing = NSColor.systemOrange
    }

    private func makeImageFile(
        named name: String = "Threading prompt fixture.png",
        size: NSSize = NSSize(width: 24, height: 16)
    ) throws -> URL {
        let image = NSImage(size: size)
        image.lockFocus()
        let halfWidth = size.width / 2
        FixtureSwatch.leading.drawSwatch(
            in: NSRect(x: 0, y: 0, width: halfWidth, height: size.height)
        )
        FixtureSwatch.trailing.drawSwatch(
            in: NSRect(x: halfWidth, y: 0, width: halfWidth, height: size.height)
        )
        image.unlockFocus()

        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func captureAppFixture(_ window: NSWindow, named name: String) throws {
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        root.wantsLayer = true
        root.layer?.backgroundColor = Design.Surface.ground.cgColor

        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000, "\(name) rendered as an empty image")

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )
        try png.write(to: output.appendingPathComponent("\(name).png"))
    }

    private func performMenuItem(
        named title: String,
        from source: NSView,
        in root: NSView
    ) throws {
        XCTAssertTrue(source.accessibilityPerformShowMenu())
        root.layoutSubtreeIfNeeded()
        let menu = try XCTUnwrap(
            descendants(of: root).first { $0.accessibilityRole() == .menu },
            "The context menu did not join the window"
        )
        let row = try XCTUnwrap(
            descendants(of: menu).first {
                $0.accessibilityRole() == .menuItem
                    && $0.accessibilityTitle() == title
            },
            "Missing context-menu item \(title)"
        )
        XCTAssertTrue(row.accessibilityPerformPress())
    }

    /// A key event as the window server delivers one, routed to whoever holds the caret.
    private func type(_ text: String, in window: NSWindow) {
        for character in text {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: String(character),
                charactersIgnoringModifiers: String(character),
                isARepeat: false,
                keyCode: 0
            ) else {
                XCTFail("Could not build a key event")
                return
            }
            (window.firstResponder as? NSView)?.keyDown(with: event)
        }
    }

    /// Return as the window server sends it. `type` cannot: it carries no key code, and the
    /// prompt decides on the code rather than on the character.
    private func returnKey(
        holding modifiers: NSEvent.ModifierFlags = [],
        in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: PromptViewDefaults.returnKeyCode
            )
        )
    }

    /// Delivered to whoever holds the caret, which is where the window server sends a key a
    /// text view has already claimed.
    private func pressReturn(
        holding modifiers: NSEvent.ModifierFlags = [],
        in window: NSWindow
    ) {
        guard let event = try? returnKey(holding: modifiers, in: window) else {
            XCTFail("Could not build a key event")
            return
        }
        (window.firstResponder as? NSView)?.keyDown(with: event)
    }

    // MARK: - Tests

    /// A themed text view built without a container has to build its own network. Nothing else
    /// checks this, and nothing about the view's appearance reveals its absence.
    func testThemedTextViewsBuildTheirOwnTextNetwork() throws {
        let standalone = ThemedTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40), textContainer: nil)
        XCTAssertNotNil(standalone.textStorage)
        XCTAssertNotNil(standalone.layoutManager)
        XCTAssertNotNil(standalone.textContainer)

        let scrolling = ThemedTextView.scrolling()
        let document = scrolling.textView
        XCTAssertNotNil(document.textStorage)
        XCTAssertNotNil(document.layoutManager)
        XCTAssertNotNil(document.textContainer)
    }

    /// A dropped file has to reach the composer as a path.
    ///
    /// The registration assertion is the one that matters and the one nothing else made:
    /// `PromptAttachmentTests` proves the pasteboard is read correctly, and every one of those
    /// assertions passed while `registeredDraggedTypes` was empty and the pointer was being
    /// refused before it ever reached that code. Reading the types is not enough on its own
    /// either, so the drop is then performed and the field checked for the path.
    func testDroppedFilesBecomePathsInThePrompt() throws {
        let prompt = PromptView()
        let window = makeWindow(hosting: prompt)
        _ = window
        let textView = try promptTextView(in: prompt)

        let registered = textView.registeredDraggedTypes
        for type in [NSPasteboard.PasteboardType.fileURL, .png, .tiff] {
            XCTAssertTrue(
                registered.contains(type),
                "\(type.rawValue) has to reach the composer; registered types were \(registered)"
            )
            XCTAssertTrue(
                prompt.registeredDraggedTypes.contains(type),
                "\(type.rawValue) has to land on the thumbnail strip too"
            )
        }

        let path = "/tmp/threading-drop-fixture.png"
        let drag = DropFixture(writing: { $0.writeObjects([URL(fileURLWithPath: path) as NSURL]) })

        XCTAssertEqual(textView.draggingEntered(drag), .copy, "The drop has to be offered")
        XCTAssertTrue(textView.performDragOperation(drag))
        XCTAssertEqual(prompt.stringValue, path)
    }

    func testImagePreviewsAreOptInForAgentMessageComposers() throws {
        let imageURL = try makeImageFile(named: "plain prompt image.png")
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let prompt = PromptView()
        prompt.attachFiles(at: [imageURL.path])

        let quotedPath = "\"\(imageURL.path)\""
        XCTAssertEqual(prompt.stringValue, quotedPath)
        XCTAssertTrue(prompt.attachmentPaths.isEmpty)
        XCTAssertEqual(prompt.submissionValue, quotedPath)
    }

    /// A screenshot dragged from another app carries image data and no path of its own, so the
    /// composer has to write one out before it can name it.
    func testDraggedImageDataIsWrittenOutAndNamed() throws {
        let prompt = PromptView()
        prompt.showsImageAttachments = true
        let window = makeWindow(hosting: prompt)
        _ = window
        let textView = try promptTextView(in: prompt)

        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 4, height: 4))
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))

        let drag = DropFixture(writing: { $0.setData(png, forType: .png) })
        XCTAssertEqual(textView.draggingEntered(drag), .copy)
        XCTAssertTrue(textView.performDragOperation(drag))

        let written = try XCTUnwrap(prompt.attachmentPaths.first)
        XCTAssertEqual(prompt.stringValue, "", "A temporary path must not masquerade as prompt text")
        XCTAssertEqual(prompt.submissionValue, written)
        XCTAssertTrue(written.hasSuffix(".png"), "Got \(written)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written), "The agent has to be able to open it")
        try? FileManager.default.removeItem(atPath: written)
    }

    /// The whole rounded surface answers a drag it can take — the accent ring at focus width
    /// over a tinted well — and lets go the moment the drag leaves or ends. Both registered
    /// destinations are exercised: the box's own padding and the editor inside it light the
    /// same one surface, or the composer reads as two drop targets where there is one.
    func testADragTheComposerCanTakeLightsTheWholeSurfaceAndLetsGoWhenItLeaves() throws {
        let prompt = PromptView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        let window = makeWindow(hosting: prompt)
        _ = window
        let textView = try promptTextView(in: prompt)

        let drag = DropFixture(writing: {
            $0.writeObjects([URL(fileURLWithPath: "/tmp/threading-drop-affordance.png") as NSURL])
        })

        XCTAssertEqual(prompt.draggingEntered(drag), .copy)
        XCTAssertEqual(prompt.layer?.borderWidth, Design.Accessibility.focusRingWidth)
        XCTAssertEqual(prompt.layer?.borderColor, Design.Surface.accent.cgColor)
        XCTAssertEqual(prompt.layer?.backgroundColor, Design.Surface.fieldDropTarget.cgColor)

        prompt.reapplyRecordedSurfaceForTesting()
        XCTAssertEqual(
            prompt.layer?.backgroundColor,
            Design.Surface.fieldDropTarget.cgColor,
            "a theme refresh discarded the drop state's well"
        )

        prompt.draggingExited(drag)
        XCTAssertEqual(prompt.layer?.borderWidth, Design.Radius.border)
        XCTAssertEqual(prompt.layer?.borderColor, Design.Surface.border.cgColor)
        XCTAssertEqual(prompt.layer?.backgroundColor, Design.Surface.field.cgColor)

        // Over the editor the *text view* is the drag destination; the box must still light.
        XCTAssertEqual(textView.draggingEntered(drag), .copy)
        XCTAssertEqual(prompt.layer?.borderColor, Design.Surface.accent.cgColor)
        XCTAssertEqual(prompt.layer?.backgroundColor, Design.Surface.fieldDropTarget.cgColor)

        // A release or a cancel ends the drag without ever exiting; the accent well may not
        // outlive the gesture it was describing.
        textView.draggingEnded(drag)
        XCTAssertEqual(prompt.layer?.borderColor, Design.Surface.border.cgColor)
        XCTAssertEqual(prompt.layer?.backgroundColor, Design.Surface.field.cgColor)
    }

    /// A plain-text drag is one the *editor* will take and the attachment affordance must not
    /// claim: the composer inserts it as text, and an accent well under it would promise a
    /// drop the composer does not perform.
    func testAPlainTextDragDoesNotLightTheDropAffordance() throws {
        let prompt = PromptView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        let window = makeWindow(hosting: prompt)
        _ = window
        let textView = try promptTextView(in: prompt)

        let drag = DropFixture(writing: { $0.setString("not an attachment", forType: .string) })

        _ = textView.draggingEntered(drag)
        XCTAssertEqual(prompt.layer?.backgroundColor, Design.Surface.field.cgColor)
        XCTAssertEqual(prompt.layer?.borderColor, Design.Surface.border.cgColor)

        XCTAssertEqual(prompt.draggingEntered(drag), [])
        XCTAssertEqual(prompt.layer?.backgroundColor, Design.Surface.field.cgColor)
        XCTAssertEqual(prompt.layer?.borderColor, Design.Surface.border.cgColor)
    }

    func testImagesBecomeRemovablePreviewsAndOnlyJoinTheSubmittedValue() throws {
        let imageURL = try makeImageFile()
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let prompt = PromptView()
        prompt.showsImageAttachments = true
        prompt.stringValue = "Compare this layout"
        prompt.attachFiles(at: [imageURL.path])

        XCTAssertEqual(prompt.stringValue, "Compare this layout")
        XCTAssertEqual(prompt.attachmentPaths, [imageURL.path])
        XCTAssertEqual(
            prompt.submissionValue,
            "Compare this layout \"\(imageURL.path)\""
        )

        let thumbnail = try XCTUnwrap(
            descendants(of: prompt).first {
                $0.accessibilityRole() == .image
                    && $0.accessibilityLabel() == imageURL.lastPathComponent
            }
        )
        XCTAssertNotNil(thumbnail)

        let remove = try XCTUnwrap(
            descendants(of: prompt).first {
                $0.accessibilityRole() == .button
                    && $0.accessibilityTitle() == "Remove \(imageURL.lastPathComponent)"
            }
        )
        XCTAssertTrue(remove.accessibilityPerformPress())
        XCTAssertTrue(prompt.attachmentPaths.isEmpty)
        XCTAssertEqual(prompt.submissionValue, "Compare this layout")
    }

    func testImagePreviewRefusesAFileThatGrowsPastItsDecodePolicy() throws {
        let imageURL = try makeImageFile(named: "oversized-preview.png")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let handle = try FileHandle(forWritingTo: imageURL)
        try handle.truncate(atOffset: UInt64(
            BoundedImageDecodePolicy.composerPreview.maximumBytes + 1
        ))
        try handle.close()

        let prompt = PromptView()
        prompt.showsImageAttachments = true
        prompt.attachFiles(at: [imageURL.path])

        XCTAssertTrue(prompt.attachmentPaths.isEmpty)
        XCTAssertEqual(
            prompt.stringValue,
            imageURL.path,
            "an unsafe preview must remain a literal path the agent can still inspect"
        )
    }

    func testImagePreviewOpensTheInWindowMediaInspector() throws {
        let imageURL = try makeImageFile(
            named: "quick look.png",
            size: NSSize(width: 600, height: 400)
        )
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let prompt = PromptView()
        prompt.showsImageAttachments = true
        let window = makeWindow(hosting: prompt)
        defer { MediaInspectorPresenter.dismiss(in: window) }
        prompt.attachFiles(at: [imageURL.path])

        let thumbnail = try XCTUnwrap(
            descendants(of: prompt).first {
                $0.accessibilityRole() == .image
                    && $0.accessibilityLabel() == imageURL.lastPathComponent
            }
        )
        XCTAssertTrue(thumbnail.acceptsFirstResponder)
        XCTAssertEqual(
            thumbnail.accessibilityHelp(),
            "Press to inspect \(imageURL.lastPathComponent)"
        )
        XCTAssertTrue(thumbnail.accessibilityPerformPress())
        XCTAssertTrue(MediaInspectorPresenter.isPresenting(in: window))

        let inspector = try XCTUnwrap(
            descendants(of: try XCTUnwrap(window.contentView))
                .compactMap { $0 as? MediaInspectorView }
                .first
        )
        XCTAssertEqual(
            inspector.accessibilityLabel(),
            "Media inspector, \(imageURL.lastPathComponent)"
        )
        XCTAssertEqual(inspector.collectionThumbnailCount, 0)
    }

    func testImagePreviewContextMenuOffersStandardFileActions() throws {
        let imageURL = try makeImageFile(named: "context menu.png")
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let prompt = PromptView()
        prompt.showsImageAttachments = true
        let window = makeWindow(hosting: prompt)
        prompt.attachFiles(at: [imageURL.path])

        let thumbnail = try XCTUnwrap(
            descendants(of: prompt).first {
                $0.accessibilityRole() == .image
                    && $0.accessibilityLabel() == imageURL.lastPathComponent
            }
        )
        let root = try XCTUnwrap(window.contentView)
        XCTAssertTrue(thumbnail.accessibilityPerformShowMenu())
        root.layoutSubtreeIfNeeded()
        try captureAppFixture(window, named: "attachment-context-menu")
        XCTAssertEqual(
            descendants(of: root)
                .filter { $0.accessibilityRole() == .menuItem }
                .compactMap { $0.accessibilityTitle() },
            [
                "Inspect",
                "Open in Default App",
                "Reveal in Finder",
                "Copy Image",
                "Copy File Name",
                "Copy File Path",
                "Open in System Quick Look",
                "Remove Attachment"
            ]
        )

        try performMenuItem(named: "Copy Image", from: thumbnail, in: root)
        XCTAssertNotNil(NSImage(pasteboard: .general))

        try performMenuItem(named: "Copy File Name", from: thumbnail, in: root)
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            imageURL.lastPathComponent
        )

        try performMenuItem(named: "Copy File Path", from: thumbnail, in: root)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), imageURL.path)
        XCTAssertEqual(NSPasteboard.general.availableType(from: [.fileURL]), .fileURL)

        try performMenuItem(named: "Remove Attachment", from: thumbnail, in: root)
        XCTAssertTrue(prompt.attachmentPaths.isEmpty)
    }

    func testChatImagePreviewCanRequestAnAttachmentComment() throws {
        let imageURL = try makeImageFile(named: "comment target.png")
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let prompt = PromptView()
        prompt.showsImageAttachments = true
        var commentedPaths: [String] = []
        prompt.onRequestImageComment = { commentedPaths.append($0) }
        let window = makeWindow(hosting: prompt)
        prompt.attachFiles(at: [imageURL.path])

        let thumbnail = try XCTUnwrap(
            descendants(of: prompt).first {
                $0.accessibilityRole() == .image
                    && $0.accessibilityLabel() == imageURL.lastPathComponent
            }
        )
        try performMenuItem(
            named: "Comment…",
            from: thumbnail,
            in: try XCTUnwrap(window.contentView)
        )

        XCTAssertEqual(commentedPaths, [imageURL.path])
    }

    func testAnImageAloneCanBeSubmitted() throws {
        let imageURL = try makeImageFile(named: "image only.png")
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let prompt = PromptView()
        prompt.showsImageAttachments = true
        prompt.attachFiles(at: [imageURL.path])
        var submitted: String?
        prompt.onSubmit = { submitted = $0 }

        let submit = try XCTUnwrap(
            descendants(of: prompt).compactMap { $0 as? ThemedButton }.first
        )
        submit.performClick()

        XCTAssertEqual(submitted, "\"\(imageURL.path)\"")
    }

    /// The first-message screen and the only follow-up screen Threading owns both host the same
    /// prompt boundary, so previews cannot quietly land on one while the other keeps paths.
    func testFirstMessageAndNativeReplyComposersBothShowImagePreviews() throws {
        let imageURL = try makeImageFile(named: "both composers.png")
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let startComposer = SessionComposerViewController(customizationLookup: { _ in .empty })
        _ = startComposer.view

        let session = AgentSession(kind: .codex, title: "Attachments")
        let project = Project(
            name: "Attachments",
            folderURL: URL(fileURLWithPath: "/tmp/Attachments")
        )
        let replyComposer = requireConversationViewController(
            agentSession: session,
            project: project,
            customizationLookup: { _ in .empty }
        )
        _ = replyComposer.view

        let prompts = try [
            XCTUnwrap(
                descendants(of: startComposer.view).compactMap { $0 as? PromptView }.first
            ),
            XCTUnwrap(
                descendants(of: replyComposer.view).compactMap { $0 as? PromptView }.first
            )
        ]

        for prompt in prompts {
            prompt.attachFiles(at: [imageURL.path])
            XCTAssertEqual(prompt.stringValue, "")
            XCTAssertEqual(prompt.attachmentPaths, [imageURL.path])
            XCTAssertTrue(
                descendants(of: prompt).contains {
                    $0.accessibilityRole() == .image
                        && $0.accessibilityLabel() == imageURL.lastPathComponent
                }
            )
        }
    }

    func testPromptAcceptsTypedCharacters() throws {
        let prompt = PromptView()
        let window = makeWindow(hosting: prompt)
        let textView = try promptTextView(in: prompt)

        XCTAssertTrue(window.makeFirstResponder(textView), "The prompt has to take focus")
        XCTAssertTrue(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)

        type("hej", in: window)

        XCTAssertEqual(prompt.stringValue, "hej")
    }

    /// NSTextView is editable while leaving undo disabled by default. The Edit menu still routes
    /// ⌘Z to its undo manager in that state, but typing registered no operation there, so the
    /// command appeared to do nothing in every prompt draft. Exercise the text system rather than
    /// assigning `stringValue`: only user edits are supposed to enter its undo history.
    func testPromptTypingCanBeUndoneAndRedone() throws {
        let prompt = PromptView()
        let window = makeWindow(hosting: prompt)
        let textView = try promptTextView(in: prompt)
        var observedDrafts: [String] = []
        prompt.onChange = { observedDrafts.append($0) }

        XCTAssertTrue(window.makeFirstResponder(textView), "The prompt has to take focus")
        type("draft", in: window)

        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(textView.allowsUndo)
        XCTAssertTrue(undoManager.canUndo, "Typing has to register the operation that ⌘Z invokes")

        undoManager.undo()

        XCTAssertEqual(prompt.stringValue, "")
        XCTAssertEqual(observedDrafts.last, "", "Undo has to persist the restored draft too")
        XCTAssertTrue(undoManager.canRedo)

        undoManager.redo()

        XCTAssertEqual(prompt.stringValue, "draft")
        XCTAssertEqual(observedDrafts.last, "draft", "Redo has to persist the restored draft too")
    }

    /// The prompt sizes itself to its text through the layout manager, so a missing network
    /// also froze the box at one line no matter how much was typed into it.
    func testPromptGrowsWithItsText() throws {
        let prompt = PromptView()
        let window = makeWindow(hosting: prompt)
        _ = window

        let single = prompt.fittingSize.height
        prompt.stringValue = Array(repeating: "en rad text", count: 12).joined(separator: "\n")
        prompt.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(prompt.fittingSize.height, single)
    }

    /// Growing to `inputMaxHeight` is only half of it: everything past that cap has to be
    /// reachable, and it was not. `isVerticallyResizable` is capped by `maxSize`, which defaults
    /// to the initializer's frame and then to the clip's size — so the document view stopped at
    /// exactly the visible height while text kept laying out below it. `documentRect` equalled
    /// the clip, which is a scroll view with no range: the wheel was pinned at zero, no scroller
    /// appeared, and typing could not pull the caret back into view. The prompt kept accepting
    /// text the person writing it could no longer read.
    ///
    /// Asserted against the clip view's own answers rather than ours, because every one of those
    /// failures is AppKit declining to scroll a document it believes already fits.
    func testTextPastTheGrowthCapCanBeScrolledBackTo() throws {
        let prompt = PromptView()
        let window = makeWindow(hosting: prompt)
        let textView = try promptTextView(in: prompt)
        let clip = try XCTUnwrap(textView.enclosingScrollView?.contentView)

        prompt.stringValue = Array(repeating: "en rad text", count: 40).joined(separator: "\n")
        prompt.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            prompt.frame.height,
            Design.Size.inputMaxHeight,
            accuracy: 1,
            "The box has to stop at its cap, or nothing below is being scrolled to"
        )
        XCTAssertGreaterThan(
            clip.documentRect.height,
            clip.bounds.height,
            "The text has to be taller than the box for there to be anything to scroll"
        )
        XCTAssertTrue(
            try XCTUnwrap(textView.enclosingScrollView).hasVerticalScroller,
            "Past the cap the scroller takes over from the growth"
        )

        // The wheel's own path. AppKit constrains every scroll — gesture, momentum and
        // `scrollRangeToVisible` alike — through this method, so it answers "can the user
        // actually get there" without synthesising a trackpad.
        var proposed = clip.bounds
        proposed.origin.y = (clip.documentRect.height - clip.bounds.height) / 2
        XCTAssertEqual(
            clip.constrainBoundsRect(proposed).origin.y,
            proposed.origin.y,
            accuracy: 1,
            "A scroll into the overflow must not be constrained back to the top"
        )

        // And what the person typing experiences: the caret stays visible as the text passes
        // the bottom edge.
        XCTAssertTrue(window.makeFirstResponder(textView), "The prompt has to take focus")
        textView.setSelectedRange(
            NSRange(location: (textView.string as NSString).length, length: 0)
        )
        type("x", in: window)
        prompt.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            clip.documentVisibleRect.origin.y,
            0,
            "Typing at the end has to scroll the caret into view rather than under the box"
        )
    }

    func testComposerPromptAcceptsTypedCharacters() throws {
        let composer = SessionComposerViewController(customizationLookup: { _ in .empty })
        _ = composer.view
        composer.updatePromptCustomization(for: ProjectID())

        let window = makeWindow(hosting: composer.view)
        let prompt = try XCTUnwrap(
            descendants(of: composer.view).compactMap { $0 as? PromptView }.first
        )
        let textView = try promptTextView(in: prompt)

        XCTAssertTrue(window.makeFirstResponder(textView), "The composer's prompt has to focus")

        type("hej", in: window)

        XCTAssertEqual(prompt.stringValue, "hej")
    }

    /// Arriving at the composer *is* the request to type: ⌘N and selecting a project both land
    /// here, and the pane focuses everything else it puts on screen — a terminal, a native
    /// conversation's reply box. The caret goes after any restored draft, because the position
    /// `stringValue` leaves it in so the draft is read from its start is the one position where
    /// the next keystroke lands in front of the user's own sentence.
    func testArrivingAtTheComposerFocusesThePromptAfterAnyRestoredDraft() throws {
        let composer = SessionComposerViewController(customizationLookup: { _ in .empty })
        _ = composer.view
        composer.updatePromptCustomization(for: ProjectID())

        let window = makeWindow(hosting: composer.view)
        let prompt = try XCTUnwrap(
            descendants(of: composer.view).compactMap { $0 as? PromptView }.first
        )
        let textView = try promptTextView(in: prompt)

        prompt.stringValue = "fixa"
        XCTAssertEqual(
            textView.selectedRange().location,
            0,
            "an unfocused draft is still read from its beginning"
        )

        composer.focusPrompt()

        XCTAssertTrue(window.firstResponder === textView, "the composer has to arrive focused")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 0))

        type(" testet", in: window)

        XCTAssertEqual(prompt.stringValue, "fixa testet", "typing has to continue the draft")
    }

    /// Removing an attachment hands the editor back, and that is not the user asking for the
    /// caret: it stays mid-sentence rather than jumping to the end the way arriving at a
    /// composer does.
    func testRemovingAnAttachmentLeavesTheCaretWhereItWas() throws {
        let imageURL = try makeImageFile(named: "caret.png")
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let prompt = PromptView()
        prompt.showsImageAttachments = true
        let window = makeWindow(hosting: prompt)
        let textView = try promptTextView(in: prompt)

        prompt.stringValue = "fixa testet"
        prompt.attachFiles(at: [imageURL.path])
        textView.setSelectedRange(NSRange(location: 4, length: 0))

        let remove = try XCTUnwrap(
            descendants(of: prompt).first {
                $0.accessibilityRole() == .button
                    && $0.accessibilityTitle() == "Remove \(imageURL.lastPathComponent)"
            },
            "an attached image has to carry its own remove control"
        )
        XCTAssertTrue(remove.accessibilityPerformPress())

        XCTAssertEqual(prompt.attachmentPaths, [])
        XCTAssertTrue(window.firstResponder === textView, "the editor has to come back focused")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 0))
    }

    /// The prompt lives inside a container that detaches and re-attaches it whenever the
    /// component customization is resolved. That happens for reasons the user cannot see — a
    /// project being selected, an extension publishing — so it must not take the caret with it.
    func testCustomizationRefreshKeepsThePromptFocusedAndTypeable() throws {
        let composer = SessionComposerViewController(customizationLookup: { _ in .empty })
        _ = composer.view
        let projectID = ProjectID()
        composer.updatePromptCustomization(for: projectID)

        let window = makeWindow(hosting: composer.view)
        let prompt = try XCTUnwrap(
            descendants(of: composer.view).compactMap { $0 as? PromptView }.first
        )
        let textView = try promptTextView(in: prompt)
        XCTAssertTrue(window.makeFirstResponder(textView))

        // What `show(projectID:)` does every time the composer is pointed at a project.
        composer.updatePromptCustomization(for: projectID)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            window.firstResponder,
            textView,
            "A customization refresh must not silently drop the caret"
        )

        type("hej", in: window)
        XCTAssertEqual(prompt.stringValue, "hej")
    }

    // MARK: - Submitting

    /// A reply box is a message: Return sends it, Shift-Return breaks the line, and the glyph
    /// in the corner is the only thing that has to say so.
    func testTheInlinePlacementSendsOnReturnAndKeepsShiftReturnForTheLine() throws {
        let prompt = PromptView()
        let window = makeWindow(hosting: prompt)
        let textView = try promptTextView(in: prompt)

        var submitted: [String] = []
        prompt.onSubmit = { submitted.append($0) }
        XCTAssertTrue(window.makeFirstResponder(textView))

        type("one", in: window)
        pressReturn(holding: .shift, in: window)
        type("two", in: window)
        XCTAssertEqual(prompt.stringValue, "one\ntwo")
        XCTAssertTrue(submitted.isEmpty, "Shift-Return sent the prompt")

        pressReturn(in: window)
        XCTAssertEqual(submitted, ["one\ntwo"])

        XCTAssertFalse(try inlineSubmitButton(in: prompt).isHidden)
    }

    /// A composer's prompt is a *brief*, so Return is a line break there and ⌘Return is the
    /// send — the chord being the one thing the button outside can name and the glyph never
    /// could.
    func testAnOutsidePlacementGivesReturnBackToTheTextAndSendsOnCommandReturn() throws {
        let prompt = PromptView()
        prompt.submitPlacement = .outside
        let window = makeWindow(hosting: prompt)
        let textView = try promptTextView(in: prompt)

        var submitted: [String] = []
        prompt.onSubmit = { submitted.append($0) }
        XCTAssertTrue(window.makeFirstResponder(textView))

        type("one", in: window)
        pressReturn(in: window)
        type("two", in: window)
        XCTAssertEqual(prompt.stringValue, "one\ntwo", "Return has to reach the editor")
        XCTAssertTrue(submitted.isEmpty, "Return sent a prompt that was still being written")

        pressReturn(holding: .command, in: window)
        XCTAssertEqual(submitted, ["one\ntwo"])

        XCTAssertTrue(
            try inlineSubmitButton(in: prompt).isHidden,
            "the glyph and the button outside must not both offer the send"
        )
    }

    // MARK: - The Control Row

    /// The reply composer's shape: the box holds the text, the row along its bottom holds what
    /// the text will be sent with, and the send closes that row.
    ///
    /// Everything here was a strip of chips floating on the pane *above* the box, which is what
    /// made it read as neither part of the conversation nor part of the input — and, because the
    /// strip sized itself to its content, left the chips clustered against the leading edge with
    /// the rest of the pane's width empty beside them.
    func testTheFooterPlacementPutsTheOwnersControlsAndTheSendInsideTheBox() throws {
        let prompt = PromptView()
        prompt.submitPlacement = .footer

        let model = ChipView()
        model.configure(symbolName: "cpu", title: "Opus · 1M")
        let speed = ChipView()
        speed.configure(symbolName: "bolt", title: "Standard")
        let context = NSTextField(labelWithString: "38% context")

        prompt.setFooterControls(leading: [model, speed], trailing: [context])
        let window = makeWindow(hosting: prompt)
        _ = window
        prompt.layoutSubtreeIfNeeded()

        let send = try inlineSubmitButton(in: prompt)
        XCTAssertFalse(send.isHidden, "The footer placement keeps the send in the box")

        for control in [model, speed, context] as [NSView] {
            XCTAssertTrue(
                control.isDescendant(of: prompt),
                // Qualified: this class has its own `type(_:in:)` helper, which shadows the
                // global `type(of:)`.
                "\(Swift.type(of: control)) stayed outside the box it belongs to"
            )
            let frame = control.convert(control.bounds, to: prompt)
            XCTAssertTrue(
                prompt.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                "\(Swift.type(of: control)) was placed outside the box's own bounds"
            )
        }

        // The row reads leading-group, gap, trailing-group, send — so the meter and the send
        // reach the box's trailing edge instead of trailing the chips.
        let inBox = { (view: NSView) in view.convert(view.bounds, to: prompt) }
        XCTAssertLessThan(inBox(model).maxX, inBox(speed).minX)
        XCTAssertLessThan(inBox(speed).maxX, inBox(context).minX)
        XCTAssertLessThan(inBox(context).maxX, inBox(send).minX)
        XCTAssertGreaterThan(
            inBox(context).minX - inBox(speed).maxX,
            inBox(speed).minX - inBox(model).maxX,
            "Nothing pushed the trailing group to the trailing edge"
        )
        XCTAssertLessThan(
            prompt.bounds.maxX - inBox(send).maxX,
            Design.Spacing.large,
            "The send has to finish the row rather than float in from its end"
        )

        // Under the text, not beside it: the row is a second line of the box. The box is
        // unflipped, so "under" is the smaller y.
        let editor = try XCTUnwrap(promptTextView(in: prompt).enclosingScrollView)
        XCTAssertLessThanOrEqual(
            inBox(model).maxY,
            inBox(editor).minY + 1,
            "The control row overlapped the text it belongs to"
        )
    }

    /// The row belongs to the *controls*, not to the send.
    ///
    /// A brief hands its send to a button under the box — Return is a paragraph break there — and
    /// still carries what the session will be run with on the box's own row. `applySubmitPlacement`
    /// read "the send is not in this box" as "this box has no row", so `setFooterControls` handed
    /// five controls to a row that was hidden the moment the placement was applied, and the
    /// session composer shipped as an empty box with a project and an account floating over it.
    ///
    /// Nothing failed. Ancestry, ordering and frames — everything the row was already asserted
    /// on — hold exactly as well for a row nobody can see, which is why this test asks the one
    /// question those could not: is it *drawn*.
    func testControlsGivenToABoxWhoseSendIsOutsideAreStillDrawnOnItsRow() throws {
        let prompt = PromptView()
        prompt.submitPlacement = .outside
        _ = makeWindow(hosting: prompt)
        prompt.layoutSubtreeIfNeeded()
        let bare = prompt.frame.height

        let model = ChipView()
        model.configure(symbolName: "cpu", title: "Opus · 1M")
        let usage = NSTextField(labelWithString: "5h 43% · 7d 73%")

        prompt.setFooterControls(leading: [model], trailing: [usage])
        prompt.layoutSubtreeIfNeeded()

        for control in [model, usage] as [NSView] {
            // Qualified: this class has its own `type(_:in:)` helper, which shadows `type(of:)`.
            let name = "\(Swift.type(of: control))"
            XCTAssertFalse(
                control.isHiddenOrHasHiddenAncestor,
                "\(name) was handed to the box and never drawn"
            )
            // A stack that detaches hidden views takes the whole row out of the hierarchy, so a
            // row switched off costs its contents their ancestry as well as their pixels.
            XCTAssertTrue(control.isDescendant(of: prompt), "\(name) left the box's own hierarchy")

            let frame = control.convert(control.bounds, to: prompt)
            XCTAssertGreaterThan(frame.width, 0, "\(name) was laid out with nothing to draw")
            XCTAssertTrue(
                prompt.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                "\(name) was placed outside the box's own bounds"
            )
        }

        XCTAssertTrue(
            try inlineSubmitButton(in: prompt).isHidden,
            "the row arrived and brought a second send into the box with it"
        )
        XCTAssertGreaterThan(
            prompt.frame.height,
            bare,
            "the row has to be visible in the box's height rather than laid over its text"
        )
    }

    /// A box with a control row stands open at two lines of prose plus its chrome, and a box
    /// without one still opens at exactly one input.
    ///
    /// The row remains the box's own chrome and still comes *out of* the resting height rather
    /// than adding to it — the arithmetic in `updateHeight` is unchanged. What changed is the
    /// number it comes out of: `Design.Size.inputHeight` centres a single line and says nothing
    /// about a panel with a row under its text, and using it left a text floor of eight points,
    /// below one line. `PromptViewDefaults.restingLines` states the answer instead.
    ///
    /// The upper bound is the point of the second half: three lines would be the hundred-point
    /// box the original arrangement was built to avoid.
    func testTheControlRowFitsInsideTheBoxsRestingHeightRatherThanOnTopOfIt() throws {
        let plain = PromptView()
        let withRow = PromptView()
        withRow.submitPlacement = .footer
        withRow.setFooterControls(leading: [ChipView()], trailing: [])

        for prompt in [plain, withRow] {
            _ = makeWindow(hosting: prompt)
            prompt.layoutSubtreeIfNeeded()
        }

        XCTAssertEqual(
            plain.frame.height,
            Design.Size.inputHeight,
            accuracy: 1,
            "A composer with no control row still opens at exactly one input"
        )
        XCTAssertGreaterThan(
            withRow.frame.height,
            plain.frame.height,
            "The row has to be visible in the box's height"
        )

        let line = Design.FontRole.body.resolved(in: .chrome).boundingRectForFont.height
        XCTAssertEqual(
            withRow.frame.height,
            (line * PromptViewDefaults.restingLines).rounded()
                + PromptViewDefaults.footerVerticalInset * 2
                + Design.Size.chipHeight
                + Design.Spacing.medium,
            accuracy: 1,
            "The resting reply box is two lines of prose over its control row"
        )
        XCTAssertLessThan(
            withRow.frame.height,
            100,
            "The resting box grew back into the paragraph-tall composer this rule exists to avoid"
        )

        // And the cap still means the same thing: the *box* stops at `inputMaxHeight`, so the
        // row cannot push a full composer past what the pane budgeted for it.
        withRow.stringValue = Array(repeating: "en rad text", count: 40).joined(separator: "\n")
        withRow.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            withRow.frame.height,
            Design.Size.inputMaxHeight,
            accuracy: 1,
            "A box with a control row grew past the cap the pane budgeted"
        )
    }

    /// The send did not move surfaces, only rows — so Return still sends, exactly as it does
    /// with the glyph in the corner.
    func testTheFooterPlacementKeepsReturnOnTheSend() throws {
        let prompt = PromptView()
        prompt.submitPlacement = .footer
        prompt.setFooterControls(leading: [ChipView()], trailing: [])
        let window = makeWindow(hosting: prompt)
        let textView = try promptTextView(in: prompt)

        var submitted: [String] = []
        prompt.onSubmit = { submitted.append($0) }
        XCTAssertTrue(window.makeFirstResponder(textView))

        type("one", in: window)
        pressReturn(holding: .shift, in: window)
        type("two", in: window)
        XCTAssertTrue(submitted.isEmpty, "Shift-Return sent the reply")

        pressReturn(in: window)
        XCTAssertEqual(submitted, ["one\ntwo"])
    }

    /// The setting overrides the surface's own answer, in the direction people ask for it most:
    /// a brief that sends on Return.
    func testTheSettingCanMakeReturnSendTheBriefAsWell() throws {
        AppSettings.shared.promptReturnKey = .sends

        let prompt = PromptView()
        prompt.submitPlacement = .outside
        let window = makeWindow(hosting: prompt)
        let textView = try promptTextView(in: prompt)

        var submitted: [String] = []
        prompt.onSubmit = { submitted.append($0) }
        XCTAssertTrue(window.makeFirstResponder(textView))

        type("one", in: window)
        pressReturn(in: window)
        XCTAssertEqual(submitted, ["one"], "the setting did not reach the composer")

        // Sending does not empty the box — the owner does that once the prompt is away — so the
        // next stretch starts from a cleared field rather than from the sent one.
        prompt.stringValue = ""

        // The escape hatch has to survive the setting, or the box cannot hold two lines at all.
        type("two", in: window)
        pressReturn(holding: .shift, in: window)
        type("three", in: window)
        XCTAssertEqual(prompt.stringValue, "two\nthree")
        XCTAssertEqual(submitted, ["one"], "Shift-Return sent a prompt that was still being written")
    }

    /// And in the other direction: a reply box that stops sending on Return, for the user who
    /// wants one answer everywhere rather than one per surface.
    func testTheSettingCanGiveReturnBackToTheTextInAReplyBox() throws {
        AppSettings.shared.promptReturnKey = .startsNewLine

        let prompt = PromptView()
        let window = makeWindow(hosting: prompt)
        let textView = try promptTextView(in: prompt)

        var submitted: [String] = []
        prompt.onSubmit = { submitted.append($0) }
        XCTAssertTrue(window.makeFirstResponder(textView))

        type("one", in: window)
        pressReturn(in: window)
        type("two", in: window)
        XCTAssertEqual(prompt.stringValue, "one\ntwo")
        XCTAssertTrue(submitted.isEmpty, "Return sent a reply the setting said to keep editing")

        pressReturn(holding: .command, in: window)
        XCTAssertEqual(submitted, ["one\ntwo"], "⌘Return has to send under every setting")

        XCTAssertFalse(
            try inlineSubmitButton(in: prompt).isHidden,
            "the setting decides the key, not where the send control lives"
        )
    }

    /// The glyph names the key that actually sends it.
    ///
    /// The tooltip is the only name a glyph has — it is the accessible name too — so a box that
    /// sends on Return while its tooltip says ⌘Return teaches a chord and then fires on a key it
    /// never mentioned. That is how a Return-send goes unnoticed until it launches something.
    func testTheSendGlyphNamesWhicheverKeySendsThisBox() throws {
        let reply = PromptView()
        _ = makeWindow(hosting: reply)
        XCTAssertEqual(try inlineSubmitButton(in: reply).toolTip, "Send · Return")
        XCTAssertEqual(
            try inlineSubmitButton(in: reply).accessibilityLabel(),
            "Send · Return",
            "an unnamed send is unusable"
        )

        AppSettings.shared.promptReturnKey = .startsNewLine
        // Any edit re-asks the setting; the tooltip is not a value cached at setup.
        reply.stringValue = "hej"
        XCTAssertEqual(try inlineSubmitButton(in: reply).toolTip, "Send · ⌘Return")

        AppSettings.shared.promptReturnKey = .matchesComposer
        let brief = PromptView()
        brief.submitPlacement = .outside
        brief.stringValue = "hej"
        _ = makeWindow(hosting: brief)
        XCTAssertEqual(
            try inlineSubmitButton(in: brief).toolTip,
            "Send · ⌘Return",
            "a box Return does not send has to name the chord that does"
        )

        // A reason to be disabled still wins the tooltip: it is the more useful sentence, and
        // naming a key that will not fire is worse than naming none.
        brief.submissionDisabledReason = "Choose a project first"
        XCTAssertEqual(try inlineSubmitButton(in: brief).toolTip, "Choose a project first")
        brief.submissionDisabledReason = nil
        XCTAssertEqual(try inlineSubmitButton(in: brief).toolTip, "Send · ⌘Return")
    }

    /// The Settings window is open *beside* the composer while this is changed, so the answer
    /// has to be read at the keystroke. A value cached when the pane was built would leave the
    /// one composer the user is looking at as the only one still behaving the old way.
    func testChangingTheSettingReachesAComposerThatIsAlreadyOnScreen() throws {
        let prompt = PromptView()
        let window = makeWindow(hosting: prompt)
        let textView = try promptTextView(in: prompt)

        var submitted: [String] = []
        prompt.onSubmit = { submitted.append($0) }
        XCTAssertTrue(window.makeFirstResponder(textView))

        type("one", in: window)
        pressReturn(in: window)
        XCTAssertEqual(submitted, ["one"], "a reply box sends on Return by default")
        prompt.stringValue = ""

        AppSettings.shared.promptReturnKey = .startsNewLine

        type("two", in: window)
        pressReturn(in: window)
        type("three", in: window)
        XCTAssertEqual(
            prompt.stringValue,
            "two\nthree",
            "the composer kept the meaning it was built with"
        )
        XCTAssertEqual(submitted, ["one"])
    }

    /// Return belongs to the input method for as long as one has marked text. With a Japanese,
    /// Chinese or Korean IME it is how a conversion candidate is accepted, and sending on it
    /// posts a half-written prompt missing the very characters still uncommitted — marked text
    /// is not yet in `string`. Filed against Claude Code, Copilot Chat, Cursor and JetBrains'
    /// AI assistant; this is the one composer here it must not happen in.
    func testAnInputMethodKeepsReturnWhileItIsStillComposing() throws {
        let prompt = PromptView()
        let window = makeWindow(hosting: prompt)
        let textView = try promptTextView(in: prompt)

        var submitted: [String] = []
        prompt.onSubmit = { submitted.append($0) }
        XCTAssertTrue(window.makeFirstResponder(textView))

        // Each press is given its own composition: the first Return is *accepted* by the input
        // method, which is the whole point — it commits the candidate and leaves nothing marked,
        // so a second press would be an ordinary Return rather than a second test of the guard.
        for modifiers in [NSEvent.ModifierFlags(), .command] {
            textView.setMarkedText(
                "にほn",
                selectedRange: NSRange(location: 3, length: 0),
                replacementRange: NSRange(location: 0, length: 0)
            )
            XCTAssertTrue(textView.hasMarkedText(), "the fixture has to reach the composing state")

            pressReturn(holding: modifiers, in: window)
            XCTAssertTrue(
                submitted.isEmpty,
                "Return accepted a conversion and sent the half-written prompt with it"
            )
        }
    }

    /// ⌘Return belongs to the field, not to whatever button happens to be beside it: the same
    /// prompt is used with no button at all.
    func testCommandReturnSendsWhicheverPlacementTheBoxHas() throws {
        let prompt = PromptView()
        let window = makeWindow(hosting: prompt)
        let textView = try promptTextView(in: prompt)

        var submitted: [String] = []
        prompt.onSubmit = { submitted.append($0) }
        XCTAssertTrue(window.makeFirstResponder(textView))

        type("hej", in: window)
        pressReturn(holding: .command, in: window)

        XCTAssertEqual(submitted, ["hej"])
    }

    /// The brief keeps Return for its text and sends from the button under the box.
    ///
    /// This shipped the other way round for one commit: the send moved onto the box's control
    /// row, `.footer` reads "the send is in the box" as "Return sends", and a brief started
    /// launching on the break that was meant to be its second line — while the glyph's tooltip
    /// went on promising ⌘Return. A send that fires on a key its own label does not name is the
    /// defect; the button outside can write the chord on its face.
    func testTheBriefKeepsReturnAndSendsFromTheButtonUnderTheBox() throws {
        let composer = SessionComposerViewController(customizationLookup: { _ in .empty })
        _ = composer.view
        composer.updatePromptCustomization(for: ProjectID())

        let window = makeWindow(hosting: composer.view)
        let prompt = try XCTUnwrap(
            descendants(of: composer.view).compactMap { $0 as? PromptView }.first
        )
        let textView = try promptTextView(in: prompt)

        XCTAssertTrue(
            try inlineSubmitButton(in: prompt).isHidden,
            "the glyph and the button under the box must not both offer the send"
        )
        let start = try XCTUnwrap(
            descendants(of: composer.view).first {
                $0.accessibilityIdentifier() == "composer.session-start.submit"
            } as? ThemedButton,
            "the brief's send has to be a button that can name its chord"
        )
        XCTAssertEqual(start.title, "Start session")
        XCTAssertEqual(start.shortcut, ComposerDefaults.startShortcut)

        var submitted: [String] = []
        prompt.onSubmit = { submitted.append($0) }
        XCTAssertTrue(window.makeFirstResponder(textView))

        type("a task", in: window)
        pressReturn(in: window)
        type("and its context", in: window)
        XCTAssertEqual(prompt.stringValue, "a task\nand its context")
        XCTAssertTrue(submitted.isEmpty, "Return launched a session that was still being written")

        // The chord belongs to the *field* as well as to the button: it is handled in `keyDown`
        // and reaches nothing else on the way, so it holds wherever the caret is.
        pressReturn(holding: .command, in: window)
        XCTAssertEqual(submitted, ["a task\nand its context"], "⌘Return did not send the brief")

        start.performClick()
        XCTAssertEqual(submitted.count, 2, "the button and the chord have to send the same thing")
        XCTAssertEqual(submitted.last, "a task\nand its context")
    }

    /// The send being outside costs the box nothing else: what the session will be *run with*
    /// stays on the box's own control row, which is where the reply composer has it.
    func testTheBriefKeepsItsControlRowWithTheSendOutside() throws {
        let composer = SessionComposerViewController(customizationLookup: { _ in .empty })
        _ = composer.view
        composer.updatePromptCustomization(for: ProjectID())

        _ = makeWindow(hosting: composer.view)
        composer.view.layoutSubtreeIfNeeded()

        let prompt = try XCTUnwrap(
            descendants(of: composer.view).compactMap { $0 as? PromptView }.first
        )
        for identifier in [
            "composer.session-start.model",
            "composer.session-start.mode",
            "composer.session-start.effort",
            "composer.session-start.surface"
        ] {
            let chip = try XCTUnwrap(
                controls(in: composer.view).first {
                    $0.accessibilityIdentifier() == identifier
                },
                "\(identifier) is not in the composer at all"
            )
            XCTAssertTrue(chip.isDescendant(of: prompt), "\(identifier) left the box it belongs in")
        }
    }

    /// The other half of the setting: a user who wants one answer everywhere says so once on the
    /// Keyboard page, and Return sends the brief too.
    func testTheSettingCanMakeReturnSendTheBriefInTheComposer() throws {
        AppSettings.shared.promptReturnKey = .sends

        let composer = SessionComposerViewController(customizationLookup: { _ in .empty })
        _ = composer.view
        composer.updatePromptCustomization(for: ProjectID())

        let window = makeWindow(hosting: composer.view)
        let prompt = try XCTUnwrap(
            descendants(of: composer.view).compactMap { $0 as? PromptView }.first
        )
        let textView = try promptTextView(in: prompt)

        var submitted: [String] = []
        prompt.onSubmit = { submitted.append($0) }
        XCTAssertTrue(window.makeFirstResponder(textView))

        type("a task", in: window)
        pressReturn(in: window)
        XCTAssertEqual(submitted, ["a task"], "the setting did not reach the brief")

        prompt.stringValue = ""

        // And the escape hatch survives it, or a brief cannot hold two lines at all.
        type("one", in: window)
        pressReturn(holding: .shift, in: window)
        type("two", in: window)
        XCTAssertEqual(prompt.stringValue, "one\ntwo")
        XCTAssertEqual(submitted.count, 1, "Shift-Return sent a brief that was still being written")
    }

    /// The composer's column, drawn.
    ///
    /// What matters is a *relationship* — chips above the box, the choices and the reading on the
    /// box's own row, the action and the quiet offer on the row underneath — and a relationship
    /// between neighbouring shapes is visible in a picture and in no assertion anyone would
    /// write. The import button is put into the state discovery gives it rather than mocked:
    /// same hidden flag, same counted title.
    func testComposerRendersItsChoicesInsideTheBoxAndItsActionsUnderIt() throws {
        let composer = SessionComposerViewController(customizationLookup: { _ in .empty })
        _ = composer.view
        composer.updatePromptCustomization(for: ProjectID())

        let window = makeWindow(hosting: composer.view)

        // The button carries the offer's visibility now, not the row: the row holds the send as
        // well, so it stands whatever discovery answers.
        let actionRow = try XCTUnwrap(
            controls(in: composer.view).first {
                $0.accessibilityIdentifier() == "composer.session-start.actions"
            }
        )
        let importButton = try XCTUnwrap(
            descendants(of: actionRow)
                .compactMap { $0 as? ThemedButton }
                .first { $0.toolTip == "Import conversation" }
        )
        let startButton = try XCTUnwrap(
            descendants(of: actionRow).first {
                $0.accessibilityIdentifier() == "composer.session-start.submit"
            } as? ThemedButton
        )
        XCTAssertFalse(actionRow.isHidden, "the send has to stand with nothing to import")
        importButton.isHidden = false
        importButton.title = ComposerDefaults.importTitle(count: 90)

        let usage = try XCTUnwrap(
            controls(in: composer.view).first {
                $0.accessibilityIdentifier() == "composer.session-start.usage"
            } as? NSTextField
        )
        usage.isHidden = false
        usage.stringValue = "5h 43% · 7d 73%"

        try captureAppFixture(window, named: "composer-column")

        let prompt = try XCTUnwrap(
            descendants(of: composer.view).compactMap { $0 as? PromptView }.first
        )
        XCTAssertTrue(usage.isDescendant(of: prompt), "the reading belongs inside the box")

        // Converted into the composer's own space, which is unflipped: below means *less* y.
        let importBox = composer.view.convert(importButton.bounds, from: importButton)
        let startBox = composer.view.convert(startButton.bounds, from: startButton)
        let promptBox = composer.view.convert(prompt.bounds, from: prompt)
        XCTAssertLessThan(
            importBox.maxY,
            promptBox.minY,
            "the import offer has to sit under the box"
        )
        XCTAssertEqual(importButton.emphasis, .tertiary, "the quietest tier there is")

        // One at each edge, the loud one where the box ends: the action is the last thing on the
        // way down the column, and the offer beside it is the alternative to taking it.
        XCTAssertEqual(startButton.emphasis, .primary, "the one action this screen is for")
        XCTAssertLessThan(importBox.maxX, startBox.minX)
        XCTAssertEqual(
            startBox.maxX,
            promptBox.maxX,
            accuracy: 1,
            "the send has to finish on the edge the box finishes on"
        )
    }

    func testComposerCapabilityResolverKeepsOpaqueArgumentsAndAcceptsAliases() throws {
        let capability = ComposerCapability(
            id: "claude.command:review",
            name: "review",
            aliases: ["inspect"],
            kind: .command,
            trigger: .slash,
            presentation: .turn
        )

        let invocation = try XCTUnwrap(ComposerCapabilityResolver.invocation(
            in: "  /INSPECT  --path \"Sources/My File.swift\"  ",
            capabilities: [capability]
        ))
        XCTAssertEqual(invocation.capability.id, capability.id)
        XCTAssertEqual(invocation.arguments, "--path \"Sources/My File.swift\"")
        XCTAssertEqual(invocation.sourceText, "/INSPECT  --path \"Sources/My File.swift\"")
    }

    func testSlashCompletionKeepsTheTextViewFocusedAndReturnOnlyInsertsFirst() throws {
        let prompt = PromptView()
        prompt.composerCapabilities = [
            ComposerCapability(
                id: "command:context",
                name: "context",
                description: "Show context usage",
                kind: .command,
                trigger: .slash,
                presentation: .command
            ),
            ComposerCapability(
                id: "skill:release",
                name: "release",
                description: "Prepare a release",
                kind: .skill,
                trigger: .dollar,
                presentation: .turn
            )
        ]
        var submissionCount = 0
        var changeCount = 0
        prompt.onSubmit = { _ in submissionCount += 1 }
        prompt.onChange = { _ in changeCount += 1 }
        let window = makeWindow(hosting: prompt)
        let textView = try promptTextView(in: prompt)
        prompt.focusAtEnd()

        type("/", in: window)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(window.firstResponder === textView)
        let root = try XCTUnwrap(window.contentView)
        let menu = try XCTUnwrap(descendants(of: root).first {
            $0.accessibilityRole() == .menu
        })
        XCTAssertEqual(
            descendants(of: menu).filter { $0.accessibilityRole() == .menuItem }.count,
            1,
            "A slash query must not mix in dollar-triggered skills"
        )

        let changesBeforeAcceptance = changeCount
        pressReturn(in: window)
        XCTAssertEqual(prompt.stringValue, "/context ")
        XCTAssertEqual(
            changeCount,
            changesBeforeAcceptance + 1,
            "Accepting a completion is one edit, so draft persistence must update once"
        )
        XCTAssertEqual(submissionCount, 0, "Accepting a completion must not run it")
        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertFalse(descendants(of: root).contains { $0.accessibilityRole() == .menu })

        pressReturn(in: window)
        XCTAssertEqual(submissionCount, 1)
    }

    func testComposerCompletionQueryOnlyOwnsTheLeadingTokenAndRanksAliases() throws {
        let capabilities = [
            ComposerCapability(
                id: "command:compact",
                name: "compact",
                description: "Reduce context",
                kind: .command,
                trigger: .slash,
                presentation: .command
            ),
            ComposerCapability(
                id: "command:review",
                name: "review",
                aliases: ["inspect"],
                kind: .command,
                trigger: .slash,
                presentation: .turn
            ),
            ComposerCapability(
                id: "skill:inspect",
                name: "inspector",
                kind: .skill,
                trigger: .dollar,
                presentation: .turn
            )
        ]

        let query = try XCTUnwrap(ComposerCompletionQuery.parse("/ins", caretUTF16Offset: 4))
        XCTAssertEqual(query.replacementRange, NSRange(location: 0, length: 4))
        XCTAssertEqual(query.suggestions(from: capabilities).map(\.id), ["command:review"])
        XCTAssertNil(ComposerCompletionQuery.parse("/review files", caretUTF16Offset: 13))

        let skillQuery = try XCTUnwrap(ComposerCompletionQuery.parse("$i", caretUTF16Offset: 2))
        XCTAssertEqual(skillQuery.suggestions(from: capabilities).map(\.id), ["skill:inspect"])
    }

    func testComposerCatalogBoundsProviderMetadataAndRenderedSuggestions() throws {
        let many = (0..<400).map { index in
            ComposerCapability(
                id: "command:\(index)",
                name: "command-\(index)",
                description: "A command",
                kind: .command,
                trigger: .slash,
                presentation: .command
            )
        }
        let bounded = ComposerCapabilityCatalogPolicy.normalize(many)
        XCTAssertTrue(bounded.wasTruncated)
        XCTAssertEqual(
            bounded.capabilities.count,
            ComposerCapabilityCatalogPolicy.maximumCapabilities
        )

        let hostile = ComposerCapabilityCatalogPolicy.normalize([
            ComposerCapability(
                id: "skill:hostile",
                name: "hostile",
                description: String(repeating: "payload", count: 10_000),
                argumentHint: String(repeating: "argument", count: 1_000),
                aliases: (0..<100).map { "alias-\($0)" },
                kind: .skill,
                trigger: .dollar,
                presentation: .turn
            )
        ])
        let safe = try XCTUnwrap(hostile.capabilities.first)
        XCTAssertTrue(hostile.wasTruncated)
        XCTAssertLessThanOrEqual(
            safe.description.utf8.count,
            ComposerCapabilityCatalogPolicy.maximumDescriptionUTF8Bytes
        )
        XCTAssertLessThanOrEqual(
            safe.aliases.count,
            ComposerCapabilityCatalogPolicy.maximumAliases
        )

        let query = try XCTUnwrap(ComposerCompletionQuery.parse("/", caretUTF16Offset: 1))
        XCTAssertEqual(
            query.suggestions(from: many).count,
            ComposerCapabilityCatalogPolicy.maximumRenderedSuggestions
        )

        let skillRows = [
            ComposerCapability(
                id: "claude.command:provisional",
                name: "provisional",
                kind: .command,
                isAvailableInSkillCatalog: true,
                trigger: .slash,
                presentation: .command
            ),
            ComposerCapability(
                id: "claude.skill:release",
                name: "release",
                kind: .skill,
                trigger: .slash,
                presentation: .turn
            ),
        ]
        XCTAssertEqual(
            query.suggestions(from: many + skillRows, matching: .skill).map(\.id),
            skillRows.map(\.id),
            "The skill filter must run before the rendered-row limit"
        )
    }

    func testDisabledCompletionAnnouncesItsUnavailableReason() {
        let row = PromptCompletionRowTestingSupport.makeRow(capability: ComposerCapability(
            id: "skill:blocked",
            name: "blocked",
            displayName: "Blocked skill",
            description: "Ordinary description",
            kind: .skill,
            trigger: .dollar,
            presentation: .turn,
            availability: .unavailable(reason: "Disabled by project policy")
        ))

        XCTAssertEqual(
            row.accessibilityLabel(),
            "$blocked, Blocked skill, Disabled by project policy"
        )
        XCTAssertEqual(row.accessibilityHelp(), "Disabled by project policy")
    }

    func testAppCommandsReplaceDisabledExpectationsWithoutShadowingProviderCommands() throws {
        let providerStatus = ComposerCapability(
            id: "provider.command:status",
            name: "status",
            kind: .command,
            trigger: .slash,
            presentation: .command
        )
        let retained = ConversationComposerCommands.addingAppCommands(
            to: [providerStatus]
        )
        XCTAssertEqual(
            retained.filter { $0.name == "status" }.map(\.id),
            [providerStatus.id],
            "An enabled live provider command remains authoritative"
        )

        let disabledStatus = ComposerCapability(
            id: "provider.terminal:status",
            name: "status",
            kind: .command,
            trigger: .slash,
            presentation: .command,
            availability: .unavailable(reason: "Terminal only")
        )
        let disabledSkills = ComposerCapability(
            id: "provider.terminal:skills",
            name: "skills",
            kind: .command,
            trigger: .slash,
            presentation: .command,
            availability: .unavailable(reason: "Terminal only")
        )
        let checkoutSkill = ComposerCapability(
            id: "provider.skill:release",
            name: "release",
            kind: .skill,
            trigger: .dollar,
            presentation: .turn
        )
        let augmented = ConversationComposerCommands.addingAppCommands(
            to: [disabledStatus, disabledSkills, checkoutSkill]
        )

        XCTAssertEqual(
            try XCTUnwrap(augmented.first { $0.name == "status" }).id,
            ConversationComposerCommands.statusID
        )
        XCTAssertEqual(
            try XCTUnwrap(augmented.first { $0.name == "skills" }).id,
            ConversationComposerCommands.skillsID
        )
        XCTAssertTrue(augmented.filter { $0.name == "status" || $0.name == "skills" }
            .allSatisfy(\.isEnabled))
    }

    func testCodexKnownTerminalCommandsHaveAnExplicitNativeFallbackExpectation() {
        let expected = Set([
            "permissions", "ide", "keymap", "vim", "setup-default-sandbox",
            "sandbox-add-read-dir", "agent", "apps", "plugins", "hooks", "clear",
            "rename", "archive", "delete", "copy", "diff", "exit", "experimental",
            "approve", "memories", "skills", "import", "feedback", "init", "logout",
            "mcp", "mention", "model", "fast", "plan", "goal", "personality", "ps",
            "stop", "fork", "app", "side", "raw", "resume", "new", "status", "usage",
            "debug-config", "statusline", "title", "theme", "pets"
        ])

        XCTAssertEqual(Set(CodexComposerCatalog.terminalOnly.map(\.name)), expected)
        XCTAssertTrue(CodexComposerCatalog.terminalOnly.allSatisfy { capability in
            !capability.isEnabled
                && capability.trigger == .slash
                && capability.unavailableReason?.isEmpty == false
        })
        XCTAssertEqual(
            CodexComposerCatalog.terminalOnly.first { $0.name == "agent" }?.aliases,
            ["subagents"]
        )
        XCTAssertEqual(
            CodexComposerCatalog.terminalOnly.first { $0.name == "exit" }?.aliases,
            ["quit"]
        )
    }

    func testRemoteParticipantEnvelopePreservesLeadingSlashSyntaxOnlyForClaude() {
        XCTAssertEqual(
            ConversationTransportText.message(
                "/future-command exact arguments",
                participantDisplayName: "Ada",
                preservesLeadingSlash: true
            ),
            "/future-command exact arguments"
        )
        XCTAssertEqual(
            ConversationTransportText.message(
                "Please inspect this",
                participantDisplayName: "Ada",
                preservesLeadingSlash: true
            ),
            "Message from Ada in the shared chat:\nPlease inspect this"
        )
        XCTAssertEqual(
            ConversationTransportText.message(
                "/unknown-codex-prompt",
                participantDisplayName: "Ada",
                preservesLeadingSlash: false
            ),
            "Message from Ada in the shared chat:\n/unknown-codex-prompt"
        )
    }

    func testCompletionPointerChoosesOnReleaseAndAllowsDragAway() throws {
        var choices = 0
        let row = PromptCompletionRowTestingSupport.makeRow(
            capability: ComposerCapability(
                id: "command:context",
                name: "context",
                kind: .command,
                trigger: .slash,
                presentation: .command
            ),
            onChoose: { choices += 1 }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 54),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = row

        func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ))
        }

        let inside = NSPoint(x: 20, y: 20)
        let outside = NSPoint(x: window.frame.width + 20, y: 20)
        row.mouseDown(with: try mouseEvent(.leftMouseDown, at: inside))
        XCTAssertEqual(choices, 0, "mouse-down must not commit a completion")
        row.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: outside))
        row.mouseUp(with: try mouseEvent(.leftMouseUp, at: outside))
        XCTAssertEqual(choices, 0, "dragging away must cancel the press")

        row.mouseDown(with: try mouseEvent(.leftMouseDown, at: inside))
        row.mouseUp(with: try mouseEvent(.leftMouseUp, at: inside))
        XCTAssertEqual(choices, 1)
        window.close()
    }

    func testFocusedWatcherKeepsEditableDraftWhileSubmissionIsDisabled() throws {
        let prompt = PromptView()
        var submissions: [String] = []
        prompt.onSubmit = { submissions.append($0) }
        prompt.stringValue = "A domain expert's unfinished answer"
        prompt.isSubmissionEnabled = false
        prompt.submissionDisabledReason = "Anna is controlling"

        prompt.submit()

        XCTAssertTrue(submissions.isEmpty)
        XCTAssertEqual(prompt.stringValue, "A domain expert's unfinished answer")
        let button = try inlineSubmitButton(in: prompt)
        XCTAssertFalse(button.isEnabled)
        XCTAssertEqual(button.toolTip, "Anna is controlling")

        prompt.isSubmissionEnabled = true
        prompt.submit()
        XCTAssertEqual(submissions, ["A domain expert's unfinished answer"])
    }

    func testContextOnlyCommentStagesAsSendableComposerContentAndClearsWithTurn() throws {
        let prompt = PromptView()
        let comment = ConversationContextAttachment(
            id: UUID(uuidString: "A9143D6F-B539-468D-8CD7-B244CFC50E26")!,
            kind: .comment,
            source: .attachment,
            title: "layout.png",
            comment: "The spacing above the toolbar feels too large.",
            locator: "attachments/layout.png"
        )
        var submittedContexts: [[ConversationContextAttachment]] = []
        prompt.onSubmit = { _ in submittedContexts.append(prompt.contextAttachments) }

        prompt.addContextAttachment(comment)
        prompt.addContextAttachment(comment)

        XCTAssertEqual(prompt.contextAttachments, [comment], "the same receipt must stage once")
        XCTAssertTrue(try inlineSubmitButton(in: prompt).isEnabled)
        prompt.submit()
        XCTAssertEqual(submittedContexts, [[comment]])

        prompt.clear()
        XCTAssertTrue(prompt.contextAttachments.isEmpty)
        XCTAssertFalse(try inlineSubmitButton(in: prompt).isEnabled)
    }

    func testWorkspaceMentionCanBeCompletedUsingOnlyTheKeyboard() throws {
        let prompt = PromptView()
        var queries: [String] = []
        prompt.workspaceFileSearch = { query, completion in
            queries.append(query)
            completion(.success([
                WorkspaceFileReference(path: "Sources/Threading/UI/Design/PromptView.swift")
            ]))
        }
        let window = makeWindow(hosting: prompt)
        let editor = try promptTextView(in: prompt)
        XCTAssertTrue(window.makeFirstResponder(editor))

        type("Review @Prompt", in: window)
        pressReturn(in: window)

        XCTAssertEqual(queries.last, "Prompt")
        XCTAssertEqual(
            prompt.stringValue,
            "Review @Sources/Threading/UI/Design/PromptView.swift "
        )
        let reference = try XCTUnwrap(prompt.contextAttachments.first)
        XCTAssertEqual(reference.source, .workspaceFile)
        XCTAssertEqual(reference.locator, "Sources/Threading/UI/Design/PromptView.swift")
        XCTAssertNil(reference.excerpt, "mention completion must not paste file contents")
        XCTAssertFalse(reference.locator?.hasPrefix("/") ?? true)
    }

    func testOrdinaryAtInProseDoesNotOpenWorkspaceCompletion() throws {
        let prompt = PromptView()
        var searches = 0
        prompt.workspaceFileSearch = { _, completion in
            searches += 1
            completion(.success([]))
        }
        let window = makeWindow(hosting: prompt)
        XCTAssertTrue(window.makeFirstResponder(try promptTextView(in: prompt)))

        type("mail@example.com", in: window)

        XCTAssertEqual(searches, 0)
        XCTAssertEqual(prompt.stringValue, "mail@example.com")
    }

    private func inlineSubmitButton(in prompt: PromptView) throws -> ThemedButton {
        try XCTUnwrap(
            descendants(of: prompt).compactMap { $0 as? ThemedButton }.first,
            "The prompt has to hold its inline submit control"
        )
    }
}

// MARK: - Drop Fixture

/// A drag carrying one pasteboard, which is the whole of what the composer inspects.
///
/// AppKit offers no way to stage a real drag from a test, and the alternative — asserting on
/// `registeredDraggedTypes` alone — proves the pointer arrives without proving anything happens
/// when it lands. Everything past the pasteboard is geometry and animation the drop path does
/// not read.
private final class DropFixture: NSObject, NSDraggingInfo {

    private let pasteboard: NSPasteboard

    init(writing contents: (NSPasteboard) -> Void) {
        // A named board rather than the general one: a test must not take the user's clipboard.
        pasteboard = NSPasteboard(name: NSPasteboard.Name("ThreadingPromptDropFixture"))
        pasteboard.clearContents()
        contents(pasteboard)
        super.init()
    }

    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic] }
    var draggingLocation: NSPoint { NSPoint(x: 10, y: 10) }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var draggingFormation: NSDraggingFormation = .default
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
