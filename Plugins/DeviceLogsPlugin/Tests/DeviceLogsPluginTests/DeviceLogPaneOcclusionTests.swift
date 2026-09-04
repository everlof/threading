import AppKit
import XCTest
import ThreadingDesignKit
@testable import DeviceLogsPlugin

/// Two surfaces in this pane stand over moving content: the column header, and the plate the
/// Resume button sits on. Both showed the log through themselves.
///
/// A plain themed button "rests on nothing" by design, which is right for a button on a panel and
/// wrong for one floating over a log. The ground is the pane's job to provide, not the button's.
///
/// The assertion is the invariant rather than a colour: **an opaque surface does not change when
/// what is behind it changes.** That holds under every theme, so it needs no golden image, and it
/// was confirmed to fail without the fix rather than merely to pass with it.
///
/// The column header had the same reported symptom and got the same treatment in
/// `ThemedTableHeaderView`, but there is deliberately **no test for it here**: every fixture I
/// built rendered that header opaque with the fix reverted, so a test would have passed either
/// way and claimed cover it does not have. The header repair stands on reasoning — `controlResting`
/// is documented as below full opacity and the pane's scroll view draws no background — and the
/// condition that actually reproduces it is still unknown.
@MainActor
final class DeviceLogPaneOcclusionTests: XCTestCase {

    // MARK: - The header

    /// The reported defect, reproduced.
    ///
    /// It took a theme to see it. `Design.Surface.controlResting` is opaque under
    /// `AppThemeStyles.threading`, which is the theme every plugin fixture gets by default
    /// (`HostSeam.swift`), and 5% alpha under Swiss Minimalist and most of the palette themes. So
    /// the first version of this test drew an opaque header no matter what the header did, passed
    /// with the repair reverted, and proved nothing — which is why it was deleted rather than kept.
    ///
    /// Nothing opaque stands behind a themed table header anywhere in the app: `ThemedScrollView`
    /// turns its own background off in `init`, and its `tile()` turns the header clip's off too.
    /// The header's own fill is the only occluder there is.
    func testTheHeaderDoesNotShowTheRowsScrollingUnderIt() throws {
        installPaletteTheme()

        let controller = DeviceLogPaneViewController(owningSessionID: UUID().uuidString)
        controller.loadView()
        controller.installRowsForTesting(Self.fixtureRows())
        let host = laidOut(controller.view, width: 900, height: 420)

        let scroll = try XCTUnwrap(
            descendants(of: host).compactMap { $0 as? NSScrollView }.first,
            "the pane should own a scroll view"
        )
        let header = try XCTUnwrap(try XCTUnwrap(scroll.documentView as? NSTableView).headerView)
        let band = header.convert(header.bounds, to: host)

        let before = try pixels(of: host, in: band)
        // Far enough that different rows sit behind the header, and past the first screenful so
        // there is certainly content there to leak through.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 140))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        let after = try pixels(of: host, in: band)

        XCTAssertEqual(
            before, after,
            "the header changed when the rows behind it moved, so it is not opaque"
        )
    }

    // MARK: - The Resume plate

    /// Asserted on the plate alone rather than through the pane, because making it appear needs a
    /// live scroll gesture. The property under test is the plate's, not the pane's.
    func testTheResumePlateHidesWhateverIsBehindIt() throws {
        // What this bites against is a plate that paints *nothing*, which is the bug as reported:
        // the button rested on nothing and the rows ran through it. It cannot bite against a
        // translucent plate, because `elevated` is opaque under every theme that ships — the
        // flattening in `FollowPlateView` guards an authored theme, which no fixture here has.
        installPaletteTheme()

        let plate = FollowPlateView(frame: NSRect(x: 0, y: 0, width: 90, height: 26))

        // Inset past the corner radius: a rounded plate shows the ground at its corners by
        // design, and the claim being made is about the face the button stands on.
        let face = plate.frame.insetBy(dx: Design.Radius.control, dy: Design.Radius.control)
        let onDark = try pixels(of: backdrop(NSColor.black, around: plate), in: face)
        let onStripes = try pixels(of: backdrop(NSColor.white, around: plate), in: face)

        XCTAssertEqual(
            onDark, onStripes,
            "the plate changed with what was behind it, so the Resume button would be read over the log"
        )
    }

    // MARK: - Harness

    private var restoreTheme: AppTheme?

    override func tearDown() {
        if let restoreTheme { AppThemePalette.install(restoreTheme) }
        restoreTheme = nil
        super.tearDown()
    }

    /// A theme whose resting control fill is nearly transparent, which is the condition the
    /// reported defect needs and the default plugin-test theme does not have.
    private func installPaletteTheme() {
        restoreTheme = AppThemePalette.current
        AppThemePalette.install(AppThemeStyles.swissMinimalist)
    }

    private static func fixtureRows() -> [DeviceLogRow] {
        (0..<40).map { index in
            DeviceLogRow(
                time: String(format: "11:01:%02d.493", index % 60),
                level: index % 5 == 0 ? "Error" : "Debug",
                process: "Kronaby",
                subsystem: "bluetooth",
                message: "WatchProviderStub.swift:121 handle(event:) entry \(index)"
            )
        }
    }

    /// A fresh plate over a fresh backdrop, so the two renders differ only in what is behind.
    private func backdrop(_ color: NSColor, around plate: FollowPlateView) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: plate.frame.width, height: plate.frame.height))
        host.wantsLayer = true
        host.layer?.backgroundColor = color.cgColor
        let copy = FollowPlateView(frame: plate.frame)
        host.addSubview(copy)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func laidOut(_ view: NSView, width: CGFloat, height: CGFloat) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            host.widthAnchor.constraint(equalToConstant: width),
            host.heightAnchor.constraint(equalToConstant: height),
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// The bytes of one rectangle, so two renders can be compared without a golden image.
    private func pixels(of view: NSView, in rect: NSRect) throws -> Data {
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)

        // Two conversions, and leaving either out reads as a defect in the code under test.
        //
        // Offscreen representations are backing-scaled, so a point rectangle is not a pixel one.
        // And `CGImage` counts from the top left while an unflipped `NSView` counts from the
        // bottom left — sampling without that flip took a band from the wrong end of the pane,
        // which showed log rows and looked exactly like a see-through header.
        let scale = CGFloat(representation.pixelsWide) / view.bounds.width
        let cropped = NSRect(
            x: rect.minX * scale,
            y: (view.bounds.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral.intersection(
            NSRect(x: 0, y: 0, width: representation.pixelsWide, height: representation.pixelsHigh)
        )
        let image = try XCTUnwrap(representation.cgImage)
        let slice = try XCTUnwrap(image.cropping(to: cropped))

        let bitmap = NSBitmapImageRep(cgImage: slice)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

/// Hiding the pane must not throw away what it has already read.
///
/// Switching to another tab or another chat and coming back wiped the whole log. The cause was one
/// line: `viewWillDisappear` cleared `runningSourceTitle` along with the reader, so the next
/// `viewDidAppear` could not tell "resume the source I was on" from "the user picked a different
/// source" — and the second of those correctly discards the rows, because they are no longer about
/// the thing being read.
///
/// Asserted on the identity rather than by driving appear/disappear end to end: `viewDidAppear`
/// starts source discovery, which spawns child processes and takes tens of seconds, and a test
/// that slow would not be run.
@MainActor
final class DeviceLogPaneResumeTests: XCTestCase {

    func testHidingThePaneStopsReadingWithoutForgettingWhatTheRowsAreAbout() {
        let controller = DeviceLogPaneViewController(owningSessionID: UUID().uuidString)
        controller.loadView()
        controller.setRunningSourceTitleForTesting("Kronaby#app")

        controller.viewWillDisappear()

        XCTAssertFalse(controller.isReadingForTesting, "a hidden tab must not keep a reader alive")
        XCTAssertEqual(
            controller.runningSourceTitleForTesting, "Kronaby#app",
            "the pane forgot which source its rows came from, so re-appearing will discard them"
        )
    }
}
