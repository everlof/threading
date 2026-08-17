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
