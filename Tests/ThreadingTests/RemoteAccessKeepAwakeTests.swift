import XCTest
@testable import Threading

/// Keeping this Mac awake for Remote Access: which choice holds on which power source, and that
/// the assertion follows Remote Access, the setting and the power source in both directions.
///
/// A phone away from home reaches this Mac only while it is awake, and the person chooses how
/// much power that is worth. The failure that matters in each direction is silent: an assertion
/// held after Remote Access stopped or the laptop was unplugged drains a battery nobody chose to
/// spend, and one released early leaves a Mac asleep that was promised to be reachable.
@MainActor
final class RemoteAccessKeepAwakeTests: XCTestCase {

    func testEachChoiceHoldsOnlyWhereItSays() {
        XCTAssertFalse(RemoteAccessKeepAwake.off.keepsAwake(isOnExternalPower: true))
        XCTAssertFalse(RemoteAccessKeepAwake.off.keepsAwake(isOnExternalPower: false))

        XCTAssertTrue(RemoteAccessKeepAwake.whilePluggedIn.keepsAwake(isOnExternalPower: true))
        XCTAssertFalse(RemoteAccessKeepAwake.whilePluggedIn.keepsAwake(isOnExternalPower: false))
        XCTAssertFalse(
            RemoteAccessKeepAwake.whilePluggedIn.keepsAwake(isOnExternalPower: nil),
            "a source macOS would not name is not the adapter"
        )

        XCTAssertTrue(RemoteAccessKeepAwake.always.keepsAwake(isOnExternalPower: true))
        XCTAssertTrue(RemoteAccessKeepAwake.always.keepsAwake(isOnExternalPower: false))
        XCTAssertTrue(RemoteAccessKeepAwake.always.keepsAwake(isOnExternalPower: nil))
    }

    func testNothingIsHeldOrWatchedWhileRemoteAccessIsOff() {
        let fixture = Fixture(choice: .always, onExternalPower: true)

        XCTAssertFalse(fixture.inhibitor.isKeepingAwake)
        XCTAssertEqual(fixture.assertion.acquired, 0)
        XCTAssertFalse(fixture.power.isObserving, "an idle Remote Access pays for no observer")
    }

    func testTheAssertionFollowsRemoteAccessOnAndOff() {
        let fixture = Fixture(choice: .always, onExternalPower: false)

        fixture.inhibitor.setRemoteAccessActive(true)
        XCTAssertTrue(fixture.inhibitor.isKeepingAwake)
        XCTAssertTrue(fixture.power.isObserving)

        fixture.inhibitor.setRemoteAccessActive(false)
        XCTAssertFalse(fixture.inhibitor.isKeepingAwake)
        XCTAssertEqual(fixture.assertion.released, 1)
        XCTAssertFalse(fixture.power.isObserving)
    }

    func testPluggedInReleasesOnUnplugAndTakesItBackOnPlugIn() {
        let fixture = Fixture(choice: .whilePluggedIn, onExternalPower: true)
        fixture.inhibitor.setRemoteAccessActive(true)
        XCTAssertTrue(fixture.inhibitor.isKeepingAwake)

        fixture.power.change(toExternalPower: false)
        XCTAssertFalse(fixture.inhibitor.isKeepingAwake, "an unplugged laptop is not kept awake")

        fixture.power.change(toExternalPower: true)
        XCTAssertTrue(fixture.inhibitor.isKeepingAwake)
        XCTAssertEqual(fixture.assertion.acquired, 2)
        XCTAssertEqual(fixture.assertion.released, 1)
    }

    func testChangingTheChoiceTakesEffectWithoutRestartingRemoteAccess() {
        let fixture = Fixture(choice: .off, onExternalPower: false)
        fixture.inhibitor.setRemoteAccessActive(true)
        XCTAssertFalse(fixture.inhibitor.isKeepingAwake)

        fixture.choice = .always
        fixture.center.post(AppSettingsDidChange(changedSettings: nil))
        XCTAssertTrue(fixture.inhibitor.isKeepingAwake)

        fixture.choice = .whilePluggedIn
        fixture.center.post(AppSettingsDidChange(changedSettings: nil))
        XCTAssertFalse(fixture.inhibitor.isKeepingAwake, "on battery, plugged-in holds nothing")
    }

    func testASettingsChangeAfterRemoteAccessStoppedHoldsNothing() {
        let fixture = Fixture(choice: .off, onExternalPower: true)
        fixture.inhibitor.setRemoteAccessActive(true)
        fixture.inhibitor.setRemoteAccessActive(false)

        fixture.choice = .always
        fixture.center.post(AppSettingsDidChange(changedSettings: nil))

        XCTAssertFalse(fixture.inhibitor.isKeepingAwake)
        XCTAssertEqual(fixture.assertion.acquired, 0)
    }

    func testAnUnrecognizedStoredChoiceReadsAsOff() throws {
        let suite = "RemoteAccessKeepAwakeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.remoteAccessKeepAwake, .off)
        settings.remoteAccessKeepAwake = .whilePluggedIn
        XCTAssertEqual(settings.remoteAccessKeepAwake, .whilePluggedIn)
        defaults.set("sometimes", forKey: "remoteAccessKeepAwake")
        XCTAssertEqual(settings.remoteAccessKeepAwake, .off)
    }

    // MARK: - Fixture

    @MainActor
    private final class Fixture {
        let center = NotificationCenter()
        let power: FakePowerSource
        let assertion = RecordingAssertion()
        var choice: RemoteAccessKeepAwake
        private(set) var inhibitor: RemoteAccessKeepAwakeInhibitor!

        init(choice: RemoteAccessKeepAwake, onExternalPower: Bool?) {
            self.choice = choice
            power = FakePowerSource(isOnExternalPower: onExternalPower)
            inhibitor = RemoteAccessKeepAwakeInhibitor(
                center: center,
                choice: { [unowned self] in self.choice },
                powerSource: power,
                assertion: assertion
            )
        }
    }

    @MainActor
    private final class FakePowerSource: PowerSourceObserving {
        private(set) var isOnExternalPower: Bool?
        private var onChange: (@MainActor () -> Void)?

        init(isOnExternalPower: Bool?) {
            self.isOnExternalPower = isOnExternalPower
        }

        var isObserving: Bool { onChange != nil }

        func start(onChange: @escaping @MainActor () -> Void) {
            self.onChange = onChange
        }

        func stop() {
            onChange = nil
        }

        func change(toExternalPower value: Bool) {
            isOnExternalPower = value
            onChange?()
        }
    }

    @MainActor
    private final class RecordingAssertion: IdleSystemSleepAsserting {
        private(set) var acquired = 0
        private(set) var released = 0

        func acquire() -> Bool {
            acquired += 1
            return true
        }

        func release() -> Bool {
            released += 1
            return true
        }
    }
}
