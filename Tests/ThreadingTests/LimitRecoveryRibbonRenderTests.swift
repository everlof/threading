import AppKit
import XCTest
@testable import Threading

/// The exact state from the reported regression: a provider refusal has ended the native agent,
/// the reply composer is gone, and the only remaining answer is to wait for reset.
///
/// This is deliberately a whole `ConversationViewController`, not an isolated ribbon. The defect
/// was the relationship between the ribbon and its shipping host, and an isolated component kept
/// drawing correctly while the real pane floated it through the middle of an empty conversation.
@MainActor
final class LimitRecoveryRibbonRenderTests: XCTestCase {

    private enum Fixture {
        static let width: CGFloat = 900
        static let height: CGFloat = 600

        static var offer: LimitEscapeStripView.Offer {
            LimitEscapeStripView.Offer(
                offersWaitForReset: true,
                bankedResetCount: 2,
                resetHint: "12:40am (Europe/Stockholm)"
            )
        }

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    // MARK: - Shipping Host

    private func exitedConversation(
        appearance: NSAppearance?
    ) -> (controller: ConversationViewController, host: NSView) {
        let session = AgentSession(kind: .codex, title: "Limit", usesNativeUI: true)
        let project = Project(
            name: "Limit",
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        )
        let controller = requireConversationViewController(
            agentSession: session,
            project: project,
            customizationLookup: { _ in .empty }
        )
        controller.view.appearance = appearance

        let host = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: Fixture.width,
            height: Fixture.height
        ))
        host.appearance = appearance
        host.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)
        host.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: Fixture.width),
            host.heightAnchor.constraint(equalToConstant: Fixture.height),
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])

        // Cross the real exit boundary without launching a transport, then drive the same
        // offer/layout seam the store uses in production.
        controller.handleExit(1)
        controller.applyLimitEscapeOffer(Fixture.offer)
        AppThemeRefresh.repaint(host)
        host.layoutSubtreeIfNeeded()
        return (controller, host)
    }

    // MARK: - Regression Boundary

    func testExitedConversationKeepsRecoveryInAPaneWidthTopRibbon() throws {
        let fixture = exitedConversation(appearance: NSAppearance(named: .darkAqua))
        let pane = fixture.controller.view
        let ribbon = fixture.controller.limitEscapeStrip

        XCTAssertTrue(fixture.controller.promptHandoffView.isHidden)
        XCTAssertFalse(ribbon.isHidden)
        XCTAssertEqual(ribbon.frame.minX, pane.bounds.minX, accuracy: 0.5)
        XCTAssertEqual(ribbon.frame.width, pane.bounds.width, accuracy: 0.5)
        XCTAssertEqual(ribbon.frame.maxY, pane.bounds.maxY, accuracy: 0.5)
        XCTAssertEqual(
            fixture.controller.scrollView.frame.maxY,
            ribbon.frame.minY,
            accuracy: 0.5,
            "the transcript did not give the pane ribbon its own row"
        )
        XCTAssertGreaterThan(
            ribbon.frame.midY,
            pane.bounds.height * 0.8,
            "the exited composer's hidden layout pulled the ribbon into the pane"
        )
        XCTAssertEqual(
            ribbon.subviews.compactMap { $0 as? SeparatorView }.count,
            1,
            "the recovery state regressed from a pane ribbon to a floating card"
        )
    }

    // MARK: - Rendered Evidence

    func testRendersExitedConversationRibbonAcrossRepresentativeThemes() throws {
        let directory = Fixture.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let originalTheme = AppThemePalette.current
        defer { AppThemePalette.set(originalTheme) }

        var rendered = 0
        for theme in [AppTheme.system, AppThemeStyles.cyberpunk, AppThemeStyles.swissMinimalist] {
            AppThemePalette.set(theme)
            let variants: [(String, NSAppearance.Name)] = theme.isAdaptive
                ? [("light", .aqua), ("dark", .darkAqua)]
                : [(theme.mode == .dark ? "dark" : "light", theme.mode == .dark ? .darkAqua : .aqua)]

            for (variant, appearanceName) in variants {
                let appearance = NSAppearance(named: appearanceName)
                var data: Data?
                let draw = {
                    let fixture = self.exitedConversation(appearance: appearance)
                    let ribbon = fixture.controller.limitEscapeStrip
                    XCTAssertEqual(ribbon.frame.width, Fixture.width, accuracy: 0.5)
                    guard let representation = fixture.host.bitmapImageRepForCachingDisplay(
                        in: fixture.host.bounds
                    ) else { return }
                    fixture.host.cacheDisplay(in: fixture.host.bounds, to: representation)
                    data = representation.representation(using: .png, properties: [:])
                }

                appearance?.performAsCurrentDrawingAppearance(draw)
                let payload = try XCTUnwrap(
                    data,
                    "The exited conversation drew no \(theme.name) \(variant) evidence"
                )
                let file = "limit-recovery-ribbon-\(theme.id.rawValue)-\(variant).png"
                try payload.write(to: directory.appendingPathComponent(file))
                rendered += 1
            }
        }

        XCTAssertEqual(rendered, 4)
        print("Rendered limit recovery ribbons to \(directory.path)")
    }
}
