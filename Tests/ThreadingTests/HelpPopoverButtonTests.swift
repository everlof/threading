import AppKit
import XCTest
@testable import Threading

/// The "?" that carries a page's explanations.
///
/// It exists so a settings page can stop being a wall of prose without the prose becoming
/// unreachable, so the tests are mostly about *reachability*: the words are on the button for a
/// screen reader, the panel opens from the keyboard as well as the pointer, Escape closes it, and
/// the two-column answer block cannot come out looking one way in a fixture and another in a
/// window — which is the exact defect that made this component necessary.
@MainActor
final class HelpPopoverButtonTests: XCTestCase {

    private static let topic = HelpTopic(
        title: "Tailscale",
        lines: [
            HelpTopic.Line(
                term: "Who can reach it",
                detail: "devices your tailnet ACLs allow"
            ),
            HelpTopic.Line(
                term: "Who can see the traffic",
                detail: "nobody reads it. Tailscale may relay it encrypted when a direct "
                    + "connection is not possible"
            ),
            HelpTopic.Line(term: "After a restart", detail: "the address stays the same"),
            HelpTopic.Line(term: "Away from home", detail: "yes")
        ],
        paragraphs: [
            "Turning this on does not put Threading on any other network. Each way in above is "
                + "separate."
        ]
    )

    // MARK: - The words are reachable without pressing anything

    func testTheButtonSpeaksTheWholeAnswerItself() {
        let button = HelpPopoverButton(topic: Self.topic)

        XCTAssertEqual(button.accessibilityLabel(), "Tailscale, help")
        XCTAssertEqual(button.accessibilityRole(), .button)

        let spoken = try? XCTUnwrap(button.accessibilityHelp())
        for line in Self.topic.lines {
            XCTAssertTrue(
                spoken?.contains(line.term) == true,
                "the button does not say “\(line.term)”"
            )
            XCTAssertTrue(
                spoken?.contains(line.detail) == true,
                "the button does not answer “\(line.term)”"
            )
        }
        for paragraph in Self.topic.paragraphs {
            XCTAssertTrue(spoken?.contains(paragraph) == true)
        }
    }

    func testRenamingTheTopicRenamesTheButton() {
        let button = HelpPopoverButton(topic: Self.topic)
        button.topic = HelpTopic(title: "This network", paragraphs: ["Same Wi-Fi."])

        XCTAssertEqual(button.accessibilityLabel(), "This network, help")
        XCTAssertEqual(button.accessibilityHelp(), "Same Wi-Fi.")
    }

    func testAnEmptyTopicOpensNothing() throws {
        let window = offscreenWindow()
        let button = HelpPopoverButton(topic: HelpTopic(title: "Nothing to say"))
        install(button, in: window)

        button.present()
        XCTAssertFalse(button.isPresenting, "an empty topic opened a blank panel")
    }

    // MARK: - The panel

    func testPressingOpensThePanelAndPressingAgainClosesIt() throws {
        let window = offscreenWindow()
        let button = HelpPopoverButton(topic: Self.topic)
        install(button, in: window)

        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertTrue(button.isPresenting)

        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertFalse(button.isPresenting, "the second press did not close it")
    }

    /// Space is the keyboard's press, which is `ThemedControl`'s contract and the whole reason
    /// this is a control rather than a hover affordance.
    func testTheKeyboardOpensIt() throws {
        let window = offscreenWindow()
        let button = HelpPopoverButton(topic: Self.topic)
        install(button, in: window)
        XCTAssertTrue(window.makeFirstResponder(button))

        button.keyDown(with: try key(" ", in: window))
        XCTAssertTrue(button.isPresenting)
        button.dismiss()
    }

    func testEscapeClosesThePanelAndGivesTheKeyboardBack() throws {
        let window = offscreenWindow()
        let button = HelpPopoverButton(topic: Self.topic)
        install(button, in: window)
        XCTAssertTrue(window.makeFirstResponder(button))

        button.present()
        let panel = try XCTUnwrap(button.isPresenting ? window.childWindows?.last : nil)
        panel.cancelOperation(nil)

        XCTAssertFalse(button.isPresenting)
        XCTAssertTrue(window.firstResponder === button, "focus did not come back to the button")
    }

    func testThePanelPrintsEveryLineAndParagraph() throws {
        let content = HelpPopoverButton(topic: Self.topic).makeContent()
        content.view.layoutSubtreeIfNeeded()
        let printed = labels(in: content.view).map(\.stringValue)

        XCTAssertTrue(printed.contains(Self.topic.title))
        for line in Self.topic.lines {
            XCTAssertTrue(printed.contains(line.term), "the panel does not ask “\(line.term)”")
            XCTAssertTrue(printed.contains(line.detail), "the panel does not answer it")
        }
        for paragraph in Self.topic.paragraphs {
            XCTAssertTrue(printed.contains(paragraph))
        }

        XCTAssertEqual(content.view.accessibilityLabel(), Self.topic.title)
        XCTAssertEqual(content.view.accessibilityHelp(), Self.topic.spokenSummary)
    }

    // MARK: - The column that shipped two ways

    /// **The regression boundary for the defect this component was built out of.**
    ///
    /// The four lines used to be printed straight onto the settings page, with the term column
    /// settled by a constraint at `.defaultLow` — the same priority AppKit gives a wrapping
    /// label's horizontal content hugging. Two constraints at 250 wanting opposite things is not
    /// a layout, and the engine spent the tie differently depending on how many passes the tree
    /// had been through: laid out once in a detached fixture the answers sat beside their
    /// questions, and the identical page in a window put the questions on the leading edge with a
    /// narrow ragged answer column hard against the trailing one. The render tests photographed
    /// one outcome and the app shipped the other.
    ///
    /// So this asserts both halves: the detail starts immediately after the longest term, and it
    /// does so identically whether the block was laid out detached or inside a window.
    func testEveryDetailStartsBesideItsTermAndSaysSoInAWindowToo() throws {
        let detached = HelpPopoverButton(topic: Self.topic).makeContent().view
        detached.layoutSubtreeIfNeeded()

        let window = offscreenWindow()
        let hosted = HelpPopoverButton(topic: Self.topic).makeContent().view
        hosted.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            hosted.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor)
        ])
        window.contentView?.layoutSubtreeIfNeeded()
        // A window lays a tree out more than once, which is what made the two disagree.
        window.setContentSize(NSSize(width: 300, height: 400))
        window.contentView?.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 420, height: 260))
        window.contentView?.layoutSubtreeIfNeeded()

        for (name, root) in [("detached", detached), ("in a window", hosted)] {
            let printed = labels(in: root)
            let terms = Self.topic.lines.compactMap { line in
                printed.first { $0.stringValue == line.term }
            }
            let details = Self.topic.lines.compactMap { line in
                printed.first { $0.stringValue == line.detail }
            }
            XCTAssertEqual(terms.count, Self.topic.lines.count, name)
            XCTAssertEqual(details.count, Self.topic.lines.count, name)

            // Alignment rects, not frames: a label's frame carries two points of padding
            // around its glyphs on each side, and comparing frames would report a straight
            // column as crooked by exactly that much.
            let columnEdge = terms.map { ink(of: $0).maxX }.max() ?? 0
            for detail in details {
                XCTAssertEqual(
                    ink(of: detail).minX - columnEdge,
                    Design.Spacing.medium,
                    accuracy: 0.5,
                    "\(name): the answer column is not beside the questions"
                )
                XCTAssertGreaterThan(
                    ink(of: detail).width,
                    HelpPopoverMetrics.contentWidth / 2,
                    "\(name): the answer column collapsed to a ragged strip"
                )
            }
        }

        // And the two are the same picture, which is the property the render tests rely on.
        // A window rounds a label to the backing store where a detached view keeps the half
        // point, so the two agree to within a pixel rather than exactly. What must not differ is
        // where a column *is*, which is the failure this whole test exists for.
        let detachedInk = labels(in: detached).map { ink(of: $0) }
        let hostedInk = labels(in: hosted).map { ink(of: $0) }
        XCTAssertEqual(detachedInk.count, hostedInk.count)
        for (detachedRect, hostedRect) in zip(detachedInk, hostedInk) {
            XCTAssertEqual(
                detachedRect.minX, hostedRect.minX, accuracy: 1,
                "a window laid the same block out differently"
            )
            XCTAssertEqual(
                detachedRect.width, hostedRect.width, accuracy: 1,
                "a window laid the same block out differently"
            )
        }
    }

    // MARK: - Theme

    func testTheMarkFollowsALiveThemeSwitch() throws {
        let original = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(original) }

        let window = offscreenWindow()
        let button = HelpPopoverButton(topic: Self.topic)
        install(button, in: window)

        var pictures: [String: Data] = [:]
        for theme in [AppTheme.system, AppThemeStyles.neoBrutalism, AppThemeStyles.claymorphism] {
            AppThemeLibrary.apply(theme)
            AppThemeRefresh.repaint(button)
            window.contentView?.layoutSubtreeIfNeeded()
            let data = try XCTUnwrap(png(of: button))
            pictures[theme.name] = data
        }
        XCTAssertEqual(pictures.count, 3)
        XCTAssertEqual(
            Set(pictures.values).count, 3,
            "the mark drew identically under three deliberately different materials"
        )
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: button), [])
    }

    // MARK: - Images

    func testRendersItsStatesToImages() throws {
        let directory = renderDirectory
        if let directory {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        var written = 0
        for (name, appearanceName) in [
            ("light", NSAppearance.Name.aqua),
            ("dark", .darkAqua)
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var states: [(String, Data?)] = []
            appearance.performAsCurrentDrawingAppearance {
                states = [
                    ("resting", self.statePicture(appearance, state: .resting)),
                    ("hover", self.statePicture(appearance, state: .hover)),
                    ("focus", self.statePicture(appearance, state: .focus)),
                    ("disabled", self.statePicture(appearance, state: .disabled)),
                    ("panel", self.panelPicture(appearance))
                ]
            }
            for (state, data) in states {
                let data = try XCTUnwrap(data, "\(state) \(name) rendered nothing")
                XCTAssertGreaterThan(data.count, 200, "\(state) \(name) rendered empty")
                let fileName = "help-popover-\(state)-\(name)"
                attach(data, named: fileName)
                try directory.map {
                    try data.write(to: $0.appendingPathComponent("\(fileName).png"))
                }
                written += 1
            }
        }
        XCTAssertEqual(written, 10)
    }

    private enum RenderState { case resting, hover, focus, disabled }

    private func statePicture(_ appearance: NSAppearance, state: RenderState) -> Data? {
        let window = offscreenWindow()
        window.appearance = appearance
        let button = HelpPopoverButton(topic: Self.topic)
        install(button, in: window, padded: true)
        switch state {
        case .resting: break
        case .hover: button.mouseEntered(with: enterEvent(for: window))
        case .focus: _ = window.makeFirstResponder(button)
        case .disabled: button.isEnabled = false
        }
        window.contentView?.layoutSubtreeIfNeeded()
        return png(of: try? XCTUnwrap(button.superview))
    }

    private func panelPicture(_ appearance: NSAppearance) -> Data? {
        let content = HelpPopoverButton(topic: Self.topic).makeContent()
        let host = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: HelpPopoverMetrics.contentWidth + Design.Spacing.inset * 2,
            height: 260
        ))
        host.appearance = appearance
        host.wantsLayer = true
        host.layer?.backgroundColor = Design.Surface.panel.cgColor
        content.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.leadingAnchor.constraint(
                equalTo: host.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            content.view.topAnchor.constraint(
                equalTo: host.topAnchor,
                constant: Design.Spacing.inset
            )
        ])
        AppThemeRefresh.repaint(host)
        host.layoutSubtreeIfNeeded()
        return png(of: host)
    }

    // MARK: - Fixture

    private var renderDirectory: URL? {
        ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"].flatMap { override in
            override.isEmpty ? nil : URL(fileURLWithPath: override, isDirectory: true)
        }
    }

    /// A window that is never ordered on screen: nothing here needs to be visible, and a popover
    /// anchored inside it is a child of a window no display is showing.
    private func offscreenWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 420, height: 260),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        return window
    }

    private func install(_ button: HelpPopoverButton, in window: NSWindow, padded: Bool = false) {
        guard let root = window.contentView else { return }
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        host.layer?.backgroundColor = Design.Surface.panel.cgColor
        root.addSubview(host)
        host.addSubview(button)
        let pad = padded ? Design.Spacing.small : 0
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            host.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            button.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: pad),
            button.topAnchor.constraint(equalTo: host.topAnchor, constant: pad),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: pad),
            host.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: pad)
        ])
        AppThemeRefresh.repaint(root)
        root.layoutSubtreeIfNeeded()
    }

    private func key(_ characters: String, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 49
        ))
    }

    private func enterEvent(for window: NSWindow) -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ) ?? NSEvent()
    }

    private func png(of view: NSView?) -> Data? {
        guard let view, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func attach(_ data: Data, named name: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A label's visible ink in its own superview's coordinates. `NSStackView` and every
    /// leading/trailing anchor align alignment rects, so this is what the layout actually said.
    private func ink(of view: NSView) -> NSRect {
        view.alignmentRect(forFrame: view.frame)
    }

    private func labels(in view: NSView) -> [NSTextField] {
        ([view] + descendants(in: view)).compactMap { $0 as? NSTextField }
    }

    private func descendants(in view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(in: $0) }
    }
}
