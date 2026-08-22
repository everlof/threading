import ThreadingRemoteKit
import UIKit
import XCTest
@testable import ThreadingMobile

final class MobileFloatingSurfaceTests: XCTestCase {
    private struct ColorComponents: Equatable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    func testFloatingChromeUsesItsDedicatedRoleInsteadOfTheTranslucentPanel() throws {
        let palette = RemoteThemePalette(theme(colors: [
            "ground": "#101820",
            "panel": "#FFFFFF0D",
            "elevated": "#263746",
            "floating_surface": "#304A60",
        ]))

        XCTAssertEqual(
            try components(of: palette.uiFloatingSurface),
            try components(of: UIColor(remoteHex: "#304A60")!)
        )
    }

    func testTranslucentFloatingChromeIsFlattenedOverTheThemeGround() throws {
        let palette = RemoteThemePalette(theme(colors: [
            "ground": "#000000",
            "floating_surface": "#FFFFFF80",
        ]))
        let components = try components(of: palette.uiFloatingSurface)

        XCTAssertEqual(components.red, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(components.green, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(components.blue, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(components.alpha, 1, accuracy: 0.001)
    }

    func testAnOlderHostFallsBackToElevatedRatherThanPanel() throws {
        let palette = RemoteThemePalette(theme(colors: [
            "ground": "#101820",
            "panel": "#FFFFFF0D",
            "elevated": "#263746",
        ]))

        XCTAssertEqual(
            try components(of: palette.uiFloatingSurface),
            try components(of: UIColor(remoteHex: "#263746")!)
        )
    }

    private func theme(colors: [String: String]) -> RemoteThemeDTO {
        RemoteThemeDTO(
            id: "floating-surface-test",
            name: "Floating surface test",
            mode: "dark",
            colors: colors,
            material: RemoteThemeDTO.Material(
                panelRadius: 20,
                controlRadius: 10,
                borderWidth: 1
            )
        )
    }

    private func components(
        of color: UIColor
    ) throws -> ColorComponents {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            throw XCTSkip("The test colour did not resolve in sRGB")
        }
        return ColorComponents(red: red, green: green, blue: blue, alpha: alpha)
    }
}

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

    func testAConnectionStatusScrollsAsOneLineUnderTheSharedPulse() {
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

    /// The reported transition is interrupted almost immediately: dashboard status gives way
    /// to "Opening chat…", then the live socket supplies the Mac name. The former five-pulse
    /// traveling wave left the final `Book Pro` bright while the first half flickered. One pulse
    /// beginning everywhere at once keeps even that interrupted handoff one visual line.
    func testAnInterruptedConnectionStatusUsesOneSynchronizedPulse() throws {
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }

        configure(
            title,
            text: "Connected · LAN",
            reducesMotion: false,
            role: .connectionStatus
        )
        window.layoutIfNeeded()
        configure(
            title,
            text: "Opening chat…",
            reducesMotion: false,
            role: .connectionStatus
        )
        configure(
            title,
            text: "David’s MacBook Pro",
            reducesMotion: false,
            role: .connectionStatus
        )

        let fades = animations(
            in: title.layer,
            key: "morph.fade.traveling",
            as: CAKeyframeAnimation.self
        )
        XCTAssertFalse(fades.isEmpty)
        let firstStart = try XCTUnwrap(fades.map(\.beginTime).min())
        let lastStart = try XCTUnwrap(fades.map(\.beginTime).max())
        XCTAssertEqual(lastStart - firstStart, 0, accuracy: 0.001)

        let values = try XCTUnwrap(fades.first?.values as? [NSNumber])
        XCTAssertEqual(values.count, 3, "a breath has one trough, not a flicker train")
        XCTAssertEqual(values[0].floatValue, 1, accuracy: 0.001)
        XCTAssertEqual(values[1].floatValue, 0.66, accuracy: 0.001)
        XCTAssertEqual(values[2].floatValue, 1, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(fades.first).duration,
            MobileDesign.Motion.connectionStatusMorphDuration,
            accuracy: 0.001
        )
    }

    func testAConnectionStatusScrollClearsTheCompleteCaptionLine() throws {
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }

        configure(
            title,
            text: "Opening chat…",
            reducesMotion: false,
            role: .connectionStatus,
            textStyle: .caption2,
            weight: .regular
        )
        window.layoutIfNeeded()
        configure(
            title,
            text: "David’s MacBook Pro",
            reducesMotion: false,
            role: .connectionStatus,
            textStyle: .caption2,
            weight: .regular
        )

        let incomingMoves = animations(
            in: title.layer,
            key: "morph.line.in.translation",
            as: CABasicAnimation.self
        )
        let move = try XCTUnwrap(incomingMoves.first)
        let offset = try XCTUnwrap(move.fromValue as? NSValue).cgSizeValue.height
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .caption2)
            .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.regular]])
        let font = UIFont(descriptor: descriptor, size: 0)
        XCTAssertGreaterThanOrEqual(
            abs(offset),
            font.lineHeight,
            "the incoming line started inside the old line instead of beyond it"
        )
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

    /// The dot moves because the centred phrase beside it changes width. The old-position copy
    /// fades away while the real dot is initially invisible at its new position, so two
    /// warning-coloured connection steps do not reveal that reflow as a teleport.
    func testTheConnectionDotFadesAcrossLayoutWhenTheStatusChangesButItsColorDoesNot() throws {
        let (window, dot) = mountedConnectionDot()
        defer { window.isHidden = true }

        dot.update(color: .systemOrange, status: "Checking connections", reducesMotion: false)
        XCTAssertFalse(dot.isAnimatingTransitionForTesting)

        let oldFrame = dot.convert(dot.bounds, to: window)
        dot.update(color: .systemOrange, status: "Trying LAN", reducesMotion: false)

        let transition = try XCTUnwrap(dot.transitionForTesting)
        let opacity = try XCTUnwrap(
            transition.animations?.compactMap { $0 as? CAKeyframeAnimation }
                .first { $0.keyPath == "opacity" }
        )
        let values = try XCTUnwrap(opacity.values as? [NSNumber])
        XCTAssertEqual(values.map(\.floatValue), [0, 0, 1])
        XCTAssertEqual(
            transition.duration,
            MobileDesign.Motion.connectionStatusMorphDuration,
            accuracy: 0.001
        )

        let departing = try XCTUnwrap(dot.departingIndicatorForTesting)
        XCTAssertEqual(departing.frame, oldFrame)
        let departure = try XCTUnwrap(
            departing.layer.animation(
                forKey: "threading.connection-status-indicator.departing"
            ) as? CABasicAnimation
        )
        XCTAssertEqual(departure.fromValue as? Float, 1)
        XCTAssertEqual(departure.toValue as? Float, 0)
    }

    func testReduceMotionLandsAConnectionDotChangeWithoutAFade() {
        let (window, dot) = mountedConnectionDot()
        defer { window.isHidden = true }

        dot.update(color: .systemOrange, status: "Checking connections", reducesMotion: false)
        dot.update(color: .systemGreen, status: "Connected", reducesMotion: true)

        XCTAssertFalse(dot.isAnimatingTransitionForTesting)
        XCTAssertNil(dot.departingIndicatorForTesting)
        XCTAssertEqual(dot.layer.backgroundColor, UIColor.systemGreen.cgColor)
    }

    func testAConnectionProgressFadeDoesNotChangeItsWords() {
        let (window, title) = mountedTitle()
        defer { window.isHidden = true }

        configure(
            title,
            text: "Trying LAN",
            reducesMotion: true,
            role: .connectionProgress
        )
        window.layoutIfNeeded()
        title.playFade()

        XCTAssertEqual(title.stringValue, "Trying LAN")
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

    private func mountedConnectionDot() -> (UIWindow, MobileConnectionStatusIndicatorView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        let dot = MobileConnectionStatusIndicatorView(
            frame: CGRect(
                x: 100,
                y: 100,
                width: MobileDesign.Size.navigationStatusIndicator,
                height: MobileDesign.Size.navigationStatusIndicator
            )
        )
        controller.view.addSubview(dot)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return (window, dot)
    }

    private func configure(
        _ title: MobileMorphingTitleLabel,
        text: String,
        reducesMotion: Bool,
        role: MobileMorphingTextRole = .chatName,
        textStyle: UIFont.TextStyle = .headline,
        weight: UIFont.Weight = .semibold
    ) {
        title.configure(
            title: text,
            textStyle: textStyle,
            weight: weight,
            textColor: .label,
            groundColor: .systemBackground,
            alignment: .center,
            reducesMotion: reducesMotion,
            role: role
        )
    }

    private func animations<Animation: CAAnimation>(
        in layer: CALayer,
        key: String,
        as type: Animation.Type
    ) -> [Animation] {
        let own = (layer.animation(forKey: key) as? Animation).map { [$0] } ?? []
        return own + (layer.sublayers ?? []).flatMap {
            animations(in: $0, key: key, as: type)
        }
    }

    private func shapeLayers(in layer: CALayer) -> [CAShapeLayer] {
        (layer.sublayers ?? []).flatMap { child in
            (child as? CAShapeLayer).map { [$0] } ?? shapeLayers(in: child)
        }
    }
}
