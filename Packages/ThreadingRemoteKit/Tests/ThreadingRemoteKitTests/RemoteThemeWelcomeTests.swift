import Foundation
import XCTest
@testable import ThreadingRemoteKit

/// The welcome block on the theme wire (`RemoteThemeDTO.welcome`): it round-trips whole, a
/// newer Mac's shapes cost only the part they spoil and never the palette, and every list and
/// string is bounded before a phone builds anything from it.
final class RemoteThemeWelcomeTests: XCTestCase {
    private typealias Welcome = RemoteThemeWelcome
    private typealias Line = ThemeWelcomeGrammar.Line

    private static let material = RemoteThemeDTO.Material(panelRadius: 4, controlRadius: 2, borderWidth: 1)

    private static func theme(_ welcome: Welcome?) -> RemoteThemeDTO {
        RemoteThemeDTO(id: "matrix", name: "Matrix", mode: .dark, colors: ["ground": "#000000"],
                       material: material, welcome: welcome)
    }

    private static let full = Welcome(
        mark: .mascot,
        markSize: 56,
        greeting: .init(
            lines: [
                Line(text: "Wake up, {user}…", when: .init(dayparts: [.night], hours: .init(from: 22, to: 4)),
                     weight: 3),
                Line(text: "Follow the white rabbit.")
            ],
            includesAppLines: true,
            style: .init(scale: 1.4, weight: .bold, ink: "#00FF41", fontFamily: "Matrix Phosphor",
                         typeface: .monospaced)
        ),
        caption: .init(lines: [Line(text: "{days_until:12-24} days to go")], style: .init(ink: "#00FF4199")),
        scrim: .init(hero: 0.4, prompt: 0.6),
        backdrop: .init(
            gradient: .init(stops: [.init(color: "#000000", position: 0), .init(color: "#003300", position: 1)],
                            angleDegrees: 160, drift: .init(duration: 30, distance: 0.1)),
            particles: .init(style: .snow, colors: ["accent"], density: 0.4)
        ),
        user: "Ada"
    )

    private func object(_ theme: RemoteThemeDTO) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(theme)) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> RemoteThemeDTO {
        try JSONDecoder().decode(RemoteThemeDTO.self, from: JSONSerialization.data(withJSONObject: object))
    }

    // MARK: - Round trip

    func testAWholeWelcomeRoundTripsInsideTheTheme() throws {
        let theme = Self.theme(Self.full)
        let data = try JSONEncoder().encode(theme)
        XCTAssertEqual(try JSONDecoder().decode(RemoteThemeDTO.self, from: data), theme)

        let welcome = try XCTUnwrap(try object(theme)["welcome"] as? [String: Any])
        XCTAssertEqual(welcome["mark"] as? String, "mascot")
        XCTAssertEqual(welcome["markSize"] as? Double, 56)
        XCTAssertEqual(welcome["user"] as? String, "Ada")
        let greeting = try XCTUnwrap(welcome["greeting"] as? [String: Any])
        XCTAssertEqual(greeting["includesAppLines"] as? Bool, true)
        XCTAssertEqual((greeting["style"] as? [String: Any])?["ink"] as? String, "#00FF41",
                       "an ink crosses resolved, never as a role the phone would have to know")
        XCTAssertNil((welcome["caption"] as? [String: Any])?["includesAppLines"], "false is not written")
        XCTAssertEqual(Welcome.Mark(rawValue: "none"), .hidden, "`none` on the wire is the hidden mark")
        XCTAssertEqual(Welcome.Mark.hidden.rawValue, "none")
    }

    func testAThemeWithoutAWelcomeWritesNoneAndAnEmptyBlockReadsAsNone() throws {
        XCTAssertNil(try object(Self.theme(nil))["welcome"])
        XCTAssertNil(Self.theme(Welcome()).welcome, "an empty block is not sent")
        var document = try object(Self.theme(nil))
        document["welcome"] = [String: Any]()
        XCTAssertNil(try decode(document).welcome)
    }

    // MARK: - Tolerance

    func testAnUnreadableWelcomeCostsOnlyItselfNeverThePalette() throws {
        var document = try object(Self.theme(Self.full))
        for spoiled: Any in [42, "welcome", [1, 2]] {
            document["welcome"] = spoiled
            let decoded = try decode(document)
            XCTAssertNil(decoded.welcome)
            XCTAssertEqual(decoded.colors, ["ground": "#000000"])
            XCTAssertEqual(decoded.material, Self.material)
        }
    }

    func testEachPartOfANewerMacsWelcomeDropsOnItsOwn() throws {
        var document = try object(Self.theme(nil))
        document["welcome"] = [
            "mark": "hologram",
            "markSize": 400,
            "greeting": ["lines": "not a list", "style": ["scale": 9, "ink": "accent", "weight": "black"]],
            "caption": ["lines": [
                ["text": "Kept"],
                ["text": "A newer condition", "when": ["dayparts": ["dusk"]]],
                NSNull(),
                ["text": 7],
                ["text": "Too heavy", "weight": 11],
                ["text": "Hours out of range", "when": ["hours": ["from": 22, "to": 25]]],
                ["text": "Also kept", "weight": 2]
            ]],
            "scrim": ["hero": 0.3, "prompt": 2],
            "backdrop": ["gradient": ["stops": [], "angleDegrees": 0],
                         "particles": ["style": "future"]],
            "user": "Ada\u{0007}"
        ] as [String: Any]
        let welcome = try XCTUnwrap(try decode(document).welcome)
        XCTAssertEqual(welcome.mark, .unknown("hologram"), "a newer mark survives; the phone draws its own")
        XCTAssertNil(welcome.markSize, "a side past the bounds is the phone's own")
        let greeting = try XCTUnwrap(welcome.greeting)
        XCTAssertEqual(greeting.lines, [], "a pool in a shape this build cannot read has no lines")
        XCTAssertEqual(greeting.style?.weight, .unknown("black"))
        XCTAssertNil(greeting.style?.scale)
        XCTAssertNil(greeting.style?.ink, "an ink must arrive resolved")
        XCTAssertEqual(welcome.caption?.lines.map(\.text), ["Kept", "Also kept"],
                       "a line this build cannot hold is skipped without taking its pool")
        XCTAssertEqual(welcome.scrim, .init(hero: 0.3))
        XCTAssertEqual(welcome.backdrop, .init(), "the stated block stays; its spoiled recipes do not")
        XCTAssertNil(welcome.user, "a name with a control character is not a name")
    }

    // MARK: - Bounds

    func testPoolsAndTextAreBoundedBeforeAnythingIsBuilt() throws {
        let many = (0..<(Welcome.Limits.maximumExaminedLines + 10)).map { Line(text: "Line \($0)") }
        XCTAssertEqual(Welcome.Wording(lines: many).lines.count, Welcome.Limits.maximumLines)

        let long = Line(text: String(repeating: "a", count: Welcome.Limits.maximumLineCharacters + 1))
        let wide = Line(text: String(repeating: "👩‍👩‍👧‍👦", count: 60))
        XCTAssertEqual(Welcome.Wording(lines: [long, wide, Line(text: "ok")]).lines.map(\.text), ["ok"],
                       "a line is held to its characters and to the bytes scanned to count them")

        // Both pools share one text budget, and the greeting is served first. Three-byte glyphs
        // fill it: 64 lines of 150 of them are about 29 KB.
        let big = (0..<64).map { Line(text: String(repeating: "ア", count: 150) + "\($0)") }
        let welcome = Welcome(greeting: .init(lines: big), caption: .init(lines: big.map {
            Line(text: "c" + $0.text.dropFirst())
        }))
        let greetingBytes = welcome.greeting?.lines.reduce(0) { $0 + $1.text.utf8.count } ?? 0
        let captionBytes = welcome.caption?.lines.reduce(0) { $0 + $1.text.utf8.count } ?? 0
        XCTAssertEqual(welcome.greeting?.lines.count, 64)
        XCTAssertLessThan(welcome.caption?.lines.count ?? 0, 64)
        XCTAssertLessThanOrEqual(greetingBytes + captionBytes, Welcome.Limits.maximumTextBytes)

        let encoded = try JSONEncoder().encode(Self.theme(welcome))
        let decoded = try JSONDecoder().decode(RemoteThemeDTO.self, from: encoded)
        XCTAssertEqual(decoded.welcome, welcome, "a bounded block reads back as itself")
        XCTAssertLessThan(encoded.count, 48 * 1_024, "the largest welcome stays a small part of a theme")
    }

    func testOnlyALineThatNamesTheUserIsAReasonToSendAName() {
        XCTAssertTrue(Welcome.namesUser(in: [Line(text: "Hi"), Line(text: "Wake up, {user}")]))
        XCTAssertFalse(Welcome.namesUser(in: [Line(text: "Hi {{user}}"), Line(text: "{project}")]))
        XCTAssertFalse(Welcome.namesUser(in: []))
    }

    func testTheWelcomePictureHasItsOwnBoundedSlot() {
        let digest = String(repeating: "d", count: 64)
        let picture = RemoteThemeAsset(slot: "welcome", digest: digest, byteCount: 2_048,
                                       pixelWidth: 1_290, pixelHeight: 800, opacity: 0.3)
        XCTAssertTrue(picture.isValid)
        XCTAssertEqual(picture.kind, .image)
        XCTAssertFalse(picture.requiresOwner, "a picture is not owner-only, unlike a font")
        XCTAssertFalse(RemoteThemeAsset(slot: "welcome", digest: digest, byteCount: 2_048,
                                        pixelWidth: 1_291, pixelHeight: 800).isValid)
    }
}
