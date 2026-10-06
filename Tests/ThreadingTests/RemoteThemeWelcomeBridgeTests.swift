import AppKit
import ThreadingRemoteKit
import XCTest
@testable import Threading

/// The welcome as the Mac projects it for the phone (`RemoteThemeBridge`): lines cross as
/// written, inks arrive resolved for the projected variant, the backdrop reuses the portable
/// recipes, and the owner's given name reaches an owner's connection only — and only when a line
/// asks for it.
@MainActor
final class RemoteThemeWelcomeBridgeTests: XCTestCase {

    private func resolvedHex(_ ink: ThemeInk, in theme: AppTheme) -> String {
        let appearance = RemoteThemeBridge.drawingAppearance(for: theme)
        var hex = ""
        appearance.performAsCurrentDrawingAppearance {
            hex = ink.resolved(in: theme, appearance: appearance).hexString
        }
        return hex
    }

    func testTheWelcomeCrossesWithItsLinesAsWrittenAndItsInksResolved() throws {
        let stated = ThemeWelcomeFixtures.dressedWelcome(mark: .mascot)
        let theme = try ThemeWelcomeFixtures.theme(stated)
        let dto = RemoteThemeBridge.appTheme(theme, includesOwnerAssets: true, ownerName: { "Ada" })
        let welcome = try XCTUnwrap(dto.welcome)

        XCTAssertEqual(welcome.mark, .mascot)
        XCTAssertEqual(welcome.markSize, 64)
        XCTAssertEqual(welcome.greeting?.lines, stated.greeting?.lines,
                       "lines are the phone's to pick and render on its own clock")
        XCTAssertEqual(welcome.caption?.lines, stated.caption?.lines)
        let greeting = try XCTUnwrap(welcome.greeting?.style)
        XCTAssertEqual(greeting.scale, 1.4)
        XCTAssertEqual(greeting.weight, .bold)
        XCTAssertEqual(greeting.typeface, .rounded)
        XCTAssertEqual(greeting.ink, resolvedHex(.role(.accent), in: theme),
                       "a role crosses as the colour it is in the projected variant")
        XCTAssertEqual(welcome.caption?.style?.ink, resolvedHex(.role(.secondaryLabel), in: theme))
        XCTAssertEqual(welcome.caption?.style?.typeface, .monospaced)
        XCTAssertEqual(welcome.scrim, .init(hero: 0.55, prompt: 0.7))
        XCTAssertEqual(welcome.backdrop?.gradient?.stops.count, 2)
        XCTAssertEqual(welcome.backdrop?.gradient?.angleDegrees, 165)
        XCTAssertEqual(welcome.backdrop?.particles?.style, .snow)
        XCTAssertEqual(welcome.backdrop?.particles?.colors, ["label"],
                       "particle inks travel as the words the phone's renderer resolves")
        XCTAssertEqual(welcome.user, "Ada")

        let decoded = try JSONDecoder().decode(RemoteThemeDTO.self, from: JSONEncoder().encode(dto))
        XCTAssertEqual(decoded.welcome, welcome, "what the Mac sends is what the phone reads")
    }

    func testOnlyAnOwnersConnectionIsToldTheNameAndOnlyWhenALineAsksForIt() throws {
        let greets = try ThemeWelcomeFixtures.theme(ThemeWelcomeFixtures.words(
            greeting: [.init(text: "Wake up, {user}.")]
        ))
        XCTAssertEqual(
            RemoteThemeBridge.appTheme(greets, includesOwnerAssets: true, ownerName: { "Ada" }).welcome?.user,
            "Ada"
        )
        let guest = RemoteThemeBridge.appTheme(greets, includesOwnerAssets: false, ownerName: { "Ada" })
        XCTAssertNil(guest.welcome?.user, "a guest's phone renders no {user} line at all")
        XCTAssertEqual(guest.welcome?.greeting?.lines.map(\.text), ["Wake up, {user}."],
                       "the guest still receives the line; it is simply ineligible there")

        let plain = try ThemeWelcomeFixtures.theme(ThemeWelcomeFixtures.words(
            greeting: [.init(text: "Hello.")], caption: [.init(text: "{{user}} is literal")]
        ))
        XCTAssertNil(
            RemoteThemeBridge.appTheme(plain, includesOwnerAssets: true, ownerName: { "Ada" }).welcome?.user,
            "a name no line asks for is not sent"
        )
        XCTAssertFalse(RemoteThemeBridge.receivesOwnerAssets(nil),
                       "no authorization is not an owner's")
    }

    func testCatalogueEntriesAndThemesWithoutAWelcomeSendNone() throws {
        let theme = try ThemeWelcomeFixtures.theme(ThemeWelcomeFixtures.dressedWelcome(mark: .logo))
        XCTAssertNil(RemoteThemeBridge.appTheme(theme, includesWelcome: false).welcome)
        XCTAssertNil(RemoteThemeBridge.appTheme(try ThemeWelcomeFixtures.theme(nil)).welcome)
        XCTAssertNil(RemoteThemeBridge.appTheme(AppThemeStyles.threading).welcome,
                     "no stock theme states a welcome, so none is sent")
    }

    func testAnIncludedAppLineIsTheGreetingsAloneAndAnUnusableFamilyIsNotSent() throws {
        let theme = try ThemeWelcomeFixtures.theme(ThemeWelcome(
            greeting: .init(lines: [.init(text: "Hi")], includesAppLines: true,
                            style: .init(fontFamily: "No Such Family 7f3a")),
            caption: .init(lines: [.init(text: "There")], includesAppLines: true)
        ))
        let welcome = try XCTUnwrap(RemoteThemeBridge.appTheme(theme).welcome)
        XCTAssertEqual(welcome.greeting?.includesAppLines, true)
        XCTAssertNil(welcome.caption?.includesAppLines, "a caption has no app lines to include")
        XCTAssertNil(welcome.greeting?.style, "a family this Mac cannot use is no style at all")
    }

    func testThePhoneIsSentTheWelcomesFontsBesideTheMaterials() throws {
        let theme = try ThemeWelcomeFixtures.theme(ThemeWelcome(
            greeting: .init(lines: [.init(text: "Hi")], style: .init(fontFamily: "Welcome Serif")),
            caption: .init(lines: [.init(text: "There")], style: .init(fontFamily: "Welcome Serif"))
        ))
        let variant = try XCTUnwrap(theme.variant(.dark))
        let families = RemoteThemeAssets.fontFamilies(variant)
        XCTAssertEqual(families.last, "Welcome Serif")
        XCTAssertEqual(families.filter { $0 == "Welcome Serif" }.count, 1, "a family is named once")
        XCTAssertEqual(Array(families.dropLast()), variant.material.fontFamilies,
                       "the material's families keep their place in front")
    }
}
