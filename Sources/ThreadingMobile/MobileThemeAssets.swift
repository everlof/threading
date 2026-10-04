import CryptoKit
import CoreText
import AVFoundation
import Foundation
import ImageIO
import os
import SwiftUI
import ThreadingRemoteKit
import UIKit

/// Decoded pictures, registered fonts, a reviewed shader source and installed notification
/// sounds for the currently visible theme. A theme can render before this store has anything;
/// cache/network misses are absent decoration and never block navigation.
///
/// A kind counts as loaded only after a load succeeded. A failure retries with backoff while the
/// Mac is live, on the next `receive`, and at once when the Mac comes back.
@MainActor
final class MobileThemeAssets: ObservableObject {
    static let shared = MobileThemeAssets()
    static let didLoad = Notification.Name("MobileThemeAssetsDidLoad")
    static let soundReceiptsKey = "MobileThemeAssets.soundReceipts"
    /// Waits before the automatic retries of a failed load while the Mac is live. After the
    /// last one, the next theme change or reconnect tries again.
    static let retryDelays: [Duration] = [.seconds(2), .seconds(10), .seconds(60)]
    /// Receipts kept for Macs that are not being browsed. Pruned to the paired hosts.
    static let maximumSoundReceiptHosts = 16
    /// Pictures of earlier themes, which memory pressure may take.
    private static let historyImageBytes = 24 * 1_024 * 1_024
    private static let historyImageCount = 32
    private static let soundReceiptThemeKey = "theme"
    private static let soundReceiptNamesKey = "names"

    @Published private(set) var revision = 0
    private(set) var surfaceSource: String?

    private let worker: MobileThemeAssetCache
    private let defaults: UserDefaults
    /// History only. Internal so a test can empty it, standing in for memory pressure.
    let images = NSCache<NSString, UIImage>()
    /// The current manifest's pictures, held strongly: an `NSCache` eviction would leave a
    /// wanted slot empty with nothing to reload it. Bounded by the manifest's own count and
    /// byte budget (`RemoteThemeAsset.admitted`); `images` holds history only.
    private var currentImages: [String: UIImage] = [:]
    private var imageRequests: [String: ImageRequest] = [:]
    private var pending: [String: PendingLoad] = [:]
    private var imageRetryRounds = 0
    private var imageRetry: Task<Void, Never>?

    private var client: RemoteClient?
    private var isOnline = false
    private var loads: [LoadKind: KindLoad] = [:]
    private var fontAssets: [RemoteThemeAsset] = []
    private var fontNames: [String: String] = [:]
    private var surfaceAsset: RemoteThemeAsset?
    private var soundAssets: [RemoteThemeAsset] = []
    private var soundHostID: String?
    private var soundThemeID: String?
    private var soundReceipts: [String: SoundReceipt]

    private struct ImageRequest {
        let asset: RemoteThemeAsset
        let pixels: Int
    }

    private struct PendingLoad {
        let id: UUID
        let pixelBound: Int
        let task: Task<Void, Never>
    }

    private enum LoadKind { case fonts, sounds, surface }

    /// What one kind wants and how far it got.
    private struct KindLoad {
        var key: String?
        var generation = 0
        var task: Task<Void, Never>?
        var retry: Task<Void, Never>?
        var loaded = false
        var failures = 0
    }

    /// The sounds this phone last confirmed installed for one Mac, and the theme they came from.
    private struct SoundReceipt: Equatable {
        let themeID: String
        let names: [String: String]
    }

    init(worker: MobileThemeAssetCache = MobileThemeAssetCache(), defaults: UserDefaults = .standard) {
        self.worker = worker
        self.defaults = defaults
        images.totalCostLimit = Self.historyImageBytes
        images.countLimit = Self.historyImageCount
        soundReceipts = Self.storedSoundReceipts(in: defaults)
    }

    // MARK: - Lookups

    func image(_ asset: RemoteThemeAsset?) -> UIImage? {
        guard let digest = asset?.digest else { return nil }
        return currentImages[digest] ?? images.object(forKey: digest as NSString)
    }

    func source(for surface: RemoteThemeSurface) -> String? {
        surfaceAsset?.digest == surface.sourceDigest ? surfaceSource : nil
    }

    func fontName(for family: String?) -> String? {
        family.flatMap { fontNames[$0] }
    }

    /// The sounds this phone last confirmed for `hostID`'s theme, whether or not that Mac is
    /// the one being browsed.
    func confirmedSounds(for hostID: String?) -> [String: String] {
        hostID.flatMap { soundReceipts[$0]?.names } ?? [:]
    }

    /// Forgets receipts for Macs that are no longer paired.
    func retainSoundReceipts(forHostIDs hostIDs: Set<String>) {
        let retained = soundReceipts.filter { hostIDs.contains($0.key) }
        guard retained.count != soundReceipts.count else { return }
        soundReceipts = retained
        storeSoundReceipts()
    }

    // MARK: - Receiving a theme

    func receive(_ theme: RemoteThemeDTO?, client: RemoteClient?, displayScale: CGFloat,
                 hostID: String? = nil, isOnline: Bool = false) async {
        let assets = RemoteThemeAsset.admitted(theme?.assets) ?? []
        let becameOnline = isOnline && !self.isOnline
        self.client = client
        self.isOnline = isOnline
        worker.pin(Set(assets.map(\.digest)))

        // A theme without any manifest while its own receipts stand is the Mac between two
        // renditions: keep the confirmed receipts rather than publishing none.
        let transient = theme == nil
            || (theme?.assets == nil && hostID.flatMap { soundReceipts[$0]?.themeID } == theme?.id)
        if !transient {
            let sounds = assets.filter { $0.kind == .sound }
            soundAssets = sounds
            soundHostID = hostID
            soundThemeID = theme?.id
            let key = hostID.map { host in
                ([host, theme?.id ?? ""] + sounds.map { $0.slot + "=" + $0.digest }).joined(separator: "|")
            }
            if want(.sounds, key: key, becameOnline: becameOnline) { start(.sounds) }
        }

        let source = assets.first { $0.slot == "surface.source" && $0.digest == theme?.surface?.sourceDigest }
        if source?.digest != surfaceAsset?.digest { surfaceSource = nil }
        surfaceAsset = source
        if want(.surface, key: source?.digest, becameOnline: becameOnline) { start(.surface) }

        // Always a key, so a theme without fonts still unregisters the previous theme's.
        let fonts = Array(assets.filter { $0.kind == .font }.prefix(MobileThemeAssetCache.maximumFonts))
        let fontKey = fonts.map { $0.digest + "=" + ($0.fontFamily ?? "") }.joined(separator: "|")
        if fontKey != loads[.fonts]?.key {
            fontAssets = fonts
            if !fontNames.isEmpty {
                fontNames = [:]
                revision &+= 1
            }
        }
        if want(.fonts, key: fontKey, becameOnline: becameOnline) { start(.fonts) }

        // One picture may serve several slots. Decode for the largest current placement,
        // independent of wire order, and upgrade a smaller rendition retained from an old theme.
        var requests: [String: ImageRequest] = [:]
        for asset in assets where asset.kind == .image {
            let pointBound: CGFloat
            if asset.slot.hasPrefix("mascot.") { pointBound = 64 }
            else if asset.slot.hasPrefix("sprite.") { pointBound = 24 }
            else if asset.slot == "logo" { pointBound = 160 }
            else { pointBound = 1_290 }
            let pixelBound = min(asset.pixelBound ?? 512, Int(ceil(pointBound * max(displayScale, 1))))
            if pixelBound > (requests[asset.digest]?.pixels ?? 0) {
                requests[asset.digest] = ImageRequest(asset: asset, pixels: pixelBound)
            }
        }
        // Pictures the manifest no longer names become evictable history.
        for (digest, image) in currentImages where requests[digest] == nil {
            images.setObject(image, forKey: digest as NSString, cost: Self.cost(of: image))
            currentImages[digest] = nil
        }
        for (digest, load) in pending where requests[digest] == nil {
            load.task.cancel()
            pending[digest] = nil
        }
        imageRequests = requests
        if becameOnline {
            imageRetry?.cancel()
            imageRetry = nil
            imageRetryRounds = 0
        }
        requestImages()
    }

    // MARK: - Private Methods

    /// Records what `kind` wants and answers whether a load should start now: on a change,
    /// or to retry a failure (at once when the Mac just came back, otherwise unless a backoff
    /// retry is already scheduled).
    private func want(_ kind: LoadKind, key: String?, becameOnline: Bool) -> Bool {
        var load = loads[kind] ?? KindLoad()
        defer { loads[kind] = load }
        if load.key != key {
            load.task?.cancel()
            load.retry?.cancel()
            load = KindLoad(key: key, generation: load.generation &+ 1)
            return key != nil
        }
        guard key != nil, !load.loaded, load.task == nil else { return false }
        if becameOnline {
            load.retry?.cancel()
            load.retry = nil
            load.failures = 0
        }
        return load.retry == nil
    }

    private func start(_ kind: LoadKind) {
        guard var load = loads[kind] else { return }
        let generation = load.generation
        let client = client
        switch kind {
        case .fonts:
            let fonts = fontAssets
            load.task = Task { [weak self, worker] in
                let batch = await worker.registerFonts(fonts, client: client)
                guard let self, !Task.isCancelled, loads[.fonts]?.generation == generation else { return }
                if batch.names != fontNames {
                    fontNames = batch.names
                    announce()
                }
                finish(.fonts, generation: generation, succeeded: batch.isComplete)
            }
        case .sounds:
            guard let hostID = soundHostID else { return }
            let sounds = soundAssets
            let themeID = soundThemeID ?? ""
            let keeping = Set(soundReceipts.values.flatMap { $0.names.values })
            load.task = Task { [weak self, worker] in
                let batch = await worker.installSounds(sounds, client: client, keeping: keeping)
                guard let self, !Task.isCancelled, loads[.sounds]?.generation == generation else { return }
                // A partial install keeps the last confirmed receipts until a retry completes.
                if batch.isComplete { recordSounds(batch.names, themeID: themeID, for: hostID) }
                finish(.sounds, generation: generation, succeeded: batch.isComplete)
            }
        case .surface:
            guard let asset = surfaceAsset else { return }
            load.task = Task { [weak self, worker] in
                let outcome = await worker.source(asset, client: client)
                guard let self, !Task.isCancelled, loads[.surface]?.generation == generation else { return }
                if case .loaded(let text) = outcome {
                    surfaceSource = text
                    announce()
                }
                finish(.surface, generation: generation, succeeded: outcome != .unavailable)
            }
        }
        loads[kind] = load
    }

    private func finish(_ kind: LoadKind, generation: Int, succeeded: Bool) {
        guard var load = loads[kind], load.generation == generation else { return }
        defer { loads[kind] = load }
        load.task = nil
        if succeeded {
            load.loaded = true
            load.failures = 0
            return
        }
        load.failures += 1
        guard isOnline, load.failures <= Self.retryDelays.count else { return }
        let delay = Self.retryDelays[load.failures - 1]
        load.retry = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, var load = loads[kind], load.generation == generation else { return }
            load.retry = nil
            loads[kind] = load
            if !load.loaded, load.task == nil { start(kind) }
        }
    }

    private func requestImages() {
        let client = client
        for (digest, request) in imageRequests {
            if currentImages[digest] == nil, let kept = images.object(forKey: digest as NSString) {
                currentImages[digest] = kept
                images.removeObject(forKey: digest as NSString)
            }
            let sourceSize = max(request.asset.pixelWidth, request.asset.pixelHeight)
            let neededSize = min(request.pixels, sourceSize)
            if let existing = currentImages[digest]?.cgImage,
               max(existing.width, existing.height) >= neededSize { continue }
            if let load = pending[digest], load.pixelBound >= request.pixels { continue }
            pending[digest]?.task.cancel()
            let id = UUID()
            let task = Task { [weak self, worker] in
                let image = try? await worker.image(request.asset, client: client,
                    maximumPixelSize: request.pixels)
                guard let self, pending[digest]?.id == id else { return }
                pending[digest] = nil
                guard !Task.isCancelled else { return }
                guard let image else {
                    scheduleImageRetry()
                    return
                }
                // Still wanted: a load for a picture the manifest dropped was cancelled above.
                currentImages[digest] = UIImage(cgImage: image)
                announce()
            }
            pending[digest] = PendingLoad(id: id, pixelBound: request.pixels, task: task)
        }
    }

    /// One retry round covers every picture that failed meanwhile.
    private func scheduleImageRetry() {
        guard isOnline, imageRetry == nil, imageRetryRounds < Self.retryDelays.count else { return }
        let delay = Self.retryDelays[imageRetryRounds]
        imageRetryRounds += 1
        imageRetry = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            imageRetry = nil
            requestImages()
        }
    }

    private func recordSounds(_ names: [String: String], themeID: String, for hostID: String) {
        let receipt = SoundReceipt(themeID: themeID, names: names)
        let previous = soundReceipts[hostID]
        guard previous != receipt else { return }
        soundReceipts[hostID] = receipt
        while soundReceipts.count > Self.maximumSoundReceiptHosts,
              let other = soundReceipts.keys.first(where: { $0 != hostID }) {
            soundReceipts[other] = nil
        }
        storeSoundReceipts()
        if previous?.names != names { announce() }
    }

    private func announce() {
        revision &+= 1
        NotificationCenter.default.post(name: Self.didLoad, object: nil)
    }

    private static func cost(of image: UIImage) -> Int {
        image.cgImage.map { $0.width * $0.height * 4 } ?? 0
    }

    /// Property-list values rather than a coder: a handful of short strings, read once.
    private static func storedSoundReceipts(in defaults: UserDefaults) -> [String: SoundReceipt] {
        guard let stored = defaults.dictionary(forKey: soundReceiptsKey) else { return [:] }
        var receipts: [String: SoundReceipt] = [:]
        for (hostID, value) in stored.prefix(maximumSoundReceiptHosts) {
            guard let record = value as? [String: Any],
                  let themeID = record[soundReceiptThemeKey] as? String,
                  let names = record[soundReceiptNamesKey] as? [String: String],
                  RemoteThemeSound.acceptsReceipts(names) else { continue }
            receipts[hostID] = SoundReceipt(themeID: themeID, names: names)
        }
        return receipts
    }

    private func storeSoundReceipts() {
        let stored = soundReceipts.mapValues { receipt -> [String: Any] in
            [Self.soundReceiptThemeKey: receipt.themeID, Self.soundReceiptNamesKey: receipt.names]
        }
        defaults.set(stored, forKey: Self.soundReceiptsKey)
    }
}

/// What a batch of fonts or sounds produced.
struct MobileThemeAssetBatch: Sendable, Equatable {
    var names: [String: String] = [:]
    /// False when some asset's bytes could not be obtained, so a retry may still succeed.
    var isComplete = true
}

/// One asset's load. `unavailable` may succeed on a retry; `unusable` verified bytes never will.
enum MobileThemeAssetLoad<Value: Sendable & Equatable>: Sendable, Equatable {
    case loaded(Value)
    case unavailable
    case unusable
}

actor MobileThemeAssetCache {
    static let maximumFonts = 4
    static let maximumSounds = 2
    /// The general cache keeps the current theme, pinned and uncounted, plus this much history:
    /// five maximal non-font themes. Fonts are never stored here.
    static let maximumHistoryBytes = 5 * RemoteThemeAsset.maximumThemeBytes
    static let maximumHistoryFiles = 96
    /// `RegisteredFonts` is a font's only copy: the current theme's, plus one maximal face of
    /// history so switching back does not download it again.
    static let maximumFontHistoryBytes = RemoteThemeAsset.maximumFontBytes
    static let maximumFontHistoryFiles = 4
    /// Library/Sounds keeps recent sounds so an already accepted push still finds its file.
    static let maximumSoundHistoryFiles = 16
    private static let maximumScannedSoundFiles = 128
    /// How bytes come from the paired Mac. A seam for tests; production asks the client.
    typealias Fetch = @Sendable (RemoteClient, RemoteThemeAsset) async throws -> Data
    private let limiter = MobileMediaDownloadLimiter(capacity: 2)
    private let fetch: Fetch
    private let directory: URL
    private let fontDirectory: URL
    private let soundDirectory: URL
    private let pinned = OSAllocatedUnfairLock(initialState: Set<String>())
    private var registeredFonts: [String: URL] = [:]

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ThemeAssets", isDirectory: true), soundDirectory: URL? = nil,
         fetch: @escaping Fetch = { client, asset in try await client.themeAssetData(asset) }) {
        self.directory = directory
        self.fetch = fetch
        fontDirectory = directory.appendingPathComponent("RegisteredFonts", isDirectory: true)
        self.soundDirectory = soundDirectory ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    /// The current manifest's digests, which eviction never removes. Set synchronously, so a
    /// load started right after cannot run ahead of it.
    nonisolated func pin(_ digests: Set<String>) {
        pinned.withLock { $0 = digests }
    }

    func source(_ asset: RemoteThemeAsset, client: RemoteClient?) async -> MobileThemeAssetLoad<String> {
#if DEBUG
        let fixture = MobileThemeAssets.evidenceSurfaceSource
        if asset.kind == .shader, Self.verifies(Data(fixture.utf8), asset: asset) { return .loaded(fixture) }
#endif
        guard asset.kind == .shader else { return .unusable }
        guard let bytes = try? await data(asset, client: client) else { return .unavailable }
        return String(data: bytes, encoding: .utf8).map { .loaded($0) } ?? .unusable
    }

    func image(_ asset: RemoteThemeAsset, client: RemoteClient?, maximumPixelSize: Int? = nil) async throws -> CGImage? {
        guard asset.kind == .image, let data = try await data(asset, client: client) else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(asset.pixelBound ?? 512, max(maximumPixelSize ?? 1_290, 1)),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    /// Verified bytes from disk, the app bundle or the paired Mac; nil when unobtainable.
    func data(_ asset: RemoteThemeAsset, client: RemoteClient?) async throws -> Data? {
        guard asset.isValid else { return nil }
        let isFont = asset.kind == .font
        let url = (isFont ? fontDirectory : directory).appendingPathComponent(asset.digest)
        if let cached = read(url, asset: asset) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return cached
        }
        if let bundled = bundledFont(asset) { return bundled }
        guard let client else { return nil }
        let fetch = fetch
        let data = try await limiter.run { try await fetch(client, asset) }
        guard Self.verifies(data, asset: asset) else { return nil }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if isFont { evictFonts() } else { evict() }
        return data
    }

    func registerFonts(_ assets: [RemoteThemeAsset], client: RemoteClient?) async -> MobileThemeAssetBatch {
        let fonts = assets.prefix(Self.maximumFonts)
        let wanted = Set(fonts.map(\.digest))
        // What the theme no longer names is unregistered; its file stays as bounded history.
        for (digest, url) in registeredFonts where !wanted.contains(digest) {
            CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
            registeredFonts[digest] = nil
        }
        var batch = MobileThemeAssetBatch()
        for asset in fonts {
            guard !Task.isCancelled else {
                batch.isComplete = false
                break
            }
            guard asset.kind == .font, let family = asset.fontFamily else { continue }
            guard let bytes = try? await data(asset, client: client), !Task.isCancelled else {
                batch.isComplete = false
                continue
            }
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(bytes as CFData) as? [CTFontDescriptor],
                  let descriptor = descriptors.first(where: {
                      CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String == family
                  }), let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { continue }
            let url = fontDirectory.appendingPathComponent(asset.digest)
            if registeredFonts[asset.digest] == nil {
                do {
                    // A bundled face arrives as bytes; everything else is already this file.
                    if !FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.createDirectory(at: fontDirectory, withIntermediateDirectories: true)
                        try bytes.write(to: url, options: .atomic)
                    }
                    var error: Unmanaged<CFError>?
                    if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                        registeredFonts[asset.digest] = url
                    } else if let error,
                              CFErrorGetCode(error.takeRetainedValue()) == CTFontManagerError.alreadyRegistered.rawValue {
                        // The same face is registered from elsewhere; its name already resolves.
                    } else {
                        continue
                    }
                } catch {
                    batch.isComplete = false
                    continue
                }
            }
            batch.names[family] = name
        }
        evictFonts()
        return batch
    }

    /// Installs up to two sounds into Library/Sounds. `keeping` names files other Macs' receipts
    /// still point at; history eviction leaves them alone.
    func installSounds(_ assets: [RemoteThemeAsset], client: RemoteClient?,
                       keeping: Set<String> = []) async -> MobileThemeAssetBatch {
        let folder = soundDirectory
        var batch = MobileThemeAssetBatch()
        for asset in assets.prefix(Self.maximumSounds) {
            guard !Task.isCancelled else {
                batch.isComplete = false
                break
            }
            guard let name = asset.notificationSoundName else { continue }
            guard let bytes = try? await data(asset, client: client), !Task.isCancelled else {
                batch.isComplete = false
                continue
            }
            let url = folder.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try bytes.write(to: url, options: .atomic)
                let file = try AVAudioFile(forReading: url)
                let duration = Double(file.length) / file.fileFormat.sampleRate
                guard duration.isFinite, duration > 0, duration < 30,
                      file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else {
                    try? FileManager.default.removeItem(at: url); continue
                }
                batch.names[asset.slot] = name
            } catch { try? FileManager.default.removeItem(at: url) }
        }
        evictSounds(protecting: keeping.union(batch.names.values))
        return batch
    }

    static func verifies(_ data: Data, asset: RemoteThemeAsset) -> Bool {
        guard asset.isValid, data.count == asset.byteCount else { return false }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == asset.digest
    }

    private func read(_ url: URL, asset: RemoteThemeAsset) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == asset.byteCount, let data = try? Data(contentsOf: url),
              Self.verifies(data, asset: asset) else { return nil }
        return data
    }

    private func bundledFont(_ asset: RemoteThemeAsset) -> Data? {
        guard asset.kind == .font else { return nil }
        // The app already carries these licensed period faces. Reuse only identical bytes;
        // other owner-supplied fonts still require the authenticated paired asset route.
        for (name, type, folder) in [("W95FA", "otf", "Fonts/W95FA"), ("Topaz_a1200_v1.0", "ttf", "Fonts/Topaz")] {
            if let url = Bundle.main.url(forResource: name, withExtension: type, subdirectory: folder),
               let data = read(url, asset: asset) { return data }
        }
        return nil
    }

    /// Keeps a small history so an already accepted push still finds its exact sound.
    private func evictSounds(protecting protected: Set<String>) {
        guard let enumerator = FileManager.default.enumerator(at: soundDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where RemoteThemeSound.acceptsName(url.lastPathComponent) {
            files.append((url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
            if files.count >= Self.maximumScannedSoundFiles { break }
        }
        files.sort { $0.1 > $1.1 }
        for (url, _) in files.dropFirst(Self.maximumSoundHistoryFiles) where !protected.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func evict() {
        evict(directory, keeping: pinned.withLock { $0 },
              historyBytes: Self.maximumHistoryBytes, historyFiles: Self.maximumHistoryFiles)
    }

    private func evictFonts() {
        evict(fontDirectory, keeping: pinned.withLock { $0 }.union(registeredFonts.keys),
              historyBytes: Self.maximumFontHistoryBytes, historyFiles: Self.maximumFontHistoryFiles)
    }

    /// Keeps `keeping` and the most recently used other digest files within the history
    /// budget. The directory holds only digest files and is evicted after every write, so the
    /// enumeration stays short; it runs on this worker, never in a render callback.
    private func evict(_ directory: URL, keeping: Set<String>, historyBytes: Int, historyFiles: Int) {
        guard let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return }
        var files: [(url: URL, size: Int, date: Date)] = []
        for case let url as URL in enumerator {
            guard RemoteThemeAsset.acceptsDigest(url.lastPathComponent), !keeping.contains(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            files.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        files.sort { $0.date > $1.date }
        var bytes = 0
        var full = false
        for (index, file) in files.enumerated() {
            bytes += file.size
            full = full || index >= historyFiles || bytes > historyBytes
            if full { try? FileManager.default.removeItem(at: file.url) }
        }
    }
}

extension RemoteThemePalette {
    func asset(_ slot: String) -> RemoteThemeAsset? {
        source?.assets?.first { $0.slot == slot && $0.isValid }
    }
}

/// One decorative slot, outside the row reuse pool. Host catalogue state selects the pose;
/// themes supply pictures only. Missing assets collapse the entire slot.
struct MobileThemeCharacterHeader: View {
    let theme: RemoteThemePalette
    let mood: String
    @ObservedObject private var assets = MobileThemeAssets.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MobileThemeMotionPreferences.motionKey) private var permitsMotion = true
    @State private var previousMood: String?
    @State private var celebratesCompletion = false

    private var pose: RemoteThemeAsset? {
        let displayedMood = celebratesCompletion ? "celebrating" : mood
        return theme.asset("mascot.\(displayedMood)") ?? theme.asset("mascot.idle")
    }

    var body: some View {
        let logo = assets.image(theme.asset("logo"))
        let mascot = assets.image(pose)
        if logo != nil || mascot != nil {
            HStack(spacing: MobileDesign.Spacing.inset) {
                if let logo {
                    Image(uiImage: logo).resizable().scaledToFit().frame(maxWidth: 160, maxHeight: 48)
                }
                if let mascot {
                    Image(uiImage: mascot).resizable().scaledToFit().frame(width: 64, height: 64)
                        .id(pose?.digest)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .padding(.vertical, MobileDesign.Spacing.small)
            .background(theme.surface)
            .animation(permitsMotion && !reduceMotion && scenePhase == .active && !ProcessInfo.processInfo.isLowPowerModeEnabled
                ? .easeInOut(duration: 0.18) : nil, value: pose?.digest)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: mood) {
                let finished = previousMood == "working" && mood == "idle"
                previousMood = mood
                celebratesCompletion = finished && permitsMotion && !reduceMotion && scenePhase == .active
                    && !ProcessInfo.processInfo.isLowPowerModeEnabled
                    && theme.asset("mascot.celebrating") != nil
                guard celebratesCompletion else { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                celebratesCompletion = false
            }
        }
    }
}

#if DEBUG
extension MobileThemeAssets {
    // Reviewed SDK RainWindowExtension fixture, using the same public fragment ABI.
    nonisolated static let evidenceSurfaceSource = """
    // Input ABI, in declaration order from main.swift:
    // values[0] density, values[1] opacity, values[2] speed.

    float threadingRainHash(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    float threadingRainLayer(
        float2 uv,
        float time,
        float density,
        float scale,
        float speed,
        float seed,
        float groundY
    ) {
        float2 p = uv;
        p.x *= scale;
        p.y *= scale * 0.58;
        p.x += p.y * 0.17;

        float2 cell = floor(p);
        float2 local = fract(p);
        float random = threadingRainHash(cell + seed);
        float active = smoothstep(1.0 - density, 1.0, random);

        float fall = fract(time * speed * (0.58 + random * 0.9) + random);
        float y = fract(local.y - fall);
        float x = abs(local.x - (0.12 + random * 0.76));
        float width = 0.018 + (1.0 - scale / 58.0) * 0.018;
        float streakLength = 0.18 + random * 0.42;

        float streak = smoothstep(width, 0.0, x)
            * smoothstep(streakLength, streakLength * 0.45, y)
            * smoothstep(0.0, 0.035, y);
        float head = smoothstep(
            width * 2.8,
            0.0,
            length(float2(y - streakLength * 0.5, x * 2.0))
        );
        float aboveGround = 1.0 - smoothstep(groundY - 0.025, groundY + 0.004, uv.y);
        return active * (streak + head * 0.32) * (0.45 + random * 0.55)
            * aboveGround;
    }

    float threadingRainSplash(
        float2 uv,
        float time,
        float density,
        float columns,
        float speed,
        float seed,
        float groundY
    ) {
        float columnPosition = uv.x * columns;
        float column = floor(columnPosition);
        float localX = fract(columnPosition) - 0.5;
        float random = threadingRainHash(float2(column, seed));
        float active = smoothstep(
            1.0 - density,
            1.0,
            threadingRainHash(float2(column + 17.0, seed * 2.7))
        );

        // One short impact phase per column. Scaling y by the column count gives the splash the
        // same proportions at every window size rather than stretching it with the viewport.
        float age = fract(time * speed * (0.24 + random * 0.22) + random);
        float2 p = float2(
            localX,
            (uv.y - groundY) * columns
        );
        float life = 1.0 - smoothstep(0.0, 0.46, age);

        // A flattened ring races out along the contact plane.
        float ringRadius = 0.05 + age * 0.46;
        float ringDistance = abs(length(float2(p.x, p.y * 5.5)) - ringRadius);
        float ring = smoothstep(0.045, 0.006, ringDistance)
            * smoothstep(0.14, 0.0, abs(p.y))
            * life;

        // Two crown droplets peel away from the impact and fall back into the wet edge.
        float crownAge = min(age / 0.46, 1.0);
        float lift = sin(crownAge * 3.14159265) * (0.17 + random * 0.10);
        float spread = 0.045 + crownAge * (0.22 + random * 0.09);
        float crownLeft = smoothstep(
            0.065,
            0.008,
            length(p - float2(-spread, -lift))
        );
        float crownRight = smoothstep(
            0.065,
            0.008,
            length(p - float2(spread, -lift * 0.84))
        );

        // The first bright contact point makes the falling streak and its splash read as one event.
        float contact = smoothstep(
            0.10,
            0.0,
            length(float2(p.x, p.y * 2.4))
        ) * (1.0 - smoothstep(0.0, 0.11, age));

        return active * (ring * 0.78 + (crownLeft + crownRight) * life + contact);
    }

    float4 threadingExtensionFragment(
        float2 uv,
        constant ThreadingSurfaceUniforms &uniforms
    ) {
        float density = clamp(uniforms.values[0], 0.0, 1.0);
        float opacity = clamp(uniforms.values[1], 0.0, 0.65);
        float speed = max(uniforms.values[2], 0.0);
        if (density <= 0.001 || speed <= 0.001) {
            return float4(0.0);
        }

        float aspect = max(uniforms.size.x / max(uniforms.size.y, 1.0), 0.4);
        float2 rainUV = float2(uv.x * aspect, uv.y);
        float time = uniforms.time;
        float groundY = 0.935;

        float farRain = threadingRainLayer(
            rainUV, time, density * 0.48, 22.0, speed * 0.72, 7.0, groundY
        );
        float midRain = threadingRainLayer(
            rainUV, time, density * 0.72, 36.0, speed, 19.0, groundY
        );
        float nearRain = threadingRainLayer(
            rainUV, time, density, 54.0, speed * 1.35, 41.0, groundY
        );
        float rain = farRain * 0.28 + midRain * 0.52 + nearRain * 0.82;

        float farSplash = threadingRainSplash(
            rainUV, time, density * 0.58, 18.0, speed * 0.76, 11.0, groundY
        );
        float nearSplash = threadingRainSplash(
            rainUV, time, density, 31.0, speed * 1.08, 37.0, groundY
        );
        float splash = farSplash * 0.46 + nearSplash * 0.92;

        // A shallow wet edge anchors the impacts. It is intentionally subtle: the extension is an
        // overlay over working UI, not a scene which may cover its controls.
        float wetEdge = smoothstep(groundY - 0.008, groundY + 0.018, uv.y)
            * (1.0 - smoothstep(groundY + 0.085, groundY + 0.15, uv.y))
            * density * density;

        // A subtle veil makes a near-spent account feel stormier without washing out text.
        float veil = density * density * 0.035
            * (0.55 + 0.45 * sin((uv.y + time * 0.025) * 31.0));
        float alpha = clamp(
            rain * opacity
                + splash * opacity * 0.92
                + wetEdge * opacity * 0.10
                + veil,
            0.0,
            0.62
        );
        float3 coldLight = mix(
            float3(0.52, 0.64, 0.74),
            float3(0.88, 0.94, 1.0),
            clamp(rain + splash * 1.3, 0.0, 1.0)
        );
        return float4(coldLight, alpha);
    }
    """

    static func evidenceSurface() -> (RemoteThemeSurface, RemoteThemeAsset) {
        let bytes = Data(evidenceSurfaceSource.utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let surface = RemoteThemeSurface(sourceDigest: digest,
            specification: .init(shaderResource: "usage-rain.metal", preferredFramesPerSecond: 24,
                inputs: [.init(name: "density", value: .constant(0.9)),
                         .init(name: "opacity", value: .constant(0.8)),
                         .init(name: "speed", value: .constant(0.4))]))
        let asset = RemoteThemeAsset(slot: "surface.source", digest: digest, byteCount: bytes.count,
            mediaType: "text/x-metal", pixelWidth: 0, pixelHeight: 0)
        return (surface, asset)
    }

    static var evidenceFont: RemoteThemeAsset {
        .init(slot: "font.0", digest: "9e1ad53708307b2b68e06d43799b2267f6aec620dda972bc62753ad16ba50f2b",
            byteCount: 43_372, mediaType: "font/otf", pixelWidth: 0, pixelHeight: 0, fontFamily: "W95FA")
    }

    /// Small deterministic fixture pictures: exercises the shipping digest/image lookup without
    /// depending on a running Mac or downloading artwork during evidence capture.
    static func evidenceAssets() -> [RemoteThemeAsset] {
        let slots = ["backdrop", "logo", "mascot.idle", "mascot.working", "mascot.attention", "sprite.0"]
        return slots.compactMap { slot in
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let size = CGSize(width: slot == "logo" ? 160 : 128, height: slot == "logo" ? 48 : 128)
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                let ink = UIColor(remoteHex: "#66FFAA")!
                ink.setFill()
                if slot == "backdrop" {
                    UIColor(remoteHex: "#204A66")!.setFill(); context.fill(CGRect(origin: .zero, size: size))
                    for index in 0..<4 {
                        ink.withAlphaComponent(0.4).setFill()
                        context.fill(CGRect(x: index * 32, y: index * 20, width: 16, height: 128))
                    }
                } else if slot == "logo" {
                    ("THREADING" as NSString).draw(at: CGPoint(x: 8, y: 10), withAttributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 24, weight: .bold), .foregroundColor: ink
                    ])
                } else if slot == "sprite.0" {
                    UIBezierPath(roundedRect: CGRect(x: 32, y: 16, width: 64, height: 96), cornerRadius: 12).fill()
                } else {
                    UIBezierPath(ovalIn: CGRect(x: 12, y: 8, width: 104, height: 112)).fill()
                    UIColor(remoteHex: "#102020")!.setFill()
                    let eyeHeight: CGFloat = slot == "mascot.working" ? 24 : 14
                    for x in [CGFloat(32), 76] {
                        UIBezierPath(ovalIn: CGRect(x: x, y: 40, width: 20, height: eyeHeight)).fill()
                    }
                    context.fill(CGRect(x: 48, y: 84, width: 32, height: slot == "mascot.attention" ? 14 : 4))
                }
            }
            guard let data = image.pngData(), let cg = image.cgImage else { return nil }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let asset = RemoteThemeAsset(slot: slot, digest: digest, byteCount: data.count,
                pixelWidth: cg.width, pixelHeight: cg.height,
                opacity: slot == "backdrop" ? 0.18 : nil, tinted: slot == "sprite.0" ? true : nil)
            shared.images.setObject(image, forKey: digest as NSString, cost: cg.width * cg.height * 4)
            return asset
        }
    }
}
#endif
