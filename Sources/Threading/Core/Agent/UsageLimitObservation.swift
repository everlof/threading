import Foundation

// MARK: - Usage Limit Observation

/// Evidence that a terminal conversation may have stopped on its provider's usage limit.
///
/// A synthetic root refusal is complete by itself. A failed background task is deliberately not:
/// the parent normally keeps working after a child fails, so that record becomes a session stop
/// only while the live terminal also shows Claude's unmistakable limit chooser or inline notice.
struct UsageLimitObservation: Equatable, Sendable {

    enum Evidence: Equatable, Sendable {
        case providerRefusal
        case failedBackgroundTask
    }

    let stop: UsageLimitStop
    let evidence: Evidence

    var requiresTerminalConfirmation: Bool {
        evidence == .failedBackgroundTask
    }

    /// Turns evidence into a stop that may drive activity and recovery, failing closed when a
    /// provisional child failure is no longer visible as a limit block in the parent terminal.
    func confirmedStop(screenLines: [String]) -> UsageLimitStop? {
        guard requiresTerminalConfirmation else { return stop }

        switch LimitChooserReading.read(screenLines: screenLines) {
        case .chooser, .notice:
            guard let visible = Self.visibleRefusal(in: screenLines) else { return stop }
            return UsageLimitStop(
                message: visible.message,
                resetHint: visible.resetHint ?? stop.resetHint,
                recordID: stop.recordID
            )

        case .absent:
            return nil
        }
    }

    /// The chooser options themselves mention limits too (including the upgrade row), so only a
    /// line shaped like an actual refusal may replace the notification's longer wrapper text.
    private static func visibleRefusal(in lines: [String]) -> UsageLimitStop? {
        let refusals = lines.reversed().compactMap { line -> UsageLimitStop? in
            guard let refusal = UsageLimitStop.recognised(in: line) else { return nil }
            let folded = refusal.message.lowercased()
            guard refusal.resetHint != nil
                    || folded.contains("limit reached")
                    || folded.contains("hit your")
                    || folded.contains("reached your")
                    || folded.contains("rate limit exceeded")
            else { return nil }
            return refusal
        }
        return refusals.first(where: { $0.resetHint != nil }) ?? refusals.first
    }
}
