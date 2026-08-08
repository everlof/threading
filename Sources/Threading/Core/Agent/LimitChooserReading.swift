import Foundation

// MARK: - Limit Chooser Reading

/// Reads the CLI's rate-limit chooser off a terminal screen, so it can be answered by label
/// and never by position.
///
/// The specification is a disagreement: the specimen in `limit-recovery.md` shows "Stop and
/// wait for limit to reset" as option 1, preselected, and the user who asked for this feature
/// remembers answering it as option 2. Whichever memory belongs to which CLI version, a blind
/// digit is wrong — the row is *found by its words*, and the digit sent is whatever digit that
/// row carries today.
///
/// Everything here fails closed. A screen that is not unmistakably this chooser — the label
/// missing, wording changed, two rows claiming it, no digit to send — reads as `.absent` with
/// the reason spelled out for the journal, and the caller does nothing. The rule is the shell
/// policy's ("wrong in one direction only"): a missed recovery costs what today already costs,
/// while a wrong keystroke types into someone's session.
enum LimitChooserReading {

    /// The chooser, read well enough to answer.
    struct Chooser: Equatable {
        /// The digit the stop-and-wait row carries.
        let optionDigit: Character

        /// Whether the selection marker already sits on that row, in which case Return alone
        /// confirms it. When it does not, the caller sends the digit and then *re-reads the
        /// screen*: Return is only ever sent at a marker verified on the right row, so a CLI
        /// that ignored the digit can never have Return land on "Upgrade your plan".
        let markerOnOption: Bool
    }

    enum Outcome: Equatable {
        case chooser(Chooser)

        /// The refusal's *other* shape: no chooser at all, the sentence printed inline and the
        /// CLI back at its ordinary prompt — observed when the limit lands as a background
        /// workflow wraps up ("You've hit your session limit · resets 1:10pm" over
        /// "/upgrade to increase your usage limit."). There is nothing to answer, which is an
        /// outcome and not a failure: recovery skips the keystrokes and goes straight to the
        /// schedule.
        ///
        /// Recognised positively, never as "chooser missing": the marker is the reset clause's
        /// own spelling (`resets `, which the chooser's stop row — "…for limit to reset" —
        /// never contains) or the slash-command hint (`/upgrade`, where the chooser's option
        /// says "Upgrade" with no slash). And only ever *after* the option scan found nothing,
        /// so a screen holding both shapes is answered as the chooser it is.
        case notice

        /// Not this chooser and not the notice. The reason is part of the contract — "it did
        /// nothing" and "it read a screen that was not the chooser" are unrelated bugs that
        /// look identical without it.
        case absent(String)
    }

    // MARK: - Public Methods

    /// Reads one screen's visible rows.
    static func read(screenLines: [String]) -> Outcome {
        let options = screenLines.compactMap(option(from:))

        let stopRows = options.filter { $0.label.localizedCaseInsensitiveContains(LimitChooserDefaults.stopAndWaitLabel) }
        guard !stopRows.isEmpty else {
            if screenLines.contains(where: isNoticeLine) { return .notice }
            return .absent("no option row contains \"\(LimitChooserDefaults.stopAndWaitLabel)\"")
        }
        guard stopRows.count == 1, let stopRow = stopRows.first else {
            return .absent("\(stopRows.count) option rows contain \"\(LimitChooserDefaults.stopAndWaitLabel)\"")
        }

        // The stop row naming an upgrade is not a parse to act on, whatever else matches.
        guard !stopRow.label.localizedCaseInsensitiveContains(LimitChooserDefaults.upgradeLabel) else {
            return .absent("the stop-and-wait row also mentions \"\(LimitChooserDefaults.upgradeLabel)\"")
        }

        // Shape check: this chooser always offers the paid way out beside the wait. A screen
        // with the right sentence but no second option is some other prompt quoting it —
        // an agent's own output can contain these words, and did in the conversation that
        // designed this.
        let upgradeRows = options.filter { $0.label.localizedCaseInsensitiveContains(LimitChooserDefaults.upgradeLabel) }
        guard !upgradeRows.isEmpty else {
            return .absent("no companion option row contains \"\(LimitChooserDefaults.upgradeLabel)\"")
        }

        return .chooser(Chooser(optionDigit: stopRow.digit, markerOnOption: stopRow.hasMarker))
    }

    // MARK: - Private Methods

    /// Whether one row is the inline refusal. The reset clause must carry the limit it
    /// belongs to, so an agent's own prose about resets does not pass on one word.
    private static func isNoticeLine(_ line: String) -> Bool {
        if line.localizedCaseInsensitiveContains(LimitChooserDefaults.upgradeHint) { return true }
        return line.localizedCaseInsensitiveContains(LimitChooserDefaults.resetClause)
            && line.localizedCaseInsensitiveContains(LimitChooserDefaults.limitWord)
    }

    private struct OptionRow {
        let digit: Character
        let label: String
        let hasMarker: Bool
    }

    /// Parses `❯ 1. Stop and wait…` / `  2. Upgrade your plan` shapes; anything else is not an
    /// option row. The digit must lead (after at most a marker), so prose that merely contains
    /// a numbered phrase does not read as an option.
    private static func option(from line: String) -> OptionRow? {
        var text = line.trimmingCharacters(in: .whitespaces)

        var hasMarker = false
        for marker in LimitChooserDefaults.selectionMarkers where text.hasPrefix(marker) {
            hasMarker = true
            text = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            break
        }

        guard let digit = text.first, digit.isNumber else { return nil }
        text = String(text.dropFirst())
        guard text.hasPrefix(".") else { return nil }

        let label = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }

        return OptionRow(digit: digit, label: label, hasMarker: hasMarker)
    }
}

// MARK: - Limit Chooser Defaults

enum LimitChooserDefaults {
    /// The words that name the only option ever chosen. Matched case-insensitively as a
    /// phrase — resilient to capitalisation, not to rewording, which is the right failure:
    /// a CLI that changed the sentence should re-measure, not be guessed at.
    static let stopAndWaitLabel = "stop and wait"

    /// The option never chosen, and the shape check that this really is the limit chooser.
    static let upgradeLabel = "upgrade"

    /// Selection markers the CLI draws ahead of the chosen row.
    static let selectionMarkers = ["❯", ">"]

    /// The chooser-less notice's two positive marks. `resets ` — with its `s` and its trailing
    /// space, the spelling `UsageLimitStop`'s reset markers also key on — appears in
    /// "resets 1:10pm" and never in the chooser's "…for limit to reset"; `/upgrade` is the
    /// slash command the notice offers, where the chooser's option has no slash.
    static let resetClause = "resets "
    static let upgradeHint = "/upgrade"
    static let limitWord = "limit"
}
