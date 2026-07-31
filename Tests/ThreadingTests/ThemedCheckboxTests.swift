import AppKit
import XCTest
@testable import Threading

/// The promoted checkbox: state cycling, accessibility, disabled behavior, and how it draws
/// under deliberately different themes. Extracted from `ThemedAlert`, so the alert's
/// suppression semantics are covered here too.
@MainActor
final class ThemedCheckboxTests: XCTestCase {

    private enum Render {
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

    // MARK: - State

    func testActivationCyclesOffOnAndReportsEachChange() {
        var reported: [NSControl.StateValue] = []
        let checkbox = ThemedCheckbox(title: "Include") { reported.append($0) }

        XCTAssertEqual(checkbox.state, .off)
        XCTAssertTrue(checkbox.performPrimaryAction())
        XCTAssertEqual(checkbox.state, .on)
        XCTAssertTrue(checkbox.performPrimaryAction())
        XCTAssertEqual(checkbox.state, .off)
        XCTAssertEqual(reported, [.on, .off])
    }

    func testActivatingAMixedBoxSelectsEverything() {
        var reported: [NSControl.StateValue] = []
        let checkbox = ThemedCheckbox(title: "Some", state: .mixed) { reported.append($0) }

        XCTAssertTrue(checkbox.performPrimaryAction())
        XCTAssertEqual(checkbox.state, .on)
        XCTAssertEqual(reported, [.on])
    }

    func testProgrammaticStateFollowsDataWithoutReporting() {
        var reported: [NSControl.StateValue] = []
        let checkbox = ThemedCheckbox(title: "Group") { reported.append($0) }

        checkbox.state = .mixed
        XCTAssertEqual(checkbox.state, .mixed)
        XCTAssertTrue(reported.isEmpty, "Following children is not a user change")
    }

    func testDisabledCheckboxRefusesActivation() {
        var reported: [NSControl.StateValue] = []
        let checkbox = ThemedCheckbox(title: "Off limits") { reported.append($0) }
        checkbox.isEnabled = false

        XCTAssertFalse(checkbox.performPrimaryAction())
        XCTAssertEqual(checkbox.state, .off)
        XCTAssertTrue(reported.isEmpty)
    }

    // MARK: - Accessibility

    func testAccessibilityContract() {
        let checkbox = ThemedCheckbox(title: "Include this one") { _ in }

        XCTAssertEqual(checkbox.accessibilityRole(), .checkBox)
        XCTAssertEqual(checkbox.accessibilityTitle(), "Include this one")
        XCTAssertEqual(checkbox.accessibilityValue() as? Int, 0)

        XCTAssertTrue(checkbox.accessibilityPerformPress())
        XCTAssertEqual(checkbox.accessibilityValue() as? Int, 1)

        checkbox.state = .mixed
        XCTAssertEqual(checkbox.accessibilityValue() as? Int, 2, "Mixed is 2, the checkbox convention")
    }

    func testEmptyDrawnTitleStillSpeaks() {
        let checkbox = ThemedCheckbox(title: "", accessibility: "Include Fix login flow") { _ in }
        XCTAssertEqual(checkbox.accessibilityTitle(), "Include Fix login flow")
    }

    // MARK: - Gallery

    func testGalleryTellsItsStory() {
        XCTAssertTrue(
            ComponentGalleryViewController.componentNames.contains("ThemedCheckbox"),
            "A design-system component without a gallery story is invisible to review"
        )
    }

    // MARK: - Renders

    /// System plus two deliberately different themes, light and dark: off, on, mixed, and
    /// disabled in one strip. Balance and legibility are judged by looking, not by asserting.
    func testRendersUnderSystemAndTwoStyledThemes() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let styled = ["Cyberpunk", "Swiss Minimalist"].map { name in
            AppThemeLibrary.stock.first { $0.name == name }
        }
        let themes = try [AppTheme.system] + styled.map { try XCTUnwrap($0) }

        var written = 0
        for theme in themes {
            AppThemePalette.set(theme)
            for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                var data: Data?
                appearance.performAsCurrentDrawingAppearance {
                    data = strip(appearance: appearance, theme: theme)
                }
                let url = directory.appendingPathComponent(
                    "checkbox-\(theme.id.rawValue)-\(suffix).png"
                )
                try XCTUnwrap(data, "Failed to render \(theme.name) \(suffix)").write(to: url)
                written += 1
            }
        }
        print("Rendered \(written) checkbox strips to \(directory.path)")
        XCTAssertEqual(written, themes.count * 2)
    }

    private func strip(appearance: NSAppearance, theme: AppTheme) -> Data? {
        let off = ThemedCheckbox(title: "Off") { _ in }
        let on = ThemedCheckbox(title: "On", state: .on) { _ in }
        let mixed = ThemedCheckbox(title: "Mixed", state: .mixed) { _ in }
        let disabled = ThemedCheckbox(title: "Disabled", state: .on) { _ in }
        disabled.isEnabled = false

        let stack = NSStackView(views: [off, on, mixed, disabled])
        stack.orientation = .horizontal
        stack.spacing = Design.Spacing.large
        stack.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 44))
        host.appearance = appearance
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Design.Spacing.inset),
            stack.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        host.layer?.backgroundColor = theme.resolved(.ground, appearance: appearance).cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
