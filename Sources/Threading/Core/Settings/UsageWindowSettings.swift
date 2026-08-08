import Foundation

// MARK: - Usage Window Settings

/// Where the poke's schedule is kept.
///
/// Through `PreferenceStore` rather than `UserDefaults.standard`, and this is the setting that
/// makes the distinction load-bearing rather than tidy. The test bundle is hosted in the app, so
/// a test that switched this on would switch it on for the developer's own copy — and unlike a
/// theme left on the wrong palette, the consequence would be a background process spending their
/// weekly limit every morning until someone noticed. The redirect makes that impossible to write
/// by accident; `UsageWindowPoker` refuses to run under a test bundle as well, because one guard
/// for that is not enough.
@MainActor
final class UsageWindowSettings {

    // MARK: - Singleton

    static let shared = UsageWindowSettings()

    // MARK: - Properties

    private let defaults: UserDefaults

    /// Decoded once and written through, so the page can read it on every layout pass without
    /// paying for JSON each time.
    private var cached: UsageWindowSchedule

    // MARK: - Initialization

    init(defaults: UserDefaults = PreferenceStore.shared) {
        self.defaults = defaults
        self.cached = Self.load(from: defaults)
    }

    // MARK: - Public Methods

    var schedule: UsageWindowSchedule {
        get { cached }
        set {
            guard newValue != cached else { return }
            cached = newValue
            store(newValue)
            NotificationCenter.default.post(UsageWindowScheduleDidChange())
        }
    }

    /// Whether this account is one the poke may open a window for.
    func isEnabled(_ accountID: AccountID) -> Bool {
        cached.accountIDs.contains(accountID.rawValue)
    }

    func setEnabled(_ isEnabled: Bool, for accountID: AccountID) {
        var updated = cached
        if isEnabled {
            updated.accountIDs.insert(accountID.rawValue)
        } else {
            updated.accountIDs.remove(accountID.rawValue)
        }
        schedule = updated
    }

    // MARK: - Private Methods

    private static func load(from defaults: UserDefaults) -> UsageWindowSchedule {
        guard let data = defaults.data(forKey: Keys.schedule),
              let decoded = try? JSONDecoder().decode(UsageWindowSchedule.self, from: data)
        else { return .default }
        return decoded
    }

    private func store(_ schedule: UsageWindowSchedule) {
        guard let data = try? JSONEncoder().encode(schedule) else { return }
        defaults.set(data, forKey: Keys.schedule)
    }

    private enum Keys {
        static let schedule = "usageWindowSchedule"
    }
}
