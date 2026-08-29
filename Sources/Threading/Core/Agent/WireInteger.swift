import Foundation

/// Reading a provider's JSON number as a whole number, and refusing the ones `Int64` cannot hold.
///
/// **JSON permits an integer of any size. `Int64` does not, and `JSONSerialization` hides the
/// difference where only the `NSNumber` itself can see it.** An integer above `Int64.max` arrives
/// stored as unsigned, an integer below `Int64.min` arrives stored as a `Double`, and both answer
/// `int64Value` with a reinterpretation of those bits rather than a reading — one of them with the
/// sign flipped. Measured against `JSONSerialization` on this platform:
///
/// ```
/// json text                objCType   doubleValue                int64Value
/// 12345678901234567890     Q          1.2345678901234567e+19     -6101065172474983726
/// 9223372036854775808      Q          9.223372036854776e+18      -9223372036854775808
/// -12345678901234567890    d         -1.2345678901234567e+19      6101065172474983726  (positive)
/// 1e30                     d          1e+30                       9223372036854775807  (saturated)
/// 9223372036854775807      q          9.223372036854776e+18       9223372036854775807  (exact)
/// ```
///
/// So an unguarded `int64Value` publishes a number no provider ever sent, and one that a later
/// `+` can trap on. Three readers took it unguarded: `JSONValue`'s scalar bridge, which claimed
/// `.integer` for a value that had wrapped; `TranscriptReplay`'s context reading, which summed
/// four of them and crashed the app on the overflow; and the usage adapters, which clamped a
/// wrapped negative to `0` and reported a token count the account was never billed for.
///
/// **The obvious guard is wrong, and that is why this type exists rather than an inline check.**
/// `Int64(exactly: number.doubleValue)` reads like the test and answers `nil` for a *legitimate*
/// `Int64.max`, because `doubleValue` has already rounded it to 2^63 — a fix built on it demotes
/// exact integers to approximations. The question has to be put to the `NSNumber`, never to a
/// `Double` made from it. `Int64(exactly:)`'s `NSNumber` overload asks Foundation what the value
/// *is*, which is the same question `JSONValue`'s `CFBooleanGetTypeID` test asks about booleans:
/// what the number is, not what it could be read as.
///
/// Neither entry point refuses on sign. A negative count is a provider protocol error rather than
/// an unrepresentable number, and the readers that care already clamp it where they use it.
enum WireInteger {

    /// The number exactly, or nil when `Int64` cannot hold it.
    ///
    /// A non-integral number is refused too, because it is not a whole number: `2.0` reads as
    /// `2` and `1.5` refuses. Use this where the answer is a *claim* about the value — deciding
    /// that a wire number is an integer rather than a real number, say.
    static func exact(_ number: NSNumber) -> Int64? {
        Int64(exactly: number)
    }

    /// The number the way `NSNumber.int64Value` reads one — truncating a fractional value toward
    /// zero — except that a value outside `Int64` is refused instead of wrapped or saturated.
    ///
    /// Use this where a reader already truncates and only the wrapping needs fixing: the token
    /// counts, which every provider writes as integers and one of which arrived as `100.4` in the
    /// recorded corpus. Truncating is that reader's existing contract; wrapping never was.
    static func whole(_ number: NSNumber) -> Int64? {
        if let exact = Int64(exactly: number) { return exact }

        // Not exactly an `Int64`, so either fractional or out of range. `doubleValue` decides
        // which, and the bounds are written as the two powers of two a `Double` represents
        // exactly: `Int64.max` is not one of them, and comparing against it would round.
        let value = number.doubleValue
        guard value >= -9223372036854775808.0, value < 9223372036854775808.0 else { return nil }
        return Int64(value)
    }

    /// `whole(_:)` as an `Int`. See it for what is refused and why.
    static func wholeInt(_ number: NSNumber) -> Int? {
        guard let value = whole(number) else { return nil }
        return Int(exactly: value)
    }
}
