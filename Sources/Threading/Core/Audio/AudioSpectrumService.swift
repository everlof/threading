import Foundation

enum AudioSpectrumState: Equatable, Sendable {
    case disabled, unsupported, waiting, starting, awaitingSamples, capturing, sourceUnavailable, failed
}

struct AudioSpectrumDidChange: AppEvent {
    static let name = Notification.Name("audioSpectrumDidChange")
    let spectrum: AudioSpectrum?
}

struct AudioSpectrumStateDidChange: AppEvent {
    static let name = Notification.Name("audioSpectrumStateDidChange")
    let state: AudioSpectrumState
}

/// The sole authority for music-reactive presentation. User consent and visible demand are
/// independent gates: an extension can request values but cannot enable capture or pick a source.
/// One serial capture lifetime, at most one new immutable snapshot per 1/30s on the main actor.
@MainActor
final class AudioSpectrumService {
    static let shared = AudioSpectrumService(settings: .shared)
    static let framesPerSecond = 30

    private(set) var spectrum: AudioSpectrum?
    private(set) var state: AudioSpectrumState = .disabled
    private let settings: AppSettings
    private let makeCapture: () -> (any AudioSpectrumCapturing)?
    private let appEvents = AppEventObservations()
    private var consumers: Set<UUID> = []
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var activeSource: String?
    private var measuredAt: TimeInterval = 0

    init(settings: AppSettings, makeCapture: @escaping () -> (any AudioSpectrumCapturing)? = {
        if #available(macOS 14.2, *) { return AudioSpectrumCapture() }
        return nil
    }) {
        self.settings = settings
        self.makeCapture = makeCapture
        appEvents.observe(AppSettingsDidChange.self) { [weak self] event in
            guard event.affects(AppSettingIdentity.sharesThemeAudio.rawValue,
                                AppSettingIdentity.themeAudioSource.rawValue) else { return }
            self?.reconcile()
        }
        reconcile(force: true)
    }

    func setDemand(_ id: UUID, active: Bool) {
        let changed = active ? consumers.insert(id).inserted : consumers.remove(id) != nil
        if changed { reconcile() }
    }

    var consumerCount: Int { consumers.count }

    /// Cached, bounded and fresh. Surfaces never reach HAL, the FFT, or process discovery.
    func reading(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> AudioSpectrum? {
        guard state == .capturing, now - measuredAt < 0.25 else { return nil }
        return spectrum
    }

    func sources() async throws -> [AudioSpectrumSource] {
        guard let capture = makeCapture() else { return [] }
        return try await capture.sources()
    }

    func retry() { reconcile(force: true) }

    func stop() {
        consumers.removeAll()
        reconcile(force: true)
    }

    private func reconcile(force: Bool = false) {
        let source = settings.sharesThemeAudio && !consumers.isEmpty
            ? settings.themeAudioSource : nil
        guard force || source != activeSource else { return }
        activeSource = source
        generation &+= 1
        let currentGeneration = generation
        let previous = task
        previous?.cancel()
        publish(nil)

        guard let source else {
            setState(settings.sharesThemeAudio ? .waiting : .disabled)
            // Retain the draining task so a later enable waits for its tap to be destroyed.
            return
        }
        guard let capture = makeCapture() else {
            setState(.unsupported)
            return
        }
        setState(.starting)
        task = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
            await self.run(capture, source: source, generation: currentGeneration)
        }
    }

    private func run(_ capture: any AudioSpectrumCapturing, source: String, generation: UInt64) async {
        while !Task.isCancelled, self.generation == generation {
            do {
                try await capture.start(sourceID: source)
                guard !Task.isCancelled, self.generation == generation else { break }
                while !Task.isCancelled, self.generation == generation {
                    let now = ProcessInfo.processInfo.systemUptime
                    let snapshot = try await capture.read(at: now)
                    guard !Task.isCancelled, self.generation == generation else { break }
                    measuredAt = ProcessInfo.processInfo.systemUptime
                    setState(snapshot == nil ? .awaitingSamples : .capturing)
                    publish(snapshot)
                    try await Task.sleep(nanoseconds: 1_000_000_000 / UInt64(Self.framesPerSecond))
                }
            } catch {
                guard !Task.isCancelled, self.generation == generation else { break }
                publish(nil)
                let recoverable = error as? AudioSpectrumCaptureError
                if recoverable == .sourceUnavailable || recoverable == .sourceChanged {
                    setState(.sourceUnavailable)
                    await capture.stop()
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
                    continue
                }
                setState(.failed)
                break
            }
            break
        }
        await capture.stop()
    }

    private func publish(_ snapshot: AudioSpectrum?) {
        guard spectrum != snapshot else { return }
        spectrum = snapshot
        NotificationCenter.default.post(AudioSpectrumDidChange(spectrum: snapshot))
    }

    private func setState(_ state: AudioSpectrumState) {
        guard self.state != state else { return }
        self.state = state
        NotificationCenter.default.post(AudioSpectrumStateDidChange(state: state))
    }
}

/// A view holds one demand lease. Releasing it cannot leave a dead view keeping capture alive.
@MainActor
final class AudioSpectrumDemand {
    private let id = UUID()
    private let service: AudioSpectrumService

    init(service: AudioSpectrumService = .shared) { self.service = service }
    func setActive(_ active: Bool) { service.setDemand(id, active: active) }
    deinit {
        let id = id
        let service = service
        Task { @MainActor in service.setDemand(id, active: false) }
    }
}
