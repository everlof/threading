import SwiftUI
import ThreadingRemoteKit
import UIKit
import XCTest
@testable import ThreadingMobile

/// The phone's runtime vocabulary. Two defects are pinned here: every chat row drew the terminal
/// glyph and so identified no provider at all, and every runtime that was not Claude was named
/// "Codex" — a two-provider assumption written as `agentKind == "claude" ? … : …` in four places.
final class MobileAgentIdentityTests: XCTestCase {

    func testEveryRuntimeThisBuildKnowsIsNamedAfterItself() {
        XCTAssertEqual(MobileAgentIdentity.resolve("claude").displayName, "Claude Code")
        XCTAssertEqual(MobileAgentIdentity.resolve("codex").displayName, "Codex")
        XCTAssertEqual(MobileAgentIdentity.resolve("grok").displayName, "Grok")
        XCTAssertEqual(MobileAgentIdentity.resolve("opencode").displayName, "OpenCode")
        XCTAssertEqual(MobileAgentIdentity.resolve("cursor").displayName, "Cursor")
    }

    /// A Grok session used to be labelled "Codex UI", because the surface title asked only whether
    /// the runtime was Claude. Nothing may fall back to another runtime's name.
    func testARuntimeThisBuildDoesNotKnowKeepsItsOwnNameRatherThanBorrowingCodex() {
        let identity = MobileAgentIdentity.resolve("someagent")

        XCTAssertEqual(identity, .unknown("someagent"))
        XCTAssertEqual(identity.displayName, "Someagent")
        XCTAssertFalse(identity.originalUITitle.contains("Codex"))
        XCTAssertTrue(identity.originalUITitle.contains("Someagent"))
    }

    func testTheTUITitleNamesTheRuntimeWhoseTUIItIs() {
        XCTAssertTrue(MobileAgentIdentity.resolve("grok").originalUITitle.contains("Grok"))
        XCTAssertTrue(MobileAgentIdentity.resolve("cursor").originalUITitle.contains("Cursor"))
    }

    /// The row's tile carries identity, so it must never be a surface glyph. Claude and OpenAI ship
    /// their own marks; the runtimes we bundle no artwork for fall to a symbol, never to `terminal`.
    func testTheMarkIdentifiesTheRuntimeAndIsNeverATerminalGlyph() {
        XCTAssertEqual(
            MobileAgentIdentity.resolve("claude").mark,
            .brand(asset: MobileAgentMarkAssets.claude, keepsItsOwnColour: true)
        )
        XCTAssertEqual(
            MobileAgentIdentity.resolve("codex").mark,
            .brand(asset: MobileAgentMarkAssets.codex, keepsItsOwnColour: false)
        )

        for kind in ["claude", "codex", "grok", "opencode", "cursor", "someagent"] {
            switch MobileAgentIdentity.resolve(kind).mark {
            case .brand: continue
            case .symbol(let name):
                XCTAssertNotEqual(name, "terminal", "\(kind) took a surface glyph as its identity")
                XCTAssertFalse(name.isEmpty)
            }
        }
    }

    /// OpenAI's knot is monochrome by design and tints with the slot it sits in, which is what keeps
    /// it visible under a light theme. Claude's coral mark is drawn as authored. Losing that
    /// distinction is how the knot went invisible on the Mac before.
    func testOnlyTheMonochromeMarkTintsWithItsSurroundings() {
        guard case .brand(_, let claudeKeepsColour) =
            MobileAgentIdentity.resolve("claude").mark,
            case .brand(_, let codexKeepsColour) =
                MobileAgentIdentity.resolve("codex").mark else {
            return XCTFail("both bundled marks should be brand artwork")
        }

        XCTAssertTrue(claudeKeepsColour)
        XCTAssertFalse(codexKeepsColour)
    }

    // MARK: - Account chip

    func testAnEmojiChipBringsItsOwnColourAndAnInitialChipDoesNot() {
        let emoji = RemoteSessionAccountDTO(
            name: "Sandbox",
            glyph: "🧪",
            isEmoji: true,
            hue: nil
        )
        let initial = RemoteSessionAccountDTO(
            name: "Vera Keller",
            glyph: "V",
            isEmoji: false,
            hue: 0.72
        )

        XCTAssertNil(emoji.hue)
        XCTAssertNotNil(initial.hue)
        XCTAssertEqual(initial.glyph.count, 1, "a chip this small holds one character")
    }
}

// MARK: - Usage Reading

/// The disc has no text beside it, so each limit window is a ring of its own. These pin which
/// windows ring, in what order, and that a model's own window rings only a chat on that model.
final class MobileAccountUsageReadingTests: XCTestCase {

    private let weekSeconds: Double = 7 * 24 * 60 * 60
    private let fiveHourSeconds: Double = 5 * 60 * 60

    private var fiveHour: RemoteAccountUsageWindowDTO {
        .init(id: "5h", name: "5h", fraction: 0.43, windowDuration: fiveHourSeconds)
    }
    private var weekly: RemoteAccountUsageWindowDTO {
        .init(id: "7d", name: "7d", fraction: 0.73, windowDuration: weekSeconds)
    }
    private var fable: RemoteAccountUsageWindowDTO {
        .init(
            id: "Fable",
            name: "7d Fable",
            fraction: 0.89,
            windowDuration: weekSeconds,
            metersModelIDs: ["claude-fable-5", "claude-fable-5[1m]"]
        )
    }

    private func account(
        windows: [RemoteAccountUsageWindowDTO]?,
        fraction: Double? = nil,
        summary: String? = nil,
        defaultModelID: String? = nil
    ) -> RemoteAccountChoiceDTO {
        RemoteAccountChoiceDTO(
            id: "default",
            name: "David",
            usageSummary: summary,
            usageFraction: fraction,
            usageWindows: windows,
            models: [],
            defaultModelID: defaultModelID
        )
    }

    /// The Mac lists windows short to long, as its text reads them; the disc rings them long to
    /// short, the week outside the five hours, so the outer ring is the one slowest to come back.
    func testTheAccountsWindowsRingLongestOutsideAndShortestInnermost() {
        let reading = MobileAccountUsageReading.resolve(
            account: account(windows: [fiveHour, weekly]),
            model: nil
        )

        XCTAssertEqual(reading?.rings.map(\.id), ["7d", "5h"])
        XCTAssertEqual(reading?.rings.map(\.fraction), [0.73, 0.43])
        XCTAssertEqual(reading?.summary, "5h 43% · 7d 73%")
    }

    func testAModelsOwnWindowRingsInnermostAndOnlyAChatOnThatModel() {
        let account = account(windows: [fiveHour, weekly, fable])

        let onFable = MobileAccountUsageReading.resolve(account: account, model: "claude-fable-5")
        XCTAssertEqual(onFable?.rings.map(\.id), ["7d", "5h", "Fable"])
        XCTAssertEqual(onFable?.summary, "5h 43% · 7d 73% · 7d Fable 89%")

        let onOpus = MobileAccountUsageReading.resolve(account: account, model: "claude-opus-5")
        XCTAssertEqual(onOpus?.rings.map(\.id), ["7d", "5h"])
        XCTAssertEqual(onOpus?.summary, "5h 43% · 7d 73%")
    }

    /// A reset is part of the resolved reading, not a second scan of the account's complete
    /// wire list. An earlier Spark reset therefore belongs only to a Spark chat.
    func testNextResetUsesTheSameModelScopeAsTheRingsAndSummary() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fiveHour = RemoteAccountUsageWindowDTO(
            id: "5h",
            name: "5h",
            fraction: 0.43,
            resetsAt: now.addingTimeInterval(3_600).timeIntervalSince1970,
            windowDuration: fiveHourSeconds
        )
        let weekly = RemoteAccountUsageWindowDTO(
            id: "7d",
            name: "7d",
            fraction: 0.73,
            resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60).timeIntervalSince1970,
            windowDuration: weekSeconds
        )
        let spark = RemoteAccountUsageWindowDTO(
            id: "GPT-5.3-Codex-Spark",
            name: "7d GPT-5.3-Codex-Spark",
            fraction: 0.12,
            resetsAt: now.addingTimeInterval(5 * 60).timeIntervalSince1970,
            windowDuration: weekSeconds,
            metersModelIDs: ["gpt-5.3-codex-spark"]
        )
        let login = account(windows: [fiveHour, weekly, spark])

        let onSol = MobileAccountUsageReading.resolve(
            account: login,
            model: "gpt-5.3-codex",
            now: now
        )
        XCTAssertEqual(onSol?.summary, "5h 43% · 7d 73%")
        XCTAssertEqual(onSol?.nextReset, now.addingTimeInterval(3_600))

        let onSpark = MobileAccountUsageReading.resolve(
            account: login,
            model: "gpt-5.3-codex-spark",
            now: now
        )
        XCTAssertEqual(
            onSpark?.summary,
            "5h 43% · 7d 73% · 7d GPT-5.3-Codex-Spark 12%"
        )
        XCTAssertEqual(onSpark?.nextReset, now.addingTimeInterval(5 * 60))
    }

    func testNextResetIgnoresARelevantWindowThatAlreadyExpired() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expired = RemoteAccountUsageWindowDTO(
            id: "5h",
            name: "5h",
            fraction: 0.91,
            resetsAt: now.addingTimeInterval(-60).timeIntervalSince1970,
            windowDuration: fiveHourSeconds
        )
        let future = RemoteAccountUsageWindowDTO(
            id: "7d",
            name: "7d",
            fraction: 0.20,
            resetsAt: now.addingTimeInterval(7_200).timeIntervalSince1970,
            windowDuration: weekSeconds
        )

        let reading = MobileAccountUsageReading.resolve(
            account: account(windows: [expired, future]),
            model: nil,
            now: now
        )

        XCTAssertEqual(reading?.nextReset, now.addingTimeInterval(7_200))
    }

    /// A chat that chose no model runs the account's default, which is what the Mac's pill meters
    /// too. With no default known nothing scoped applies, the conservative answer.
    func testAChatWithoutAModelIsMeteredByTheAccountsDefault() {
        let defaulted = account(windows: [fiveHour, weekly, fable], defaultModelID: "claude-fable-5")
        XCTAssertEqual(
            MobileAccountUsageReading.resolve(account: defaulted, model: nil)?.rings.map(\.id),
            ["7d", "5h", "Fable"]
        )

        let undecided = account(windows: [fiveHour, weekly, fable])
        XCTAssertEqual(
            MobileAccountUsageReading.resolve(account: undecided, model: nil)?.rings.map(\.id),
            ["7d", "5h"]
        )
    }

    func testAnOlderHostRingsTheOneFractionItSent() {
        let reading = MobileAccountUsageReading.resolve(
            account: account(windows: nil, fraction: 0.73, summary: "5h 43% · 7d 73%"),
            model: "claude-fable-5"
        )

        XCTAssertEqual(reading?.rings.map(\.id), [MobileUsageDefaults.bindingRingID])
        XCTAssertEqual(reading?.rings.first?.fraction, 0.73)
        XCTAssertEqual(reading?.summary, "5h 43% · 7d 73%")
    }

    /// A phone may hold a catalogue for hours. Past its reset a window's fraction is a leftover,
    /// so the ring keeps its track and loses its arc, and the words say so.
    func testAWindowPastItsResetKeepsItsTrackAndLosesItsArc() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let spent = RemoteAccountUsageWindowDTO(
            id: "5h",
            name: "5h",
            fraction: 0.91,
            resetsAt: now.timeIntervalSince1970 - 1,
            windowDuration: fiveHourSeconds
        )
        let live = RemoteAccountUsageWindowDTO(
            id: "7d",
            name: "7d",
            fraction: 0.2,
            resetsAt: now.timeIntervalSince1970 + 60,
            windowDuration: weekSeconds
        )

        let reading = MobileAccountUsageReading.resolve(
            account: account(windows: [spent, live]),
            model: nil,
            now: now
        )

        XCTAssertEqual(reading?.rings.map(\.fraction), [0.2, nil])
        XCTAssertEqual(reading?.summary, "5h — · 7d 20%")
    }

    /// Three rings clear the mark; a fourth would touch it. The disc stops there, and the spoken
    /// value still names every window, so nothing is hidden, only undrawn.
    func testTheDiscHoldsThreeRingsWhileTheWordsNameEveryWindow() {
        let mythos = RemoteAccountUsageWindowDTO(
            id: "Mythos",
            name: "7d Mythos",
            fraction: 0.5,
            windowDuration: weekSeconds,
            metersModelIDs: ["claude-fable-5"]
        )

        let reading = MobileAccountUsageReading.resolve(
            account: account(windows: [fiveHour, weekly, fable, mythos]),
            model: "claude-fable-5"
        )

        XCTAssertEqual(reading?.rings.count, MobileUsageDefaults.ringCapacity)
        XCTAssertEqual(reading?.rings.map(\.id), ["7d", "5h", "Fable"])
        XCTAssertEqual(reading?.summary, "5h 43% · 7d 73% · 7d Fable 89% · 7d Mythos 50%")
    }

    func testALoginWithNothingToReportDrawsTheMarkAlone() {
        XCTAssertNil(MobileAccountUsageReading.resolve(account: nil, model: nil))

        let empty = MobileAccountUsageReading.resolve(account: account(windows: []), model: nil)
        XCTAssertEqual(empty?.rings, [])
        XCTAssertNil(empty?.summary)

        let silent = MobileAccountUsageReading.resolve(account: account(windows: nil), model: nil)
        XCTAssertEqual(silent?.rings, [])
    }
}

// MARK: - Disc Render

/// The rings are read from a picture, so the picture is what is tested: three rings sit 17, 14
/// and 11 points from the centre with a clear gap between each, and each ring wears its own
/// window's colour rather than the account's worst. A stroke drawn a point off would pass every
/// assertion about the reading and still touch its neighbour on screen.
@MainActor
final class MobileAccountDiscRenderTests: XCTestCase {

    private let scale: CGFloat = 3

    func testThreeRingsSitAtTheirRadiiWithClearGapsAndTheirOwnTints() throws {
        let reading = MobileAccountUsageReading(
            rings: [
                .init(id: "7d", fraction: 0.73),
                .init(id: "5h", fraction: 0.43),
                .init(id: "Fable", fraction: 0.95),
            ],
            summary: "5h 43% · 7d 73% · 7d Fable 95%"
        )
        let image = try render(MobileAccountDisc(identity: .resolve("claude"), reading: reading))
        try save(image, named: "account-disc-three-rings")

        // Up and to the right, an eighth of the way round, every arc above 12.5% is present.
        let outer = try pixel(in: image, atRadius: 17)
        let middle = try pixel(in: image, atRadius: 14)
        let inner = try pixel(in: image, atRadius: 11)
        XCTAssertGreaterThan(outer.alpha, 200, "the week's ring is drawn at 17pt")
        XCTAssertGreaterThan(middle.alpha, 200, "the five-hour ring is drawn at 14pt")
        XCTAssertGreaterThan(inner.alpha, 200, "the model's ring is drawn at 11pt")
        XCTAssertTrue(outer.green > outer.red && outer.green > outer.blue, "73% is comfortable: green")
        XCTAssertTrue(middle.green > middle.red && middle.green > middle.blue, "43% is comfortable: green")
        XCTAssertTrue(inner.red > inner.green && inner.red > inner.blue, "95% is nearly spent: red")

        let outerGap = try pixel(in: image, atRadius: 15.5)
        let innerGap = try pixel(in: image, atRadius: 12.5)
        XCTAssertLessThan(outerGap.alpha, 80, "a clear point between the week and the five hours")
        XCTAssertLessThan(innerGap.alpha, 80, "a clear point between the five hours and the model")
    }

    /// The login chip is drawn *inside* the disc, and this is the test that says why.
    ///
    /// A navigation bar clips its item at the item's own bounds, so the three-point overhang a
    /// row's tile uses came out as a badge with a flat bottom — 13 points of 15, measured off a
    /// simulator screenshot, and 9 at a wider one. Padding the item does not buy the room back.
    /// An offscreen render clips at that same edge, so an overhang restored here fails exactly
    /// the way the bar failed.
    func testTheLoginChipIsDrawnWhollyInsideTheDisc() throws {
        let disc = MobileAccountDisc(
            identity: .resolve("claude"),
            reading: MobileAccountUsageReading(
                rings: [.init(id: "7d", fraction: 0.56)],
                summary: "7d 56%"
            ),
            account: RemoteSessionAccountDTO(
                name: "Vera Keller",
                glyph: "V",
                isEmoji: false,
                hue: 0.72
            )
        )
        let image = try render(disc)
        try save(image, named: "account-disc-login-chip")

        let chip = try chipBounds(in: image)
        XCTAssertEqual(
            chip.height,
            MobileDesign.Size.accountChip,
            accuracy: 1,
            "the chip lost \(MobileDesign.Size.accountChip - chip.height) points off its bottom"
        )
        XCTAssertEqual(chip.width, MobileDesign.Size.accountChip, accuracy: 1)
    }

    /// The extent of the chip's own hue in the rendered disc, in points.
    private func chipBounds(in image: UIImage) throws -> CGSize {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let red = CGFloat(bytes[offset]) / 255
                let green = CGFloat(bytes[offset + 1]) / 255
                let blue = CGFloat(bytes[offset + 2]) / 255
                var hue: CGFloat = 0
                var saturation: CGFloat = 0
                var brightness: CGFloat = 0
                UIColor(red: red, green: green, blue: blue, alpha: 1)
                    .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
                guard (0.66...0.80).contains(hue), saturation > 0.35, brightness > 0.25 else {
                    continue
                }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else {
            throw XCTSkip("no chip was drawn at all")
        }
        return CGSize(
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale
        )
    }

    /// The mark must not grow into the innermost ring: at 16 points it ends 2 points short of it.
    func testTheMarkClearsTheInnermostRing() throws {
        let reading = MobileAccountUsageReading(
            rings: [
                .init(id: "7d", fraction: 1),
                .init(id: "5h", fraction: 1),
                .init(id: "Fable", fraction: 1),
            ],
            summary: nil
        )
        let image = try render(MobileAccountDisc(identity: .resolve("codex"), reading: reading))

        // Straight up, where a full arc and the mark's own extent would meet first.
        let ringEdge = try pixel(in: image, atRadius: 10, angle: .pi / 2)
        XCTAssertLessThan(ringEdge.alpha, 80, "the inside edge of the innermost ring is clear of the mark")
    }

    // MARK: - Helpers

    private struct Pixel {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int
    }

    private func render<Content: View>(_ content: Content) throws -> UIImage {
        let renderer = ImageRenderer(content: content.environment(\.remoteTheme, RemoteThemePalette(nil)))
        renderer.scale = scale
        return try XCTUnwrap(renderer.uiImage)
    }

    /// Samples the disc `radius` points from its centre, along `angle` from three o'clock.
    private func pixel(
        in image: UIImage,
        atRadius radius: CGFloat,
        angle: CGFloat = .pi / 4
    ) throws -> Pixel {
        let cgImage = try XCTUnwrap(image.cgImage)
        let centre = CGPoint(x: CGFloat(cgImage.width) / 2, y: CGFloat(cgImage.height) / 2)
        let point = CGPoint(
            x: centre.x + radius * scale * cos(angle),
            y: centre.y - radius * scale * sin(angle)
        )
        let cropped = try XCTUnwrap(cgImage.cropping(to: CGRect(
            x: Int(point.x.rounded()),
            y: Int(point.y.rounded()),
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
        return Pixel(red: Int(bytes[0]), green: Int(bytes[1]), blue: Int(bytes[2]), alpha: Int(bytes[3]))
    }

    /// Kept beside the assertions so a reviewer can look at what passed. `THREADING_RENDER_OUT`
    /// names the folder, as it does for the Mac's render tests; unset, the picture is not written.
    private func save(_ image: UIImage, named name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
              !folder.isEmpty else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: folder), withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: url)
    }
}

// MARK: - Usage Gauge

/// The chat menu's usage row asked for the percentages as a graphic rather than as words, and a
/// `UIMenu` row holds a title, a subtitle and an image — so the graphic has to *be* the image.
/// These pin that the picture is the same reading the disc rings, drawn whole at glyph size and
/// handed over in its own colours.
@MainActor
final class MobileAccountUsageGaugeTests: XCTestCase {

    private let scale: CGFloat = 3
    private let palette = RemoteThemePalette(nil)

    private var threeWindows: MobileAccountUsageReading {
        MobileAccountUsageReading(
            rings: [
                .init(id: "7d", fraction: 0.73),
                .init(id: "5h", fraction: 0.43),
                .init(id: "Fable", fraction: 0.95),
            ],
            summary: "5h 43% · 7d 73% · 7d Fable 95%"
        )
    }

    /// A host that reports usage in words alone rings nothing, and a blank glyph would say the
    /// account had spent nothing at all. The row keeps its symbol and its words instead.
    func testAReadingWithNoRingsDrawsNoGauge() {
        let wordsOnly = MobileAccountUsageReading(rings: [], summary: "5h 43% · 7d 73%")

        XCTAssertNil(MobileAccountUsageGauge.image(for: wordsOnly, theme: palette, scale: scale))
    }

    /// The outermost ring is stroked on the edge of its frame, so half of it lies outside: the
    /// renderer clips to what it was given, and without the inset the week's ring came out flat
    /// on four sides.
    func testTheGaugeIsGlyphSizedWithRoomForTheOutermostStroke() throws {
        let image = try XCTUnwrap(
            MobileAccountUsageGauge.image(for: threeWindows, theme: palette, scale: scale)
        )
        try save(image, named: "account-usage-gauge")

        let side = MobileDesign.Size.usageMenuGauge + 2 * MobileDesign.Size.usageMenuGaugeInset
        XCTAssertEqual(image.size.width, side, accuracy: 0.01)
        XCTAssertEqual(image.size.height, side, accuracy: 0.01)
        XCTAssertEqual(image.scale, scale, accuracy: 0.01)

        // Straight up, on the outermost ring's own radius, at full stroke width.
        let crown = try pixel(in: image, atRadius: 10, angle: .pi / 2)
        XCTAssertGreaterThan(crown.alpha, 200, "the outermost ring survives the render whole")
    }

    /// The same three rings the disc draws, at the same pitch, each in its own window's colour.
    /// Shrinking the drawing must not merge them into one thick arc or repaint them all in the
    /// account's worst reading.
    func testEachWindowRingsAtItsOwnRadiusAndItsOwnTint() throws {
        let image = try XCTUnwrap(
            MobileAccountUsageGauge.image(for: threeWindows, theme: palette, scale: scale)
        )

        let outer = try pixel(in: image, atRadius: 10)
        let middle = try pixel(in: image, atRadius: 7)
        let inner = try pixel(in: image, atRadius: 4)
        XCTAssertGreaterThan(outer.alpha, 200, "the week's ring is drawn at 10pt")
        XCTAssertGreaterThan(middle.alpha, 200, "the five-hour ring is drawn at 7pt")
        XCTAssertGreaterThan(inner.alpha, 200, "the model's ring is drawn at 4pt")
        XCTAssertTrue(outer.green > outer.red, "73% is comfortable: green")
        XCTAssertTrue(middle.green > middle.red, "43% is comfortable: green")
        XCTAssertTrue(inner.red > inner.green, "95% is nearly spent: red")
    }

    /// An arc past the point it was trimmed at is a lie about the account, whatever size it is
    /// drawn. A fifth of the way round, only the window over 20% has ink.
    func testAnArcStopsWhereItsWindowDoes() throws {
        let reading = MobileAccountUsageReading(
            rings: [.init(id: "7d", fraction: 0.5), .init(id: "5h", fraction: 0.1)],
            summary: nil
        )
        let image = try XCTUnwrap(
            MobileAccountUsageGauge.image(for: reading, theme: palette, scale: scale)
        )

        // A fifth of the way round from the top, clockwise: to the right and slightly down.
        let angle = CGFloat.pi / 2 - 2 * .pi * 0.2
        let half = try pixel(in: image, atRadius: 10, angle: angle)
        let tenth = try pixel(in: image, atRadius: 7, angle: angle)
        XCTAssertGreaterThan(half.alpha, 200, "50% has passed a fifth of the way round")
        XCTAssertLessThan(tenth.alpha, 120, "10% has not, so only its track is there")
    }

    /// A `Menu`'s content is built by the body that holds it, so a chat streaming terminal
    /// output asks for this glyph many times a second. The same reading is drawn once.
    func testTheSameReadingIsDrawnOnceAndAChangedOneIsDrawnAgain() throws {
        let first = try XCTUnwrap(
            MobileAccountUsageGauge.image(for: threeWindows, theme: palette, scale: scale)
        )
        let repeated = try XCTUnwrap(
            MobileAccountUsageGauge.image(for: threeWindows, theme: palette, scale: scale)
        )
        XCTAssertTrue(first === repeated, "an unchanged reading was rendered a second time")

        let spent = MobileAccountUsageReading(
            rings: [.init(id: "7d", fraction: 0.99)],
            summary: "7d 99%"
        )
        let redrawn = try XCTUnwrap(
            MobileAccountUsageGauge.image(for: spent, theme: palette, scale: scale)
        )
        XCTAssertFalse(first === redrawn, "a moved reading kept the picture of the old one")

        // And a screen at another scale is not handed the picture drawn for the first.
        let retina = try XCTUnwrap(
            MobileAccountUsageGauge.image(for: spent, theme: palette, scale: 2)
        )
        XCTAssertFalse(redrawn === retina)
        XCTAssertEqual(retina.scale, 2, accuracy: 0.01)
    }

    /// An authored theme names its own status colours, and the gauge is drawn from them. A
    /// cached picture must not outlive the palette it was drawn in.
    func testAnAuthoredThemeRedrawsTheGaugeInItsOwnStatusColours() throws {
        let authored = RemoteThemePalette(RemoteThemeDTO(
            id: "usage-gauge-test",
            name: "Usage gauge test",
            mode: .dark,
            colors: ["status_positive": "#3B6FE0"],
            material: RemoteThemeDTO.Material(panelRadius: 20, controlRadius: 10, borderWidth: 1)
        ))
        let comfortable = MobileAccountUsageReading(
            rings: [.init(id: "7d", fraction: 0.4)],
            summary: "7d 40%"
        )

        _ = MobileAccountUsageGauge.image(for: comfortable, theme: palette, scale: scale)
        let themed = try XCTUnwrap(
            MobileAccountUsageGauge.image(for: comfortable, theme: authored, scale: scale)
        )
        let ring = try pixel(in: themed, atRadius: 10, angle: .pi / 2)

        XCTAssertGreaterThan(ring.alpha, 200)
        XCTAssertTrue(ring.blue > ring.green, "the theme's own positive colour, not the fallback green")
    }

    /// A menu tints a template image with its own colour, which would paint a spent account and
    /// a fresh one the same. The severity tints are the reading.
    func testTheGaugeKeepsItsOwnColoursInsideAMenu() throws {
        let image = try XCTUnwrap(
            MobileAccountUsageGauge.image(for: threeWindows, theme: palette, scale: scale)
        )

        XCTAssertEqual(image.renderingMode, .alwaysOriginal)
    }

    // MARK: - Helpers

    private struct Pixel {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int
    }

    /// Samples the gauge `radius` points from its centre, along `angle` from three o'clock.
    private func pixel(
        in image: UIImage,
        atRadius radius: CGFloat,
        angle: CGFloat = .pi / 4
    ) throws -> Pixel {
        let cgImage = try XCTUnwrap(image.cgImage)
        let centre = CGPoint(x: CGFloat(cgImage.width) / 2, y: CGFloat(cgImage.height) / 2)
        let point = CGPoint(
            x: centre.x + radius * scale * cos(angle),
            y: centre.y - radius * scale * sin(angle)
        )
        let cropped = try XCTUnwrap(cgImage.cropping(to: CGRect(
            x: Int(point.x.rounded()),
            y: Int(point.y.rounded()),
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
        return Pixel(red: Int(bytes[0]), green: Int(bytes[1]), blue: Int(bytes[2]), alpha: Int(bytes[3]))
    }

    private func save(_ image: UIImage, named name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
              !folder.isEmpty else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: folder), withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: url)
    }
}
