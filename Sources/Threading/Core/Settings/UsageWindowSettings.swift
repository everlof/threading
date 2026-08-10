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

    private let persistence: RecoverableDefaultsStore<UsageWindowSchedule>

    /// Decoded once and written through, so the page can read it on every layout pass without
    /// paying for JSON each time.
    private var cached: UsageWindowSchedule

    // MARK: - Initialization

    init(defaults: UserDefaults = PreferenceStore.shared) {
        let persistence = RecoverableDefaultsStore<UsageWindowSchedule>(
            defaults: defaults,
            key: Keys.schedule,
            criticality: .preference,
            sizePolicy: .compactMetadata
        )
        self.persistence = persistence
        self.cached = persistence.load(
            defaultValue: .default,
            validate: Self.validate
        ).value
    }

    // MARK: - Public Methods

    var schedule: UsageWindowSchedule {
        get { cached }
        set {
            guard newValue != cached else { return }
            do {
                try Self.validate(newValue)
            } catch {
                ThreadingLogger.session.error("Refusing invalid usage-window schedule")
                return
            }
            guard persistence.save(newValue) else { return }
            cached = newValue
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

    private enum ValidationError: Error {
        case invalidSchedule
    }

    private static func validate(_ schedule: UsageWindowSchedule) throws {
        let maximumAccounts = 64
        let maximumAccountIDBytes = 1_024
        guard (0 ..< 24 * 60).contains(schedule.startMinute),
              (0 ... 24 * 60).contains(schedule.endMinute),
              schedule.weekdays.isSubset(of: Set(1 ... 7)),
              schedule.accountIDs.count <= maximumAccounts,
              schedule.accountIDs.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= maximumAccountIDBytes
              }) else {
            throw ValidationError.invalidSchedule
        }
    }

    private enum Keys {
        static let schedule = "usageWindowSchedule"
    }
}
