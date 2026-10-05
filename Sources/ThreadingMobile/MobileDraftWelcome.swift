import SwiftUI
import ThreadingRemoteKit
import UIKit

// MARK: - Draft Welcome

/// The theme's welcome on the phone's new-chat screen (`RemoteThemeWelcome`): which greeting and
/// caption an arrival shows, and how they are rendered at the moment they are read.
///
/// **The phone's clock.** Lines arrive as the author wrote them and are picked and rendered with
/// the shared grammar (`ThemeWelcomeGrammar`) on this phone's clock, calendar and locale — a
/// Mac in Stockholm greets a phone in Tokyo with Tokyo's evening. `{project}` is the draft's
/// project, `{working}` and `{waiting}` the phone's own catalogue, and `{user}` the name the Mac
/// sends to its owner only. A `{fact:KEY}` line is never shown here: facts live in the Mac's
/// extension registry and are not projected to the phone, so the context states none and the
/// grammar finds such a line ineligible.
///
/// **Picked once, rendered whenever.** A pick names lines, not text, and is kept for the
/// arrival; a theme change that alters the pools picks again. A line that reads the clock is
/// set again on the minute, and only while the screen is visible.
///
/// **The phone has no greeting of its own.** Where the Mac falls back to its own line — no theme
/// line eligible, or `include_app_lines` drawing the app's share — the phone shows none, which
/// is its own new-chat screen. A caption likewise shows only an eligible line.
enum MobileDraftWelcome {

    /// One arrival's lines.
    struct Pick: Equatable {
        var greeting: ThemeWelcomeGrammar.Line?
        var caption: ThemeWelcomeGrammar.Line?
        /// The pools this was picked from, so a theme change that leaves them alone keeps it.
        var greetingPool: RemoteThemeWelcome.Wording?
        var captionPool: RemoteThemeWelcome.Wording?

        /// Whether either line reads the clock, so the screen re-renders it on the minute.
        var followsClock: Bool {
            [greeting, caption].contains { line in
                line.map { ThemeWelcomeGrammar.Template.followsClock($0.text) } ?? false
            }
        }

        func rendered(_ line: ThemeWelcomeGrammar.Line?, at context: ThemeWelcomeGrammar.Context) -> String? {
            guard let line,
                  let text = ThemeWelcomeGrammar.Template.render(line.text, context: context),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
    }

    /// Picks an arrival's lines from the welcome's pools at `context`.
    static func pick(
        _ welcome: RemoteThemeWelcome?,
        at context: ThemeWelcomeGrammar.Context,
        using generator: inout some RandomNumberGenerator
    ) -> Pick {
        var pick = Pick(greetingPool: welcome?.greeting, captionPool: welcome?.caption)
        if let pool = welcome?.greeting {
            pick.greeting = ThemeWelcomeGrammar.pickSharing(
                pool.lines, includesHostLine: pool.includesHostLines, at: context, using: &generator
            )
        }
        if let pool = welcome?.caption {
            pick.caption = ThemeWelcomeGrammar.pick(pool.lines, at: context, using: &generator)
        }
        return pick
    }

    /// The part of the day in the phone's own words, for `{daypart}`: lower case, because it is
    /// read inside an author's sentence ("Good {daypart}").
    static func daypartName(_ daypart: ThemeWelcomeGrammar.Daypart) -> String {
        switch daypart {
        case .morning: return MobileL10n.string("morning")
        case .afternoon: return MobileL10n.string("afternoon")
        case .evening: return MobileL10n.string("evening")
        case .night: return MobileL10n.string("night")
        }
    }

    /// The mark's side when the theme states none: the Mac composer's own hero mark.
    static let defaultMarkSide: CGFloat = 40

    /// What the phone's catalogue and the draft say, for the tokens that are not the clock.
    struct Inputs: Equatable {
        var project: String?
        var user: String?
        var working = 0
        var waiting = 0
    }
}

// MARK: - Environment

/// Everything the welcome reads from the world, injected so a test states a moment, a seed and
/// a clock instead of reading the phone's.
@MainActor
struct MobileDraftWelcomeEnvironment {
    var now: () -> Date
    var calendar: () -> Calendar
    var locale: () -> Locale
    /// One draw of randomness. A seeded closure makes every pick a fact.
    var random: () -> UInt64
    /// Runs `fire` once at `date`; calling the returned closure cancels it.
    var schedule: (_ date: Date, _ fire: @escaping @MainActor () -> Void) -> () -> Void

    static var live: MobileDraftWelcomeEnvironment {
        MobileDraftWelcomeEnvironment(
            now: { Date() },
            calendar: { Calendar.autoupdatingCurrent },
            locale: { Locale.autoupdatingCurrent },
            random: {
                var generator = SystemRandomNumberGenerator()
                return generator.next()
            },
            schedule: { date, fire in
                let task = Task { @MainActor in
                    let delay = max(date.timeIntervalSinceNow, 0)
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    fire()
                }
                return { task.cancel() }
            }
        )
    }

    struct Generator: RandomNumberGenerator {
        let draw: () -> UInt64
        mutating func next() -> UInt64 { draw() }
    }
}

// MARK: - Model

/// Holds one arrival's pick and the minute that renders it. Owned by the new-chat screen for
/// its lifetime; nothing here runs while the screen is not visible.
@MainActor
final class MobileDraftWelcomeModel: ObservableObject {
    @Published private(set) var pick: MobileDraftWelcome.Pick?
    /// The moment lines are rendered at. Advanced on the minute while visible and following.
    @Published private(set) var moment: Date
    private(set) var isVisible = false
    private var cancelTick: (() -> Void)?
    let environment: MobileDraftWelcomeEnvironment

    init(environment: MobileDraftWelcomeEnvironment = .live) {
        self.environment = environment
        moment = environment.now()
    }

    /// Whether a minute is scheduled — true only while visible with a line that reads the clock.
    var isTicking: Bool { cancelTick != nil }

    /// The grammar's context at the current moment.
    func context(_ inputs: MobileDraftWelcome.Inputs) -> ThemeWelcomeGrammar.Context {
        ThemeWelcomeGrammar.Context(
            date: moment,
            calendar: environment.calendar(),
            locale: environment.locale(),
            project: inputs.project,
            user: inputs.user,
            working: inputs.working,
            waiting: inputs.waiting,
            daypartName: MobileDraftWelcome.daypartName
        )
    }

    /// Picks for `welcome` unless the pools it would pick from are the ones already picked from.
    /// No welcome clears the pick.
    func arrive(_ welcome: RemoteThemeWelcome?, inputs: MobileDraftWelcome.Inputs) {
        guard let welcome, welcome.greeting != nil || welcome.caption != nil else {
            if pick != nil { pick = nil }
            refreshTick()
            return
        }
        if let pick, pick.greetingPool == welcome.greeting, pick.captionPool == welcome.caption { return }
        moment = environment.now()
        var generator = MobileDraftWelcomeEnvironment.Generator(draw: environment.random)
        pick = MobileDraftWelcome.pick(welcome, at: context(inputs), using: &generator)
        refreshTick()
    }

    func greeting(_ inputs: MobileDraftWelcome.Inputs) -> String? {
        pick.flatMap { $0.rendered($0.greeting, at: context(inputs)) }
    }

    func caption(_ inputs: MobileDraftWelcome.Inputs) -> String? {
        pick.flatMap { $0.rendered($0.caption, at: context(inputs)) }
    }

    /// The screen appeared, disappeared, or its scene left the foreground.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible { moment = environment.now() }
        refreshTick()
    }

    private func refreshTick() {
        cancelTick?()
        cancelTick = nil
        guard isVisible, pick?.followsClock == true else { return }
        let now = environment.now()
        let calendar = environment.calendar()
        let next = calendar.dateInterval(of: .minute, for: now)?.end ?? now.addingTimeInterval(60)
        cancelTick = environment.schedule(next) { [weak self] in
            guard let self else { return }
            cancelTick = nil
            moment = environment.now()
            refreshTick()
        }
    }
}

// MARK: - Hero

/// The welcome above the draft's sentence: the mark, the greeting and the caption. The rest of
/// the hero — "Agent in Project" and the branch — stays the screen's own beneath it.
struct MobileDraftWelcomeHero<Glyph: View>: View {
    let welcome: RemoteThemeWelcome
    let theme: RemoteThemePalette
    let greeting: String?
    let caption: String?
    /// The catalogue's mood, for a mascot mark.
    let mood: String
    /// The screen's own mark, sized to `side` — what an absent or unknown `mark` keeps.
    @ViewBuilder let glyph: (_ side: CGFloat?) -> Glyph
    @ObservedObject private var assets = MobileThemeAssets.shared
    @ScaledMetric(relativeTo: .title2) private var greetingSize: CGFloat = 22
    @ScaledMetric(relativeTo: .subheadline) private var captionSize: CGFloat = 15

    init(
        welcome: RemoteThemeWelcome,
        theme: RemoteThemePalette,
        greeting: String?,
        caption: String?,
        mood: String,
        @ViewBuilder glyph: @escaping (_ side: CGFloat?) -> Glyph
    ) {
        self.welcome = welcome
        self.theme = theme
        self.greeting = greeting
        self.caption = caption
        self.mood = mood
        self.glyph = glyph
    }

    var body: some View {
        let _ = assets.revision
        VStack(spacing: MobileDesign.Spacing.small) {
            mark
                .padding(.bottom, MobileDesign.Spacing.tight)
            if let greeting {
                Text(verbatim: greeting)
                    .font(font(welcome.greeting?.style, size: greetingSize, weight: .semibold))
                    .foregroundStyle(ink(welcome.greeting?.style) ?? theme.label)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("draft-welcome-greeting")
            }
            if let caption {
                Text(verbatim: caption)
                    .font(font(welcome.caption?.style, size: captionSize, weight: .regular))
                    .foregroundStyle(ink(welcome.caption?.style) ?? theme.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("draft-welcome-caption")
            }
        }
    }

    // MARK: Mark

    private var side: CGFloat? { welcome.markSize.map { CGFloat($0) } }

    @ViewBuilder
    private var mark: some View {
        switch welcome.mark {
        case .hidden:
            EmptyView()
        case .app:
            appMark
        case .logo:
            if let image = assets.image(theme.asset("logo")) {
                picture(image)
            } else {
                appMark
            }
        case .mascot:
            if let image = assets.image(theme.asset("mascot.\(mood)") ?? theme.asset("mascot.idle")) {
                picture(image)
            } else {
                appMark
            }
        case .none, .unknown:
            glyph(side)
        }
    }

    private var appMark: some View {
        Image("ThreadingMark")
            .resizable()
            .scaledToFit()
            .frame(width: side ?? MobileDraftWelcome.defaultMarkSide,
                   height: side ?? MobileDraftWelcome.defaultMarkSide)
            .accessibilityHidden(true)
    }

    /// A theme's picture keeps its own proportions at the mark's height.
    private func picture(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: (side ?? MobileDraftWelcome.defaultMarkSide) * 4,
                   maxHeight: side ?? MobileDraftWelcome.defaultMarkSide)
            .accessibilityHidden(true)
    }

    // MARK: Type

    /// The stated family when it arrived and registered, else the stated typeface, else the
    /// chrome's own font; always at a Dynamic Type size.
    private func font(_ style: RemoteThemeWelcome.Style?, size base: CGFloat, weight fallback: Font.Weight) -> Font {
        let size = base * CGFloat(style?.scale ?? 1)
        let weight = style?.weight.map(Self.weight) ?? fallback
        if let name = assets.fontName(for: style?.fontFamily) {
            return .custom(name, fixedSize: size).weight(weight)
        }
        if let typeface = style?.typeface {
            return .system(size: size, weight: weight, design: Self.design(typeface))
        }
        if let name = theme.registeredFontName ?? assets.fontName(for: theme.source?.material.fontFamily) {
            return .custom(name, fixedSize: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: theme.fontDesign)
    }

    private func ink(_ style: RemoteThemeWelcome.Style?) -> Color? {
        style?.ink.flatMap(UIColor.init(remoteHex:)).map(Color.init)
    }

    static func weight(_ weight: RemoteThemeWelcome.Weight) -> Font.Weight {
        switch weight {
        case .light: return .light
        case .regular, .unknown: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }

    static func design(_ typeface: RemoteThemeTypeface) -> Font.Design {
        switch typeface {
        case .serif: return .serif
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        case .default, .unknown: return .default
        }
    }
}

// MARK: - Scrims

/// Soft veils in the theme's ground behind the two regions a person works in, so a busy picture
/// or a bright particle field never sits straight under the greeting or the composer. Drawing
/// only: they take no touches and say nothing to VoiceOver.
enum MobileDraftWelcomeScrim {
    /// How far a veil reaches past the region it sits behind.
    static let reach = MobileDesign.Spacing.pane * 2

    static func opacity(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return min(max(value, RemoteThemeWelcome.Limits.scrimOpacities.lowerBound),
                   RemoteThemeWelcome.Limits.scrimOpacities.upperBound)
    }

    /// A radial veil behind the hero, peaking at its centre.
    struct Hero: View {
        let ground: Color
        let opacity: Double

        var body: some View {
            GeometryReader { proxy in
                RadialGradient(
                    colors: [ground.opacity(opacity), ground.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) / 2
                )
            }
            .padding(-MobileDraftWelcomeScrim.reach)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// A veil rising from the screen's foot to the composer's top edge and fading above it.
    struct Prompt: View {
        let ground: Color
        let opacity: Double

        var body: some View {
            VStack(spacing: 0) {
                LinearGradient(colors: [ground.opacity(0), ground.opacity(opacity)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: MobileDraftWelcomeScrim.reach)
                ground.opacity(opacity)
            }
            .padding(.top, -MobileDraftWelcomeScrim.reach)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
