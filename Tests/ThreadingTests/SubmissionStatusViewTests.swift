import AppKit
import XCTest
@testable import Threading

@MainActor
final class SubmissionStatusViewTests: XCTestCase {

  /// Found in a render: a refusal in the display panel stayed on one line and widened the panel
  /// and window to fit it. The window here stands in for any host that means to keep its size.
  func testLongOutcomeWrapsInsideItsColumnInsteadOfWideningTheWindow() throws {
    let width: CGFloat = 320
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
      styleMask: [.borderless],
      backing: .buffered,
      defer: true
    )
    window.isReleasedWhenClosed = false
    let content = try XCTUnwrap(window.contentView)
    let status = SubmissionStatusView()
    status.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(status)
    NSLayoutConstraint.activate([
      status.topAnchor.constraint(equalTo: content.topAnchor),
      status.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      status.trailingAnchor.constraint(equalTo: content.trailingAnchor)
    ])

    status.show(
      "No opted-in phone has a live connection or usable push registration. Open Threading on "
        + "the phone to refresh notification delivery.",
      tone: .failed
    )
    content.layoutSubtreeIfNeeded()
    content.layoutSubtreeIfNeeded()

    XCTAssertEqual(window.frame.width, width, accuracy: 0.5)
    XCTAssertEqual(status.frame.width, width, accuracy: 0.5)
    let label = try XCTUnwrap(find(SubmissionStatusDefaults.labelIdentifier, in: status))
    XCTAssertLessThanOrEqual(
      label.alignmentRect(forFrame: label.frame).maxX, status.bounds.maxX + 0.5
    )
    let oneLine = Design.Typography.lineHeight(of: try XCTUnwrap(label.font))
    XCTAssertGreaterThan(label.frame.height, oneLine * 1.5, "the outcome did not wrap")
  }

  private func find(_ identifier: String, in view: NSView) -> NSTextField? {
    if view.accessibilityIdentifier() == identifier, let field = view as? NSTextField {
      return field
    }
    return view.subviews.lazy.compactMap { self.find(identifier, in: $0) }.first
  }
}
