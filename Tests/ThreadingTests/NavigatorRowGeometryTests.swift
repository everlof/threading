import AppKit
import XCTest
@testable import Threading

@MainActor
final class NavigatorRowGeometryTests: XCTestCase {
    func testMountedProjectRowUsesSharedIconAndTitleSlots() throws {
        let row = ProjectRowView(customizationLookup: { _ in .empty })
        row.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
            row.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        let window = NSWindow(contentRect: host.bounds, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        row.configure(with: Project(name: "Threading", folderURL: URL(fileURLWithPath: "/tmp/Threading")))
        host.layoutSubtreeIfNeeded()

        let icon = try XCTUnwrap(descendants(of: row).first {
            $0.accessibilityIdentifier() == "sidebar.project.identity"
        })
        let title = try XCTUnwrap(descendants(of: row).first {
            $0.accessibilityIdentifier() == "sidebar.project.title"
        })
        let iconFrame = icon.convert(icon.bounds, to: row)
        let titleFrame = title.convert(title.bounds, to: row)
        let geometry = SidebarRowDefaults.geometry
        let slot = geometry.iconRect(in: row.bounds, side: geometry.iconSlotWidth)
        XCTAssertEqual(iconFrame.minX, slot.minX, accuracy: 0.5)
        XCTAssertEqual(iconFrame.width, slot.width, accuracy: 0.5)
        XCTAssertEqual(titleFrame.minX, geometry.titleRect(in: row.bounds, trailingInset: 0).minX,
                       accuracy: 0.5)
        XCTAssertEqual(geometry.titleLeadingOffset, 26)
    }

    func testNarrowTextRegionDoesNotCrossTrailingSlot() {
        let geometry = SidebarRowDefaults.geometry
        let row = NSRect(x: 6, y: 0, width: 30, height: 22)
        let title = geometry.titleRect(in: row, trailingInset: 12)
        XCTAssertEqual(title.minX, row.minX + geometry.titleLeadingOffset)
        XCTAssertEqual(title.width, 0)
        XCTAssertLessThanOrEqual(title.maxX, row.maxX)

        let narrowerRow = NSRect(x: 6, y: 0, width: 12, height: 22)
        let clampedTitle = geometry.titleRect(in: narrowerRow, trailingInset: 12)
        XCTAssertEqual(clampedTitle.minX, narrowerRow.maxX)
        XCTAssertEqual(clampedTitle.width, 0)
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
