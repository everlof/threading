import Foundation
@testable import Threading

/// An identity store pointed at a directory the calling test owns.
///
/// The store's own default already redirects under a hosted test, for the same reason
/// `StateManager` does. This is the second belt: a test that mints a certificate writes it into a
/// directory it erases in teardown, so one run cannot read or replace another run's identity, and
/// a build that ever undid the redirect fails here rather than by unpairing the developer's phone.
enum RemoteIdentityTestStore {

    /// A fresh store and the directory it owns. The caller removes the directory in teardown.
    static func make(
        label: String = #function,
        strategy: RemoteIdentityImportStrategy? = nil
    ) -> (store: RemoteAccessIdentityStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingIdentityTests")
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        let store = RemoteAccessIdentityStore(directory: directory, strategy: strategy)
        // A hosted test runs inside the shipping app, so an unredirected journal call would
        // append identity events to the developer's own support journal.
        store.journal = { _, _, _ in }
        return (store, directory)
    }

    static func erase(_ directory: URL?) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
