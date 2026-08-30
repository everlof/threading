import AppKit
import XCTest
@testable import Threading

/// The launch picker is a transient surface, so its evidence captures the shipping popover
/// chrome and body rather than changing the composer's permanent layout fixture.
@MainActor
final class ModelEffortPickerRenderTests: XCTestCase {
    private var savedTheme: AppTheme?

    override func setUp() {
        super.setUp()
        savedTheme = AppThemePalette.current
        Design.Motion.reduceMotionOverrideForTesting = true
    }

    override func tearDown() {
        if let savedTheme { AppThemePalette.set(savedTheme) }
        savedTheme = nil
        Design.Motion.reduceMotionOverrideForTesting = nil
        super.tearDown()
    }

    func testSelectedCellAnswersBothLaunchValues() {
        var chosenModel: String?
        var chosenEffort: String?
        let controller = ModelEffortPickerViewController(presentation: presentation()) {
            chosenModel = $0
            chosenEffort = $1
        }

        XCTAssertTrue(controller.matrixView.accessibilityPerformPress())
        XCTAssertNil(chosenModel, "the marked default row keeps model inheritance")
        XCTAssertEqual(chosenEffort, "ultra")
        XCTAssertTrue(
            controller.matrixView.subviews.isEmpty,
            "a provider-sized matrix stays one drawing surface, not one view per cell"
        )
    }

    func testAxisHighlightStaysBetweenTheThemesRestingAndHoverStates() throws {
        let pure = try XCTUnwrap(
            AppThemeLibrary.stock.first { $0.name == "Pure" }
        )
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        AppThemePalette.set(pure)

        appearance.performAsCurrentDrawingAppearance {
            let matrix = ModelEffortMatrixControl(
                presentation: presentation(),
                onChoose: { _, _ in }
            )
            let resting = Design.Surface.controlResting.usingColorSpace(.sRGB)
                ?? Design.Surface.controlResting
            let hover = Design.Surface.controlHover.usingColorSpace(.sRGB)
                ?? Design.Surface.controlHover
            let axis = matrix.axisHoverFillForTesting.usingColorSpace(.sRGB)
                ?? matrix.axisHoverFillForTesting

            XCTAssertGreaterThan(axis.alphaComponent, resting.alphaComponent)
            XCTAssertLessThan(axis.alphaComponent, hover.alphaComponent)
        }
    }

    func testRendersTheShippingPopoverUnderDissimilarThemes() throws {
        let directory = renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let cyberpunk = try XCTUnwrap(
            AppThemeLibrary.stock.first { $0.name == "Cyberpunk" }
        )
        let win98 = try XCTUnwrap(
            AppThemeLibrary.stock.first { $0.name == "Windows 98" }
        )
        let pure = try XCTUnwrap(
            AppThemeLibrary.stock.first { $0.name == "Pure" }
        )
        let fixtures: [(String, AppTheme, NSAppearance.Name, (row: Int, column: Int)?)] = [
            ("system-light", .system, .aqua, nil),
            ("system-dark", .system, .darkAqua, nil),
            ("cyberpunk-dark", cyberpunk, .darkAqua, nil),
            ("windows-98-light", win98, .aqua, nil),
            ("pure-dark", pure, .darkAqua, (row: 1, column: 5)),
            ("pure-light", pure, .aqua, (row: 1, column: 5)),
        ]

        for (name, theme, appearanceName, hoveredCell) in fixtures {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var png: Data?
            appearance.performAsCurrentDrawingAppearance {
                png = renderPopover(
                    theme: theme,
                    appearance: appearance,
                    hoveredCell: hoveredCell
                )
            }
            try XCTUnwrap(png, "Failed to render \(name)").write(
                to: directory.appendingPathComponent("model-effort-picker-\(name).png")
            )
        }
    }

    private var renderDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
    }

    private func renderPopover(
        theme: AppTheme,
        appearance: NSAppearance,
        hoveredCell: (row: Int, column: Int)?
    ) -> Data? {
        AppThemePalette.set(theme)

        let parent = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 900, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        parent.appearance = appearance
        parent.isReleasedWhenClosed = false

        let root = NSView(frame: parent.contentView?.bounds ?? .zero)
        root.appearance = appearance
        let anchor = ChipView()
        anchor.configure(symbolName: "cpu", title: "GPT-5.6 Sol")
        anchor.frame = NSRect(
            x: 96,
            y: 500,
            width: 132,
            height: anchor.intrinsicContentSize.height
        )
        root.addSubview(anchor)
        parent.contentView = root
        AppThemeRefresh.repaint(root)

        let controller = ModelEffortPickerViewController(
            presentation: presentation(),
            hiddenModelCount: 2,
            onHideModel: { _ in },
            onShowHiddenModels: {},
            onChoose: { _, _ in }
        )
        if let hoveredCell {
            controller.matrixView.hoverCellForTesting(
                row: hoveredCell.row,
                column: hoveredCell.column
            )
        } else {
            controller.matrixView.hoverModelForTesting(at: 1)
        }
        let popover = HostPopoverFactory.make(.composerModelEffortPicker)
        popover.animates = false
        popover.contentViewController = controller
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        defer { popover.close() }

        guard let panel = popover.presentedWindow,
              let content = panel.contentView else { return nil }
        panel.appearance = appearance
        AppThemeRefresh.repaint(content)
        content.layoutSubtreeIfNeeded()
        content.wantsLayer = true
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            return nil
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func presentation() -> ModelEffortPickerPresentation {
        ModelEffortPickerPresentation(
            models: [
                .init(
                    id: "sol",
                    name: "GPT-5.6 Sol · Default",
                    representedValue: nil,
                    supportedEffortIDs: ["medium", "high", "xhigh", "max", "ultra"]
                ),
                .init(
                    id: "terra",
                    name: "GPT-5.6 Terra",
                    representedValue: "terra",
                    supportedEffortIDs: ["low", "medium", "high", "xhigh", "max", "ultra"]
                ),
                .init(
                    id: "luna",
                    name: "GPT-5.6 Luna",
                    representedValue: "luna",
                    supportedEffortIDs: ["low", "medium", "high", "xhigh", "max"]
                ),
            ],
            efforts: [
                .init(
                    id: ModelEffortPickerPresentation.automaticEffortID,
                    name: "Auto",
                    representedValue: nil
                ),
                .init(id: "low", name: "Light", representedValue: "low"),
                .init(id: "medium", name: "Medium", representedValue: "medium"),
                .init(id: "high", name: "High", representedValue: "high"),
                .init(id: "xhigh", name: "Extra High", representedValue: "xhigh"),
                .init(id: "max", name: "Max", representedValue: "max"),
                .init(id: "ultra", name: "Ultra", representedValue: "ultra"),
            ],
            selectedModelID: "sol",
            selectedEffortID: "ultra"
        )
    }
}
