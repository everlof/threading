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
/// Only values that record a *choice* come through here. Operational behavioural settings still
/// read `.standard` directly, because several tests set one of those keys and then assert that
/// the app read it. A General-tab value may still be a recorded choice: the provider a new
/// session opens on is changed by the composer itself, so hosted picker tests must not answer it
/// for the developer.
enum PreferenceStore {

    /// The family every hosted test bundle's scratch suite belongs to. `scripts/test.sh` sweeps
    /// by this prefix, so the name a run picks below has to keep it.
    static let hostedTestSuitePrefix = "codes.threading.hosted-tests"

    /// Named rather than volatile, so a test can still read back through the app's own code
    /// paths what it wrote through them — which is what `restore()`'s tests do.
    ///
    /// **Named per process, though, or the seam only moves the collision.** One suite name for
    /// every test host meant two `xcodebuild test` runs on the same machine shared a preferences
    /// domain, and this repository's normal working state is several agents running the suite at
    /// once. What that looks like from inside is not a shared-state bug but a haunting: a test
    /// applies Cyberpunk, reads the choice back, and finds Claymorphism; a recovery test that
    /// stored `threading` reads `ext.com.example.pack.storm`, an id from a *contributed* theme
    /// no test in the process ever installed. Every one of them passes alone, passes on a
    /// re-run, and bisects to a different culprit each time, because the interfering write comes
    /// from another process rather than an earlier test. The pid is what makes a run's recorded
    /// choices its own, and `StateManager` already scopes its scratch store the same way for the
    /// same reason — see `persistence.md`.
    static let hostedTestSuiteName =
        "\(hostedTestSuitePrefix).\(ProcessInfo.processInfo.processIdentifier)"

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
