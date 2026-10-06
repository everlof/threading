import AppKit
import CryptoKit
import CoreText
import AVFoundation
import ImageIO
import ThreadingRemoteKit
import ThreadingExtensionKit

struct RemoteThemeAssetsDidChange: AppEvent {
    static let name = Notification.Name("remoteThemeAssetsDidChange")
}

/// Where an admitted asset's bytes live. Pictures, sounds and a surface's source are small
/// renditions held in memory; a font stays in its file and the route reads only the requested
/// range on its own queue, so a theme's fonts (up to 4 × 16 MiB) are never resident here.
enum RemoteThemeAssetPayload: Sendable, Equatable {
    case bytes(Data)
    case file(URL)

    /// The bytes in `range` (the whole asset when nil), or nil when a file no longer has the
    /// size it was admitted at. Called off the main actor; a range is at most one response.
    func read(_ range: Range<Int>?, expectedCount: Int) -> Data? {
        switch self {
        case .bytes(let data):
            guard data.count == expectedCount else { return nil }
            return range.map { data.subdata(in: $0) } ?? data
        case .file(let url):
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd(), size == UInt64(expectedCount) else { return nil }
            let requested = range ?? 0..<expectedCount
            guard (try? handle.seek(toOffset: UInt64(requested.lowerBound))) != nil,
                  let data = try? handle.read(upToCount: requested.count),
                  data.count == requested.count else { return nil }
            return data
        }
    }
}

/// Current-theme admission lives on the host; a digest grants no access by itself.
///
/// Nothing is prepared until a client or a push first asks (`manifest`, `soundName`), so a Mac
/// with no paired device does no rendition work. Afterwards the admitted set follows the current
/// theme: switching theme or variant retires the old set immediately, before any replacement is
/// ready, while an edit of the same theme and variant keeps serving the published set until
/// its replacement is prepared, and announces a change only when the set actually differs. A
/// transient empty set would otherwise make every paired phone drop its fonts, pictures, shader
/// and sound receipts on each library or customization event and each live-tuning tick.
@MainActor
final class RemoteThemeAssets {
    static let shared = RemoteThemeAssets()
    /// Pointer-cadence live tuning and rapid appearance changes settle into one preparation.
    static let preparationDelay: Duration = .milliseconds(150)
    private let events = AppEventObservations()
    private let worker = RemoteThemeRenditionWorker()
    private var pending: Task<Void, Never>?
    /// The theme and variant the admitted set belongs to; nil until first asked for.
    private var key: String?
    private var generation = 0
    private var assets: [RemoteThemeAsset] = []
    private var payloads: [String: RemoteThemeAssetPayload] = [:]
    private(set) var surface: RemoteThemeSurface?

    private init() {
        events.observe(AppThemeDidChange.self) { [weak self] change in
            // A Tune drag's ticks are unsaved previews; its release posts a settled change.
            guard !change.isLivePreview else { return }
            self?.refresh()
        }
        events.observe(AppThemeLibraryDidChange.self) { [weak self] _ in self?.refresh() }
        events.observe(ComponentCustomizationDidChange.self) { [weak self] change in
            // Only the sidebar backdrop is projected; other components' patches cannot change it.
            guard change.targets?.contains(Self.backdropTarget) ?? true else { return }
            self?.refresh()
        }
        events.observe(ExtensionSettingsValuesDidChange.self) { [weak self] _ in
            // A projected surface carries its setting bindings as constants, so only a surface
            // that binds a setting has anything to re-project.
            guard Self.surfaceHook()?.specification.boundSettingIDs.isEmpty == false else { return }
            self?.refresh()
        }
    }

    private static var backdropTarget: ExtensionComponentTarget {
        let contract = ThreadingComponentCatalog.sidebarBackdrop
        return ExtensionComponentTarget(component: contract.id, contractVersion: contract.version)
    }

    private static func key(for theme: AppTheme, appearance: NSAppearance) -> String {
        theme.id.rawValue + "|" + theme.variantKind(for: appearance).rawValue
    }

    private func refresh() {
        guard key != nil else { return }
        let current = AppThemeLibrary.current
        prepare(current, appearance: RemoteThemeBridge.drawingAppearance(for: current))
    }

    func manifest(for theme: AppTheme, appearance: NSAppearance) -> [RemoteThemeAsset]? {
        guard theme.id == AppThemeLibrary.current.id else { return nil }
        if Self.key(for: theme, appearance: appearance) != key {
            prepare(theme, appearance: appearance)
        }
        return assets.isEmpty ? nil : assets
    }

    /// Starts (or restarts, after the coalescing delay) preparation of `theme`'s set.
    private func prepare(_ theme: AppTheme, appearance: NSAppearance) {
        let requested = Self.key(for: theme, appearance: appearance)
        if requested != key {
            retire()
            key = requested
        }
        generation &+= 1
        pending?.cancel()
        let variant = theme.variant(for: appearance)
        let sources = Self.sources(theme: theme, variant: variant)
        let families = variant?.material.fontFamilies ?? []
        let fontDirectory = ThemeFontStore.folder(for: theme.id)
        let fontURLs = ExtensionAppearanceRegistry.shared.phoneFontURLs(families: families)
        let hook = Self.surfaceHook().map(Self.resolvingSettingInputs)
        let expected = generation
        pending = Task { [weak self, worker] in
            do { try await Task.sleep(for: Self.preparationDelay) } catch { return }
            var prepared = await worker.prepare(sources, fontDirectory: fontDirectory,
                fontURLs: fontURLs, fontFamilies: families)
            let backdrop = if let hook { await worker.prepareSurface(hook.specification, root: hook.root) } else { nil as RemoteThemeRenditionWorker.PreparedSurface? }
            guard let self, !Task.isCancelled, generation == expected else { return }
            var preparedSurface: RemoteThemeSurface?
            if let hook, let backdrop,
               ExtensionManager.shared.remoteSurfaceResourceRoot(for: hook.identifier)?.generation == hook.generation {
                prepared.append(contentsOf: backdrop.assets)
                preparedSurface = backdrop.surface
            }
            let admitted = RemoteThemeAsset.admitted(prepared.map(\.asset)) ?? []
            prepared = prepared.filter { admitted.contains($0.asset) }
            if !admitted.contains(where: { $0.slot == "surface.source" }) { preparedSurface = nil }
            pending = nil
            let changed = admitted != assets || preparedSurface != surface
            assets = admitted
            // Stored even when the set is unchanged: the same font bytes may now live at
            // another path, which is where the route has to read them from.
            payloads = Dictionary(prepared.map { ($0.asset.digest, $0.payload) }, uniquingKeysWith: { a, _ in a })
            surface = preparedSurface
            if changed { NotificationCenter.default.post(RemoteThemeAssetsDidChange()) }
        }
    }

    /// Ends the current admission at once: another theme or variant is about to be prepared.
    private func retire() {
        generation &+= 1
        pending?.cancel(); pending = nil; key = nil
        assets = []; payloads = [:]
        surface = nil
    }

    func payload(for digest: String) -> RemoteThemeAssetPayload? {
        guard RemoteThemeAsset.acceptsDigest(digest), assets.contains(where: { $0.digest == digest }) else { return nil }
        return payloads[digest]
    }

    func descriptor(for digest: String) -> RemoteThemeAsset? {
        assets.first { $0.digest == digest }
    }

    /// A push may be the first thing to ask after launch, with no client connected yet: it
    /// starts preparation so later pushes can name the theme's sound, and uses the default now.
    func soundName(for kind: RemoteNotificationKind, confirmed: [String: String]) -> String? {
        if key == nil { refreshCurrent() }
        guard let slot = RemoteThemeSound.slot(for: kind), let name = confirmed[slot],
              assets.contains(where: { $0.slot == slot && $0.notificationSoundName == name }) else { return nil }
        return name
    }

    private func refreshCurrent() {
        let current = AppThemeLibrary.current
        prepare(current, appearance: RemoteThemeBridge.drawingAppearance(for: current))
    }

    struct SurfaceHook {
        let identifier: String
        let generation: String
        let root: URL
        let specification: ExtensionMetalSurface
    }

    /// The sidebar backdrop surface a phone may draw, read from the same resolved
    /// customization the Mac's plane renders. A patch scoped to its extension's own themes is
    /// therefore projected exactly while the Mac draws it, and the registry's change for the
    /// backdrop target on a theme switch is what re-prepares the set.
    static func surfaceHook(
        resourceRoot: (String) -> (root: URL, generation: String)? = {
            ExtensionManager.shared.remoteSurfaceResourceRoot(for: $0)
        }
    ) -> SurfaceHook? {
        for hook in ComponentCustomizationProviderSlot.shared.customization(for: backdropTarget).hooks {
            guard case .overlay(let base, let overlay) = hook.node, overlay == .proceed,
                  case .customSurface(.metal(let specification), _) = base, specification.isValid,
                  let resource = resourceRoot(hook.extensionIdentifier) else { continue }
            return SurfaceHook(identifier: hook.extensionIdentifier, generation: resource.generation,
                root: resource.root, specification: specification)
        }
        return nil
    }

    private static func sources(theme: AppTheme, variant: AppTheme.Variant?) -> [RemoteThemeRenditionWorker.Source] {
        guard let variant else { return [] }
        var result: [RemoteThemeRenditionWorker.Source] = []
        func append(slot: String, asset: String, bound: Int, opacity: Double? = nil, tinted: Bool? = nil) {
            result.append(.init(slot: slot,
                data: ExtensionAppearanceRegistry.shared.sidebarAssetData(named: asset, forThemeID: theme.id),
                url: ThemeAssetStore.assetURL(named: asset, for: theme.id),
                bound: bound, opacity: opacity, tinted: tinted))
        }
        if let image = variant.material.backdrop?.image {
            append(slot: "backdrop", asset: image.asset, bound: 1_290, opacity: image.opacity)
        }
        if let image = variant.sidebar?.background?.image {
            append(slot: "sidebarImage", asset: image.asset, bound: 1_290, opacity: image.opacity)
        }
        // No logo: the phone has no brand row, and a mascot is the one character it shows.
        for mood in ThemeMascotMood.allCases {
            if let pose = variant.sidebar?.mascot?.poses[mood] {
                append(slot: "mascot.\(mood.rawValue)", asset: pose.asset, bound: 512)
            }
        }
        for (index, sprite) in variant.sprites.prefix(8).enumerated() {
            append(slot: "sprite.\(index)", asset: sprite.asset, bound: 128, tinted: sprite.tinted)
        }
        for (event, slot) in [(ThemeMomentEvent.needsAttention, "sound.needsAttention"), (.turnFinished, "sound.turnFinished")] {
            if let sound = variant.moments?[event]?.sound { append(slot: slot, asset: sound, bound: 0) }
        }
        return Array(result.prefix(RemoteThemeAsset.maximumCount))
    }
}

/// File reads, hashing, image decoding and encoding stay on this bounded serial worker. A
/// source digest memoizes its rendition even when a theme is edited without changing pictures.
actor RemoteThemeRenditionWorker {
    /// AVAudioConverter owns a synchronous input callback, annotated Sendable by the SDK.
    /// Keep its mutable decoder state behind one lock rather than capturing local variables.
    private final class SoundInput: @unchecked Sendable {
        private let file: AVAudioFile
        private let buffer: AVAudioPCMBuffer
        private let lock = NSLock()
        private var finished = false
        private var failed = false
        init(file: AVAudioFile, buffer: AVAudioPCMBuffer) { self.file = file; self.buffer = buffer }
        var endedSuccessfully: Bool {
            lock.lock(); defer { lock.unlock() }
            return finished && !failed
        }
        var hasFailed: Bool {
            lock.lock(); defer { lock.unlock() }; return failed
        }
        func read(_ frames: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            lock.lock(); defer { lock.unlock() }
            guard !finished, !failed else { status.pointee = .endOfStream; return nil }
            let remaining = file.length - file.framePosition
            guard remaining > 0 else { finished = true; status.pointee = .endOfStream; return nil }
            do {
                let count = min(frames, buffer.frameCapacity, AVAudioFrameCount(min(remaining, AVAudioFramePosition(buffer.frameCapacity))))
                try file.read(into: buffer, frameCount: count)
                finished = buffer.frameLength == 0
                status.pointee = finished ? .endOfStream : .haveData
                return finished ? nil : buffer
            } catch { failed = true; status.pointee = .endOfStream; return nil }
        }
    }
    struct Source: Sendable {
        let slot: String
        let data: Data?
        let url: URL?
        let bound: Int
        let opacity: Double?
        let tinted: Bool?
    }
    struct Prepared: Sendable { let asset: RemoteThemeAsset; let payload: RemoteThemeAssetPayload }
    struct PreparedSurface: Sendable { let surface: RemoteThemeSurface; let assets: [Prepared] }
    private struct Rendition: Sendable { let data: Data; let width: Int; let height: Int; let digest: String }
    /// What a font file says about itself; read once per path, size and modification date.
    private struct FontFacts: Sendable { let digest: String; let families: [String]; let mediaType: String; let byteCount: Int }
    /// Memo keys name a source by its file identity (path, size, modification date) or, for
    /// bytes held in memory, by their digest — so an unchanged file is neither read nor hashed
    /// again when the theme is re-prepared after an unrelated edit or a tuning tick.
    private var cache = BoundedMemo<Rendition>(capacity: 24)
    private var soundCache = BoundedMemo<Data>(capacity: 4)
    private var fontCache = BoundedMemo<FontFacts>(capacity: 16)
    private static let maximumSourceBytes = 8 * 1_024 * 1_024

    func prepareSurface(_ specification: ExtensionMetalSurface, root: URL) -> PreparedSurface? {
        guard specification.isValid, !Task.isCancelled,
              let data = Self.packageData(specification.shaderResource, root: root,
                  maximumBytes: RemoteThemeAsset.maximumShaderBytes),
              String(data: data, encoding: .utf8) != nil else { return nil }
        let source = RemoteThemeAsset(slot: "surface.source", digest: Self.digest(data),
            byteCount: data.count, mediaType: "text/x-metal", pixelWidth: 0, pixelHeight: 0)
        guard source.isValid else { return nil }
        var assets = [Prepared(asset: source, payload: .bytes(data))]
        if let texture = specification.texture,
           let bytes = Self.packageData(texture, root: root, maximumBytes: 4 * 1_024 * 1_024),
           let picture = Self.render(bytes, bound: 1_024) {
            assets.append(.init(asset: .init(slot: "surface.texture", digest: picture.digest,
                byteCount: picture.data.count, pixelWidth: picture.width, pixelHeight: picture.height),
                payload: .bytes(picture.data)))
        }
        return PreparedSurface(surface: .init(sourceDigest: source.digest, specification: specification), assets: assets)
    }

    private static func packageData(_ path: String, root: URL, maximumBytes: Int) -> Data? {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(resolvedRoot.path + "/") else { return nil }
        return try? BoundedFileReader.read(url, maximumBytes: maximumBytes)
    }

    func prepare(_ sources: [Source], fontDirectory: URL? = nil,
                 fontURLs: [URL] = [], fontFamilies: [String] = []) -> [Prepared] {
        var result: [Prepared] = []
        var bytes = 0
        for source in sources.prefix(RemoteThemeAsset.maximumCount) {
            guard !Task.isCancelled else { return [] }
            guard let key = Self.memoKey(source) else { continue }
            if source.slot.hasPrefix("sound.") {
                guard let sound = soundCache[key] ?? Self.read(source).flatMap(Self.notificationSound),
                      bytes + sound.count <= RemoteThemeAsset.maximumThemeBytes else { continue }
                soundCache[key] = sound
                let asset = RemoteThemeAsset(slot: source.slot, digest: Self.digest(sound), byteCount: sound.count,
                    mediaType: "audio/x-caf", pixelWidth: 0, pixelHeight: 0)
                if asset.isValid { result.append(.init(asset: asset, payload: .bytes(sound))); bytes += sound.count }
                continue
            }
            let renditionKey = key + "-\(source.bound)"
            guard let rendered = cache[renditionKey] ?? Self.read(source).flatMap({ Self.render($0, bound: source.bound) }),
                  bytes + rendered.data.count <= RemoteThemeAsset.maximumThemeBytes else { continue }
            cache[renditionKey] = rendered
            let asset = RemoteThemeAsset(slot: source.slot, digest: rendered.digest,
                byteCount: rendered.data.count, pixelWidth: rendered.width, pixelHeight: rendered.height,
                opacity: source.opacity, tinted: source.tinted)
            guard asset.isValid else { continue }
            result.append(.init(asset: asset, payload: .bytes(rendered.data))); bytes += rendered.data.count
        }
        result.append(contentsOf: fonts(directory: fontDirectory, urls: fontURLs, families: fontFamilies))
        return result
    }

    private func fonts(directory: URL?, urls: [URL], families: [String]) -> [Prepared] {
        guard !families.isEmpty else { return [] }
        var candidates = Array(urls.prefix(4))
        if let directory, let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) {
            // A theme owns at most four fonts. Bound even a manually modified asset directory.
            var inspected = 0
            for case let url as URL in enumerator {
                inspected += 1
                if inspected > 256 { break }
                if url.lastPathComponent.hasPrefix("font-") { candidates.append(url) }
                if candidates.count >= 8 { break }
            }
        }
        var result: [Prepared] = []
        var seen = Set<String>()
        for url in candidates.sorted(by: { $0.path < $1.path }) {
            guard !Task.isCancelled, result.count < 4 else { break }
            guard let facts = fontFacts(url),
                  let family = families.first(where: facts.families.contains),
                  seen.insert(family).inserted else { continue }
            let asset = RemoteThemeAsset(slot: "font.\(result.count)", digest: facts.digest,
                byteCount: facts.byteCount, mediaType: facts.mediaType, pixelWidth: 0, pixelHeight: 0, fontFamily: family)
            // The route reads the requested range from this file; nothing stays resident.
            if asset.isValid { result.append(.init(asset: asset, payload: .file(url))) }
        }
        return result
    }

    private func fontFacts(_ url: URL) -> FontFacts? {
        guard let identity = Self.fileIdentity(url), identity.size > 0,
              identity.size <= RemoteThemeAsset.maximumFontBytes else { return nil }
        if let known = fontCache[identity.key] { return known }
        guard let data = try? BoundedFileReader.read(url, maximumBytes: RemoteThemeAsset.maximumFontBytes),
              data.count == identity.size,
              let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor] else { return nil }
        let families = descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
        let signature = String(data: data.prefix(4), encoding: .ascii)
        let facts = FontFacts(digest: Self.digest(data), families: families,
            mediaType: signature == "ttcf" ? "font/collection" : (signature == "OTTO" ? "font/otf" : "font/ttf"),
            byteCount: data.count)
        fontCache[identity.key] = facts
        return facts
    }

    private static func fileIdentity(_ url: URL) -> (key: String, size: Int)? {
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return ("file:\(url.path)|\(size)|\(modified)", size)
    }

    private static func memoKey(_ source: Source) -> String? {
        if let data = source.data {
            return data.count <= maximumSourceBytes ? "data:" + digest(data) : nil
        }
        guard let url = source.url, let identity = fileIdentity(url),
              identity.size <= maximumSourceBytes else { return nil }
        return identity.key
    }

    /// Streaming conversion keeps both decoder buffers and the resulting iOS notification
    /// file bounded. 16-kHz mono PCM16 is below 1 MiB for the admitted duration (<30 s).
    private static func notificationSound(_ data: Data) -> Data? {
        guard data.count <= ThemeMomentLimits.maximumSoundBytes else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let inputURL = directory.appendingPathComponent("source")
            let outputURL = directory.appendingPathComponent("notification.caf")
            try data.write(to: inputURL)
            let input = try AVAudioFile(forReading: inputURL)
            let inputFormat = input.processingFormat
            let duration = Double(input.length) / inputFormat.sampleRate
            guard duration.isFinite, duration > 0, duration < 30,
                  inputFormat.sampleRate <= 192_000, (1...2).contains(inputFormat.channelCount),
                  let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: inputFormat, to: format),
                  let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_096),
                  let target = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else { return nil }
            do {
                var output: AVAudioFile? = try AVAudioFile(forWriting: outputURL, settings: format.settings,
                    commonFormat: .pcmFormatInt16, interleaved: true)
                var writtenFrames: AVAudioFramePosition = 0
                let reader = SoundInput(file: input, buffer: source)
                for _ in 0..<1_500 {
                    guard !Task.isCancelled else { return nil }
                    var error: NSError?
                    let status = converter.convert(to: target, error: &error) { requested, state in
                        reader.read(requested, status: state)
                    }
                    guard !reader.hasFailed, error == nil, status != .error else { return nil }
                    writtenFrames += AVAudioFramePosition(target.frameLength)
                    guard writtenFrames < 480_000 else { return nil }
                    if target.frameLength > 0 { try output?.write(from: target) }
                    if status == .endOfStream { break }
                }
                guard reader.endedSuccessfully, writtenFrames > 0 else { return nil }
                // AVAudioFile closes and finalizes the CAF packet metadata on release.
                output = nil
            }
            return try BoundedFileReader.read(outputURL, maximumBytes: RemoteThemeAsset.maximumBytes)
        } catch { return nil }
    }

    private static func read(_ source: Source) -> Data? {
        if let data = source.data { return data.count <= maximumSourceBytes ? data : nil }
        guard let url = source.url else { return nil }
        return try? BoundedFileReader.read(url, maximumBytes: maximumSourceBytes)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func render(_ data: Data, bound: Int) -> Rendition? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var pixels = bound
        while pixels >= 64 {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels
            ] as CFDictionary) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            let data = output as Data
            if data.count <= RemoteThemeAsset.maximumBytes {
                return Rendition(data: data, width: image.width, height: image.height, digest: digest(data))
            }
            pixels = Int(Double(pixels) * 0.7)
        }
        return nil
    }
}

/// A small least-recently-used memo for the rendition worker's prepared values.
private struct BoundedMemo<Value: Sendable>: Sendable {
    let capacity: Int
    private var values: [String: Value] = [:]
    private var order: [String] = []

    init(capacity: Int) { self.capacity = capacity }

    subscript(key: String) -> Value? {
        get { values[key] }
        set {
            order.removeAll { $0 == key }
            values[key] = newValue
            guard newValue != nil else { return }
            order.append(key)
            while order.count > capacity { values[order.removeFirst()] = nil }
        }
    }
}

// MARK: - Setting-bound inputs

extension RemoteThemeAssets {
    /// The hook with every setting-bound input replaced by the constant the Mac reads for it
    /// now. The phone has no access to the Mac's extension settings, and a phone built before
    /// setting inputs existed could not decode one, so a setting never crosses the wire: the
    /// constant does, and a settings change re-projects the surface.
    static func resolvingSettingInputs(_ hook: SurfaceHook) -> SurfaceHook {
        SurfaceHook(
            identifier: hook.identifier,
            generation: hook.generation,
            root: hook.root,
            specification: resolvingSettingInputs(hook.specification) { fieldID in
                ExtensionManager.shared.surfaceSettingReading(
                    extensionIdentifier: hook.identifier,
                    fieldID: fieldID
                )
            }
        )
    }

    /// `specification` with each `.setting` input resolved through its own mapping — the same
    /// `ExtensionScalarMapping.output(for:)` the Mac's surface uses — and every other input,
    /// order and name untouched.
    static func resolvingSettingInputs(
        _ specification: ExtensionMetalSurface,
        reading: (String) -> Double?
    ) -> ExtensionMetalSurface {
        guard !specification.boundSettingIDs.isEmpty else { return specification }
        return ExtensionMetalSurface(
            shaderResource: specification.shaderResource,
            fragmentFunction: specification.fragmentFunction,
            preferredFramesPerSecond: specification.preferredFramesPerSecond,
            inputs: specification.inputs.map { input in
                guard case .setting(let fieldID, let mapping) = input.value else { return input }
                return ExtensionSurfaceInputBinding(
                    name: input.name,
                    value: .constant(mapping.output(for: reading(fieldID)))
                )
            },
            texture: specification.texture
        )
    }
}
