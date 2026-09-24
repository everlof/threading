import AppKit
import XCTest
@testable import Threading

/// The strip scrolls rather than shrinking its tabs, so the tab a person selects has to be moved
/// into view: left where it was, a tab past the clipped edge showed a cut title and half a ×.
@MainActor
final class TabStripSelectionRevealTests: XCTestCase {

  func testSelectingATabPastTheEdgeScrollsItWhollyIntoView() throws {
    let fixture = try makeStrip(width: 240)
    let ids = [UUID(), UUID(), UUID()]
    fixture.strip.update(items: items(ids, active: ids[2]))
    fixture.settle()

    XCTAssertGreaterThan(fixture.clip.bounds.minX, 0, "the strip did not scroll")
    assertWhollyVisible(ids[2], in: fixture)

    fixture.strip.update(items: items(ids, active: ids[0]))
    fixture.settle()
    XCTAssertEqual(fixture.clip.bounds.minX, 0, accuracy: 0.5)
    assertWhollyVisible(ids[0], in: fixture)
  }

  /// A browser retitles its tab constantly; each retitle re-renders the strip. Only a change of
  /// selection may move the row, or it would keep pulling back from where the person scrolled.
  func testAnUpdateThatKeepsTheSelectionLeavesTheScrollAlone() throws {
    let fixture = try makeStrip(width: 240)
    let ids = [UUID(), UUID(), UUID()]
    fixture.strip.update(items: items(ids, active: ids[2]))
    fixture.settle()

    fixture.clip.scroll(to: .zero)
    fixture.scroll.reflectScrolledClipView(fixture.clip)
    fixture.strip.update(items: items(ids, active: ids[2], suffix: " (2)"))
    fixture.settle()

    XCTAssertEqual(fixture.clip.bounds.minX, 0, accuracy: 0.5)
  }

  func testATabAlreadyInViewDoesNotMoveTheRow() throws {
    let fixture = try makeStrip(width: 600)
    let ids = [UUID(), UUID()]
    fixture.strip.update(items: items(ids, active: ids[1]))
    fixture.settle()

    XCTAssertEqual(fixture.clip.bounds.minX, 0, accuracy: 0.5)
  }

  // MARK: - Helpers

  @MainActor
  private struct Fixture {
    let window: NSWindow
    let strip: ThemedTabStripView
    let scroll: ThemedScrollView
    var clip: NSClipView { scroll.contentView }

    func settle() {
      window.contentView?.layoutSubtreeIfNeeded()
      window.contentView?.layoutSubtreeIfNeeded()
    }
  }

  private func makeStrip(width: CGFloat) throws -> Fixture {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 60),
      styleMask: [.borderless], backing: .buffered, defer: true
    )
    window.isReleasedWhenClosed = false
    let content = try XCTUnwrap(window.contentView)
    let strip = ThemedTabStripView(inkSource: .chrome)
    strip.chipMaxWidth = DisplayPaneDefaults.tabChipMaxWidth
    strip.fillsHostWidth = true
    strip.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(strip)
    NSLayoutConstraint.activate([
      strip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      strip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      strip.topAnchor.constraint(equalTo: content.topAnchor),
      strip.widthAnchor.constraint(equalToConstant: width)
    ])
    let scroll = try XCTUnwrap(find(ThemedScrollView.self, in: strip))
    return Fixture(window: window, strip: strip, scroll: scroll)
  }

  private func items(_ ids: [UUID], active: UUID, suffix: String = "") -> [TabStripItem] {
    ids.enumerated().map { index, id in
      TabStripItem(
        id: id,
        title: "A page with a long enough title \(index)\(suffix)",
        symbolName: "globe",
        isActive: id == active
      )
    }
  }

  private func assertWhollyVisible(
    _ id: UUID,
    in fixture: Fixture,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let tab = fixture.strip.chipView(for: id) else {
      return XCTFail("no chip", file: file, line: line)
    }
    let frame = fixture.clip.convert(tab.bounds, from: tab)
    XCTAssertGreaterThanOrEqual(frame.minX, fixture.clip.bounds.minX - 0.5, file: file, line: line)
    XCTAssertLessThanOrEqual(frame.maxX, fixture.clip.bounds.maxX + 0.5, file: file, line: line)
  }

  private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
  }
}
