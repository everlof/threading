import AppKit

// MARK: - Chrome Automation Profile

/// The one Google Chrome profile Threading is allowed to drive, and everything known about it.
///
/// It is deliberately **not** the user's everyday profile, and that is not a preference. Since
/// Chrome 136 (May 2025) Chrome refuses `--remote-debugging-port` and `--remote-debugging-pipe`
/// against the default user-data directory, precisely to stop tools — and infostealers — from
/// driving the profile that holds a person's signed-in sessions. Playwright's persistent-context
/// launch speaks CDP too, so "attach to the Chrome you already use" is not reachable on current
/// Chrome by any transport.
///
/// What is reachable is a profile of Threading's own, in Threading's own Application Support
/// directory, that the user signs into once and installs their password manager's extension
/// into. From then on sign-in happens where the extension, passkeys, and device-bound tokens
/// actually work — inside real Chrome — and Threading still reads no cookie, no Keychain item,
/// and no credential. The honest form of "signed into what Chrome is signed into" is "signed in
/// once, kept".
///
/// The profile lives under `AppDataLocations.supportDirectory`, so Settings ▸ Advanced ▸ Reset
/// Everything moves it aside with the rest of Threading's state. That is the right blast radius:
/// it is Threading's directory, holding sessions the user created through Threading.
@MainActor
final class ChromeAutomationProfile {

    /// What a caller has to say to the user before it can launch anything.
    enum State: Equatable {
        /// Google Chrome is not installed. Nothing here can be offered.
        case chromeMissing
        /// Chrome is installed but has never run against this profile, so it holds no sign-ins
        /// and no extension. Attaching would only produce a blank browser.
        case notSetUp
        /// Chrome is installed and the profile has been used at least once.
        case ready
    }

    static let shared = ChromeAutomationProfile()

    /// Threading's own user-data directory for Chrome.
    let directory: URL

    private let fileManager: FileManager
    private let locateChrome: @MainActor () -> URL?
    private let launch: @MainActor (URL, [String]) -> Bool

    init(
        directory: URL = ChromeAutomationDefaults.directory,
        fileManager: FileManager = .default,
        locateChrome: @escaping @MainActor () -> URL? = ChromeAutomationProfile.installedChromeURL,
        launch: @escaping @MainActor (URL, [String]) -> Bool
            = ChromeAutomationProfile.openApplication
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.locateChrome = locateChrome
        self.launch = launch
    }

    // MARK: - State

    /// Where Chrome is, asked of LaunchServices rather than of `/Applications`.
    ///
    /// Same argument as `ExternalApp`: a bundle identifier is true the moment the app is on the
    /// disk, wherever the user keeps it, while a path is a guess and a `PATH` probe would need a
    /// login shell before it could answer at all.
    var chromeApplicationURL: URL? { locateChrome() }

    var state: State {
        guard chromeApplicationURL != nil else { return .chromeMissing }
        return hasBeenSetUp ? .ready : .notSetUp
    }

    /// Chrome writes its profile directory the first time it runs against a user-data directory,
    /// so this is a claim about Chrome having *been there*, not about the folder existing —
    /// Playwright creates the folder itself and would otherwise make an empty profile look ready.
    var hasBeenSetUp: Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(
            atPath: directory
                .appendingPathComponent(ChromeAutomationDefaults.profileMarker, isDirectory: true)
                .path,
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }

    /// Whether Chrome currently holds the profile. One user-data directory is one Chrome, so an
    /// attach run and a setup window cannot share it; Playwright reports this as a launch failure
    /// and this read is what lets a caller say so in advance, in the user's own words.
    ///
    /// `attributesOfItem` rather than `fileExists`, because the lock is a symlink whose target is
    /// `host-ip:pid` and never resolves — following it answers "no lock" for a profile that is
    /// very much locked.
    var isLocked: Bool {
        let lock = directory.appendingPathComponent(ChromeAutomationDefaults.lockName)
        return (try? fileManager.attributesOfItem(atPath: lock.path)) != nil
    }

    // MARK: - Setup

    /// Opens real Chrome, headful, on this profile so the user can sign in and install their
    /// password manager's extension.
    ///
    /// A separate application instance on purpose: a running everyday Chrome would otherwise
    /// simply come forward and the arguments would go nowhere, which reads as "the button did
    /// nothing" while silently pointing the user at the profile this feature exists to avoid.
    @discardableResult
    func openForSetup() -> Bool {
        guard let application = chromeApplicationURL else { return false }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return launch(application, launchArguments)
    }

    /// What Chrome is told, and nothing more. No debugging port, no disabled security, no
    /// profile import: the setup window is an ordinary Chrome that happens to keep its state
    /// somewhere Threading can point Playwright at later.
    var launchArguments: [String] {
        [
            "--user-data-dir=\(directory.path)",
            "--no-first-run",
            "--no-default-browser-check"
        ]
    }

    // MARK: - Platform

    static func installedChromeURL() -> URL? {
        ChromeAutomationDefaults.bundleIdentifiers.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    private static func openApplication(_ application: URL, arguments: [String]) -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: application, configuration: configuration) { _, error in
            guard let error else { return }
            ThreadingLogger.agent.error(
                "Chrome automation profile did not open: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
        return true
    }
}

// MARK: - Defaults

enum ChromeAutomationDefaults {

    /// Chrome ships under one identifier; the beta and Canary channels are deliberately not
    /// accepted, because the profile the user signs into has to be the browser they trust.
    static let bundleIdentifiers = ["com.google.Chrome"]

    /// The Playwright channel name for a real, locally installed Google Chrome — as opposed to
    /// Playwright's own bundled Chromium, which carries no extensions and no sign-ins.
    static let channel = "chrome"

    /// `~/Library/Application Support/Threading/ChromeAutomationProfile`.
    static var directory: URL {
        AppDataLocations.supportDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static let directoryName = "ChromeAutomationProfile"

    /// Chrome's own first profile inside a user-data directory. Its presence is the proof that
    /// Chrome — not Playwright, and not `createDirectory` — has run here.
    static let profileMarker = "Default"

    /// Chrome's single-instance lock inside a user-data directory.
    static let lockName = "SingletonLock"

    /// How many origins one attach run may be pre-authorized for. The bridge is a one-shot batch
    /// that cannot come back and ask, so the whole list is granted before launch — which is only
    /// an honest prompt while it stays short enough to read.
    static let maximumAllowedOrigins = 10
}
