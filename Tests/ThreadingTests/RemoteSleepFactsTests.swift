import XCTest
@testable import Threading

/// When this Mac sleeps, read from `pmset`, and what the Remote Access page says about it.
///
/// A sleeping Mac answers no way in, so a page that promised "from anywhere" without saying when
/// the Mac sleeps left a person to find out from a phone that could not connect. These pin the
/// reading — including the display-sleep floor that makes `sleep 1` mean five minutes — and every
/// sentence the page can print.
final class RemoteSleepFactsTests: XCTestCase {
    private static let readAt = Date(timeIntervalSince1970: 1_790_000_000)

    /// `pmset -g custom` verbatim from the MacBook this was reported on: never on the adapter,
    /// `sleep 1` beside `displaysleep 5` on battery.
    private static let laptopOutput = """
    Battery Power:
     Sleep On Power Button 1
     powermode            0
     standby              1
     ttyskeepawake        1
     hibernatemode        3
     powernap             1
     hibernatefile        /var/vm/sleepimage
     displaysleep         5
     womp                 0
     networkoversleep     0
     sleep                1
     lessbright           0
     tcpkeepalive         1
     disksleep            10
    AC Power:
     Sleep On Power Button 1
     powermode            0
     standby              1
     ttyskeepawake        1
     hibernatemode        3
     powernap             1
     hibernatefile        /var/vm/sleepimage
     displaysleep         30
     womp                 1
     networkoversleep     0
     sleep                0
     tcpkeepalive         1
     disksleep            0

    """

    /// A desktop prints one block.
    private static func desktopOutput(sleep: Int, displaySleep: Int) -> String {
        """
        AC Power:
         Sleep On Power Button 1
         displaysleep         \(displaySleep)
         womp                 1
         sleep                \(sleep)
         disksleep            10

        """
    }

    // MARK: - Reading

    func testALaptopSleepsNoSoonerThanItsDisplay() {
        let facts = RemoteSleepFacts.parse(pmsetCustomOutput: Self.laptopOutput, readAt: Self.readAt)

        XCTAssertEqual(facts.hasBattery, true)
        XCTAssertEqual(facts.adapterIdleMinutes, 0)
        XCTAssertEqual(facts.batteryIdleMinutes, 5, "`sleep 1` waits for `displaysleep 5`")
        XCTAssertTrue(facts.isRead)
    }

    func testADesktopHasNoBatteryAndADisplayThatNeverSleepsKeepsItAwake() {
        let sleeps = RemoteSleepFacts.parse(
            pmsetCustomOutput: Self.desktopOutput(sleep: 10, displaySleep: 5),
            readAt: Self.readAt
        )
        XCTAssertEqual(sleeps.hasBattery, false)
        XCTAssertEqual(sleeps.adapterIdleMinutes, 10)
        XCTAssertNil(sleeps.batteryIdleMinutes)
        XCTAssertTrue(sleeps.isRead)

        let litForever = RemoteSleepFacts.parse(
            pmsetCustomOutput: Self.desktopOutput(sleep: 10, displaySleep: 0),
            readAt: Self.readAt
        )
        XCTAssertEqual(litForever.adapterIdleMinutes, 0)
    }

    func testOutputWithoutAnAdapterBlockIsUnreadableRatherThanNever() {
        for output in [nil, "", "Currently in use:\n sleep 0\n"] {
            let facts = RemoteSleepFacts.parse(pmsetCustomOutput: output, readAt: Self.readAt)
            XCTAssertFalse(facts.isRead, String(describing: output))
            XCTAssertEqual(facts.readAt, Self.readAt)
        }
    }

    // MARK: - What the page says

    func testALaptopThatSleepsOnlyOnBatterySaysSoAndThatPowerKeepsItAwake() {
        let status = RemoteDoorStatus.sleep(
            RemoteSleepFacts.parse(pmsetCustomOutput: Self.laptopOutput, readAt: Self.readAt)
        )
        XCTAssertEqual(
            status.text,
            "On battery this Mac goes to sleep after 5 minutes idle, and a phone away from home "
                + "cannot reach it while it sleeps."
        )
        XCTAssertEqual(
            status.hint,
            "Plugged in, it stays awake. Choose “Always” above to keep it awake on battery too."
        )
        XCTAssertEqual(status.tone, .off)
    }

    func testAMacThatSleepsPluggedInIsTheOneToFixAndSaysWhere() {
        let laptop = RemoteDoorStatus.sleep(RemoteSleepFacts(
            adapterIdleMinutes: 10,
            batteryIdleMinutes: 5,
            hasBattery: true,
            readAt: Self.readAt
        ))
        XCTAssertTrue(laptop.text.contains("after 10 minutes idle, even plugged in"), laptop.text)
        XCTAssertEqual(
            laptop.hint,
            "Choose “Plugged in” above to keep it awake while Remote Access is on."
        )
        XCTAssertEqual(laptop.tone, .attention)

        let desktop = RemoteDoorStatus.sleep(
            RemoteSleepFacts.parse(
                pmsetCustomOutput: Self.desktopOutput(sleep: 60, displaySleep: 10),
                readAt: Self.readAt
            )
        )
        XCTAssertTrue(desktop.text.contains("after 1 hour idle"), desktop.text)
        XCTAssertFalse(desktop.text.contains("plugged in"), "a desktop has no plug to mention")
        XCTAssertEqual(desktop.hint, laptop.hint, "the remedy is the control on the page")
        XCTAssertEqual(desktop.tone, .attention)
    }

    // MARK: - With a keep-awake choice

    func testPluggedInOnALaptopThatSleepsOnBatterySaysWhatIsStillLeft() {
        let facts = RemoteSleepFacts.parse(pmsetCustomOutput: Self.laptopOutput, readAt: Self.readAt)
        let status = RemoteDoorStatus.sleep(facts, keepAwake: .whilePluggedIn)

        XCTAssertEqual(
            status.text,
            "Plugged in, Threading keeps this Mac awake while Remote Access is on. On battery it "
                + "goes to sleep after 5 minutes idle, and a phone away from home cannot reach it "
                + "then."
        )
        XCTAssertEqual(status.hint, "Choose “Always” above to keep it awake on battery too.")
        XCTAssertEqual(status.tone, .off)
    }

    func testAlwaysOnALaptopNamesTheBatteryCostAndTheLid() {
        let facts = RemoteSleepFacts.parse(pmsetCustomOutput: Self.laptopOutput, readAt: Self.readAt)
        let status = RemoteDoorStatus.sleep(facts, keepAwake: .always)

        XCTAssertEqual(
            status.text,
            "Threading keeps this Mac awake while Remote Access is on, plugged in or on battery."
        )
        XCTAssertTrue(status.hint?.contains("uses charge") == true)
        XCTAssertTrue(status.hint?.contains("Closing the lid") == true)
        XCTAssertEqual(status.tone, .ready)
    }

    /// A Mac with no battery is always plugged in, so both choices are the same promise.
    func testEitherChoiceOnADesktopIsTheSamePromise() {
        let facts = RemoteSleepFacts.parse(
            pmsetCustomOutput: Self.desktopOutput(sleep: 10, displaySleep: 5),
            readAt: Self.readAt
        )
        let pluggedIn = RemoteDoorStatus.sleep(facts, keepAwake: .whilePluggedIn)
        XCTAssertEqual(pluggedIn, RemoteDoorStatus.sleep(facts, keepAwake: .always))
        XCTAssertEqual(pluggedIn.text, "Threading keeps this Mac awake while Remote Access is on.")
        XCTAssertNil(pluggedIn.hint)
        XCTAssertEqual(pluggedIn.tone, .ready)
    }

    /// "Always" is a promise Threading keeps whatever `pmset` said, so it does not wait on it.
    func testAlwaysDoesNotDependOnReadingTheSettings() {
        for facts in [
            RemoteSleepFacts.unknown,
            RemoteSleepFacts.parse(pmsetCustomOutput: nil, readAt: Self.readAt)
        ] {
            let status = RemoteDoorStatus.sleep(facts, keepAwake: .always)
            XCTAssertFalse(status.isBusy)
            XCTAssertEqual(status.text, "Threading keeps this Mac awake while Remote Access is on.")
        }
        let pluggedIn = RemoteDoorStatus.sleep(
            RemoteSleepFacts.parse(pmsetCustomOutput: nil, readAt: Self.readAt),
            keepAwake: .whilePluggedIn
        )
        XCTAssertNotEqual(pluggedIn.tone, .ready, "plugged-in on an unknown Mac promises nothing")
    }

    func testAMacThatNeverSleepsSaysSoAndALaptopStillMentionsItsLid() {
        let desktop = RemoteDoorStatus.sleep(
            RemoteSleepFacts.parse(
                pmsetCustomOutput: Self.desktopOutput(sleep: 0, displaySleep: 10),
                readAt: Self.readAt
            )
        )
        XCTAssertEqual(desktop.text, "This Mac does not go to sleep on its own.")
        XCTAssertNil(desktop.hint)
        XCTAssertEqual(desktop.tone, .ready)

        let laptop = RemoteDoorStatus.sleep(RemoteSleepFacts(
            adapterIdleMinutes: 0,
            batteryIdleMinutes: 0,
            hasBattery: true,
            readAt: Self.readAt
        ))
        XCTAssertEqual(laptop.text, "This Mac does not go to sleep on its own.")
        XCTAssertTrue(laptop.hint?.contains("Closing the lid") == true)
    }

    /// Unread is never "does not sleep": the line keeps the one thing that is always true.
    func testAnUnreadableSettingPromisesNothing() {
        let checking = RemoteDoorStatus.sleep(.unknown)
        XCTAssertTrue(checking.isBusy)

        let unreadable = RemoteDoorStatus.sleep(
            RemoteSleepFacts.parse(pmsetCustomOutput: nil, readAt: Self.readAt)
        )
        XCTAssertFalse(unreadable.isBusy)
        XCTAssertEqual(
            unreadable.text,
            "A phone away from home cannot reach this Mac while it sleeps."
        )
        XCTAssertNotEqual(unreadable.tone, .ready)

        let batteryUnread = RemoteDoorStatus.sleep(RemoteSleepFacts(
            adapterIdleMinutes: 0,
            batteryIdleMinutes: nil,
            hasBattery: true,
            readAt: Self.readAt
        ))
        XCTAssertNotEqual(batteryUnread.text, "This Mac does not go to sleep on its own.")
    }

    /// Every way in that works away from home says it does so only while the Mac is awake.
    func testEveryWayInFromAwaySaysTheMacMustBeAwake() {
        for wayIn in [RemoteAccessWayIn.throughAVPN, .tailscale, .threadingDirect] {
            XCTAssertTrue(
                wayIn.disclosure.awayFromHome.hasSuffix("this Mac is awake"),
                "\(wayIn): \(wayIn.disclosure.awayFromHome)"
            )
        }
        for wayIn in [RemoteAccessWayIn.tailscale, .threadingDirect] {
            XCTAssertTrue(wayIn.promise.contains("while it is awake"), "\(wayIn): \(wayIn.promise)")
        }
    }
}
