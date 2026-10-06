import Foundation
import ThreadingExtensionKit

// MARK: - Theme Welcome Facts

/// How the new-session composer's welcome reads and words the extension facts a theme line names
/// with `{fact:KEY}` (`ThemeWelcome.Template.Token.fact`).
///
/// **Where a value is looked up.** A composer for a project reads that project's own chain — the
/// project subject, then its repository branch, then its repository, in the navigator's order
/// (`ExtensionFactResolver`) — and then the application subject, which is where a value about no
/// project (the weather, an on-call rota) is published. A composer with no project reads the
/// application subject alone. Every read is a dictionary lookup in the live registry on the main
/// actor: no file, no process, no IPC.
///
/// **Freshness is the registry's.** A provider's value older than
/// `ExtensionFactRegistry.maximumProviderFactAge` is already gone from what the registry
/// resolves, and that expiry posts the same `ExtensionFactsDidChange` a publication does, so a
/// line whose fact went stale stops being shown without a second policy here.
///
/// **The wording is the host's.** An extension supplies a scalar; Threading decides how it reads
/// inside an author's sentence. A fact's `label` — the provider's own presentation of the value,
/// already through its localization table — is preferred when it states one, as the navigator's
/// label facet does. Otherwise a string is shown as published, an integer or number in the
/// person's locale, a boolean as the app's own "yes"/"no", and a date as a time today or a short
/// date on any other day. Every result is one line of at most `maximumLength` characters.
enum ThemeWelcomeFacts {

    // MARK: - Bounds

    /// A fact fills one slot in a sentence of at most 160 characters, so it may take well under
    /// half of it. Longer values end in an ellipsis rather than pushing the line into a wrap.
    static let maximumLength = 64
    /// A number is read, not audited: two decimals say "4.25" without "4.2500001".
    static let maximumFractionDigits = 2
    static let ellipsis = "…"

    // MARK: - Lookup

    /// The fact `{fact:key}` reads in a composer for `project` (nil for none), or nil when no
    /// fresh value is published for any subject in its chain.
    @MainActor
    static func fact(
        _ key: ExtensionFactKey,
        project: ProjectID?,
        resolver: ExtensionFactResolver
    ) -> ExtensionFact? {
        if let project,
           let resolved = resolver.fact(
               key,
               for: .project(HostFactPublisher.opaqueID(project))
           ) {
            return resolved.fact
        }
        return resolver.fact(key, for: .application)?.fact
    }

    // MARK: - Wording

    /// The fact as a line shows it at `date`, or nil when it words as nothing.
    static func text(
        for fact: ExtensionFact,
        at date: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String? {
        if let label = fact.label.flatMap(singleLine) {
            return capped(label)
        }
        return text(for: fact.value, at: date, calendar: calendar, locale: locale)
    }

    /// A bare value as a line shows it at `date`, or nil when it words as nothing.
    static func text(
        for value: ExtensionFactValue,
        at date: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String? {
        let text: String?
        switch value {
        case .string(let raw):
            text = singleLine(raw)
        case .integer(let number):
            text = number.formatted(.number.locale(locale))
        case .number(let number):
            text = number.isFinite
                ? number.formatted(
                    .number.precision(.fractionLength(0...maximumFractionDigits)).locale(locale)
                )
                : nil
        case .boolean(let flag):
            // Lower case: read inside an author's sentence ("Deploys frozen: yes").
            text = flag ? L10n.string("yes") : L10n.string("no")
        case .date(let moment):
            text = dateText(moment, at: date, calendar: calendar, locale: locale)
        }
        return text.map(capped)
    }

    /// Every run of whitespace, line breaks and control characters becomes one space, and the
    /// ends are trimmed. Nil for nothing left.
    static func singleLine(_ raw: String) -> String? {
        let separators = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        let line = raw.components(separatedBy: separators)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    /// At most `maximumLength` characters, the last of them an ellipsis when it was cut.
    static func capped(_ line: String) -> String {
        guard line.count > maximumLength else { return line }
        let kept = line.prefix(maximumLength - ellipsis.count)
        return kept.trimmingCharacters(in: .whitespaces) + ellipsis
    }

    /// A time on the day of `date` ("14:05"), a day and month in its year ("3 Oct"), and the
    /// year as well beyond it. Never relative: "5 minutes ago" would need the minute tick that
    /// fact lines deliberately do not take.
    private static func dateText(
        _ moment: Date,
        at date: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(moment, inSameDayAs: date) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else if calendar.component(.year, from: moment) == calendar.component(.year, from: date) {
            formatter.setLocalizedDateFormatFromTemplate("dMMM")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("dMMMy")
        }
        return formatter.string(from: moment)
    }
}

// MARK: - Source

/// The process-wide seam through which the composer's welcome reads facts: the live registry's
/// resolver, installed at the composition root when extensions start. Empty in Recovery Mode,
/// with extensions held back and under XCTest, where every `{fact:…}` line is simply ineligible.
@MainActor
final class ThemeWelcomeFactSource {
    static let shared = ThemeWelcomeFactSource()

    /// Held weakly: the host fact pipeline owns it for the app's lifetime.
    weak var resolver: ExtensionFactResolver?

    func fact(_ key: ExtensionFactKey, project: ProjectID?) -> ExtensionFact? {
        guard let resolver else { return nil }
        return ThemeWelcomeFacts.fact(key, project: project, resolver: resolver)
    }
}
