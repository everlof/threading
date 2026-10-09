import Foundation

/// A small mutable value whose every access belongs to the same lock.
final class LockedState<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State
    init(initialState: State) { state = initialState }
    func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
