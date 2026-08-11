import Foundation

// MARK: - Launch Flag

/// The one-shot answers a recovery launch leaves for the next one.
enum LaunchFlag: String, CaseIterable, Sendable {

    /// "Try Normal Launch Once": come up normally even though the history says otherwise.
    case forceNormalNextLaunch

    /// "Disable Extensions for Next Launch": start no extension host and no packages.
    case disableExtensionsNextLaunch
}

// MARK: - Launch Flags

/// One record, holding every flag explicitly.
///
/// **Explicit booleans, and consumption rewrites rather than deletes.** There is no
/// "cleared versus never set" question to answer here, so that is not why: what the positive
/// record buys is a readable afterwards. A support report that says a forced-normal launch was
/// armed by launch X and consumed by launch Y is what makes the "and then *that* one crashed
/// too" story legible, and a deleted file says none of it.
struct LaunchFlags: Codable, Equatable, Sendable {

    var version: Int
    var forceNormalNextLaunch: Bool
    var disableExtensionsNextLaunch: Bool
    /// When the flags were last armed, in the ledger's own timestamp form.
    var armedAt: String?
    var armedByLaunch: String?
    var consumedByLaunch: String?

    static let none = LaunchFlags(
        version: LaunchFlagsDefaults.formatVersion,
        forceNormalNextLaunch: false,
        disableExtensionsNextLaunch: false
    )

    init(
        version: Int = LaunchFlagsDefaults.formatVersion,
        forceNormalNextLaunch: Bool = false,
        disableExtensionsNextLaunch: Bool = false,
        armedAt: String? = nil,
        armedByLaunch: String? = nil,
        consumedByLaunch: String? = nil
    ) {
        self.version = version
        self.forceNormalNextLaunch = forceNormalNextLaunch
        self.disableExtensionsNextLaunch = disableExtensionsNextLaunch
        self.armedAt = armedAt
        self.armedByLaunch = armedByLaunch
        self.consumedByLaunch = consumedByLaunch
    }

    var isArmed: Bool { forceNormalNextLaunch || disableExtensionsNextLaunch }

    func armed(_ flag: LaunchFlag) -> Bool {
        switch flag {
        case .forceNormalNextLaunch: return forceNormalNextLaunch
        case .disableExtensionsNextLaunch: return disableExtensionsNextLaunch
        }
    }

    /// Machine-stable, for the journal. Never a path.
    var token: String {
        guard isArmed else { return LaunchFlagsDefaults.noneToken }
        return LaunchFlag.allCases
            .filter { armed($0) }
            .map(\.rawValue)
            .joined(separator: ",")
    }
}

// MARK: - Launch Flags Store

/// Where a recovery launch writes what the next launch should do differently.
///
/// **A file beside the ledger, not `PreferenceStore`.** The onboarding flag's rule is a preference
/// the user set on a settings page with the app running normally; this one is written immediately
/// before `AppRelaunch.PreparedRelaunch.commit`, which deliberately leaves without the quit path
/// every store hangs its final save on. `UserDefaults` is asynchronous to disk, `cfprefsd`
/// holds the domain, and `synchronize()` is deprecated — so a sentinel written immediately before
/// an `exit()` is exactly the case it is worst at. It also has to survive Reset Settings, which
/// takes the preferences domain, while being taken by Reset Everything, which moves the support
/// directory: a file under `Launch/` does both by construction, and inherits that directory's
/// hosted-test redirection so a test cannot arm the developer's own next launch.
///
/// `@unchecked Sendable`: every mutable property is touched only inside `queue`, a serial queue,
/// and every entry point below hops onto it.
final class LaunchFlagsStore: @unchecked Sendable {

    // MARK: - Singleton

    static let shared = LaunchFlagsStore(url: LaunchFlagsDefaults.defaultURL)

    // MARK: - Properties

    let url: URL

    private let fileManager: FileManager
    private let queue = DispatchQueue(label: LaunchFlagsDefaults.queueLabel)
    private var reportedReadRefusal = false

    // MARK: - Initialization

    init(url: URL = LaunchFlagsDefaults.defaultURL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    // MARK: - Public Methods

    /// What is on disk, changing nothing. The surface reads this to title its own buttons.
    func read() -> LaunchFlags {
        queue.sync { readFlags().value }
    }

    /// Reads the flags and clears them in one breath, returning what this launch may act on.
    ///
    /// **Called before the mode is resolved and before the `begin` record is appended**, so a
    /// one-shot is spent whether or not the branch it would have chosen won.
    ///
    /// A clear that fails returns `.none`: a one-shot that cannot be cleared is a permanent
    /// setting, and a permanent "always launch normally" would defeat the crash-loop protection
    /// outright. Failing this way costs the user one more crash and one more press of the button;
    /// failing the other way costs them the feature silently.
    func consume(launchID: String?) -> LaunchFlags {
        queue.sync {
            guard case .loaded(let flags) = readFlags() else { return .none }
            guard flags.isArmed else { return .none }

            var cleared = flags
            cleared.forceNormalNextLaunch = false
            cleared.disableExtensionsNextLaunch = false
            cleared.consumedByLaunch = launchID

            guard write(cleared) else {
                ThreadingLogger.app.error(
                    """
                    Could not clear the launch flags at \(self.url.path, privacy: .private(mask: .hash)). \
                    They are ignored for this launch rather than becoming permanent.
                    """
                )
                return .none
            }
            return flags
        }
    }

    /// Arms or disarms one flag, leaving the other alone. Returns whether the write landed.
    @discardableResult
    func set(_ flag: LaunchFlag, armed: Bool, launchID: String?) -> Bool {
        queue.sync {
            let read = readFlags()
            guard !read.isRefused else {
                ThreadingLogger.app.error(
                    "Refusing to replace unreadable launch flags at \(self.url.path, privacy: .private(mask: .hash))"
                )
                return false
            }
            var flags = read.value
            switch flag {
            case .forceNormalNextLaunch: flags.forceNormalNextLaunch = armed
            case .disableExtensionsNextLaunch: flags.disableExtensionsNextLaunch = armed
            }
            flags.version = LaunchFlagsDefaults.formatVersion
            flags.consumedByLaunch = nil
            if armed {
                flags.armedAt = LaunchLedgerTimestamp.string(from: Date())
                flags.armedByLaunch = launchID
            }
            return write(flags)
        }
    }

    // MARK: - Private Methods

    /// A record from a later Threading is left byte for byte and read as no flags at all.
    ///
    /// The ledger's posture, for its reason: the cost of being wrong about a newer build is that
    /// build's own state, and the cost of standing down is one launch that does not honour a
    /// one-shot it could not understand.
    private func readFlags() -> LaunchFlagsRead {
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do {
            data = try BoundedFileReader.read(
                url,
                maximumBytes: LaunchFlagsDefaults.maximumFileBytes
            )
        } catch {
            reportReadRefusal(
                stage: "read",
                detail: error.localizedDescription
            )
            return .refused
        }
        let flags: LaunchFlags
        do {
            flags = try JSONDecoder().decode(LaunchFlags.self, from: data)
        } catch {
            reportReadRefusal(
                stage: "decode",
                detail: error.localizedDescription
            )
            return .refused
        }
        guard flags.version <= LaunchFlagsDefaults.formatVersion else {
            if !reportedReadRefusal {
                reportedReadRefusal = true
                ThreadingLogger.app.warning(
                    "Launch flags use a newer format version=\(flags.version, privacy: .public); flags are ignored"
                )
            }
            return .refused
        }
        if reportedReadRefusal {
            reportedReadRefusal = false
            ThreadingLogger.app.notice("Launch flags became readable again")
        }
        return .loaded(flags)
    }

    private func write(_ flags: LaunchFlags) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(flags)
        } catch {
            ThreadingLogger.app.fault(
                "Launch flags encoding failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return false
        }

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            ThreadingLogger.app.error(
                "Launch flags write failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return false
        }
    }

    private func reportReadRefusal(stage: String, detail: String) {
        guard !reportedReadRefusal else { return }
        reportedReadRefusal = true
        ThreadingLogger.app.error(
            "Launch flags are unreadable stage=\(stage, privacy: .public): \(detail, privacy: .private(mask: .hash))"
        )
    }
}

private enum LaunchFlagsRead {
    case missing
    case loaded(LaunchFlags)
    case refused

    var value: LaunchFlags {
        if case .loaded(let flags) = self { return flags }
        return .none
    }

    var isRefused: Bool {
        if case .refused = self { return true }
        return false
    }
}

// MARK: - Launch Flags Defaults

enum LaunchFlagsDefaults {

    static let fileName = "launch-flags.json"
    static let queueLabel = "codes.threading.launch-flags"
    static let maximumFileBytes = 16 * 1_024

    /// Raised only when the record's shape changes. A reader stands down above its own.
    static let formatVersion = 1

    static let noneToken = "none"

    /// Beside the ledger, in the directory `LaunchLedgerDefaults` already redirects under a
    /// hosted test bundle. Derived from the ledger's own URL rather than rebuilt from the
    /// support directory, so the two can never disagree about which directory that is.
    static var defaultURL: URL {
        LaunchLedgerDefaults.defaultURL
            .deletingLastPathComponent()
            .appendingPathComponent(fileName)
    }
}
