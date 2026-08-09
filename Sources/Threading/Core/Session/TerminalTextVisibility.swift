import Foundation
import SwiftTerm

/// A rendered terminal colour collision, attributed to the terminal instance and palette that
/// produced it. The emulator has already qualified the run as visible, meaningful text; this
/// value is the app-facing identity used for copy and durable dismissal.
struct TerminalTextVisibilityIssue: Hashable, Sendable {
    let identity: TerminalInstanceIdentity
    let themeID: String
    let conflict: TerminalTextColorConflict

    var signature: String {
        [
            themeID,
            conflict.foregroundSource.persistenceToken,
            conflict.backgroundSource.persistenceToken,
            conflict.foreground.hexString,
            conflict.background.hexString
        ].joined(separator: "|")
    }

    var title: String {
        L10n.string("A program color conflicts with this terminal theme")
    }

    var detail: String {
        L10n.format(
            "%@ (%@) is %@ against %@ (%@). Threading shows it as sent. "
                + "Use default foreground (ANSI 39), or change themes.",
            conflict.foregroundSource.displayName,
            conflict.foreground.hexString,
            String(format: "%.2f:1", conflict.contrastRatio),
            conflict.backgroundSource.displayName,
            conflict.background.hexString
        )
    }
}

/// Posted asynchronously from the renderer callback so showing the diagnostic never mutates the
/// AppKit hierarchy from inside a terminal draw pass.
struct TerminalTextVisibilityIssueDetected: AppEvent {
    static let name = Notification.Name("terminalTextVisibilityIssueDetected")
    let issue: TerminalTextVisibilityIssue
}

/// Drops renderer findings that belonged to a palette before that palette is reapplied.
/// SwiftTerm will report the still-relevant pair again from the next visible draw; if the new
/// palette fixed it, the stale explanation stays gone.
struct TerminalTextVisibilityIssuesInvalidated: AppEvent {
    static let name = Notification.Name("terminalTextVisibilityIssuesInvalidated")
    let identity: TerminalInstanceIdentity
}

/// The exact colour/theme signatures a person dismissed.
///
/// The list is capped because 24-bit colour is externally controlled. Newest first makes the
/// finite policy deterministic without turning a diagnostic preference into an unbounded log.
@MainActor
struct TerminalTextVisibilityDismissals {
    static let shared = TerminalTextVisibilityDismissals(defaults: PreferenceStore.shared)
    static let maximumCount = 64

    private let defaults: UserDefaults
    private let key = "dismissedTerminalTextVisibilityIssues"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func contains(_ issue: TerminalTextVisibilityIssue) -> Bool {
        stored.contains(issue.signature)
    }

    func dismiss(_ issue: TerminalTextVisibilityIssue) {
        let updated = [issue.signature] + stored.filter { $0 != issue.signature }
        defaults.set(Array(updated.prefix(Self.maximumCount)), forKey: key)
    }

    private var stored: [String] {
        defaults.stringArray(forKey: key) ?? []
    }
}

private extension TerminalRenderedColor {
    var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }
}

private extension TerminalRenderedColorSource {
    var persistenceToken: String {
        switch self {
        case .ansi256(let index): return "ansi:\(index)"
        case .trueColor(let red, let green, let blue):
            return "rgb:\(red):\(green):\(blue)"
        case .defaultForeground: return "default-fg"
        case .defaultBackground: return "default-bg"
        case .invertedDefaultForeground: return "inverted-default-fg"
        case .invertedDefaultBackground: return "inverted-default-bg"
        }
    }

    var displayName: String {
        switch self {
        case .ansi256(let index):
            switch index {
            case 0: return L10n.string("ANSI black")
            case 1: return L10n.string("ANSI red")
            case 2: return L10n.string("ANSI green")
            case 3: return L10n.string("ANSI yellow")
            case 4: return L10n.string("ANSI blue")
            case 5: return L10n.string("ANSI magenta")
            case 6: return L10n.string("ANSI cyan")
            case 7: return L10n.string("ANSI white")
            case 8: return L10n.string("ANSI bright black")
            case 9: return L10n.string("ANSI bright red")
            case 10: return L10n.string("ANSI bright green")
            case 11: return L10n.string("ANSI bright yellow")
            case 12: return L10n.string("ANSI bright blue")
            case 13: return L10n.string("ANSI bright magenta")
            case 14: return L10n.string("ANSI bright cyan")
            case 15: return L10n.string("ANSI bright white")
            default: return L10n.format("ANSI palette color %lld", Int64(index))
            }
        case .trueColor:
            return L10n.string("24-bit color")
        case .defaultForeground:
            return L10n.string("the terminal foreground")
        case .defaultBackground:
            return L10n.string("the terminal background")
        case .invertedDefaultForeground:
            return L10n.string("the inverted terminal foreground")
        case .invertedDefaultBackground:
            return L10n.string("the inverted terminal background")
        }
    }
}
