import AppKit
import XCTest
@testable import Threading

@MainActor
final class ToastSizingTests: XCTestCase {
    private var previousTheme = AppThemeLibrary.current
    private var previousMotion: Bool?

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            previousTheme = AppThemeLibrary.current
            previousMotion = Design.Motion.reduceMotionOverrideForTesting
            Design.Motion.reduceMotionOverrideForTesting = true
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            AppThemeLibrary.apply(previousTheme)
            Design.Motion.reduceMotionOverrideForTesting = previousMotion
        }
        try await super.tearDown()
    }

    func testLongTextKeepsTheReceiptAndItsControlsInsideThePane() throws {
        let themes: [AppTheme] = [
            .system, AppThemeStyles.cyberpunk, AppThemeStyles.swissMinimalist,
            AppThemeStyles.claymorphism, AppThemeStyles.win98
        ]
        let message = String(repeating: "Archived a session with a long name ", count: 40)
        let detail = String(repeating: "A full report with paths, results and next steps.\n\n", count: 128)
        for theme in themes {
            AppThemePalette.set(theme)
            for width in [SidebarDefaults.minWidth, SidebarDefaults.defaultWidth, 460] {
                let (host, presenter, window) = pane(width: width)
                defer { presenter.invalidate() }
                var undoCount = 0
                let request = ToastRequest(
                    message: message, detail: detail,
                    actionTitle: "Undo", action: { undoCount += 1 },
                    persistsUntilDismissed: true
                )
                presenter.present(request)
                host.layoutSubtreeIfNeeded()
                let toast = try XCTUnwrap(presenter.current)
                XCTAssertLessThan(toast.frame.height, 180, "\(theme.name), \(width)pt")
                XCTAssertTrue(host.bounds.contains(toast.frame))
                XCTAssertEqual(toast.request.detail, detail)
                XCTAssertEqual(toast.accessibilityLabel(), request.announcement)

                let controls = descendants(in: toast).compactMap { $0 as? ThemedControl }
                for control in controls {
                    XCTAssertTrue(toast.bounds.contains(control.convert(control.bounds, to: toast)))
                    let center = NSPoint(x: control.bounds.midX, y: control.bounds.midY)
                    let hit = try XCTUnwrap(host.hitTest(control.convert(center, to: host.superview)))
                    XCTAssertTrue(hit === control || hit.isDescendant(of: control))
                }
                try XCTUnwrap(controls.compactMap { $0 as? ThemedButton }.first).performClick()
                XCTAssertEqual(undoCount, 1)
                XCTAssertNil(presenter.current)
                XCTAssertFalse(window.isVisible)
            }
        }
    }

    func testReplacementAndResizeKeepLongReportsCompact() throws {
        let (host, presenter, window) = pane(width: 460)
        defer { presenter.invalidate() }
        presenter.present(ToastRequest(
            message: "Automation running", detail: "Checking the device",
            persistsUntilDismissed: true, replacementID: "automation"
        ))
        let toast = try XCTUnwrap(presenter.current)
        let report = String(repeating: "Full results and next steps.\n", count: 256)
        presenter.present(ToastRequest(
            message: "Automation completed", detail: report,
            persistsUntilDismissed: true, replacementID: "automation"
        ))
        XCTAssertTrue(presenter.current === toast)
        for width in [SidebarDefaults.minWidth, 460, SidebarDefaults.defaultWidth] {
            window.setContentSize(NSSize(width: width, height: 400))
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThan(toast.frame.height, 120)
            XCTAssertTrue(host.bounds.contains(toast.frame))
        }
        XCTAssertEqual(toast.request.detail, report)
    }

    /// A line cap alone still hands AppKit the complete input. Include a single enormous
    /// grapheme as well as ordinary prose so the preparation bound is in scalars, not letters.
    func testLargeInputsAreBoundedBeforeTextLayout() throws {
        for text in [String(repeating: "Report ", count: 150_000),
                     "A" + String(repeating: "\u{0301}", count: 150_000)] {
            let toast = ToastView(request: ToastRequest(message: text, detail: text))
            let labels = descendants(in: toast).compactMap { $0 as? NSTextField }
            XCTAssertEqual(labels.count, 2)
            for label in labels {
                XCTAssertLessThanOrEqual(label.stringValue.unicodeScalars.count,
                                         ToastDefaults.maximumPreviewScalars + 1)
                XCTAssertTrue(label.stringValue.hasSuffix("…"))
            }
            XCTAssertEqual(toast.request.message, text)
            XCTAssertEqual(toast.request.detail, text)
        }
    }

    private func pane(width: CGFloat) -> (NSView, ToastPresenter, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host
        let footer = PaneFooterView()
        host.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        return (host, ToastPresenter(host: host, above: footer.topAnchor), window)
    }

    private func descendants(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(in: $0) }
    }
}
