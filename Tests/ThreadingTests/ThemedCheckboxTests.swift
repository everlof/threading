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

    func testRadioButtonSelectsWithoutTogglingItsSelectedState() {
        var reported: [NSControl.StateValue] = []
        let radio = ThemedRadioButton(title: "Use compact", state: .on) {
            reported.append($0)
        }

        XCTAssertEqual(radio.accessibilityRole(), .radioButton)
        XCTAssertEqual(radio.accessibilityValue() as? Bool, true)
        XCTAssertTrue(radio.performPrimaryAction())
        XCTAssertEqual(radio.state, .on)
        XCTAssertTrue(reported.isEmpty, "selecting an already-selected radio should be inert")

        radio.state = .off
        XCTAssertTrue(radio.performPrimaryAction())
        XCTAssertEqual(radio.state, .on)
        XCTAssertEqual(reported, [.on])
    }

    func testWin98RadioButtonUsesACompactCircularFieldAndDot() throws {
        AppThemePalette.set(AppThemeStyles.win98)
        let radio = ThemedRadioButton(title: "", state: .on) { _ in }
        radio.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        let rep = try XCTUnwrap(radio.bitmapImageRepForCachingDisplay(in: radio.bounds))
        radio.cacheDisplay(in: radio.bounds, to: rep)

        XCTAssertEqual(radio.intrinsicContentSize.height, Design.Size.chipHeight)
        XCTAssertEqual(radio.intrinsicContentSize.width, 20, accuracy: 0.01)
        let centre = try XCTUnwrap(rep.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(centre.redComponent, 0, accuracy: 0.05)
        XCTAssertEqual(centre.greenComponent, 0, accuracy: 0.05)
        XCTAssertEqual(centre.blueComponent, 0, accuracy: 0.05)
    }

    // MARK: - Gallery

    func testGalleryTellsItsStory() {
        XCTAssertTrue(
            ComponentGalleryViewController.componentNames.contains("ThemedCheckbox"),
            "A design-system component without a gallery story is invisible to review"
        )
        XCTAssertTrue(
            ComponentGalleryViewController.componentNames.contains("ThemedRadioButton"),
            "A design-system radio control without a gallery story is invisible to review"
        )
    }

    // MARK: - Focus

    /// The rule the alert's default button broke, in the control beside it.
    ///
    /// A ring is stroked inside whatever silhouette it is handed, and a **checked** box is filled
    /// with the accent — so the ring, which defaults to the accent, was the accent drawn on the
    /// accent. A checked checkbox said nothing at all about where the keyboard was, on every
    /// theme, while the unchecked one beside it rang clearly. It is rung from outside now, in
    /// margin the control reserves, which is also the only treatment that reads the same in all
    /// three states instead of vanishing in two of them.
    func testAFocusedCheckboxSaysSoInEveryState() throws {
        for state: NSControl.StateValue in [.off, .on, .mixed] {
            let checkbox = ThemedCheckbox(title: "", state: state) { _ in }
            checkbox.frame = NSRect(origin: .zero, size: checkbox.intrinsicContentSize)

            let window = NSWindow(
                contentRect: checkbox.bounds,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(checkbox)

            let resting = try rendered(checkbox)
            XCTAssertTrue(window.makeFirstResponder(checkbox))
            let focused = try rendered(checkbox)

            // Asserted on the *ink*, not on the bytes. Comparing the two PNGs passes on the
            // accent-on-accent drawing this test exists to catch: stroking a colour over the
            // antialiased pixels of a corner already painted that colour moves a handful of
            // them a shade, so the images differ while the picture does not.
            XCTAssertGreaterThan(
                changedPixels(resting, focused),
                40,
                "a \(state == .off ? "clear" : "filled") box drew no visible focus treatment"
            )
        }
    }

    private func rendered(_ view: NSView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// How many pixels a reader would call different — a shade apart is not a focus ring.
    private func changedPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        var count = 0
        for x in 0..<min(a.pixelsWide, b.pixelsWide) {
            for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
                guard let first = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let second = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let delta = max(
                    abs(first.redComponent - second.redComponent),
                    abs(first.greenComponent - second.greenComponent),
                    abs(first.blueComponent - second.blueComponent)
                )
                if delta > 0.2 { count += 1 }
            }
        }
        return count
    }

    // MARK: - Renders

    /// System plus two deliberately different themes, light and dark: off, on, mixed, disabled
    /// and focused in one strip. Balance and legibility are judged by looking, not by asserting —
    /// which is why the focused box earns a place in it. Where the keyboard is was drawn on a
    /// checked box in the accent, on the accent, and no assertion anyone had written could see
    /// that there was nothing there.
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
        let focused = ThemedCheckbox(title: "Focused", state: .on) { _ in }

        let stack = NSStackView(views: [off, on, mixed, disabled, focused])
        stack.orientation = .horizontal
        stack.spacing = Design.Spacing.large
        stack.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 44))
        host.appearance = appearance
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Design.Spacing.inset),
            stack.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])
        host.layoutSubtreeIfNeeded()

        // A window, never ordered on screen: a control only draws its ring while it *is* the
        // first responder, and a view with no window can never be one. Unshown keeps this clear
        // of the host's termination trap — see CLAUDE.md.
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(host)
        window.makeFirstResponder(focused)

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        host.layer?.backgroundColor = theme.resolved(.ground, appearance: appearance).cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
