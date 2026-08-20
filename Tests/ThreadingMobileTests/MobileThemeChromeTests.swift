import ThreadingRemoteKit
import UIKit
import XCTest
@testable import ThreadingMobile

/// The one property iOS lets an authored theme reach on the system keyboard.
///
/// There is no API for tinting keycaps, so `UIKeyboardAppearance` is the whole seam and the only
/// thing to get right is which side of the line a themed background lands on. These pin the
/// saturated cases, where a channel average and perceived luminance disagree most, and pin the
/// keyboard to the same crossover the accent's ink already uses.
final class MobileKeyboardAppearanceTests: XCTestCase {
    func testADarkTerminalKeepsTheDarkKeyboard() {
        XCTAssertEqual(
            MobileKeyboardAppearance.over(UIColor(remoteHex: "#0A0C10")!),
            .dark
        )
    }

    func testAPaperTerminalGetsTheLightKeyboard() {
        XCTAssertEqual(
            MobileKeyboardAppearance.over(UIColor(remoteHex: "#FBF7EE")!),
            .light
        )
    }

    /// A saturated mid-tone, where a channel average and perceived luminance are furthest apart.
    /// Blue contributes least of the three to what the eye reads as brightness, so this stays a
    /// dark background however high its blue channel runs.
    func testASaturatedDeepBlueIsReadAsDark() {
        let background = UIColor(remoteHex: "#12306B")!
        XCTAssertEqual(MobileKeyboardAppearance.over(background), .dark)
        XCTAssertLessThan(
            background.remoteRelativeLuminance ?? 1,
            MobileKeyboardAppearance.lightThreshold
        )
    }

    /// A saturated yellow is the mirror image: bright to the eye, and it needs the light keyboard
    /// even though two of its three channels are at the top of their range.
    func testASaturatedYellowIsReadAsLight() {
        XCTAssertEqual(
            MobileKeyboardAppearance.over(UIColor(remoteHex: "#F2C744")!),
            .light
        )
    }

    /// The accent's ink and the keyboard's appearance answer the same question — "does this
    /// colour read as light?" — so they share one reading of luminance rather than each carrying
    /// a copy of the maths that can drift apart.
    func testTheAccentInkAndTheKeyboardCrossOverTogether() {
        for hex in ["#0A0C10", "#12306B", "#F2C744", "#FBF7EE", "#FFFFFF", "#000000"] {
            let palette = RemoteThemePalette(theme(accent: hex))
            let inkIsDark = palette.uiAccentForeground == UIColor.black
            let backgroundIsLight = MobileKeyboardAppearance.over(
                UIColor(remoteHex: hex)!
            ) == .light
            XCTAssertEqual(
                inkIsDark,
                backgroundIsLight,
                "\(hex) must be light for both the ink beside it and the keyboard under it"
            )
        }
    }

    private func theme(accent: String) -> RemoteThemeDTO {
        RemoteThemeDTO(
            id: "test",
            name: "Test",
            mode: "dark",
            colors: ["accent": accent],
            material: RemoteThemeDTO.Material(
                panelRadius: 20,
                controlRadius: 10,
                borderWidth: 1
            )
        )
    }
}

@MainActor
final class MobileMorphingTitleTests: XCTestCase {
    func testAMountedTitleMorphsWhenItsChatNameChanges() {
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }

        configure(title, text: "First chat", reducesMotion: false)
        window.layoutIfNeeded()
        XCTAssertFalse(title.isAnimatingTitleForTesting)

        configure(title, text: "Renamed chat", reducesMotion: false)

        XCTAssertEqual(title.stringValue, "Renamed chat")
        XCTAssertEqual(title.accessibilityLabel, "Renamed chat")
        XCTAssertTrue(title.isAnimatingTitleForTesting)
    }

    func testReduceMotionLandsAChangedChatNameWithoutAnimation() {
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }

        configure(title, text: "First chat", reducesMotion: false)
        window.layoutIfNeeded()
        configure(title, text: "Renamed chat", reducesMotion: true)

        XCTAssertEqual(title.stringValue, "Renamed chat")
        XCTAssertFalse(title.isAnimatingTitleForTesting)
    }

    func testAConnectionStatusScrollsAsOneLineUnderTheTravelingFade() {
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }

        configure(
            title,
            text: "Opening chat…",
            reducesMotion: false,
            role: .connectionStatus
        )
        window.layoutIfNeeded()
        configure(
            title,
            text: "David's MacBook Pro",
            reducesMotion: false,
            role: .connectionStatus
        )

        XCTAssertEqual(title.stringValue, "David's MacBook Pro")
        XCTAssertTrue(title.isAnimatingLineScrollForTesting)
        XCTAssertTrue(title.isAnimatingTravelingFadeForTesting)
    }

    func testReduceMotionLandsAConnectionStatusWithoutEitherAnimation() {
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }

        configure(
            title,
            text: "Opening chat…",
            reducesMotion: false,
            role: .connectionStatus
        )
        window.layoutIfNeeded()
        configure(
            title,
            text: "David's MacBook Pro",
            reducesMotion: true,
            role: .connectionStatus
        )

        XCTAssertFalse(title.isAnimatingLineScrollForTesting)
        XCTAssertFalse(title.isAnimatingTravelingFadeForTesting)
    }

    func testAConnectionProgressFadeDoesNotChangeItsWords() {
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }

        configure(
            title,
            text: "Trying This network",
            reducesMotion: true,
            role: .connectionProgress
        )
        window.layoutIfNeeded()
        title.playFade()

        XCTAssertEqual(title.stringValue, "Trying This network")
        XCTAssertTrue(title.isAnimatingTravelingFadeForTesting)
        XCTAssertFalse(title.isAnimatingLineScrollForTesting)

        title.stopFade()
        XCTAssertFalse(title.isAnimatingTravelingFadeForTesting)
    }

    func testNavigationStackCompressesALongChatNameWithoutCollapsingIt() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 280, height: 44))
        let title = MobileMorphingTitleLabel()
        configure(title, text: "Review the new remote access feature", reducesMotion: false)
        let status = UILabel()
        status.text = "Connected"
        let stack = UIStackView(arrangedSubviews: [title, status])
        stack.axis = .vertical
        stack.alignment = .center
        stack.frame = host.bounds
        host.addSubview(stack)

        host.layoutIfNeeded()

        XCTAssertEqual(title.frame.width, host.bounds.width, accuracy: 0.5)
        XCTAssertGreaterThan(title.frame.height, 0)
    }

    func testShapeMorphGlyphsUseUIKitCoordinateDirection() throws {
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }

        configure(title, text: "I", reducesMotion: false)
        window.layoutIfNeeded()
        configure(title, text: "P", reducesMotion: false)

        let path = try XCTUnwrap(shapeLayers(in: title.layer).compactMap(\.path).first)
        let box = path.boundingBoxOfPath
        var upperInk = 0
        var lowerInk = 0
        for row in 0..<40 {
            for column in 0..<40 {
                let point = CGPoint(
                    x: box.minX + (CGFloat(column) + 0.5) * box.width / 40,
                    y: box.minY + (CGFloat(row) + 0.5) * box.height / 40
                )
                guard path.contains(point, using: .evenOdd) else { continue }
                if point.y < box.midY {
                    upperInk += 1
                } else {
                    lowerInk += 1
                }
            }
        }

        XCTAssertGreaterThan(upperInk, lowerInk, "P's bowl belongs above its stem on UIKit")
    }

    private func mountedTitle() -> (UIWindow, MobileMorphingTitleLabel) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        let title = MobileMorphingTitleLabel(frame: CGRect(x: 55, y: 80, width: 280, height: 24))
        controller.view.addSubview(title)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return (window, title)
    }

    private func configure(
        _ title: MobileMorphingTitleLabel,
        text: String,
        reducesMotion: Bool,
        role: MobileMorphingTextRole = .chatName
    ) {
        title.configure(
            title: text,
            textStyle: .headline,
            weight: .semibold,
            textColor: .label,
            groundColor: .systemBackground,
            alignment: .center,
            reducesMotion: reducesMotion,
            role: role
        )
    }

    private func shapeLayers(in layer: CALayer) -> [CAShapeLayer] {
        (layer.sublayers ?? []).flatMap { child in
            (child as? CAShapeLayer).map { [$0] } ?? shapeLayers(in: child)
        }
    }
}
