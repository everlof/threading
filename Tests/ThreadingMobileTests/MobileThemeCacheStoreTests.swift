@testable import ThreadingMobile
import ThreadingRemoteKit
import XCTest
import CryptoKit
import UIKit
import CoreText
import AVFoundation
import os

@MainActor
final class MobileThemeCacheStoreTests: XCTestCase {
    func testThemeFontRegistersOnlyTheVerifiedDeclaredFamily() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "W95FA", withExtension: "otf", subdirectory: "Fonts/W95FA"))
        let bytes = try await Task.detached { try Data(contentsOf: url) }.value
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let descriptor = RemoteThemeAsset(slot: "font.0", digest: digest, byteCount: bytes.count,
            mediaType: "font/otf", pixelWidth: 0, pixelHeight: 0, fontFamily: "W95FA")
        // A font's one copy is the file it registers from.
        let fonts = directory.appendingPathComponent("RegisteredFonts")
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        try bytes.write(to: fonts.appendingPathComponent(digest))
        let worker = MobileThemeAssetCache(directory: directory)
        let names = await worker.registerFonts([descriptor], client: nil).names
        let name = try XCTUnwrap(names["W95FA"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(digest).path))
        XCTAssertEqual(try XCTUnwrap(UIFont(name: name, size: 17)).familyName, "W95FA")
        let wrong = RemoteThemeAsset(slot: "font.0", digest: digest, byteCount: bytes.count,
            mediaType: "font/otf", pixelWidth: 0, pixelHeight: 0, fontFamily: "Different Family")
        let rejected = await worker.registerFonts([wrong], client: nil)
        XCTAssertTrue(rejected.names.isEmpty)
        XCTAssertTrue(rejected.isComplete, "verified bytes of another family will never register")
        _ = await worker.registerFonts([], client: nil)
    }

    func testOnlyVerifiedShortPCMFilesReceiveAnInstalledSoundReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("fixture.caf")
        let bytes = try await Task.detached {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
            do {
                var file: AVAudioFile? = try AVAudioFile(forWriting: source, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
                buffer.frameLength = 1_600
                memset(buffer.int16ChannelData![0], 0, 3_200)
                try file?.write(from: buffer)
                    file = nil
            }
            return try Data(contentsOf: source)
        }.value
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try bytes.write(to: directory.appendingPathComponent(digest))
        let asset = RemoteThemeAsset(slot: "sound.needsAttention", digest: digest, byteCount: bytes.count,
            mediaType: "audio/x-caf", pixelWidth: 0, pixelHeight: 0)
        let sounds = directory.appendingPathComponent("Sounds")
        let worker = MobileThemeAssetCache(directory: directory, soundDirectory: sounds)
        let installed = await worker.installSounds([asset], client: nil)
        let name = try XCTUnwrap(installed.names[asset.slot])
        XCTAssertEqual(name, asset.notificationSoundName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sounds.appendingPathComponent(name).path))
        try Data(repeating: 0, count: bytes.count).write(to: directory.appendingPathComponent(digest))
        let corrupted = await worker.installSounds([asset], client: nil)
        XCTAssertTrue(corrupted.names.isEmpty)
        XCTAssertFalse(corrupted.isComplete, "unobtainable bytes are worth a retry")
    }
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MobileThemeCacheStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAContentAddressedPictureLoadsOfflineAndRejectsCorruption() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let data = try XCTUnwrap(image.pngData())
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let asset = RemoteThemeAsset(slot: "logo", digest: digest, byteCount: data.count,
            pixelWidth: image.cgImage!.width, pixelHeight: image.cgImage!.height)
        let file = directory.appendingPathComponent(digest)
        try data.write(to: file)
        let cache = MobileThemeAssetCache(directory: directory)
        let decoded = try await cache.image(asset, client: nil, maximumPixelSize: 12)
        XCTAssertNotNil(decoded)
        XCTAssertLessThanOrEqual(try XCTUnwrap(decoded).width, 12)
        try Data(repeating: 0, count: data.count).write(to: file)
        let corrupted = try await cache.image(asset, client: nil)
        XCTAssertNil(corrupted)
    }

    func testLastThemeReloadsForTheSameMacOnly() {
        let store = MobileThemeCacheStore(defaults: defaults)
        let theme = theme(id: "cyberpunk", ground: "#101015")

        XCTAssertTrue(store.remember(theme, for: "host:mac-a"))
        XCTAssertNil(store.theme(for: "host:mac-b"))

        let reloaded = MobileThemeCacheStore(defaults: defaults)
        XCTAssertEqual(reloaded.theme(for: "host:mac-a"), theme)
        XCTAssertNil(reloaded.theme(for: "host:mac-b"))
    }

    func testAPictureCachedForAMascotUpgradesForALogoWithoutNetworkAccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        }
        let data = try XCTUnwrap(image.pngData())
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try data.write(to: directory.appendingPathComponent(digest))
        func asset(_ slot: String) -> RemoteThemeAsset {
            .init(slot: slot, digest: digest, byteCount: data.count, pixelWidth: 512, pixelHeight: 512)
        }
        let mascot = asset("mascot.idle")
        let logo = asset("logo")
        let images = MobileThemeAssets(worker: MobileThemeAssetCache(directory: directory))
        func receive(_ assets: [RemoteThemeAsset]) async {
            let source = RemoteThemeDTO(id: "shared-picture", name: "Shared picture", mode: .dark,
                colors: [:], material: .init(panelRadius: 8, controlRadius: 4, borderWidth: 1),
                assets: assets)
            await images.receive(source, client: nil, displayScale: 3)
        }
        func expectWidth(_ width: Int) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while images.image(logo)?.cgImage?.width != width, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(images.image(logo)?.cgImage?.width, width)
        }
        await receive([mascot])
        try await expectWidth(192)
        // Deliberately keep the smaller slot first, and retain the original digest.
        await receive([mascot, logo])
        try await expectWidth(480)
        XCTAssertEqual(images.revision, 2)
    }

    func testCachedThemeBridgesLaunchButLiveThemeWinsAfterReconnect() {
        let cached = theme(id: "cached", ground: "#111111")
        let live = theme(id: "live", ground: "#F8F8F8", mode: .light)

        XCTAssertEqual(MobileThemeResolution.current(live: nil, cached: cached), cached)
        XCTAssertEqual(MobileThemeResolution.current(live: live, cached: cached), live)
    }

    func testSameThemeDoesNotRewriteTheArchive() throws {
        let store = MobileThemeCacheStore(defaults: defaults)
        let theme = theme(id: "threading", ground: "#101A2A")
        XCTAssertTrue(store.remember(theme, for: "host:mac"))
        let first = try XCTUnwrap(defaults.data(forKey: MobileThemeCacheStore.archiveKey))

        XCTAssertTrue(store.remember(theme, for: "host:mac"))

        XCTAssertEqual(defaults.data(forKey: MobileThemeCacheStore.archiveKey), first)
    }

    func testRecordsAreBoundedToTheMostRecentlyChangedMacs() {
        let store = MobileThemeCacheStore(defaults: defaults)
        for index in 0 ... MobileThemeCacheStore.maximumRecordCount {
            XCTAssertTrue(store.remember(
                theme(id: "theme-\(index)", ground: "#111111"),
                for: "host:mac-\(index)"
            ))
        }

        XCTAssertNil(store.theme(for: "host:mac-0"))
        XCTAssertEqual(
            store.theme(for: "host:mac-\(MobileThemeCacheStore.maximumRecordCount)")?.id,
            "theme-\(MobileThemeCacheStore.maximumRecordCount)"
        )
    }

    func testRejectedCandidateLeavesLastGoodThemeUntouched() {
        let store = MobileThemeCacheStore(defaults: defaults)
        let good = theme(id: "threading", ground: "#101A2A")
        XCTAssertTrue(store.remember(good, for: "host:mac"))
        let persisted = defaults.data(forKey: MobileThemeCacheStore.archiveKey)
        let invalid = theme(
            id: String(
                repeating: "x",
                count: MobileThemeCacheStore.maximumIdentifierBytes + 1
            ),
            ground: "#FFFFFF",
            mode: .light
        )

        XCTAssertFalse(store.remember(invalid, for: "host:mac"))
        XCTAssertEqual(store.theme(for: "host:mac"), good)
        XCTAssertEqual(defaults.data(forKey: MobileThemeCacheStore.archiveKey), persisted)
    }

    func testThemeWordsAreCachedAndBoundedWithTheTheme() {
        let store = MobileThemeCacheStore(defaults: defaults)
        let base = theme(id: "matrix", ground: "#020A04")
        let worded = RemoteThemeDTO(
            id: base.id, name: base.name, mode: base.mode, colors: base.colors,
            material: base.material,
            words: .init(
                working: ["Jacking in…"],
                composerPlaceholder: "Follow the white rabbit.",
                untitledSession: "Unknown program"
            )
        )
        XCTAssertTrue(store.remember(worded, for: "host:mac"))
        let reloaded = MobileThemeCacheStore(defaults: defaults).theme(for: "host:mac")
        XCTAssertEqual(reloaded?.words?.untitledSession, "Unknown program")
        XCTAssertEqual(RemoteThemePalette(reloaded).untitledSessionName, "Unknown program")
        XCTAssertEqual(RemoteThemePalette(reloaded).composerPlaceholder, "Follow the white rabbit.")

        let flooded = RemoteThemeDTO(
            id: base.id, name: base.name, mode: base.mode, colors: base.colors,
            material: base.material,
            words: .init(working: Array(
                repeating: "w",
                count: MobileThemeCacheStore.maximumThemeWorkingWords + 1
            ))
        )
        XCTAssertFalse(store.remember(flooded, for: "host:mac"))
        XCTAssertEqual(store.theme(for: "host:mac"), worded, "the last good theme stays")
    }

    func testCorruptArchiveIsQuarantinedBeforeAReplacementIsWritten() {
        let original = Data("not-json".utf8)
        defaults.set(original, forKey: MobileThemeCacheStore.archiveKey)

        let store = MobileThemeCacheStore(defaults: defaults)

        XCTAssertNil(defaults.data(forKey: MobileThemeCacheStore.archiveKey))
        XCTAssertTrue(defaults.dictionaryRepresentation().contains { key, value in
            key.hasPrefix(MobileThemeCacheStore.unreadableKeyPrefix)
                && (value as? Data) == original
        })
        XCTAssertTrue(store.remember(
            theme(id: "threading", ground: "#101A2A"),
            for: "host:mac"
        ))
    }

    func testNewerArchiveRemainsUntouchedAndDisablesThisOlderWriter() {
        let newer = Data(#"{"version":2,"records":[]}"#.utf8)
        defaults.set(newer, forKey: MobileThemeCacheStore.archiveKey)
        let store = MobileThemeCacheStore(defaults: defaults)

        XCTAssertFalse(store.remember(
            theme(id: "threading", ground: "#101A2A"),
            for: "host:mac"
        ))
        XCTAssertEqual(defaults.data(forKey: MobileThemeCacheStore.archiveKey), newer)
    }

    // MARK: - Theme asset transport, cache bounds and reloads

    func testThemeAssetDataAssemblesRangedChunksAndRefusesAWrongContentRange() async throws {
        let bytes = Data((0 ..< (2 * RemoteThemeAsset.maximumBytes + 512)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let asset = Self.fontAsset(bytes)
        let client = try Self.client()
        let session = ThemeAssetStubProtocol.session()
        ThemeAssetStubProtocol.serve { request in
            let header = request.value(forHTTPHeaderField: "Range") ?? ""
            guard let range = RemoteThemeAssetRange(header: header, total: bytes.count) else {
                return .init(status: 416, headers: [:], body: Data())
            }
            return .init(status: 206, headers: ["Content-Range": range.responseHeader],
                         body: bytes.subdata(in: range.bytes))
        }
        defer { ThemeAssetStubProtocol.reset() }

        let received = try await client.themeAssetData(asset, session: session)
        XCTAssertEqual(received, bytes)
        XCTAssertEqual(ThemeAssetStubProtocol.requestedRanges(), [
            "bytes=0-1048575", "bytes=1048576-2097151", "bytes=2097152-2097663",
        ])

        ThemeAssetStubProtocol.serve { request in
            let range = RemoteThemeAssetRange(header: request.value(forHTTPHeaderField: "Range") ?? "",
                                              total: bytes.count)!
            // The right bytes under another range's label.
            return .init(status: 206, headers: ["Content-Range": "bytes 0-1048575/\(bytes.count + 1)"],
                         body: bytes.subdata(in: range.bytes))
        }
        do {
            _ = try await client.themeAssetData(asset, session: session)
            XCTFail("a mislabelled range must not be assembled")
        } catch RemoteClientError.invalidResponse {
        }
    }

    func testBytesWhoseDigestDiffersFromTheManifestAreNeitherReturnedNorCached() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = Data(repeating: 7, count: 256)
        let asset = RemoteThemeAsset(slot: "logo", digest: Self.digest(expected), byteCount: expected.count,
            pixelWidth: 8, pixelHeight: 8)
        let session = ThemeAssetStubProtocol.session()
        ThemeAssetStubProtocol.serve { _ in .init(status: 200, headers: [:], body: Data(repeating: 8, count: 256)) }
        defer { ThemeAssetStubProtocol.reset() }
        let cache = MobileThemeAssetCache(directory: directory) { client, asset in
            try await client.themeAssetData(asset, session: session)
        }

        let data = try await cache.data(asset, client: try Self.client())

        XCTAssertNil(data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(asset.digest).path))
    }

    func testEvictionKeepsTheCurrentManifestAndBoundsHistory() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func image(_ index: Int) -> (RemoteThemeAsset, Data) {
            let data = Data("history-\(index)".utf8)
            return (RemoteThemeAsset(slot: "logo", digest: Self.digest(data), byteCount: data.count,
                pixelWidth: 8, pixelHeight: 8), data)
        }
        let history = (0 ..< MobileThemeAssetCache.maximumHistoryFiles + 8).map(image)
        let current = image(-1)
        // The current theme's picture is the least recently used file of all.
        try Self.write(current.1, to: directory.appendingPathComponent(current.0.digest), age: 100_000)
        for (index, entry) in history.enumerated() {
            try Self.write(entry.1, to: directory.appendingPathComponent(entry.0.digest), age: Double(history.count - index))
        }
        let arriving = image(10_000)
        let cache = MobileThemeAssetCache(directory: directory) { _, _ in arriving.1 }
        cache.pin([current.0.digest, arriving.0.digest])

        _ = try await cache.data(arriving.0, client: try Self.client())

        func exists(_ asset: RemoteThemeAsset) -> Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(asset.digest).path)
        }
        XCTAssertTrue(exists(current.0), "the current manifest is pinned")
        XCTAssertTrue(exists(arriving.0))
        let kept = history.filter { exists($0.0) }
        XCTAssertEqual(kept.count, MobileThemeAssetCache.maximumHistoryFiles)
        XCTAssertEqual(kept.map(\.0), history.suffix(MobileThemeAssetCache.maximumHistoryFiles).map(\.0),
                       "the most recently used history survives")
        XCTAssertGreaterThanOrEqual(MobileThemeAssetCache.maximumHistoryBytes, RemoteThemeAsset.maximumThemeBytes,
                                    "history holds at least one maximal non-font theme")
    }

    func testFontsAreStoredOnceAndTheirHistoryIsBoundedByBytes() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fonts = directory.appendingPathComponent("RegisteredFonts")
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        let historySize = MobileThemeAssetCache.maximumFontHistoryBytes / 2 + 1
        let older = Self.fontAsset(Data(repeating: 1, count: historySize))
        let newer = Self.fontAsset(Data(repeating: 2, count: historySize))
        try Self.write(Data(repeating: 1, count: historySize), to: fonts.appendingPathComponent(older.digest), age: 200)
        try Self.write(Data(repeating: 2, count: historySize), to: fonts.appendingPathComponent(newer.digest), age: 100)
        let bytes = Data(repeating: 3, count: 512)
        let arriving = Self.fontAsset(bytes)
        let cache = MobileThemeAssetCache(directory: directory) { _, _ in bytes }
        cache.pin([arriving.digest])

        _ = try await cache.data(arriving, client: try Self.client())

        XCTAssertTrue(FileManager.default.fileExists(atPath: fonts.appendingPathComponent(arriving.digest).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(arriving.digest).path),
                       "a font is never kept in the general cache as well")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fonts.appendingPathComponent(newer.digest).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fonts.appendingPathComponent(older.digest).path))
    }

    func testCurrentPicturesSurviveMemoryPressureUntilTheThemeDropsThem() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format)
            .image { context in
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }.pngData())
        let logo = RemoteThemeAsset(slot: "logo", digest: Self.digest(png), byteCount: png.count,
            pixelWidth: 32, pixelHeight: 32)
        try png.write(to: directory.appendingPathComponent(logo.digest))
        let assets = MobileThemeAssets(worker: MobileThemeAssetCache(directory: directory), defaults: defaults)

        await assets.receive(Self.theme(id: "pictures", assets: [logo]), client: nil, displayScale: 1)
        try await Self.waitUntil { assets.image(logo) != nil }
        assets.images.removeAllObjects()
        XCTAssertNotNil(assets.image(logo), "a wanted picture is held, not merely cached")

        await assets.receive(Self.theme(id: "plain"), client: nil, displayScale: 1)
        XCTAssertNotNil(assets.image(logo), "a dropped picture moves to history")
        assets.images.removeAllObjects()
        XCTAssertNil(assets.image(logo))
    }

    func testAFailedSoundRetriesOnReconnectAndReceiptsArePerMacAndSurviveATransientTheme() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try await Self.pcmSound(in: directory)
        let sound = RemoteThemeAsset(slot: "sound.needsAttention", digest: Self.digest(bytes), byteCount: bytes.count,
            mediaType: "audio/x-caf", pixelWidth: 0, pixelHeight: 0)
        let reachable = OSAllocatedUnfairLock(initialState: false)
        let worker = MobileThemeAssetCache(directory: directory,
            soundDirectory: directory.appendingPathComponent("Sounds")) { _, _ in
            guard reachable.withLock({ $0 }) else { throw URLError(.notConnectedToInternet) }
            return bytes
        }
        let assets = MobileThemeAssets(worker: worker, defaults: defaults)
        let client = try Self.client()
        let themed = Self.theme(id: "chime", assets: [sound])

        await assets.receive(themed, client: client, displayScale: 1, hostID: "mac-a", isOnline: false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(assets.confirmedSounds(for: "mac-a").isEmpty)

        reachable.withLock { $0 = true }
        await assets.receive(themed, client: client, displayScale: 1, hostID: "mac-a", isOnline: true)
        try await Self.waitUntil { !assets.confirmedSounds(for: "mac-a").isEmpty }
        let receipts = assets.confirmedSounds(for: "mac-a")
        XCTAssertEqual(receipts, [sound.slot: try XCTUnwrap(sound.notificationSoundName)])

        // The Mac between two renditions: same theme, no manifest yet.
        await assets.receive(Self.theme(id: "chime"), client: client, displayScale: 1, hostID: "mac-a", isOnline: true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(assets.confirmedSounds(for: "mac-a"), receipts)

        // Browsing another Mac keeps the first Mac's receipts, across launches too.
        await assets.receive(Self.theme(id: "quiet"), client: client, displayScale: 1, hostID: "mac-b", isOnline: true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(assets.confirmedSounds(for: "mac-a"), receipts)
        XCTAssertTrue(assets.confirmedSounds(for: "mac-b").isEmpty)
        let relaunched = MobileThemeAssets(worker: worker, defaults: defaults)
        XCTAssertEqual(relaunched.confirmedSounds(for: "mac-a"), receipts)
        relaunched.retainSoundReceipts(forHostIDs: ["mac-b"])
        XCTAssertTrue(MobileThemeAssets(worker: worker, defaults: defaults).confirmedSounds(for: "mac-a").isEmpty,
                      "an unpaired Mac's receipts are forgotten")

        // A real switch to a theme without sounds empties that Mac's receipts.
        await assets.receive(Self.theme(id: "quiet"), client: client, displayScale: 1, hostID: "mac-a", isOnline: true)
        try await Self.waitUntil { assets.confirmedSounds(for: "mac-a").isEmpty }
    }

    func testAShaderSourceThatFailedOfflineLoadsOnTheNextReceive() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "float4 threadingFixture() { return float4(0); }"
        let bytes = Data(text.utf8)
        let source = RemoteThemeAsset(slot: "surface.source", digest: Self.digest(bytes), byteCount: bytes.count,
            mediaType: "text/x-metal", pixelWidth: 0, pixelHeight: 0)
        let surface = RemoteThemeSurface(sourceDigest: source.digest,
            specification: .init(shaderResource: "fixture.metal", preferredFramesPerSecond: 24,
                inputs: [.init(name: "density", value: .constant(0.5))]))
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let worker = MobileThemeAssetCache(directory: directory) { _, _ in
            let attempt = attempts.withLock { count in
                count += 1
                return count
            }
            guard attempt > 1 else { throw URLError(.timedOut) }
            return bytes
        }
        let assets = MobileThemeAssets(worker: worker, defaults: defaults)
        let theme = RemoteThemeDTO(id: "rain", name: "Rain", mode: .dark, colors: [:],
            material: .init(panelRadius: 8, controlRadius: 4, borderWidth: 1), assets: [source], surface: surface)

        await assets.receive(theme, client: try Self.client(), displayScale: 1)
        try await Self.waitUntil { attempts.withLock { $0 } == 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(assets.source(for: surface))

        await assets.receive(theme, client: try Self.client(), displayScale: 1)
        try await Self.waitUntil { assets.source(for: surface) != nil }
        XCTAssertEqual(assets.source(for: surface), text)
        XCTAssertEqual(attempts.withLock { $0 }, 2)
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fontAsset(_ bytes: Data) -> RemoteThemeAsset {
        RemoteThemeAsset(slot: "font.0", digest: digest(bytes), byteCount: bytes.count,
            mediaType: "font/ttf", pixelWidth: 0, pixelHeight: 0, fontFamily: "Fixture")
    }

    private static func client() throws -> RemoteClient {
        RemoteClient(link: try XCTUnwrap(RemoteConnectionLink(
            baseURL: URL(string: "https://127.0.0.1:41003/")!, token: "token")))
    }

    private static func theme(id: String, assets: [RemoteThemeAsset]? = nil) -> RemoteThemeDTO {
        RemoteThemeDTO(id: id, name: id, mode: .dark, colors: [:],
            material: .init(panelRadius: 8, controlRadius: 4, borderWidth: 1), assets: assets)
    }

    private static func write(_ data: Data, to url: URL, age: TimeInterval) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)],
                                              ofItemAtPath: url.path)
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    private static func pcmSound(in directory: URL) async throws -> Data {
        let source = directory.appendingPathComponent("fixture-\(UUID().uuidString).caf")
        return try await Task.detached {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
            do {
                let file = try AVAudioFile(forWriting: source, settings: format.settings,
                                           commonFormat: .pcmFormatInt16, interleaved: true)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
                buffer.frameLength = 1_600
                memset(buffer.int16ChannelData![0], 0, 3_200)
                try file.write(from: buffer)
            }
            return try Data(contentsOf: source)
        }.value
    }

    private func theme(
        id: String,
        ground: String,
        mode: RemoteThemeMode = .dark
    ) -> RemoteThemeDTO {
        RemoteThemeDTO(
            id: id,
            name: id,
            mode: mode,
            colors: [
                "ground": ground,
                "label": mode == .light ? "#111111" : "#F8F8F8",
                "accent": "#FF7A45",
            ],
            material: RemoteThemeDTO.Material(
                panelRadius: 18,
                controlRadius: 9,
                borderWidth: 1,
                glow: .init(color: "#FF7A45", radius: 12, opacity: 0.2),
                textScale: 1,
                typeface: .rounded
            )
        )
    }
}

/// Serves theme-asset requests from a test's handler, recording each `Range` asked for.
private final class ThemeAssetStubProtocol: URLProtocol {
    struct Reply: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private static let handler = OSAllocatedUnfairLock<(@Sendable (URLRequest) -> Reply)?>(initialState: nil)
    private static let ranges = OSAllocatedUnfairLock<[String]>(initialState: [])

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThemeAssetStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func serve(_ reply: @escaping @Sendable (URLRequest) -> Reply) {
        handler.withLock { $0 = reply }
        ranges.withLock { $0 = [] }
    }

    static func reset() {
        handler.withLock { $0 = nil }
        ranges.withLock { $0 = [] }
    }

    static func requestedRanges() -> [String] { ranges.withLock { $0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let reply = Self.handler.withLock({ $0 }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let range = request.value(forHTTPHeaderField: "Range") ?? ""
        Self.ranges.withLock { $0.append(range) }
        let answer = reply(request)
        var headers = answer.headers
        headers["Content-Length"] = String(answer.body.count)
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
