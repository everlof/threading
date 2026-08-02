import AppKit
import XCTest
@testable import Threading

/// The redesigned composer: bottom-flush, a hero floating in the room above, and a project
/// chip that makes "no project yet" a mode rather than a wall. Geometry and legibility are
/// reviewed on the renders; the behavior the layout promises is asserted.
@MainActor
final class SessionComposerRenderTests: XCTestCase {

    private enum Render {
        static let tall = NSSize(width: 900, height: 640)
        static let short = NSSize(width: 720, height: 300)

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - Behavior

    func testNilProjectModeDisablesStartUntilAProjectIsChosen() throws {
        let composer = SessionComposerViewController()
        _ = composer.view

        composer.show(projectID: nil)
        let start = try XCTUnwrap(startButton(in: composer.view))
        XCTAssertFalse(start.isEnabled, "A session cannot start nowhere")

        let store = ProjectStore.shared
        let project = store.addProject(
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("threading-composer-start-\(UUID().uuidString)")
        )
        defer { store.removeProject(id: project.id) }

        composer.show(projectID: project.id)
        XCTAssertTrue(start.isEnabled)
    }

    func testWordsTypedBeforeChoosingAProjectFollowIntoIt() throws {
        let composer = SessionComposerViewController()
        _ = composer.view

        composer.show(projectID: nil)
        let prompt = try XCTUnwrap(promptView(in: composer.view))
        prompt.stringValue = "Fix the login flow"

        let store = ProjectStore.shared
        let project = store.addProject(
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("threading-composer-carry-\(UUID().uuidString)")
        )
        defer {
            store.removeProject(id: project.id)
            DraftStore.shared.setDraft("", for: project.id)
        }

        composer.show(projectID: project.id)
        XCTAssertEqual(prompt.stringValue, "Fix the login flow")

        // And leaving again does not drag the adopted draft back into the empty mode.
        composer.show(projectID: nil)
        XCTAssertEqual(prompt.stringValue, "")
    }

    /// Looking at a session and coming back to the composer is a detour, not a change of
    /// project. Only the text is written to `DraftStore`, so everything else the user had set
    /// up — first of all an attached screenshot — survives that trip only if being pointed at
    /// the project it already holds leaves the composer alone. It did not: the image was gone
    /// from the prompt on the way back, with the sentence describing it still sitting there.
    func testReturningToTheProjectItAlreadyHoldsKeepsTheAttachment() throws {
        let composer = SessionComposerViewController()
        _ = composer.view

        let store = ProjectStore.shared
        let project = store.addProject(folderURL: fixtureFolder())
        let elsewhere = store.addProject(folderURL: fixtureFolder())
        defer {
            store.removeProject(id: project.id)
            store.removeProject(id: elsewhere.id)
        }

        let imageURL = try makeImageFile()
        defer { try? FileManager.default.removeItem(at: imageURL) }

        composer.show(projectID: project.id)
        let prompt = try XCTUnwrap(promptView(in: composer.view))
        prompt.stringValue = "Crop the empty space out of this"
        prompt.attachFiles(at: [imageURL.path])

        // The session in between, then the same project selected again.
        composer.show(projectID: project.id)
        XCTAssertEqual(prompt.stringValue, "Crop the empty space out of this")
        XCTAssertEqual(prompt.attachmentPaths, [imageURL.path], "the attachment was dropped")

        // Another project *is* a change of project, and an image attached for one is not an
        // attachment to a session started in another.
        composer.show(projectID: elsewhere.id)
        XCTAssertEqual(prompt.stringValue, "")
        XCTAssertTrue(prompt.attachmentPaths.isEmpty)
    }

    /// The other half of keeping the composer: what has been sent must not still be sitting in
    /// it. Nothing else empties it any more, and a composer returned to after starting a session
    /// would otherwise offer that session's opening prompt, and its images, as though they were
    /// still waiting to be sent. Only once a session exists — a start that failed is the moment
    /// those words matter most, which is why `DraftStore` is cleared on the same answer.
    func testStartingASessionEmptiesTheComposerButAFailedStartDoesNot() throws {
        let composer = SessionComposerViewController()
        _ = composer.view

        let store = ProjectStore.shared
        let project = store.addProject(folderURL: fixtureFolder())
        defer { store.removeProject(id: project.id) }

        let delegate = StartRecorder()
        composer.delegate = delegate
        composer.show(projectID: project.id)

        let imageURL = try makeImageFile()
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let prompt = try XCTUnwrap(promptView(in: composer.view))
        let start = try XCTUnwrap(startButton(in: composer.view))
        prompt.stringValue = "Read this screenshot"
        prompt.attachFiles(at: [imageURL.path])

        delegate.starts = false
        start.performClick()
        XCTAssertEqual(prompt.stringValue, "Read this screenshot", "a failed start took the words")
        XCTAssertEqual(prompt.attachmentPaths, [imageURL.path])

        delegate.starts = true
        start.performClick()
        XCTAssertEqual(
            delegate.prompts.last,
            "Read this screenshot \"\(imageURL.path)\"",
            "the image has to reach the agent as a path"
        )
        XCTAssertEqual(prompt.stringValue, "")
        XCTAssertTrue(prompt.attachmentPaths.isEmpty)

        // And it stays empty when the project is selected again.
        composer.show(projectID: project.id)
        XCTAssertEqual(prompt.stringValue, "")
        XCTAssertTrue(prompt.attachmentPaths.isEmpty)
    }

    func testHeroHidesWhenThePaneIsTooShortToFloatIt() throws {
        let composer = SessionComposerViewController()
        let host = host(composer, size: Render.tall)
        composer.show(projectID: nil)
        host.layoutSubtreeIfNeeded()

        let mark = try XCTUnwrap(threadingMark(in: composer.view))
        XCTAssertFalse(mark.isHiddenOrHasHiddenAncestor, "A tall pane floats the hero")

        host.setFrameSize(Render.short)
        host.layoutSubtreeIfNeeded()
        composer.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(mark.isHiddenOrHasHiddenAncestor, "A short pane shows the composer alone")
    }

    func testComposerSitsFlushWithThePaneBottom() throws {
        let composer = SessionComposerViewController()
        let host = host(composer, size: Render.tall)
        composer.show(projectID: nil)
        host.layoutSubtreeIfNeeded()

        let start = try XCTUnwrap(startButton(in: composer.view))
        let frame = composer.view.convert(start.bounds, from: start)
        // Flipped or not, the action row's edge lands one pane inset above the bottom.
        let gap = composer.view.isFlipped
            ? composer.view.bounds.height - frame.maxY
            : frame.minY
        XCTAssertEqual(
            gap,
            Design.Spacing.pane,
            accuracy: 1,
            "The composer hangs from the pane's bottom edge"
        )
    }

    // MARK: - Renders

    func testRendersTallAndShortUnderSystemAndTwoStyledThemes() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = ProjectStore.shared
        let project = store.addProject(
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("threading-composer-render-\(UUID().uuidString)")
        )
        defer { store.removeProject(id: project.id) }

        let styled = ["Cyberpunk", "Swiss Minimalist"].map { name in
            AppThemeLibrary.stock.first { $0.name == name }
        }
        let themes = try [AppTheme.system] + styled.map { try XCTUnwrap($0) }

        var written = 0
        for theme in themes {
            AppThemePalette.set(theme)
            for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                for (label, size, projectID) in [
                    ("tall", Render.tall, project.id as ProjectID?),
                    ("short", Render.short, project.id as ProjectID?),
                    ("empty", Render.tall, nil)
                ] {
                    var data: Data?
                    appearance.performAsCurrentDrawingAppearance {
                        data = image(
                            size: size,
                            appearance: appearance,
                            theme: theme,
                            projectID: projectID
                        )
                    }
                    let url = directory.appendingPathComponent(
                        "composer-\(theme.id.rawValue)-\(suffix)-\(label).png"
                    )
                    try XCTUnwrap(data, "Failed to render \(theme.name) \(suffix) \(label)")
                        .write(to: url)
                    written += 1
                }
            }
        }
        print("Rendered \(written) composers to \(directory.path)")
        XCTAssertEqual(written, themes.count * 2 * 3)
    }

    // MARK: - Fixtures

    private func fixtureFolder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("threading-composer-\(UUID().uuidString)")
    }

    /// A real PNG on disk: the prompt only previews a file it can decode, and only a path can
    /// be sent to an agent. The name carries a space so the quoting is the same every run.
    private func makeImageFile() throws -> URL {
        let image = NSImage(size: NSSize(width: 12, height: 8))
        image.lockFocus()
        NSColor.systemTeal.drawSwatch(in: NSRect(x: 0, y: 0, width: 12, height: 8))
        image.unlockFocus()

        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString) composer fixture.png")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func host(_ composer: SessionComposerViewController, size: NSSize) -> NSView {
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        let view = composer.view
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        return host
    }

    private func image(
        size: NSSize,
        appearance: NSAppearance,
        theme: AppTheme,
        projectID: ProjectID?
    ) -> Data? {
        let composer = SessionComposerViewController()
        let host = host(composer, size: size)
        host.appearance = appearance
        composer.show(projectID: projectID)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        host.layer?.backgroundColor = theme.resolved(.ground, appearance: appearance).cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Tree walking

    private func startButton(in view: NSView) -> ThemedButton? {
        descendants(of: view).first {
            ($0 as? ThemedButton)?.accessibilityIdentifier() == "composer.session-start.submit"
        } as? ThemedButton
    }

    private func promptView(in view: NSView) -> PromptView? {
        descendants(of: view).first { $0 is PromptView } as? PromptView
    }

    private func threadingMark(in view: NSView) -> ThreadingMarkView? {
        descendants(of: view).first { $0 is ThreadingMarkView } as? ThreadingMarkView
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}

// MARK: - Start Recorder

/// Stands in for `SessionCoordinator`: records what the composer sent, and answers whether a
/// session was made of it — the answer the composer decides on whether to empty itself.
@MainActor
private final class StartRecorder: SessionComposerViewControllerDelegate {

    var starts = true
    private(set) var prompts: [String] = []

    func sessionComposer(
        _ composer: SessionComposerViewController,
        startSessionIn projectID: ProjectID,
        kind: AgentKind,
        accountHandle: AccountHandle,
        model: String?,
        branch: String?,
        usesNativeUI: Bool,
        permissionMode: AgentPermissionMode?,
        prompt: String
    ) -> Bool {
        prompts.append(prompt)
        return starts
    }

    func sessionComposer(
        _ composer: SessionComposerViewController,
        didCreateWorktreeAt url: URL,
        branch: String
    ) {}

    func sessionComposer(
        _ composer: SessionComposerViewController,
        importSession session: ImportableSession,
        into projectID: ProjectID
    ) {}

    func sessionComposer(
        _ composer: SessionComposerViewController,
        didSelectProject projectID: ProjectID
    ) {}

    func sessionComposerDidRequestAddFolder(_ composer: SessionComposerViewController) {}
    func sessionComposerDidRequestNewFolder(_ composer: SessionComposerViewController) {}
}
