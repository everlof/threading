import SwiftUI
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
            mode: .dark,
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

@MainActor
final class MobileThemedPopoverChromeTests: XCTestCase {
    func testThemeDoesNotReplaceUIKitManagedShadowPath() throws {
        let view = MobileThemedPopoverBackgroundView(
            frame: CGRect(x: 0, y: 0, width: 100, height: 80)
        )
        view.arrowDirection = .down
        view.apply(.init(
            fill: .white,
            border: .black,
            borderWidth: 2,
            cornerRadius: 0
        ))
        view.layoutIfNeeded()

        let shadowBounds = try XCTUnwrap(view.layer.shadowPath).boundingBoxOfPath
        XCTAssertGreaterThan(
            shadowBounds.minX,
            view.bounds.minX,
            "the theme must not replace UIKit's inset shadow with its body outline"
        )
        XCTAssertLessThan(
            shadowBounds.maxY,
            view.bounds.maxY,
            "UIKit's shadow excludes the arrow instead of following the theme's full outline"
        )
    }

    func testThemeRadiusReachesTheOuterCornerAndArrowHasNoBodySeam() throws {
        let view = MobileThemedPopoverBackgroundView(
            frame: CGRect(x: 0, y: 0, width: 100, height: 80)
        )
        view.arrowDirection = .down
        view.arrowOffset = 0
        view.apply(.init(
            fill: .black,
            border: .white,
            borderWidth: 2,
            cornerRadius: 3
        ))
        view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }

        XCTAssertGreaterThan(
            try rgba(in: image, at: CGPoint(x: 3, y: 1)).alpha,
            200,
            "a 3-point authored radius must not retain UIKit's large popover corner"
        )
        XCTAssertGreaterThan(
            try rgba(in: image, at: CGPoint(x: 10, y: 67)).red,
            200,
            "the ordinary bottom edge keeps the theme border"
        )
        XCTAssertLessThan(
            try rgba(in: image, at: CGPoint(x: 50, y: 67)).red,
            40,
            "the arrow repaints the body border at its base instead of leaving an internal rule"
        )
    }

    private func rgba(in image: UIImage, at point: CGPoint) throws -> RGBA {
        let cgImage = try XCTUnwrap(image.cgImage)
        let cropped = try XCTUnwrap(cgImage.cropping(to: CGRect(
            x: Int(point.x),
            y: Int(point.y),
            width: 1,
            height: 1
        )))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return RGBA(red: bytes[0], alpha: bytes[3])
    }

    private struct RGBA {
        let red: UInt8
        let alpha: UInt8
    }
}

@MainActor
final class MobileRootBackdropTests: XCTestCase {
    /// During an interactive pop, SwiftUI lays the destination out only above the still-focused
    /// keyboard. A background attached to that content stops at the same height, exposing the
    /// hosting view below. The root backdrop must keep painting independently of that short view.
    func testBackdropPaintsBelowKeyboardSizedNavigationContent() throws {
        let ground = UIColor(red: 31 / 255, green: 31 / 255, blue: 31 / 255, alpha: 1)
        let root = MobileRootBackdrop(ground: Color(uiColor: ground)) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 520)
        }
        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = .black
        let window = hostedWindow(rootViewController: controller)
        defer { window.isHidden = true }

        let screenshot = UIGraphicsImageRenderer(
            bounds: window.bounds,
            format: onePixelPointFormat
        ).image { context in
            window.layer.render(in: context.cgContext)
        }
        let pixel = try rgba(in: screenshot, at: CGPoint(x: 20, y: 820))

        XCTAssertEqual(pixel.red, 31, accuracy: 1)
        XCTAssertEqual(pixel.green, 31, accuracy: 1)
        XCTAssertEqual(pixel.blue, 31, accuracy: 1)
        XCTAssertEqual(pixel.alpha, 255, accuracy: 1)
    }

    private var onePixelPointFormat: UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return format
    }

    private func hostedWindow(rootViewController: UIViewController) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()
        return window
    }

    private func rgba(in image: UIImage, at point: CGPoint) throws -> RGBA {
        let cgImage = try XCTUnwrap(image.cgImage)
        let cropped = try XCTUnwrap(cgImage.cropping(to: CGRect(
            x: Int(point.x),
            y: Int(point.y),
            width: 1,
            height: 1
        )))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return RGBA(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes[3])
    }

    private struct RGBA {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }
}

/// The one property iOS lets an authored theme reach on the system keyboard.
///
/// There is no API for tinting keycaps, so `UIKeyboardAppearance` is the whole seam and the only
/// thing to get right is which side of the line a themed background lands on. These pin the
/// saturated cases, where a channel average and perceived luminance disagree most, and pin the
/// keyboard to the same crossover the accent's ink already uses.
final class MobileKeyboardAppearanceTests: XCTestCase {
    func testApplicationSurfaceModesResolveToExplicitKeyboardAppearances() {
        XCTAssertEqual(MobileKeyboardAppearance.matching(.light), .light)
        XCTAssertEqual(MobileKeyboardAppearance.matching(.dark), .dark)
    }

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
            mode: .dark,
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
final class SessionDraftKeyboardAppearanceTests: XCTestCase {
    func testEditorPinsItsLightAppearanceBeforeTakingFocus() throws {
        let (window, textView) = try mountedEditor(theme: theme(mode: .light))
        defer { window.isHidden = true }

        XCTAssertEqual(textView.keyboardAppearance, .light)
        XCTAssertFalse(textView.isFirstResponder)
    }

    func testEditorPinsItsDarkAppearanceBeforeTakingFocus() throws {
        let (window, textView) = try mountedEditor(theme: theme(mode: .dark))
        defer { window.isHidden = true }

        XCTAssertEqual(textView.keyboardAppearance, .dark)
        XCTAssertFalse(textView.isFirstResponder)
    }

    private func mountedEditor(
        theme: RemoteThemePalette
    ) throws -> (UIWindow, IntrinsicTextView) {
        let controller = UIHostingController(rootView: Harness(theme: theme))
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()
        return (window, try XCTUnwrap(descendant(of: IntrinsicTextView.self, in: window)))
    }

    private func descendant<T: UIView>(of type: T.Type, in root: UIView) -> T? {
        if let root = root as? T { return root }
        return root.subviews.lazy.compactMap { self.descendant(of: type, in: $0) }.first
    }

    private func theme(mode: RemoteThemeMode) -> RemoteThemePalette {
        RemoteThemePalette(RemoteThemeDTO(
            id: "draft-keyboard-\(mode.rawValue)",
            name: "Draft keyboard",
            mode: mode,
            colors: ["ground": mode == .light ? "#FFFFFF" : "#101010"],
            material: RemoteThemeDTO.Material(
                panelRadius: 20,
                controlRadius: 10,
                borderWidth: 1
            )
        ))
    }

    private struct Harness: View {
        @State private var text = ""
        @State private var isFocused = false
        @State private var isOverflowing = false
        let theme: RemoteThemePalette

        var body: some View {
            SessionDraftPromptEditor(
                text: $text,
                isFocused: $isFocused,
                isOverflowing: $isOverflowing,
                isEnabled: true,
                theme: theme,
                offersFiles: { false },
                pasteFiles: { false },
                firstLineLeadingAccessoryWidth: 0,
                firstLineTrailingAccessoryWidth: 0,
                firstLineAccessoryHeight: 0,
                firstLineAccessoriesInline: true
            )
        }
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
        window.layoutIfNeeded()

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
        window.layoutIfNeeded()

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
        window.layoutIfNeeded()

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
        window.layoutIfNeeded()

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
    /// warning-coloured connection steps do not reveal that reflow as a teleport. The copy is
    /// the row's own subview at the row-local frame the dot was drawn in: a bar carrying the row
    /// somewhere — a push — carries the copy with it, where a copy parked in the window at the
    /// dot's *model* frame sat at the far end of the slide while the words slid under it.
    func testTheConnectionDotFadesAcrossLayoutWhenTheStatusChangesButItsColorDoesNot() throws {
        let (window, line) = mountedStatusLine()
        defer { window.isHidden = true }

        update(line, status: "Checking connections", color: .systemOrange)
        XCTAssertFalse(line.indicator.isAnimatingTransitionForTesting)
        let oldFrame = line.indicator.frame

        update(line, status: "Trying LAN", color: .systemOrange)
        window.layoutIfNeeded()

        let transition = try XCTUnwrap(line.indicator.transitionForTesting)
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
        XCTAssertNotEqual(line.indicator.frame, oldFrame, "a shorter phrase leaves the dot where it was")

        let departing = try XCTUnwrap(line.departingIndicatorForTesting)
        XCTAssertTrue(departing.superview === line, "the departing copy left the row it belongs to")
        XCTAssertEqual(departing.frame, oldFrame)
        XCTAssertEqual(departing.backgroundColor, .systemOrange)
        let departure = try XCTUnwrap(
            departing.layer.animation(
                forKey: "threading.connection-status-indicator.departing"
            ) as? CABasicAnimation
        )
        XCTAssertEqual(departure.fromValue as? Float, 1)
        XCTAssertEqual(departure.toValue as? Float, 0)
        XCTAssertEqual(
            departure.duration,
            MobileDesign.Motion.connectionStatusMorphDuration
                * MobileDesign.Motion.connectionStatusDepartureShare,
            accuracy: 0.001
        )
    }

    func testReduceMotionLandsAConnectionDotChangeWithoutAFade() {
        let (window, line) = mountedStatusLine()
        defer { window.isHidden = true }

        update(line, status: "Checking connections", color: .systemOrange)
        update(line, status: "Connected", color: .systemGreen, reducesMotion: true)

        XCTAssertFalse(line.indicator.isAnimatingTransitionForTesting)
        XCTAssertFalse(line.label.isAnimatingLineScrollForTesting)
        XCTAssertNil(line.departingIndicatorForTesting)
        XCTAssertEqual(line.indicator.layer.backgroundColor, UIColor.systemGreen.cgColor)
    }

    /// SwiftUI and the UIKit conversation title may restate the same model several times while
    /// the transition is still playing. An idempotent update must not make the new dot pop in or
    /// discard the old-position copy early.
    func testRestatingAConnectionStatusPreservesItsInFlightTransition() throws {
        let (window, line) = mountedStatusLine()
        defer { window.isHidden = true }

        update(line, status: "Checking connections", color: .systemOrange)
        update(line, status: "Connected", color: .systemGreen)
        let departing = try XCTUnwrap(line.departingIndicatorForTesting)
        XCTAssertTrue(line.indicator.isAnimatingTransitionForTesting)

        update(line, status: "Connected", color: .systemGreen)

        XCTAssertTrue(line.indicator.isAnimatingTransitionForTesting)
        XCTAssertTrue(line.departingIndicatorForTesting === departing)
    }

    /// The working orb replaces the connection dot. If work begins during a connection change,
    /// both halves of the dot's fade must leave before the orb is shown.
    func testEnteringWorkCancelsBothConnectionDotHalves() throws {
        let (window, line) = mountedStatusLine()
        defer { window.isHidden = true }

        let mark = UIView()
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: MobileDesign.Size.navigationWorkingOrb),
            mark.heightAnchor.constraint(equalToConstant: MobileDesign.Size.navigationWorkingOrb),
        ])
        line.workingMark = mark
        update(line, status: "Checking connections", color: .systemOrange)
        update(line, status: "Connected", color: .systemGreen)
        XCTAssertNotNil(line.departingIndicatorForTesting)

        line.isWorking = true

        XCTAssertTrue(line.indicator.isHidden)
        XCTAssertNil(line.departingIndicatorForTesting)
        XCTAssertFalse(line.indicator.isAnimatingTransitionForTesting)
    }

    /// The recording this line exists for: "Opening chat…" gave way to "David's MacBook Pro"
    /// and the new phrase was drawn in two pieces, "David's MacBo" still rising while "ok Pro"
    /// already sat lit a line above it. The label had been sized to the old words, so the morph
    /// was built in the old width and the characters that had not fit were made fresh, without
    /// the animation, when the wider frame landed a pass later. The line gives the phrase a
    /// frame the words do not decide, so the morph it builds is the one that plays.
    func testThePhraseKeepsItsFrameThroughAChangeSoTheMorphItBuildsIsTheOneThatPlays() {
        let (window, line) = mountedStatusLine()
        defer { window.isHidden = true }

        update(line, status: "Opening chat…", color: .systemOrange)
        window.layoutIfNeeded()
        let frame = line.label.frame

        update(line, status: "David's MacBook Pro", color: .systemGreen)
        window.layoutIfNeeded()

        XCTAssertEqual(line.label.frame, frame)
        XCTAssertEqual(
            frame.width,
            line.bounds.width
                - MobileDesign.Size.navigationStatusIndicator
                - MobileDesign.Spacing.tight,
            accuracy: 0.5,
            "the phrase's frame is the row's width less the mark's slot, never the phrase's own"
        )
        XCTAssertTrue(line.label.isAnimatingLineScrollForTesting)
        XCTAssertEqual(line.label.stringValue, "David's MacBook Pro")
    }

    /// The mark stands `Spacing.tight` before the phrase's first character, and the pair is
    /// centred on the row — the geometry the SwiftUI row used to get from an `HStack`, now
    /// answered by the line itself so that the label can fill the row.
    func testTheMarkStandsBesideThePhrasesFirstCharacterAndThePairIsCentred() throws {
        let (window, line) = mountedStatusLine()
        defer { window.isHidden = true }

        update(line, status: "Connected · Tailscale", color: .systemGreen, reducesMotion: true)
        window.layoutIfNeeded()

        let ink = line.label.glyphInkFrames.map { line.convert($0, from: line.label) }
        let first = try XCTUnwrap(ink.min { $0.minX < $1.minX })
        let last = try XCTUnwrap(ink.max { $0.maxX < $1.maxX })
        XCTAssertEqual(
            line.indicator.frame.maxX + MobileDesign.Spacing.tight,
            first.minX,
            accuracy: 1
        )
        XCTAssertEqual((line.indicator.frame.minX + last.maxX) / 2, line.bounds.midX, accuracy: 1)
        XCTAssertEqual(line.indicator.frame.midY, line.bounds.midY, accuracy: 0.5)
    }

    /// A phrase too long for the row is drawn as its ellipsized head, and the mark stands
    /// beside that head — not beside where the whole phrase would have begun.
    func testATruncatedPhraseKeepsTheMarkBesideItsHead() throws {
        let (window, line) = mountedStatusLine()
        defer { window.isHidden = true }

        let phrase = String(repeating: "Connected over a very long route name ", count: 3)
        update(line, status: phrase, color: .systemGreen, reducesMotion: true)
        window.layoutIfNeeded()

        let ink = line.label.glyphInkFrames.map { line.convert($0, from: line.label) }
        let first = try XCTUnwrap(ink.min { $0.minX < $1.minX })
        let last = try XCTUnwrap(ink.max { $0.maxX < $1.maxX })
        XCTAssertLessThanOrEqual(last.maxX, line.bounds.maxX + 0.5)
        XCTAssertGreaterThanOrEqual(line.indicator.frame.minX, -0.01)
        XCTAssertEqual(
            line.indicator.frame.maxX + MobileDesign.Spacing.tight,
            first.minX,
            accuracy: 1
        )
    }

    /// A change that lands while the bar is carrying the row — a push in flight — is committed,
    /// not performed: the title arrives already saying the settled state. The connection settles
    /// about 100 ms after a chat's screen appears, which is always inside its push.
    func testAStatusChangeWhileTheHostIsInFlightLandsWithoutAnimation() throws {
        let (window, line) = mountedStatusLine()
        defer { window.isHidden = true }

        update(line, status: "Opening chat…", color: .systemOrange)
        let host = try XCTUnwrap(line.superview)
        UIView.animate(withDuration: 1) { host.center.x += 120 }
        XCTAssertFalse(host.layer.animationKeys()?.isEmpty ?? true, "the fixture's host is not moving")

        update(line, status: "David's MacBook Pro", color: .systemGreen)

        XCTAssertFalse(line.label.isAnimatingLineScrollForTesting)
        XCTAssertFalse(line.indicator.isAnimatingTransitionForTesting)
        XCTAssertNil(line.departingIndicatorForTesting)
        XCTAssertEqual(line.label.stringValue, "David's MacBook Pro")
        XCTAssertEqual(line.indicator.layer.backgroundColor, UIColor.systemGreen.cgColor)
        host.layer.removeAllAnimations()
    }

    /// The working mark takes the dot's slot: the dot is hidden, the mark is centred where the
    /// dot stood, and the phrase moves over to make room for the wider mark.
    func testTheWorkingMarkStandsInTheDotsPlace() {
        let (window, line) = mountedStatusLine()
        defer { window.isHidden = true }

        let mark = UIView()
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: MobileDesign.Size.navigationWorkingOrb),
            mark.heightAnchor.constraint(equalToConstant: MobileDesign.Size.navigationWorkingOrb),
        ])
        line.workingMark = mark
        update(line, status: "David's MacBook Pro", color: .systemGreen, reducesMotion: true)
        window.layoutIfNeeded()
        let restingLabel = line.label.frame

        line.isWorking = true
        window.layoutIfNeeded()

        XCTAssertTrue(line.indicator.isHidden)
        XCTAssertFalse(mark.isHidden)
        let markFrame = mark.convert(mark.bounds, to: line)
        XCTAssertEqual(markFrame.width, MobileDesign.Size.navigationWorkingOrb, accuracy: 0.5)
        XCTAssertEqual(markFrame.midY, line.bounds.midY, accuracy: 0.5)
        XCTAssertEqual(
            line.label.frame.minX - restingLabel.minX,
            MobileDesign.Size.navigationWorkingOrb - MobileDesign.Size.navigationStatusIndicator,
            accuracy: 0.5
        )
        XCTAssertEqual(
            line.intrinsicContentSize.height,
            MobileDesign.Size.navigationWorkingOrb,
            accuracy: 0.5
        )

        line.isWorking = false
        window.layoutIfNeeded()
        XCTAssertFalse(line.indicator.isHidden)
        XCTAssertEqual(line.label.frame, restingLabel)
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
        window.layoutIfNeeded()

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

    /// The line at the width the bar hands a title, inside a host that stands in for the bar's
    /// title area — something a push can move.
    private func mountedStatusLine() -> (UIWindow, MobileConnectionStatusLineView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        let host = UIView(frame: CGRect(
            x: 77,
            y: 60,
            width: MobileDesign.Size.navigationTitleWidth,
            height: MobileDesign.Size.navigationTitleHeight
        ))
        let line = MobileConnectionStatusLineView(frame: CGRect(
            x: 0,
            y: 24,
            width: MobileDesign.Size.navigationTitleWidth,
            height: 14
        ))
        host.addSubview(line)
        controller.view.addSubview(host)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return (window, line)
    }

    private func update(
        _ line: MobileConnectionStatusLineView,
        status: String,
        color: UIColor,
        reducesMotion: Bool = false
    ) {
        line.update(
            status: status,
            color: color,
            textColor: .secondaryLabel,
            groundColor: .systemBackground,
            reducesMotion: reducesMotion
        )
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

/// Whether an anchored popover has the room it asks for, which decides whether the draft's
/// choosers keep the keyboard under them or ask for its height.
@MainActor
final class MobileThemedPopoverRoomTests: XCTestCase {
    /// An iPhone 17 Pro with the keyboard up: the composer's action row stands at about 490
    /// points, under a navigation bar whose bottom is at about 116.
    private let anchorAboveTheKeyboard = CGRect(x: 16, y: 490, width: 160, height: 34)
    private let barBottom: CGFloat = 116
    private let screenBottom: CGFloat = 874 - 34

    func testAPickerThatFitsAboveItsAnchorNeedsNoRoom() {
        XCTAssertTrue(MobileThemedPopoverRoom.fits(
            contentHeight: 330,
            arrowEdge: .bottom,
            anchor: anchorAboveTheKeyboard,
            between: barBottom,
            and: screenBottom
        ))
    }

    /// A five-row page of the picker with its pager is 360 points; between a 116-point bar and
    /// an action row at 497 that leaves nine to spare once the arrow is counted, and none if
    /// UIKit's margin is charged a second time at the bar.
    func testOnlyTheArrowStandsBetweenTheBodyAndTheAnchor() {
        let bare = anchorAboveTheKeyboard.minY - barBottom
        XCTAssertFalse(
            MobileThemedPopoverRoom.fits(
                contentHeight: bare,
                arrowEdge: .bottom,
                anchor: anchorAboveTheKeyboard,
                between: barBottom,
                and: screenBottom
            ),
            "the content is not the whole popover: the arrow stands in the same room"
        )
        XCTAssertTrue(MobileThemedPopoverRoom.fits(
            contentHeight: bare - MobileThemedPopoverBackgroundView.arrowHeight(),
            arrowEdge: .bottom,
            anchor: anchorAboveTheKeyboard,
            between: barBottom,
            and: screenBottom
        ))
        XCTAssertTrue(MobileThemedPopoverRoom.fits(
            contentHeight: 360,
            arrowEdge: .bottom,
            anchor: CGRect(x: 16, y: 497, width: 160, height: 34),
            between: 116,
            and: screenBottom
        ))
    }

    /// An iPhone SE with the keyboard up leaves about 230 points between the bar and the row.
    func testAPickerTallerThanTheRoomAboveItsAnchorAsksForRoom() {
        let anchorOnASmallPhone = CGRect(x: 16, y: 300, width: 160, height: 34)
        XCTAssertFalse(MobileThemedPopoverRoom.fits(
            contentHeight: 330,
            arrowEdge: .bottom,
            anchor: anchorOnASmallPhone,
            between: 72,
            and: 667
        ))
    }

    func testAPopoverBelowItsAnchorMeasuresTheRoomBelow() {
        let anchorNearTheTop = CGRect(x: 16, y: 130, width: 160, height: 34)
        XCTAssertTrue(MobileThemedPopoverRoom.fits(
            contentHeight: 330,
            arrowEdge: .top,
            anchor: anchorNearTheTop,
            between: barBottom,
            and: screenBottom
        ))
        XCTAssertFalse(MobileThemedPopoverRoom.fits(
            contentHeight: 330,
            arrowEdge: .top,
            anchor: anchorAboveTheKeyboard,
            between: barBottom,
            and: 874 - 336
        ))
    }

    func testAPopoverBesideItsAnchorAlwaysHasRoom() {
        for edge in [Edge.leading, .trailing] {
            XCTAssertTrue(MobileThemedPopoverRoom.fits(
                contentHeight: 10_000,
                arrowEdge: edge,
                anchor: anchorAboveTheKeyboard,
                between: barBottom,
                and: screenBottom
            ))
        }
    }

    @MainActor
    func testTheContentTopIsTheNavigationBarsBottomWhenOneIsOnScreen() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let navigation = UINavigationController(rootViewController: UIViewController())
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        let bar = navigation.navigationBar
        let barBottom = bar.convert(bar.bounds, to: window).maxY

        XCTAssertEqual(MobileThemedPopoverRoom.contentTop(of: window), barBottom, accuracy: 0.5)
        XCTAssertGreaterThan(barBottom, window.safeAreaInsets.top)
        window.isHidden = true
    }

    @MainActor
    func testWithoutABarTheBoundsAreUIKitsSafeAreaPlusItsMargin() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIViewController()
        window.isHidden = false
        window.layoutIfNeeded()

        XCTAssertEqual(
            MobileThemedPopoverRoom.contentTop(of: window),
            window.safeAreaInsets.top + MobileThemedPopoverRoom.layoutMargin
        )
        XCTAssertEqual(
            MobileThemedPopoverRoom.contentBottom(of: window),
            874 - window.safeAreaInsets.bottom - MobileThemedPopoverRoom.layoutMargin
        )
        window.isHidden = true
    }
}
