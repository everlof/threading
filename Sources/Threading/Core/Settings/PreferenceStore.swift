import Foundation

/// Where a preference the *user chose* is written.
///
/// `UserDefaults.standard` in the app, and a scratch suite under a hosted test bundle.
///
/// **The tests run inside the shipping app.** `ThreadingTests` is hosted in the app target, so
/// `UserDefaults.standard` there is the developer's own preferences — the ones the app they are
/// running launches into. A test that applies a theme was rewriting that choice: `appThemeID`
/// came back as `system` after every suite run, which is the reported "theme selection doesn't
/// persist between app launches". It is not the app forgetting; it is the last test to run
/// answering the question on the user's behalf. A palette named "Reserved Name Probe" was left
/// standing in the real terminal-theme list the same way.
///
/// Deciding the store **once, here** is what makes that impossible to forget. Three test classes
/// apply a theme in `setUp` and exactly one put the old value back afterwards, which is the kind
/// of bookkeeping a seam should own rather than every call site. `AppDelegate` already skips its
/// whole startup on the same signal, for the same reason: a hosted test must not act on the
/// user's state.
///
/// Only the stores that record a *choice* come through here. Behavioural settings still read
/// `.standard` directly, because several tests set one of those keys and then assert that the
/// app read it — a seam under those would be a second bug, not a fix.
enum PreferenceStore {

    /// Named rather than volatile, so a test can still read back through the app's own code
    /// paths what it wrote through them — which is what `restore()`'s tests do.
    static let hostedTestSuiteName = "codes.threading.hosted-tests"

    /// Resolved once: `NSClassFromString` is a runtime lookup, and the answer cannot change
    /// within a process.
    /// `UserDefaults` documents concurrent access as safe, but its Objective-C declaration does
    /// not yet carry `Sendable`. Keep that compatibility assertion inside one immutable wrapper
    /// rather than marking the globally visible property `nonisolated(unsafe)`.
    private static let storage = SendableUserDefaults({
        guard NSClassFromString("XCTestCase") != nil else { return .standard }
        return UserDefaults(suiteName: hostedTestSuiteName) ?? .standard
    })

    static var shared: UserDefaults { storage.value }

    /// Whether this process redirects, so a test can assert the redirect rather than the
    /// developer's luck.
    static var isRedirected: Bool { shared !== UserDefaults.standard }
}

/// Foundation documents `UserDefaults` as safe for concurrent use; the imported Objective-C
/// type has not acquired that conformance. This wrapper is immutable after initialization.
private final class SendableUserDefaults: @unchecked Sendable {
    let value: UserDefaults
    init(_ makeValue: () -> UserDefaults) { value = makeValue() }
}
