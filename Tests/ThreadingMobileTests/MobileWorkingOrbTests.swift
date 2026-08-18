import ThreadingRemoteKit
import UIKit
import XCTest
@testable import ThreadingMobile

/// The chat's navigation title says whether the agent is working, and the orb is how it says it.
/// Two separable claims live here: which facts add up to "a turn is in flight" — the phone is
/// never told that in words — and that the mark drawn for it belongs to the Mac's theme rather
/// than to the dependency's own grayscale.
final class MobileAgentTurnActivityTests: XCTestCase {

    /// The signal itself: a client that would be allowed to type, told it cannot.
    func testAnInteractiveViewerToldItCannotSendReadsAsATurnInFlight() {
        XCTAssertTrue(MobileAgentTurnActivity.isWorking(
            isConnected: true,
            capability: .interact,
            canWrite: true,
            canSend: false,
            isPromptSubmissionPending: false
        ))
    }

    func testAnIdleSessionIsNotWorking() {
        XCTAssertFalse(MobileAgentTurnActivity.isWorking(
            isConnected: true,
            capability: .interact,
            canWrite: true,
            canSend: true,
            isPromptSubmissionPending: false
        ))
    }

    /// A view-only viewer is sent `canSend: false` whatever the agent is doing, so the same
    /// bytes mean nothing here. Reading them as work would spin an orb on an idle session for
    /// everyone who was invited to watch one.
    func testAViewOnlyViewerNeverReadsItsOwnLockedComposerAsWork() {
        XCTAssertFalse(MobileAgentTurnActivity.isWorking(
            isConnected: true,
            capability: .view,
            canWrite: false,
            canSend: false,
            isPromptSubmissionPending: false
        ))
    }

    /// Same bytes again, and again not about the agent: a collaborator holding the input control
    /// closes everyone else's composer.
    func testAnotherPersonHoldingTheInputControlIsNotTheAgentWorking() {
        XCTAssertFalse(MobileAgentTurnActivity.isWorking(
            isConnected: true,
            capability: .interact,
            canWrite: false,
            canSend: false,
            isPromptSubmissionPending: false
        ))
    }

    /// Before the connection is up, `canSend` is merely still false from its initial value.
    func testAConnectingSessionIsNotYetWorking() {
        XCTAssertFalse(MobileAgentTurnActivity.isWorking(
            isConnected: false,
            capability: .interact,
            canWrite: true,
            canSend: false,
            isPromptSubmissionPending: false
        ))
    }

    /// The one case that runs ahead of `canSend`: our own prompt is sent and unacknowledged, so
    /// the turn has begun on this side before the Mac has said so.
    func testAPromptStillBeingAcknowledgedAlreadyCountsAsWork() {
        XCTAssertTrue(MobileAgentTurnActivity.isWorking(
            isConnected: true,
            capability: .interact,
            canWrite: true,
            canSend: true,
            isPromptSubmissionPending: true
        ))
    }
}

@MainActor
final class MobileWorkingOrbViewTests: XCTestCase {

    /// A colour claim — "the ink is the theme's accent, not grey" — which no assertion about the
    /// drawing math can make, so it is checked against rendered pixels the way the Mac's own orb
    /// test is. This is also what proves the UIKit front end reaches the fork's `tint` seam at
    /// all: the stock engine draws grayscale and knows nothing of Threading's accent.
    func testTheOrbInksInTheThemeAccent() throws {
        let orb = MobileWorkingOrbView()
        orb.applyTheme(RemoteThemePalette(Self.theme(accent: "#FF0000")))

        let ink = try inkPixels(orb)
        XCTAssertFalse(ink.isEmpty, "the orb painted nothing to sample")

        let reddest = try XCTUnwrap(ink.max { $0.red < $1.red })
        XCTAssertGreaterThan(reddest.red, 0.5)
        XCTAssertLessThan(reddest.green, 0.35)
        XCTAssertLessThan(reddest.blue, 0.35)
        for pixel in ink {
            XCTAssertGreaterThanOrEqual(
                pixel.red + 0.01,
                pixel.green,
                "green-dominant ink under a red accent"
            )
            XCTAssertGreaterThanOrEqual(
                pixel.red + 0.01,
                pixel.blue,
                "blue-dominant ink under a red accent"
            )
        }
    }

    /// A second theme, so the assertion above is about the accent that was applied rather than
    /// about whichever hue the fixture happened to pick.
    func testAnotherAccentMovesTheInkWithIt() throws {
        let orb = MobileWorkingOrbView()
        orb.applyTheme(RemoteThemePalette(Self.theme(accent: "#0000FF")))

        let ink = try inkPixels(orb)
        XCTAssertFalse(ink.isEmpty, "the orb painted nothing to sample")
        for pixel in ink {
            XCTAssertGreaterThanOrEqual(pixel.blue + 0.01, pixel.red, "red-dominant ink under blue")
            XCTAssertGreaterThanOrEqual(pixel.blue + 0.01, pixel.green, "green-dominant ink under blue")
        }
    }

    /// One turn keeps the animation it started with, and the next turn is a different one. The
    /// host only ever calls this on the hidden→visible edge; the no-immediate-repeat rule is the
    /// orb's, so that two consecutive turns are told apart at a glance.
    func testConsecutiveTurnsNeverDrawTheSameVariantTwiceRunning() {
        let orb = MobileWorkingOrbView()
        var seen: [String] = []
        // Always take the first candidate: with no exclusion that is the same state every time,
        // so a repeat here would be the filter failing rather than the chooser hiding it.
        for _ in 0..<4 {
            orb.prepareForWorking(choosingIndex: { $0.lowerBound })
            seen.append(orb.variantName)
        }

        XCTAssertEqual(seen.count, 4)
        for (previous, next) in zip(seen, seen.dropFirst()) {
            XCTAssertNotEqual(previous, next, "a turn repeated the previous turn's animation")
        }
    }

    // MARK: - Helpers

    private struct Pixel {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// Every dot the orb actually painted (alpha above a floor).
    private func inkPixels(_ view: UIView, size: CGFloat = 20) throws -> [Pixel] {
        view.frame = CGRect(x: 0, y: 0, width: size, height: size)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let width = Int(size)
        let height = Int(size)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        view.layer.render(in: context)

        var out: [Pixel] = []
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Double(bytes[index + 3]) / 255
            guard alpha > 0.15 else { continue }
            // The buffer is premultiplied; undo it so a faint dot is compared by hue, not by
            // how much of the transparent ground it is standing on.
            out.append(Pixel(
                red: Double(bytes[index]) / 255 / alpha,
                green: Double(bytes[index + 1]) / 255 / alpha,
                blue: Double(bytes[index + 2]) / 255 / alpha
            ))
        }
        return out
    }

    private static func theme(accent: String) -> RemoteThemeDTO {
        RemoteThemeDTO(
            id: "orb-fixture",
            name: "Orb fixture",
            mode: "dark",
            colors: ["ground": "#000000", "label": "#FFFFFF", "accent": accent],
            material: .init(panelRadius: 8, controlRadius: 6, borderWidth: 1, glow: nil)
        )
    }
}
