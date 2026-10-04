import AppKit
import ThreadingExtensionKit

/// The live values a host-owned custom surface may bind to, answered in one place.
///
/// A surface's inputs are declared as `ExtensionSurfaceScalar.signal` bindings, and the host —
/// never the extension — supplies the number at draw time. Several hosts draw such surfaces —
/// the main window's hook and the backdrop planes under the sidebar, the display panel and the
/// composer — and they must agree on every answer, so the answers live here rather than in any
/// of them. `supported` is the other half of the same promise: `ExtensionHostService` refuses a
/// patch naming a signal this build cannot answer, so an extension built against a newer SDK
/// fails at publication with a reason, rather than drawing its fallback forever and looking
/// merely dull.
///
/// Every reading is cheap and main-actor: the workload monitor's current envelope, an integer,
/// a calendar arithmetic, a dictionary lookup. Nothing here touches a store, a file or a
/// process, because a signal is read once per frame by a surface that may run at 60 fps.
///
/// **Scaling.** A surface binds at most eight inputs and a window holds a handful of surfaces
/// (the window hook and three backdrop planes), so a frame reads at most a few dozen signals.
/// Theme readings are resolved once per appearance name — a set bounded by the system's own
/// appearances, in practice two to four — and cached until the theme, the system colours or
/// the accessibility display options change; a frame read is one dictionary lookup. Moment
/// pulses are one subtraction against the last event's timestamp.
@MainActor
enum ExtensionHostSignals {

    /// Every signal this build answers. Pinned against `ExtensionHostSignal.all` by
    /// `ExtensionHostSignalsTests`, so the SDK cannot name a signal the host forgot.
    nonisolated static let supported: Set<ExtensionHostSignal> = Set<ExtensionHostSignal>([
        .activeAccountUsageRemaining,
        .workloadIntensity,
        .workloadWorkingCount,
        .timeOfDayFraction
    ])
    .union(ExtensionHostSignal.audioSignals)
    .union(ExtensionHostSignal.themeSignals)
    .union(ExtensionHostSignal.momentSignals)

    /// The one signal only a window can answer. Which account is "active" is the toolbar's
    /// account item's to say, so `MainWindowController` installs the reading when it builds
    /// that item; until then, and in a process with no window, the signal resolves to its
    /// binding's fallback.
    static var activeAccountUsageRemaining: () -> Double? = { nil }

    // MARK: - Seams

    /// The workload monitor's current envelope. A seam so a test can state a fleet without
    /// starting sessions.
    static var intensity: () -> AgentIntensity = { AgentWorkloadMonitor.shared.intensity }
    static var audio: () -> AudioSpectrum? = { AudioSpectrumService.shared.reading() }
    /// The monotonic clock the envelope and the moment pulses decay against.
    static var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// The wall clock the day fraction is read from.
    static var now: () -> Date = Date.init
    /// The calendar that decides where the day starts — the user's, so a surface following the
    /// hour follows the hour the user sees.
    static var calendar: () -> Calendar = { Calendar.current }
    /// The app theme in force. Replacing it — a test stating a theme — drops every cached
    /// reading, exactly as a real theme change does.
    static var theme: () -> AppTheme = { AppThemePalette.current } {
        didSet { invalidateThemeReadings() }
    }
    /// When each app moment last happened on the uptime clock, or nil when it has not since a
    /// surface began listening.
    static var momentOccurredAt: (ThemeMomentEvent) -> TimeInterval? = {
        ExtensionMomentSignalReader.shared.lastOccurrence(of: $0)
    }

    // MARK: - Reading

    /// The signal's current value, or nil when the host has nothing to say — which the surface
    /// turns into the binding's fallback. An unsupported signal is nil too, but it never reaches
    /// a surface: publication refused it.
    ///
    /// `context` says where the surface is drawn. Only the theme readings use it, so the
    /// default — the application's own appearance — is right for everything else.
    static func value(
        _ signal: ExtensionHostSignal,
        in context: ExtensionHostSignalContext = .application
    ) -> Double? {
        switch signal {
        case .activeAccountUsageRemaining:
            return activeAccountUsageRemaining()

        case .workloadIntensity:
            return min(max(intensity().level(at: uptime()), 0), 1)

        case .workloadWorkingCount:
            return Double(max(intensity().workload.workingCount, 0))

        case .timeOfDayFraction:
            return dayFraction(of: now(), in: calendar())

        case .audioAvailable: return audio() == nil ? 0 : 1
        case .audioLevel: return audio()?.level
        case .audioBass: return audio()?.bass
        case .audioMids: return audio()?.mids
        case .audioTreble: return audio()?.treble

        case .themeDark: return themeReading(in: context).isDark ? 1 : 0
        case .themeAccentRed: return themeReading(in: context).accent.red
        case .themeAccentGreen: return themeReading(in: context).accent.green
        case .themeAccentBlue: return themeReading(in: context).accent.blue
        case .themeGroundRed: return themeReading(in: context).ground.red
        case .themeGroundGreen: return themeReading(in: context).ground.green
        case .themeGroundBlue: return themeReading(in: context).ground.blue

        case .momentTurnFinished:
            return momentPulse(since: momentOccurredAt(.turnFinished), at: uptime())
        case .momentNeedsAttention:
            return momentPulse(since: momentOccurredAt(.needsAttention), at: uptime())

        default:
            guard let index = ExtensionHostSignal.audioBands.firstIndex(of: signal) else { return nil }
            return audio()?.bands[index]
        }
    }

    /// Midnight to midnight as `0...1`, measured against the day's actual length so a daylight
    /// saving change moves the fraction rather than letting it run past one.
    static func dayFraction(of date: Date, in calendar: Calendar) -> Double {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        let length = max(end.timeIntervalSince(start), 1)
        return min(max(date.timeIntervalSince(start) / length, 0), 1)
    }

    /// A moment's pulse: `1` at the event, easing to `0` over
    /// `ExtensionHostSignal.momentPulseDuration` with a smoothstep, and `0` before any event or
    /// once it has decayed. A smoothstep rather than a line so a surface's glow neither snaps
    /// off nor starts falling with a corner.
    static func momentPulse(since occurredAt: TimeInterval?, at time: TimeInterval) -> Double {
        guard let occurredAt else { return 0 }
        let elapsed = time - occurredAt
        let duration = ExtensionHostSignal.momentPulseDuration
        guard elapsed >= 0, elapsed < duration else { return 0 }
        let progress = elapsed / duration
        return 1 - progress * progress * (3 - 2 * progress)
    }

    // MARK: - Theme Readings

    private static var themeReadings: [NSAppearance.Name: ExtensionThemeSignalReading] = [:]
    private static let themeInvalidations = AppEventObservations()
    private static var observesThemeInvalidations = false

    /// The theme reading for `context`'s appearance, resolved once and then answered from the
    /// cache until something it was resolved from changes.
    static func themeReading(in context: ExtensionHostSignalContext) -> ExtensionThemeSignalReading {
        let appearance = context.appearance ?? NSAppearance.currentDrawing()
        if let cached = themeReadings[appearance.name] { return cached }
        observeThemeInvalidationsIfNeeded()
        let reading = ExtensionThemeSignalReading(theme: theme(), appearance: appearance)
        themeReadings[appearance.name] = reading
        return reading
    }

    /// Forgets every resolved theme reading; the next frame of each surface resolves afresh.
    static func invalidateThemeReadings() {
        themeReadings.removeAll()
    }

    /// The cache is only worth keeping once something has read it, so the observers are
    /// installed by the first read rather than at launch.
    private static func observeThemeInvalidationsIfNeeded() {
        guard !observesThemeInvalidations else { return }
        observesThemeInvalidations = true
        themeInvalidations.observe(AppThemeDidChange.self) { _ in
            ExtensionHostSignals.invalidateThemeReadings()
        }
        themeInvalidations.observe(AccessibilityDisplayOptionsDidChange.self) { _ in
            ExtensionHostSignals.invalidateThemeReadings()
        }
        // System's accent is the user's macOS accent colour, which moves without a theme change.
        themeInvalidations.observe(NSColor.systemColorsDidChangeNotification) {
            ExtensionHostSignals.invalidateThemeReadings()
        }
    }
}

// MARK: - Context

/// Where a surface reading a signal is drawn.
///
/// Most signals are app-wide and ignore it. The theme readings do not: under an adaptive theme
/// a window drawn in light and one drawn in dark wear different variants, so the surface hands
/// its own effective appearance to every read.
struct ExtensionHostSignalContext {
    /// The surface's effective appearance, or nil for the application's own.
    var appearance: NSAppearance?

    /// The application's own appearance — what a surface with no view of its own reads.
    static var application: ExtensionHostSignalContext { .init(appearance: nil) }
}

// MARK: - Theme Reading

/// The app theme as a custom surface may read it: whether the variant in force is dark, and
/// the resolved accent and ground roles as sRGB components.
struct ExtensionThemeSignalReading: Equatable {
    /// One colour as `0...1` sRGB components; wide-gamut values are clamped into the range.
    struct Components: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        static let black = Components(red: 0, green: 0, blue: 0)

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// Converts in the current drawing appearance, so a dynamic system colour resolves to
        /// the variant the caller is drawing — the caller sets that appearance.
        init(_ color: NSColor) {
            guard let srgb = color.usingColorSpace(.sRGB) else {
                self = .black
                return
            }
            self.init(
                red: Self.clamped(srgb.redComponent),
                green: Self.clamped(srgb.greenComponent),
                blue: Self.clamped(srgb.blueComponent)
            )
        }

        private static func clamped(_ component: CGFloat) -> Double {
            min(max(Double(component), 0), 1)
        }
    }

    var isDark: Bool
    var accent: Components
    var ground: Components

    init(isDark: Bool, accent: Components, ground: Components) {
        self.isDark = isDark
        self.accent = accent
        self.ground = ground
    }

    /// Resolves `theme` for `appearance`. `isDark` names the variant actually in force, which
    /// is not always the one the appearance prefers: a theme stating only a light variant wears
    /// it under a dark appearance too, and its surfaces should read light.
    init(theme: AppTheme, appearance: NSAppearance) {
        let preferred = theme.variantKind(for: appearance)
        let inForce = theme.variant(preferred) != nil || theme.availableVariants.isEmpty
            ? preferred
            : theme.availableVariants.first ?? preferred
        var accent = Components.black
        var ground = Components.black
        appearance.performAsCurrentDrawingAppearance {
            accent = Components(theme.resolved(.accent, appearance: appearance))
            ground = Components(theme.resolved(.ground, appearance: appearance))
        }
        self.init(isDark: inForce == .dark, accent: accent, ground: ground)
    }
}
