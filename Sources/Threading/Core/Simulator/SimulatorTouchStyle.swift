import Foundation

/// How touch indicators look — in the live pane, in the presenter window and in touch-inclusive
/// recordings. One value for all three, so what a person sees while sharing their screen is what
/// the saved movie shows.
///
/// Foundation-only: the colours these names resolve to belong to `Design.SimulatorTouch`.
struct SimulatorTouchStyle: Equatable, Sendable {

    /// A fixed set rather than a free colour. Marks are drawn over arbitrary device content and
    /// burned into movies that outlive the app's theme, so every choice carries a contrasting
    /// edge drawn by the design layer, and a short list is quicker to pick from in a menu.
    enum Color: String, CaseIterable, Sendable {
        case accent
        case white
        case black
        case red
        case orange
        case yellow
        case green
        case blue
        case pink
    }

    enum Size: String, CaseIterable, Sendable {
        case small
        case medium
        case large

        /// Multiplies the contact radius, which is itself a fraction of the screen's short side.
        var scale: Double {
            switch self {
            case .small: 0.7
            case .medium: 1
            case .large: 1.45
            }
        }
    }

    var color: Color = .accent
    var size: Size = .medium
    /// Whether a drag leaves a fading line behind its contact.
    var showsTrail = true

    static let standard = SimulatorTouchStyle()
}

/// The person's touch-indicator choices: whether touches show live over the device, and how they
/// look. Stored through `PreferenceStore`, so a hosted test writes a scratch suite rather than the
/// developer's own preferences. Primitive keys only — nothing here is worth an encode on main.
@MainActor
final class SimulatorTouchPreferences {

    static let shared = SimulatorTouchPreferences()

    /// Posted with the preferences object whenever a value changes, so every pane and presenter
    /// window redraws with the same style.
    static let didChange = Notification.Name("SimulatorTouchPreferencesDidChange")

    private enum Key {
        static let showsLiveTouches = "simulator.touches.showLive"
        static let color = "simulator.touches.color"
        static let size = "simulator.touches.size"
        static let showsTrail = "simulator.touches.showTrail"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = PreferenceStore.shared) {
        self.defaults = defaults
    }

    /// Touches drawn over the live device — in the pane and the presenter window — whether or not
    /// a recording is running. Off by default: a device screen is the person's own content.
    var showsLiveTouches: Bool {
        get { defaults.object(forKey: Key.showsLiveTouches) as? Bool ?? false }
        set {
            guard newValue != showsLiveTouches else { return }
            defaults.set(newValue, forKey: Key.showsLiveTouches)
            announce()
        }
    }

    var style: SimulatorTouchStyle {
        get {
            var style = SimulatorTouchStyle.standard
            if let raw = defaults.string(forKey: Key.color),
               let color = SimulatorTouchStyle.Color(rawValue: raw) {
                style.color = color
            }
            if let raw = defaults.string(forKey: Key.size),
               let size = SimulatorTouchStyle.Size(rawValue: raw) {
                style.size = size
            }
            if let showsTrail = defaults.object(forKey: Key.showsTrail) as? Bool {
                style.showsTrail = showsTrail
            }
            return style
        }
        set {
            guard newValue != style else { return }
            defaults.set(newValue.color.rawValue, forKey: Key.color)
            defaults.set(newValue.size.rawValue, forKey: Key.size)
            defaults.set(newValue.showsTrail, forKey: Key.showsTrail)
            announce()
        }
    }

    private func announce() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
