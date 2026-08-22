import AppKit
import XCTest
@testable import Threading

/// The pointer over the session pane's corner card.
///
/// Cursor rectangles are a *window's* list. The card is opaque chrome floating over a terminal —
/// and `TerminalView` claims an I-beam over the whole of itself — so a part of the card claiming
/// nothing does not fall back to the arrow, it inherits that I-beam. The usage and children rows
/// are buttons, and they were answering the pointer with a promise of text.
@MainActor
final class GitStatusCardPointerTests: XCTestCase {

    private enum Fixture {
        static let hostSize = NSSize(width: 620, height: 420)
        static let branch = "master"
        static let summary = GitChangeSummary(files: 62, added: 4_600, removed: 425)
    }

    // MARK: - Fixture

    /// The card as the pane holds it: pinned into a host that states its own size, since a
    /// detached view with a frame constrains nothing.
    private func card(withGitSentence hasGitSentence: Bool) -> GitStatusOverlayView {
        let host = NSView(frame: NSRect(origin: .zero, size: Fixture.hostSize))
        let card = GitStatusOverlayView()
        host.addSubview(card)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: Fixture.hostSize.width),
            host.heightAnchor.constraint(equalToConstant: Fixture.hostSize.height),
            card.topAnchor.constraint(equalTo: host.topAnchor, constant: Design.Spacing.medium),
            card.trailingAnchor.constraint(
                equalTo: host.trailingAnchor,
                constant: -Design.Spacing.medium
            )
        ])

        if hasGitSentence {
            card.update(with: GitChangeMonitor.Reading(
                branch: Fixture.branch,
                summary: Fixture.summary
            ))
        }
        card.updateUsage(SessionUsageSnapshot.Reading(unindexedTokens: 5_800_000))
        card.updateSubagents(workingCount: 0, doneCount: 18, tokenCount: 556_300_000)
        host.layoutSubtreeIfNeeded()
        return card
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private func branchRow(in card: GitStatusOverlayView) -> NSRect? {
        descendants(of: card)
            .first { ($0 as? NSTextField)?.stringValue.contains(Fixture.branch) ?? false }
            .map { $0.convert($0.bounds, to: card) }
    }

    /// The row a given destination is reached from, in the card's own coordinates.
    private func row(in card: GitStatusOverlayView, opening destination: String) throws -> NSRect {
        let button = try XCTUnwrap(
            descendants(of: card).first {
                ($0 as? ThemedButton).map { !$0.isHidden && $0.accessibilityHelp() == destination }
                    ?? false
            },
            "the card should carry a row opening \(destination)"
        )
        return button.convert(button.bounds, to: card)
    }

    private func cursor(in card: GitStatusOverlayView, at point: NSPoint) throws -> NSCursor {
        let claims = card.resolvedPointerClaims().filter { $0.rect.contains(point) }
        XCTAssertEqual(claims.count, 1, "exactly one claim answers a point on the card")
        return try XCTUnwrap(claims.first?.cursor)
    }

    // MARK: - Tests

    func testTheCardClaimsEveryPointItCoversSoNothingBehindItAnswersThePointer() throws {
        let card = card(withGitSentence: true)
        let claims = card.resolvedPointerClaims()

        XCTAssertFalse(claims.isEmpty)
        for claim in claims {
            XCTAssertEqual(
                claim.rect, card.bounds.intersection(claim.rect),
                "a claim reaching past the card would answer for the pane beside it"
            )
        }
        for (index, claim) in claims.enumerated() {
            for other in claims[claims.index(after: index)...] {
                XCTAssertFalse(
                    claim.rect.intersects(other.rect),
                    "overlapping cursor rectangles are undefined; the acting region is carved out"
                )
            }
        }
        let claimed = claims.reduce(0) { $0 + $1.rect.width * $1.rect.height }
        XCTAssertEqual(
            claimed, card.bounds.width * card.bounds.height, accuracy: 0.5,
            "disjoint claims summing to the card's own area cover all of it and no more"
        )
    }

    func testTheActingRowsKeepTheHandAndTheRowsBelowThemTakeTheArrow() throws {
        let card = card(withGitSentence: true)
        let branch = try XCTUnwrap(
            branchRow(in: card),
            "the card should be showing the branch it was given"
        )

        XCTAssertEqual(
            try cursor(in: card, at: NSPoint(x: branch.midX, y: branch.midY)),
            NSCursor.pointingHand,
            "the branch and counters rows open Git Review, and have said so all along"
        )
        for destination in ["Open Session Info", "Open Subagents"] {
            let row = try row(in: card, opening: destination)
            XCTAssertEqual(
                try cursor(in: card, at: NSPoint(x: row.midX, y: row.midY)),
                NSCursor.arrow,
                "\(destination) is a button, and a button here answers as every other one does"
            )
        }
    }

    func testACardWithNoGitSentenceClaimsAllOfItselfForTheArrow() {
        let card = card(withGitSentence: false)

        XCTAssertNil(branchRow(in: card), "no branch, so no row that opens Git Review")
        XCTAssertEqual(card.resolvedPointerClaims().count, 1)
        XCTAssertEqual(card.resolvedPointerClaims().first?.rect, card.bounds)
        XCTAssertEqual(card.resolvedPointerClaims().first?.cursor, NSCursor.arrow)
    }
}
