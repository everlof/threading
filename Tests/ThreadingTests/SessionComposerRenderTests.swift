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
