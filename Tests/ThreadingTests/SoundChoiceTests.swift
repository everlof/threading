import UserNotifications
import XCTest
@testable import Threading

/// The one type both of Threading's sounds are set through, and the two stored forms it had to
/// keep reading.
///
/// The alert sound and the bell were two enums with two stored dialects: the alert wrote a bare
/// file name or nothing at all, the bell wrote a bare file name or one of two reserved words.
/// Collapsing them means every install alive is holding one of those dialects, so the decode is
/// the load-bearing half — a person who chose Submarine two releases ago must still hear
/// Submarine, and a person who unchecked "Play a sound" must still hear nothing.
///
/// Playback is deliberately absent. `TerminalBell.play` ends in `NSSound.beep()` for two of its
/// three cases, so a test that exercised it would make noise on every run and assert nothing;
/// what it can hold is the input that branch turns on — a name that resolves nowhere — which is
/// asserted here through the library.
@MainActor
final class SoundChoiceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundChoiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Stored Form

    func testEveryCaseRoundTripsThroughItsStoredValue() {
        for choice: SoundChoice in [.silent, .system, .named("Tink.aiff")] {
            XCTAssertEqual(SoundChoice(storedValue: choice.storedValue), choice)
        }
    }

    /// The prefix is the point of the new form: it puts every file name in a namespace of its
    /// own, so a sound that happens to be called "silent" is a sound rather than an off switch.
    /// The old bare-name form could not say that, which is why nothing writes it any more.
    func testAPrefixedNameCannotBeMistakenForAReservedWord() {
        XCTAssertEqual(SoundChoice.named("silent").storedValue, "file:silent")
        XCTAssertEqual(SoundChoice(storedValue: "file:silent"), .named("silent"))
        XCTAssertEqual(SoundChoice(storedValue: "file:system"), .named("system"))

        XCTAssertEqual(SoundChoice.silent.storedValue, SoundChoiceDefaults.silentToken)
        XCTAssertEqual(SoundChoice.system.storedValue, SoundChoiceDefaults.systemToken)
    }

    /// Absence is not a value here: the two settings that read this do not share a default —
    /// an absent bell is the system alert, an absent alert is the macOS tone — so the decode
    /// declines rather than guessing, and each property supplies its own.
    func testAnAbsentOrEmptyValueDecodesToNothing() {
        XCTAssertNil(SoundChoice(storedValue: nil))
        XCTAssertNil(SoundChoice(storedValue: ""))
        // A prefix with nothing after it is a malformed record, not a sound with no name.
        XCTAssertNil(SoundChoice(storedValue: "file:"))
    }

    // MARK: - Legacy Forms

    /// The bell's dialect: two reserved words and a bare file name.
    func testTheBellsOldStoredFormStillDecodes() {
        XCTAssertEqual(SoundChoice(storedValue: "silent"), .silent)
        XCTAssertEqual(SoundChoice(storedValue: "system"), .system)
        XCTAssertEqual(SoundChoice(storedValue: "Submarine.aiff"), .named("Submarine.aiff"))
    }

    /// The alert's dialect: a bare file name, and nothing at all for the system tone — which
    /// the property turns back into `.system`, since that is the default it has always had.
    func testTheAlertsOldStoredFormStillDecodes() throws {
        XCTAssertEqual(SoundChoice(storedValue: "Glass.aiff"), .named("Glass.aiff"))

        let suite = "SoundChoiceLegacyAlert.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("Glass.aiff", forKey: "attentionAlertSound")
        XCTAssertEqual(AppSettings(defaults: defaults).attentionAlertSound, .named("Glass.aiff"))
    }

    func testTheBellsLegacyPreferenceSurvivesTheCollapse() throws {
        let suite = "SoundChoiceLegacyBell.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("Submarine.aiff", forKey: "terminalBellSound")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.terminalBellSound, .named("Submarine.aiff"))

        // Read back through the new writer, the record is prefixed and means the same thing.
        settings.terminalBellSound = .named("Submarine.aiff")
        XCTAssertEqual(defaults.string(forKey: "terminalBellSound"), "file:Submarine.aiff")
        XCTAssertEqual(AppSettings(defaults: defaults).terminalBellSound, .named("Submarine.aiff"))
    }

    // MARK: - Resolution

    /// A name is not a file. Measured on macOS 26.5: a `UNNotificationSound` name that resolves
    /// nowhere posts the banner in silence with no fallback of the system's own, so the choice
    /// checks the folders itself and degrades to the tone it used to be heard beside.
    func testANameThatResolvesNowhereFallsBackToTheSystemTone() {
        XCTAssertEqual(SoundChoice.named("NoSuchSound.aiff").notificationSound(in: [root]), .default)
    }

    func testAResolvableNameIsHandedOverAsItsOwnSound() throws {
        try write("Chime.aiff", to: root)
        let sound = SoundChoice.named("Chime.aiff").notificationSound(in: [root])
        XCTAssertNotNil(sound)
        XCTAssertNotEqual(sound, .default)
    }

    func testSilenceIsNoSoundAtAllAndTheSystemChoiceIsTheDefaultTone() {
        XCTAssertNil(SoundChoice.silent.notificationSound(in: [root]))
        XCTAssertEqual(SoundChoice.system.notificationSound(in: [root]), .default)
    }

    /// The bell's fallback shares this input: `TerminalBell.play` rings the system alert when
    /// the name answers nowhere, which is the branch this nil selects.
    func testAGoneFileIsWhatBothFallbacksTurnOn() {
        XCTAssertNil(NotificationSoundLibrary.resolve(fileName: "NoSuchSound.aiff", in: [root]))
    }

    // MARK: - Settings

    func testTheTwoSettingsKeepTheirOwnDefaults() throws {
        let suite = "SoundChoiceDefaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.terminalBellSound, .system)
        XCTAssertEqual(settings.attentionAlertSound, .system)

        settings.attentionAlertSound = .silent
        settings.terminalBellSound = .named("Purr.aiff")

        let reread = AppSettings(defaults: defaults)
        XCTAssertEqual(reread.attentionAlertSound, .silent)
        XCTAssertEqual(reread.terminalBellSound, .named("Purr.aiff"))
    }

    // MARK: - Retiring the Checkbox

    /// The unchecked box meant "alerts never sound", which is a value the picker now offers.
    func testAnUncheckedSoundBoxBecomesSilence() throws {
        let suite = "SoundChoiceMigrationOff.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(false, forKey: "playsAttentionAlertSound")

        XCTAssertEqual(AppSettings(defaults: defaults).attentionAlertSound, .silent)
        XCTAssertEqual(defaults.string(forKey: "attentionAlertSound"), "silent")
        // The old key is the migration's own marker: gone means carried over.
        XCTAssertNil(defaults.object(forKey: "playsAttentionAlertSound"))
    }

    /// A checked box said what the picker already says, so it carries nothing over — including
    /// the sound the user had chosen underneath it, which stays exactly as it was.
    func testACheckedSoundBoxCarriesNothingOver() throws {
        let suite = "SoundChoiceMigrationOn.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "playsAttentionAlertSound")
        defaults.set("Glass.aiff", forKey: "attentionAlertSound")

        XCTAssertEqual(AppSettings(defaults: defaults).attentionAlertSound, .named("Glass.aiff"))
        XCTAssertNil(defaults.object(forKey: "playsAttentionAlertSound"))
    }

    func testAnInstallThatNeverTouchedTheBoxIsLeftAlone() throws {
        let suite = "SoundChoiceMigrationAbsent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppSettings(defaults: defaults).attentionAlertSound, .system)
        XCTAssertNil(defaults.object(forKey: "attentionAlertSound"))
        XCTAssertNil(defaults.object(forKey: "playsAttentionAlertSound"))
    }

    /// Every launch after the first runs it again, so a choice made *after* the migration must
    /// survive one — which is what removing the old key buys.
    func testTheMigrationDoesNotRunTwice() throws {
        let suite = "SoundChoiceMigrationTwice.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(false, forKey: "playsAttentionAlertSound")
        let migrated = AppSettings(defaults: defaults)
        XCTAssertEqual(migrated.attentionAlertSound, .silent)

        migrated.attentionAlertSound = .named("Ping.aiff")
        XCTAssertEqual(AppSettings(defaults: defaults).attentionAlertSound, .named("Ping.aiff"))
    }

    // MARK: - Helpers

    @discardableResult
    private func write(_ name: String, to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }
}
