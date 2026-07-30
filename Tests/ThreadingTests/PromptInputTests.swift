import AppKit
import QuickLookUI
import XCTest
@testable import Threading

/// The composer's prompt is the app's primary input. These tests drive it the way a user does —
/// focus it, then send real key events through the responder chain — because every layer between
/// the key and the string can fail without failing anything a layout or rendering test would
/// notice: a text view with no text network draws its box, takes focus, shows its focus ring, and
/// swallows every keystroke in silence.
final class PromptInputTests: XCTestCase {

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

    /// The two halves of every image fixture. The Quick Look assertion looks for these same
    /// colours in the captured panel, so they are named once rather than written twice.
    private enum FixtureSwatch {
        static let leading = NSColor.systemTeal
        static let trailing = NSColor.systemOrange

        static let hueTolerance: CGFloat = 12
        static let minimumSaturation: CGFloat = 0.25
        static let minimumBrightness: CGFloat = 0.25
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

    private func captureQuickLookFixture(_ panel: QLPreviewPanel, directory: String) throws {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let image = try XCTUnwrap(
            CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                CGWindowID(panel.windowNumber),
                [.boundsIgnoreFraming]
            ),
            "The window server did not capture Quick Look"
        )
        let rep = NSBitmapImageRep(cgImage: image)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000, "Quick Look rendered as an empty image")
        assertQuickLookContainsFixtureColours(rep)

        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )
        try png.write(to: output.appendingPathComponent("quick-look-panel.png"))
    }

    /// Match the swatches by hue, not by raw components.
    ///
    /// The window server hands back the capture in the *display's* colour space — Display P3 on
    /// this hardware — and `colorAt` reports those components verbatim: `usingColorSpace` does not
    /// convert them, so an sRGB teal of `(0.00, 0.82, 0.88)` reads as `(0.43, 0.84, 0.89)`. Any
    /// threshold written against the fixture's own red/green/blue therefore fails on a wide-gamut
    /// display while the panel is plainly rendering the right picture. Hue survives the round trip
    /// — the same teal measures 183.8° in the fixture and 186–187° in the capture — so the two
    /// halves are identified by hue proximity instead, which stays true on any display.
    private func assertQuickLookContainsFixtureColours(_ rep: NSBitmapImageRep) {
        var foundLeading = false
        var foundTrailing = false

        for y in stride(from: 0, to: rep.pixelsHigh, by: 16) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 16) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                foundLeading = foundLeading || matches(color, FixtureSwatch.leading)
                foundTrailing = foundTrailing || matches(color, FixtureSwatch.trailing)
                if foundLeading, foundTrailing { break }
            }
            if foundLeading, foundTrailing { break }
        }

        XCTAssertTrue(foundLeading, "Quick Look did not render the teal half of the fixture")
        XCTAssertTrue(foundTrailing, "Quick Look did not render the orange half of the fixture")
    }

    /// A captured pixel counts as one of the fixture's swatches when it carries the same hue and
    /// is saturated and bright enough not to be panel chrome. The tolerance is wide enough for the
    /// gamut shift above and far narrower than the 155° between the two swatches.
    private func matches(_ pixel: NSColor, _ swatch: NSColor) -> Bool {
        // `getHue` needs an RGB colour space; a capture is never monochrome, but converting keeps
        // the helper honest if one ever is.
        guard let measured = pixel.usingColorSpace(.sRGB),
              let expected = swatch.usingColorSpace(.sRGB) else { return false }
        let (pixelHue, saturation, brightness) = hueSaturationBrightness(measured)
        guard saturation > FixtureSwatch.minimumSaturation,
              brightness > FixtureSwatch.minimumBrightness else { return false }
        let (expectedHue, _, _) = hueSaturationBrightness(expected)
        let separation = abs(pixelHue - expectedHue)
        return min(separation, 360 - separation) <= FixtureSwatch.hueTolerance
    }

    private func hueSaturationBrightness(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (hue * 360, saturation, brightness)
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
        let document = try XCTUnwrap(scrolling.documentView as? NSTextView)
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

    func testImagePreviewOpensTheSystemQuickLookPanel() throws {
        let imageURL = try makeImageFile(
            named: "quick look.png",
            size: NSSize(width: 600, height: 400)
        )
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let prompt = PromptView()
        prompt.showsImageAttachments = true
        let window = makeWindow(hosting: prompt)
        window.makeKeyAndOrderFront(nil)
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
            "Press to open \(imageURL.lastPathComponent) in Quick Look"
        )
        XCTAssertTrue(thumbnail.accessibilityPerformPress())

        let panel = try XCTUnwrap(QLPreviewPanel.shared())
        defer {
            panel.orderOut(nil)
            window.orderOut(nil)
        }
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.dataSource?.numberOfPreviewItems(in: panel), 1)

        let item = try XCTUnwrap(
            panel.dataSource?.previewPanel(panel, previewItemAt: 0)
        )
        XCTAssertEqual(item.previewItemURL, imageURL)

        let renderDirectory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
                .path
        try captureQuickLookFixture(panel, directory: renderDirectory)
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
                "Quick Look",
                "Open in Default App",
                "Reveal in Finder",
                "Copy Image",
                "Copy File Name",
                "Copy File Path",
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
        let replyComposer = ConversationViewController(
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

    /// The whole shape of the composer's action row, from the outside: one primary that says
    /// its chord, one secondary beside it, and a prompt that keeps Return.
    func testComposerSendsFromItsPrimaryButtonAndItsChordRatherThanFromReturn() throws {
        let composer = SessionComposerViewController(customizationLookup: { _ in .empty })
        _ = composer.view
        composer.updatePromptCustomization(for: ProjectID())

        let window = makeWindow(hosting: composer.view)
        let prompt = try XCTUnwrap(
            descendants(of: composer.view).compactMap { $0 as? PromptView }.first
        )
        let textView = try promptTextView(in: prompt)

        let start = try XCTUnwrap(
            descendants(of: composer.view).first {
                $0.accessibilityIdentifier() == "composer.session-start.submit"
            } as? ThemedButton,
            "The composer has to offer its send outside the box"
        )
        XCTAssertEqual(start.emphasis, .primary, "the one action this screen is for")
        XCTAssertEqual(start.shortcut, KeyboardShortcut(key: "\r", modifiers: .command))
        XCTAssertEqual(start.accessibilityTitle(), "Start session")

        let importButton = try XCTUnwrap(
            descendants(of: composer.view)
                .compactMap { $0 as? ThemedButton }
                .first { $0.toolTip == "Import conversation" }
        )
        XCTAssertEqual(importButton.emphasis, .secondary, "the quieter of the two offers")

        // What the user types, including the line breaks that used to launch a session.
        var submitted: [String] = []
        prompt.onSubmit = { submitted.append($0) }
        XCTAssertTrue(window.makeFirstResponder(textView))

        type("a task", in: window)
        pressReturn(in: window)
        type("and its context", in: window)
        XCTAssertEqual(prompt.stringValue, "a task\nand its context")
        XCTAssertTrue(submitted.isEmpty)

        // Through the window, as AppKit routes a key equivalent — the caret is in the prompt,
        // and the button still has to hear the chord.
        XCTAssertTrue(
            window.performKeyEquivalent(with: try returnKey(holding: .command, in: window))
        )
        XCTAssertEqual(submitted, ["a task\nand its context"])

        start.performClick()
        XCTAssertEqual(submitted.count, 2, "the button and the chord have to send the same thing")
        XCTAssertEqual(submitted.last, "a task\nand its context")
    }

    /// The action row, drawn.
    ///
    /// What matters here is a *relationship* — one loud button naming its chord beside one quiet
    /// one — and a relationship between neighbouring shapes is visible in a picture and in no
    /// assertion anyone would write. The import button is put into the state discovery gives it
    /// rather than mocked: same hidden flag, same counted title.
    func testComposerActionRowRendersOnePrimaryNamingItsChordBesideOneSecondary() throws {
        let composer = SessionComposerViewController(customizationLookup: { _ in .empty })
        _ = composer.view
        composer.updatePromptCustomization(for: ProjectID())

        let window = makeWindow(hosting: composer.view)
        let importButton = try XCTUnwrap(
            descendants(of: composer.view)
                .compactMap { $0 as? ThemedButton }
                .first { $0.toolTip == "Import conversation" }
        )
        importButton.isHidden = false
        importButton.title = ComposerDefaults.importTitle(count: 90)

        try captureAppFixture(window, named: "composer-action-row")

        let start = try XCTUnwrap(
            descendants(of: composer.view).first {
                $0.accessibilityIdentifier() == "composer.session-start.submit"
            } as? ThemedButton
        )
        let prompt = try XCTUnwrap(
            descendants(of: composer.view).compactMap { $0 as? PromptView }.first
        )

        // Converted into the composer's own space, which is unflipped: below means *less* y.
        let sendBox = composer.view.convert(start.bounds, from: start)
        let promptBox = composer.view.convert(prompt.bounds, from: prompt)
        XCTAssertLessThan(
            sendBox.maxY,
            promptBox.minY,
            "the send has to sit under the box rather than inside it"
        )
        XCTAssertEqual(
            sendBox.minY,
            composer.view.convert(importButton.bounds, from: importButton).minY,
            accuracy: 1,
            "the two buttons have to sit on one line"
        )
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
