import Foundation
import XCTest
import ThreadingExtensionKit
@testable import ThreadingRemoteKit

final class RemoteThemeEvolutionTests: XCTestCase {
    func testFontsHaveASeparateBudgetAndEveryRangeIsBounded() throws {
        let digest = String(repeating: "a", count: 64)
        let font = RemoteThemeAsset(slot: "font.0", digest: digest, byteCount: 16 * 1_024 * 1_024,
            mediaType: "font/collection", pixelWidth: 0, pixelHeight: 0, fontFamily: "Fixture")
        let image = RemoteThemeAsset(slot: "backdrop", digest: digest, byteCount: 1_024,
            pixelWidth: 32, pixelHeight: 32)
        XCTAssertEqual(RemoteThemeAsset.admitted([font, image]), [font, image])
        XCTAssertTrue(font.requiresOwner)
        var start = 0
        while start < font.byteCount {
            let range = try XCTUnwrap(RemoteThemeAssetRange(start: start, total: font.byteCount))
            XCTAssertLessThanOrEqual(range.bytes.count, RemoteThemeAsset.maximumBytes)
            XCTAssertEqual(RemoteThemeAssetRange(header: range.requestHeader, total: font.byteCount), range)
            start = range.bytes.upperBound
        }
        for invalid in ["bytes=0-1048576", "bytes=-10", "bytes=2-1", "bytes=0-1,4-5", "bytes=0-16777216"] {
            XCTAssertNil(RemoteThemeAssetRange(header: invalid, total: font.byteCount), invalid)
        }
    }

    func testReviewedSurfaceRoundTripsAndMalformedOptionalSourceKeepsPalette() throws {
        let surface = RemoteThemeSurface(sourceDigest: String(repeating: "b", count: 64),
            specification: .init(shaderResource: "rain.metal", preferredFramesPerSecond: 24,
                inputs: [.init(name: "work", value: .signal(.workloadIntensity, mapping: .identity))]))
        let theme = RemoteThemeDTO(id: "surface", name: "Surface", mode: .dark, colors: ["ground": "#101010"],
            material: .init(panelRadius: 4, controlRadius: 4, borderWidth: 1), surface: surface)
        let encoded = try JSONEncoder().encode(theme)
        XCTAssertEqual(try JSONDecoder().decode(RemoteThemeDTO.self, from: encoded), theme)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["surface"] = ["definition": ["type": "future"]]
        let decoded = try JSONDecoder().decode(RemoteThemeDTO.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.surface)
        XCTAssertEqual(decoded.colors, theme.colors)
    }

    func testGlowAndSoundReceiptsRejectUnsupportedOptionalValues() throws {
        let name = "threading-theme-" + String(repeating: "c", count: 64) + ".caf"
        XCTAssertTrue(RemoteThemeSound.acceptsReceipts(["sound.needsAttention": name]))
        XCTAssertFalse(RemoteThemeSound.acceptsReceipts(["sound.needsAttention": "../alert.caf"]))
        XCTAssertFalse(RemoteThemeSound.acceptsReceipts(["sound.future": name]))
        let theme = RemoteTerminalThemeDTO(id: "glow", name: "Glow", foreground: "#FFFFFF",
            background: "#101010", cursor: "#FFFFFF", selection: "#888888", ansi: [],
            glow: .init(radius: 4, opacity: 0.6))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(theme)) as? [String: Any])
        object["glow"] = ["radius": 40, "opacity": 2]
        let decoded = try JSONDecoder().decode(RemoteTerminalThemeDTO.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.glow)
        XCTAssertEqual(decoded.foreground, theme.foreground)
    }
    func testAssetAdmissionDropsUnknownAndOversizedEntries() throws {
        let digest = String(repeating: "a", count: 64)
        let good = RemoteThemeAsset(slot: "backdrop", digest: digest, byteCount: 128,
            pixelWidth: 32, pixelHeight: 32)
        let unknown = RemoteThemeAsset(slot: "future", digest: digest, byteCount: 128,
            pixelWidth: 32, pixelHeight: 32)
        let large = RemoteThemeAsset(slot: "logo", digest: digest,
            byteCount: RemoteThemeAsset.maximumBytes + 1, pixelWidth: 32, pixelHeight: 32)
        XCTAssertEqual(RemoteThemeAsset.admitted([unknown, large, good]), [good])
        XCTAssertFalse(RemoteThemeAsset.acceptsDigest("../secret"))
        let theme = RemoteThemeDTO(id: "assets", name: "Assets", mode: .dark, colors: [:],
            material: .init(panelRadius: 0, controlRadius: 0, borderWidth: 0), assets: [good])
        XCTAssertEqual(try JSONDecoder().decode(RemoteThemeDTO.self,
            from: JSONEncoder().encode(theme)).assets, [good])
    }

    func testOneMalformedAssetEntryCostsOnlyThatEntry() throws {
        let good = RemoteThemeAsset(slot: "backdrop", digest: String(repeating: "a", count: 64),
            byteCount: 128, pixelWidth: 32, pixelHeight: 32)
        let theme = RemoteThemeDTO(id: "assets", name: "Assets", mode: .dark, colors: [:],
            material: .init(panelRadius: 0, controlRadius: 0, borderWidth: 0), assets: [good])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(theme)) as? [String: Any])
        let entry = try XCTUnwrap((object["assets"] as? [Any])?.first)
        // A newer Mac's shape, a wrong type, a null and an unrelated value, around a good entry.
        object["assets"] = [["slot": "logo", "digest": 7], NSNull(), "future", entry, ["slot": "x"]]
        let decoded = try JSONDecoder().decode(RemoteThemeDTO.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.assets, [good])
        XCTAssertEqual(decoded.colors, theme.colors)
    }

    func testAnOverLongAssetListKeepsItsFirstAdmissibleEntries() throws {
        func image(_ index: Int) -> RemoteThemeAsset {
            RemoteThemeAsset(slot: "sprite.\(index % 8)", digest: String(format: "%064x", index),
                byteCount: 128, pixelWidth: 32, pixelHeight: 32)
        }
        // Eight distinct sprite slots; repeats of a slot are refused, never the whole list.
        let many = (0 ..< RemoteThemeAsset.maximumCount + 8).map(image)
        XCTAssertEqual(RemoteThemeAsset.admitted(many), Array(many.prefix(8)))
        let slots = (0 ..< RemoteThemeAsset.maximumCount + 1).map { index in
            RemoteThemeAsset(slot: "backdrop", digest: String(format: "%064x", index),
                byteCount: 128, pixelWidth: 32, pixelHeight: 32)
        }
        XCTAssertEqual(RemoteThemeAsset.admitted(slots), [slots[0]])
        let theme = RemoteThemeDTO(id: "many", name: "Many", mode: .dark, colors: [:],
            material: .init(panelRadius: 0, controlRadius: 0, borderWidth: 0), assets: many)
        XCTAssertEqual(try JSONDecoder().decode(RemoteThemeDTO.self,
            from: JSONEncoder().encode(theme)).assets, Array(many.prefix(8)))
    }

    func testASpacedScrambleAlphabetCountsOnlyItsGlyphs() {
        // What the Mac's validator accepts: 60 glyphs, spaced, 119 characters in all.
        let glyphs = (0 ..< 60).map { String(UnicodeScalar(0x30A2 + $0)!) }
        let spaced = RemoteThemeDTO.TitleMorph(style: "scramble", characters: glyphs.joined(separator: " "))
        XCTAssertTrue(spaced.isValid)
        XCTAssertEqual(spaced.scrambleCharacters?.count, 60)
        let wrapped = RemoteThemeDTO.TitleMorph(style: "scramble",
            characters: String(repeating: "A", count: 96) + "\n" + String(repeating: " ", count: 40))
        XCTAssertTrue(wrapped.isValid)
        XCTAssertFalse(RemoteThemeDTO.TitleMorph(style: "scramble",
            characters: String(repeating: "A ", count: 97)).isValid)
        XCTAssertFalse(RemoteThemeDTO.TitleMorph(style: "scramble", characters: String(repeating: " ",
            count: RemoteThemeDTO.TitleMorph.maximumScrambleSourceBytes + 1)).isValid,
            "the scan itself is bounded")
    }

    func testUnknownOptionalDecorationKeepsThePalette() throws {
        let bytes = Data("""
        {"id":"newer","name":"Newer","mode":"dark","colors":{"ground":"#101010"},
         "material":{"panelRadius":4,"controlRadius":2,"borderWidth":1,
           "typeface":"future","identityMarks":"future","particles":{"style":"future"}},
         "titleMorph":{"style":"future","characters":"ABC"}}
        """.utf8)
        let theme = try JSONDecoder().decode(RemoteThemeDTO.self, from: bytes)
        XCTAssertEqual(theme.colors["ground"], "#101010")
        XCTAssertNil(theme.titleMorph)
        XCTAssertNil(theme.material.particles)
        XCTAssertEqual(theme.material.typeface, .unknown("future"))
    }

    func testOptionalBlocksRoundTripAndOversizedAlphabetIsDropped() throws {
        let theme = RemoteThemeDTO(id: "matrix", name: "Matrix", mode: .dark,
            colors: ["accent": "#00FF88"],
            material: .init(panelRadius: 4, controlRadius: 2, borderWidth: 1,
                typeface: .monospaced, identityMarks: "tinted",
                particles: .init(style: .snow, colors: ["accent"], density: 1)),
            titleMorph: .init(style: "scramble", characters: "アイウエオ"))
        let data = try JSONEncoder().encode(theme)
        XCTAssertEqual(try JSONDecoder().decode(RemoteThemeDTO.self, from: data), theme)
        XCTAssertFalse(RemoteThemeDTO.TitleMorph(style: "scramble", characters: String(repeating: "A", count: 97)).isValid)
        XCTAssertEqual(theme.titleMorph?.scrambleCharacters, Array("アイウエオ"))
    }
}
