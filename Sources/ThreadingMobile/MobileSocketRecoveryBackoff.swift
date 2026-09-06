import Foundation

/// The wait before the next event-socket recovery, by how many recoveries have run since the
/// socket last delivered a frame.
///
/// Doubling from one second to a sixty-second ceiling. The count it reads is reset by a frame on
/// the socket and by nothing else: a catalogue answer says the Mac is reachable, not that the
/// socket is back, and the 2026-09-06 report had a `304` every second resetting a socket that
/// failed every second, so the ladder never climbed off its first step.
enum MobileSocketRecoveryBackoff {
    static let firstDelay: TimeInterval = 1
    static let ceiling: TimeInterval = 60
    /// The exponent stops growing here. The ceiling would cap the value anyway; a runaway
    /// counter is not something to hand `pow`.
    private static let maximumExponent = 6

    static func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt, 0), maximumExponent)
        return min(firstDelay * pow(2, Double(exponent)), ceiling)
    }
}
