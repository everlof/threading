import Foundation

/// The person's own pinned notes on the adopted Simulator, one list per device, persisted across
/// launches.
///
/// These are **user-authored** by construction — only the pane's annotate mode creates them, and the
/// agent tool that reads them is read-only — so they are kept entirely separate from the untrusted
/// accessibility tree a snapshot returns. Points are normalized (0…1, top-left) like every other
/// `ImageAnnotation`, so a pin drawn on the live framebuffer, and the coordinate an agent reads, stay
/// in step regardless of the pane's size.
/// Not main-actor isolated: it is pure, bounded persistence (a per-device list capped at
/// `maximumCount` tiny notes), so its synchronous JSON is frame-cheap and belongs on the caller's
/// thread rather than counting as main-actor work. `UserDefaults` is thread-safe, which is what
/// `@unchecked Sendable` asserts here.
final class SimulatorAnnotationStore: @unchecked Sendable {
    static let shared = SimulatorAnnotationStore()

    /// The most notes the pane offers to pin — the same cap as the shared image-annotation
    /// affordance (`ImageAnnotationDefaults.maximumCount`), inlined because that lives on the main
    /// actor and this store does not.
    static let maximumCount = 20

    private let defaults: UserDefaults
    private static let keyPrefix = "simulator.annotations."

    init(defaults: UserDefaults = PreferenceStore.shared) {
        self.defaults = defaults
    }

    func annotations(for device: SimulatorDeviceID) -> [ImageAnnotation] {
        guard let data = defaults.data(forKey: Self.key(device)),
              let decoded = try? JSONDecoder().decode([ImageAnnotation].self, from: data)
        else { return [] }
        return decoded
    }

    func setAnnotations(_ annotations: [ImageAnnotation], for device: SimulatorDeviceID) {
        let bounded = Array(annotations.prefix(Self.maximumCount))
        if bounded.isEmpty {
            defaults.removeObject(forKey: Self.key(device))
        } else if let data = try? JSONEncoder().encode(bounded) {
            defaults.set(data, forKey: Self.key(device))
        }
    }

    private static func key(_ device: SimulatorDeviceID) -> String {
        keyPrefix + device.rawValue
    }
}
