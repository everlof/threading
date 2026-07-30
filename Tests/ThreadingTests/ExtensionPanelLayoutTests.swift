import AppKit
import XCTest
@testable import Threading
import ThreadingExtensionKit

/// Pins the panel host's readable inset. The content stack always *declared*
/// `Design.Spacing.pane` on every edge — and the GitHub Checks panel still rendered flush
/// against the pane's edge, because each row was pinned to the stack's full width, the
/// trailing inset became unsatisfiable, and the solver broke the leading pin. Frames, not
/// constraints, are what this asserts, since the constraints were "right" the whole time.
@MainActor
final class ExtensionPanelLayoutTests: XCTestCase {

    private final class FakeRouter: ExtensionPanelRouting {
        var item: ExtensionPanelInventoryItem?

        var extensionPanelInventory: [ExtensionPanelInventoryItem] {
            item.map { [$0] } ?? []
        }

        func registeredPanel(
            extensionIdentifier: String,
            panelID: String
        ) -> ExtensionPanelInventoryItem? {
            item
        }

        func extensionImageResourceURL(
            extensionIdentifier: String,
            relativePath: String
        ) -> URL? {
            nil
        }

        func invokePanelAction(
            extensionIdentifier: String,
            panelID: String,
            actionID: String,
            context: ExtensionCommandContext,
            completion: @escaping (Result<ExtensionActionResponse, Error>) -> Void
        ) -> Bool {
            // Deliberately never completes: the test reads the panel's *registered* value.
            true
        }
    }

    private func laidOutPanel(
        _ panel: ExtensionPanel,
        width: CGFloat = 360
    ) -> (host: NSView, controller: ExtensionPanelViewController) {
        let router = FakeRouter()
        router.item = ExtensionPanelInventoryItem(
            extensionIdentifier: "com.example.checks",
            extensionName: "Checks",
            processGeneration: "generation-one",
            panel: panel
        )
        let controller = ExtensionPanelViewController(
            extensionIdentifier: "com.example.checks",
            panelID: panel.id,
            title: panel.title,
            context: ExtensionCommandContext(),
            router: router
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return (host, controller)
    }

    func testPanelContentKeepsThePaneInsetOnBothSides() throws {
        let panel = ExtensionPanel(
            id: "checks",
            title: "Checks",
            root: .stack(
                axis: .vertical,
                spacing: .medium,
                children: [
                    .text("everlof/threading", role: .heading),
                    .status("Couldn't read checks", role: .warning),
                    .text(
                        "GitHub doesn't have this commit — it hasn't been pushed.",
                        role: .detail
                    )
                ]
            )
        )
        let (host, controller) = laidOutPanel(panel)

        let rendered = try XCTUnwrap(
            view(
                withIdentifierPrefix: "extension.panel.com.example.checks",
                under: controller.view
            ),
            "the rendered panel root went missing"
        )
        let frame = rendered.superview!.convert(rendered.frame, to: host)
        XCTAssertEqual(
            frame.minX, Design.Spacing.pane, accuracy: 0.5,
            "content lost its leading pane inset"
        )
        XCTAssertEqual(
            frame.maxX, host.bounds.width - Design.Spacing.pane, accuracy: 0.5,
            "content overflows the trailing pane inset"
        )
    }

    func testTheUnavailableStateKeepsTheSameInset() throws {
        let router = FakeRouter()
        let controller = ExtensionPanelViewController(
            extensionIdentifier: "com.example.checks",
            panelID: "checks",
            title: "Checks",
            context: ExtensionCommandContext(),
            router: router
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()

        let unavailable = try XCTUnwrap(
            view(withIdentifierPrefix: "extension.panel.unavailable", under: controller.view)
        )
        // A text field's frame carries AppKit's 2pt halo outside its alignment rect, and the
        // stack aligns by the rect — so measure the rect, which is where the ink is.
        let frame = unavailable.alignmentRect(
            forFrame: unavailable.superview!.convert(unavailable.frame, to: host)
        )
        XCTAssertEqual(frame.minX, Design.Spacing.pane, accuracy: 0.5)
        XCTAssertEqual(
            frame.maxX, host.bounds.width - Design.Spacing.pane, accuracy: 0.5
        )
    }

    private func view(withIdentifierPrefix prefix: String, under root: NSView) -> NSView? {
        if root.accessibilityIdentifier().hasPrefix(prefix) { return root }
        for child in root.subviews {
            if let found = view(withIdentifierPrefix: prefix, under: child) { return found }
        }
        return nil
    }
}
