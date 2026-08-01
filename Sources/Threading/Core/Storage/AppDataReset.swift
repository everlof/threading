import Foundation

// MARK: - App Data Locations

/// Every file location where Threading keeps ordinary state, named once.
///
/// There are exactly two: the preferences domain, and one directory under Application Support.
/// Ordinary durable state is under one of them — the SQLite store, panel layouts and their cached
/// PNGs, project icons, avatars, usage history, icon-research records, the single-instance lock.
/// Stores reach it through `ProjectIconDefaults.applicationDirectoryName`, which is the same
/// `Threading` folder `StateManager` owns.
///
/// **What is deliberately not here** is anything written into another program's folder. The
/// Claude status-line cache lives under `Claudex/ClaudeStatus` because that is where the *CLI*
/// reads it from, and per-session hook and MCP config files are handed to an agent process.
/// Those are not Threading's state to reset, and a reset that took them would be reaching into
/// someone else's directory on the strength of having written there once.
///
/// App-owned security capabilities are the exception: paired-owner bearers live in Keychain.
/// `AdvancedPreferencesViewController` erases that item before `Reset Everything`, rather than
/// exporting secrets into the recoverable reset folder. A settings-only reset preserves it.
enum AppDataLocations {

    /// The preferences domain, which is the bundle identifier — `codes.threading`.
    ///
    /// Read from the bundle rather than written out, so a build with another identifier resets
    /// its own preferences instead of a string someone typed here.
    static var preferencesDomain: String {
        Bundle.main.bundleIdentifier ?? AppDataResetDefaults.fallbackDomain
    }

    /// Where macOS keeps that domain. Only ever *revealed* — a reset goes through
    /// `UserDefaults`, because `cfprefsd` holds the file and would write its cache back over
    /// anything done behind it.
    static var preferencesFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(AppDataResetDefaults.preferencesDirectory, isDirectory: true)
            .appendingPathComponent("\(preferencesDomain).plist")
    }

    /// `~/Library/Application Support/Threading`.
    static var supportDirectory: URL {
        applicationSupport
            .appendingPathComponent(
                ProjectIconDefaults.applicationDirectoryName,
                isDirectory: true
            )
    }

    /// Where a reset puts what it took, a **sibling** of the directory being moved rather than
    /// something inside it — a backup that moves with the thing it is a backup of is not one.
    static var resetsDirectory: URL {
        applicationSupport
            .appendingPathComponent(AppDataResetDefaults.resetsDirectoryName, isDirectory: true)
    }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}

// MARK: - App Data Reset

/// Puts Threading back to a first launch, keeping what it took.
///
/// **Moved aside, never deleted**, which is the posture `ProjectStore` already takes with a
/// database it cannot open: the old state goes into a dated folder under `Threading Resets/` and
/// the app starts on nothing. A reset performed by mistake costs a drag back; a store reset
/// because it was corrupt is still there to be read. The cost is disk until the user clears the
/// folder out, which is why the page that offers this also reveals it.
enum AppDataReset {

    /// How much a reset takes.
    enum Scope {
        /// The preferences domain only: themes, profiles, behavioural settings, account
        /// customisation. Projects, sessions and conversations are untouched.
        case settings
        /// The above, plus the Application Support directory — the store, layouts, icons,
        /// caches. A true first launch.
        case everything
    }

    /// What a reset did, so the caller can say so and open the result.
    struct Outcome {
        /// The dated folder holding what was taken.
        let backup: URL
        /// Whether a preferences snapshot was written into it.
        let tookPreferences: Bool
        /// Whether the support directory was moved into it.
        let tookSupportDirectory: Bool
    }

    /// Performs the reset and returns where the old state went.
    ///
    /// The date is passed in rather than read, so a test names the folder it expects instead of
    /// racing the clock.
    @discardableResult
    static func perform(
        _ scope: Scope,
        at date: Date,
        defaults: UserDefaults = .standard,
        locations: Locations = .live,
        fileManager: FileManager = .default
    ) throws -> Outcome {
        let backup = locations.resets
            .appendingPathComponent(Self.stamp(date), isDirectory: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)

        let tookPreferences = try snapshotPreferences(
            of: locations.preferencesDomain,
            into: backup,
            defaults: defaults
        )

        var tookSupportDirectory = false
        if scope == .everything {
            tookSupportDirectory = try moveAsideSupportDirectory(
                locations.support,
                into: backup,
                fileManager: fileManager
            )
        }

        return Outcome(
            backup: backup,
            tookPreferences: tookPreferences,
            tookSupportDirectory: tookSupportDirectory
        )
    }

    // MARK: - Private Methods

    /// Writes the domain out, then removes it.
    ///
    /// Through `UserDefaults` rather than by moving the plist: `cfprefsd` owns that file and
    /// holds the domain in memory, so a file moved out from under it is simply written back —
    /// the reset would appear to work and be undone on the next flush.
    private static func snapshotPreferences(
        of domain: String,
        into backup: URL,
        defaults: UserDefaults
    ) throws -> Bool {
        guard let contents = defaults.persistentDomain(forName: domain), !contents.isEmpty else {
            return false
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: contents,
            format: .xml,
            options: 0
        )
        try data.write(
            to: backup.appendingPathComponent(AppDataResetDefaults.preferencesSnapshotName),
            options: .atomic
        )

        defaults.removePersistentDomain(forName: domain)
        return true
    }

    /// Renames the directory into the backup. Files inside it that are still open — the SQLite
    /// store, the instance lock — follow the move, which is why the caller must not let the app
    /// shut down normally afterwards. See `AppRelaunch.discardingState`.
    private static func moveAsideSupportDirectory(
        _ directory: URL,
        into backup: URL,
        fileManager: FileManager
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: directory.path) else { return false }

        try fileManager.moveItem(
            at: directory,
            to: backup.appendingPathComponent(
                directory.lastPathComponent,
                isDirectory: true
            )
        )
        return true
    }

    /// Sortable, readable, and legal in a file name — a colon is a path separator to the Finder
    /// even though the file system takes it.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = AppDataResetDefaults.stampFormat
        return formatter.string(from: date)
    }

    // MARK: - Locations

    /// The three paths a reset touches, injected so a test resets a temporary directory rather
    /// than the developer's own Application Support.
    struct Locations {
        let preferencesDomain: String
        let support: URL
        let resets: URL

        static var live: Locations {
            Locations(
                preferencesDomain: AppDataLocations.preferencesDomain,
                support: AppDataLocations.supportDirectory,
                resets: AppDataLocations.resetsDirectory
            )
        }
    }
}

// MARK: - Defaults

enum AppDataResetDefaults {
    static let resetsDirectoryName = "Threading Resets"
    static let preferencesSnapshotName = "preferences.plist"
    static let preferencesDirectory = "Library/Preferences"
    static let stampFormat = "yyyy-MM-dd HH-mm-ss"

    /// Only reachable if the bundle has no identifier at all, which no built app has.
    static let fallbackDomain = "codes.threading"
}
