import AppKit
import ThreadingExtensionKit
import ThreadingRemoteKit

// MARK: - Composer Welcome

/// The words over the new-session composer's box: which greeting and which caption an arrival
/// shows, drawn from the theme's welcome (`ThemeWelcome.Wording`) and the app's own greeting
/// (`ComposerGreeting`), and rendered at the moment they are shown.
///
/// **Picked once, rendered whenever.** A pick names *lines*, not text, and is kept for the whole
/// arrival — the `chatGreeting` rule that a choice made on the composer never rewrites its
/// welcome. Rendering is separate and cheap, so a line with `{time}` can be set again on the
/// minute without being picked again, and a `{project}` line reads the project in force.
///
/// **The pool.** The theme's eligible lines, weighted; with `includesAppLines` the app's own
/// greeting joins as one more candidate of weight 1; with no eligible theme line at all, the
/// app's greeting stands. A caption has no app lines: with none eligible there is no caption.
///
/// **Facts.** A `{fact:KEY}` line is eligible only while its fact has a fresh value
/// (`ThemeWelcomeFacts`). A publication or an expiry renders the picked lines again — it never
/// picks again, so a line that became eligible waits for the next arrival, and one whose value
/// went away falls back as a `{project}` line does.
enum ComposerWelcome {

    // MARK: - Pick

    /// One arrival's lines.
    struct Pick: Equatable {
        enum Greeting: Equatable {
            /// The app's own greeting, minted for this arrival.
            case app(String)
            /// A theme line, rendered each time it is shown.
            case theme(ThemeWelcome.Line)
        }

        var greeting: Greeting
        var caption: ThemeWelcome.Line?
        /// The app's line minted beside the pick, shown in place of a theme line that stops
        /// rendering (its project went away, say) rather than leaving the hero empty.
        var appGreeting: String
        /// The pools this was picked from, so a theme change that leaves them alone keeps it.
        var greetingPool: ThemeWelcome.Wording?
        var captionPool: ThemeWelcome.Wording?

        /// A pick for a composer with no theme words: the app's line alone.
        static func app(_ line: String) -> Pick {
            Pick(greeting: .app(line), caption: nil, appGreeting: line)
        }

        /// Whether either line reads the clock, so the host re-renders it on the minute.
        var followsClock: Bool {
            if case .theme(let line) = greeting, ThemeWelcome.Template.followsClock(line.text) {
                return true
            }
            return caption.map { ThemeWelcome.Template.followsClock($0.text) } ?? false
        }

        /// The facts the picked lines read: what a render looks up, and what a fact change must
        /// touch before it is worth rendering again.
        var factKeys: Set<ExtensionFactKey> {
            var lines: [ThemeWelcome.Line] = caption.map { [$0] } ?? []
            if case .theme(let line) = greeting { lines.append(line) }
            return ThemeWelcomeGrammar.factKeys(in: lines)
        }

        /// Whether any line is the theme's, and therefore needs a context to be rendered.
        var usesTheme: Bool {
            if case .theme = greeting { return true }
            return caption != nil
        }

        /// The greeting as shown at `context`.
        func renderedGreeting(at context: ThemeWelcome.Context) -> String {
            switch greeting {
            case .app(let line):
                return line
            case .theme(let line):
                return ThemeWelcome.Template.render(line.text, context: context) ?? appGreeting
            }
        }

        /// The caption as shown at `context`, or nil for none.
        func renderedCaption(at context: ThemeWelcome.Context) -> String? {
            guard let caption,
                  let text = ThemeWelcome.Template.render(caption.text, context: context),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
    }

    /// Picks an arrival's lines from the theme's pools at `context`.
    ///
    /// The app's greeting is minted first, always — it is the fallback for a theme line that
    /// later stops rendering — so a seeded generator gives the same pick for the same pools
    /// and moment whatever the theme states.
    static func pick(
        greeting greetingPool: ThemeWelcome.Wording?,
        caption captionPool: ThemeWelcome.Wording?,
        at context: ThemeWelcome.Context,
        using generator: inout some RandomNumberGenerator
    ) -> Pick {
        let appLine = ComposerGreeting.message(
            on: context.date,
            calendar: context.calendar,
            using: &generator
        )
        var pick = Pick.app(appLine)
        pick.greetingPool = greetingPool
        pick.captionPool = captionPool

        if let greetingPool {
            let total = greetingPool.eligible(at: context)
                .reduce(0) { $0 + max($1.line.weight, 1) }
            // One weighted draw over the theme's lines plus, when the theme keeps the app's
            // lines, one more candidate of weight 1: deciding the app's share first and then
            // drawing among the theme's lines by their own weights is the same distribution.
            if total > 0,
               !(greetingPool.includesAppLines
                   && Int.random(in: 0..<(total + 1), using: &generator) == 0),
               let line = greetingPool.pick(at: context, using: &generator) {
                pick.greeting = .theme(line)
            }
        }
        pick.caption = captionPool?.pick(at: context, using: &generator)
        return pick
    }

    /// The facts any line of the two pools reads: what a pick looks up before it judges which
    /// lines are eligible. Bounded by the pools' own caps.
    static func factKeys(
        greeting greetingPool: ThemeWelcome.Wording?,
        caption captionPool: ThemeWelcome.Wording?
    ) -> Set<ExtensionFactKey> {
        ThemeWelcomeGrammar.factKeys(in: greetingPool?.lines ?? [])
            .union(ThemeWelcomeGrammar.factKeys(in: captionPool?.lines ?? []))
    }

    // MARK: - Words

    /// The part of the day in the app's own words, for `{daypart}`: lower case, because it is
    /// read inside an author's sentence ("Good {daypart}").
    static func daypartName(_ daypart: ThemeWelcome.Daypart) -> String {
        switch daypart {
        case .morning: return L10n.string("morning")
        case .afternoon: return L10n.string("afternoon")
        case .evening: return L10n.string("evening")
        case .night: return L10n.string("night")
        }
    }

    /// The given name in a full name: what a person is greeted by. The first word when the
    /// name cannot be parsed into parts; nil for no name at all.
    static func givenName(from fullName: String) -> String? {
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let given = PersonNameComponentsFormatter().personNameComponents(from: trimmed)?
            .givenName, !given.isEmpty {
            return given
        }
        return trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }
}

// MARK: - Environment

/// Everything the composer's welcome reads from the world, injected so a test states a moment,
/// a seed and a clock instead of reading the machine's.
@MainActor
struct ComposerWelcomeEnvironment {
    var now: @MainActor () -> Date
    var calendar: @MainActor () -> Calendar
    var locale: @MainActor () -> Locale
    /// The person's given name, for `{user}`.
    var userName: @MainActor () -> String?
    /// Sessions working and sessions waiting on the person, for `{working}` and `{waiting}`.
    var sessionCounts: @MainActor () -> (working: Int, waiting: Int)
    /// One draw of randomness. A seeded closure makes every pick a fact.
    var random: () -> UInt64
    /// Runs `fire` once at `date`. The returned tick cancels it.
    var schedule: @MainActor (
        _ date: Date,
        _ fire: @escaping @MainActor @Sendable () -> Void
    ) -> ComposerWelcomeTick
    /// The extension fact `{fact:KEY}` reads in a composer for a project (nil for none), or nil
    /// while none is published and fresh. An in-memory read: it is asked once per key per render.
    var fact: @MainActor (_ key: ExtensionFactKey, _ project: ProjectID?) -> ExtensionFact? = {
        _, _ in nil
    }
    /// Runs `work` on a later main-queue turn, so a burst of fact publications renders the hero
    /// once rather than once each.
    var nextTurn: @MainActor (_ work: @escaping @MainActor @Sendable () -> Void) -> Void = {
        work in
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    /// The machine's clock, the person's name and the app's own session state.
    static var live: ComposerWelcomeEnvironment {
        ComposerWelcomeEnvironment(
            now: { Date() },
            calendar: { Calendar.autoupdatingCurrent },
            locale: { Locale.autoupdatingCurrent },
            userName: { LiveUser.givenName },
            sessionCounts: {
                // The counts the mascot's mood is folded from, read once per render: O(live
                // sessions), never per frame.
                let counts = AgentMoodMonitor.shared.countsProvider()
                return (counts.working, counts.attention)
            },
            random: {
                var generator = SystemRandomNumberGenerator()
                return generator.next()
            },
            schedule: { date, fire in
                let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
                    MainActor.assumeIsolated { fire() }
                }
                RunLoop.main.add(timer, forMode: .common)
                return ComposerWelcomeTick { timer.invalidate() }
            },
            fact: { key, project in
                ThemeWelcomeFactSource.shared.fact(key, project: project)
            }
        )
    }

    /// A generator drawing from `random`, for the `inout some RandomNumberGenerator` the pick
    /// takes.
    func generator() -> Generator {
        Generator(draw: random)
    }

    struct Generator: RandomNumberGenerator {
        let draw: () -> UInt64

        mutating func next() -> UInt64 {
            draw()
        }
    }

    /// The full user name parsed once: it does not change while the app runs.
    private enum LiveUser {
        @MainActor static let givenName: String? = ComposerWelcome.givenName(from: NSFullUserName())
    }
}

/// A scheduled re-render, cancelled when the composer goes out of view.
@MainActor
final class ComposerWelcomeTick {
    private var cancel: (() -> Void)?

    init(cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    var isCancelled: Bool { cancel == nil }

    func invalidate() {
        cancel?()
        cancel = nil
    }
}
