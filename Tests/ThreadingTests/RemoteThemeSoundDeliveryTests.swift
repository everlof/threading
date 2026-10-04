import ThreadingRemoteKit
@testable import Threading
import XCTest

/// The three rules that decide whether a push names the phone's installed theme sound: who may
/// be told it, what an older broker is sent, and what reaches `aps.sound` directly.
final class RemoteThemeSoundDeliveryTests: XCTestCase {
    private let soundName = "threading-theme-" + String(repeating: "a", count: 64) + ".caf"

    @MainActor
    func testOnlyAConsentingOwnerDeviceThatWantsTheSoundIsSentTheThemeSound() {
        let owner = RemoteAuthorization(shareID: "owner", capability: .interact, scope: .allSessions)
        let guest = RemoteAuthorization(shareID: "guest", capability: .interact, scope: .allSessions,
                                        principal: .guest)
        let session = RemoteAuthorization(shareID: "chat", capability: .interact, scope: .session(SessionID()))
        func permits(_ authorization: RemoteAuthorization, previews: Bool = true,
                     sounds: Set<RemoteNotificationKind> = [.permissionRequest]) -> Bool {
            RemoteThemeSoundDelivery.permits(.permissionRequest, includesResponsePreviews: previews,
                                             authorization: authorization, soundEnabledKinds: sounds)
        }
        XCTAssertTrue(permits(owner))
        XCTAssertFalse(permits(guest), "a guest cannot read host appearance assets")
        XCTAssertFalse(permits(session), "a one-session share is not an owner device")
        XCTAssertFalse(permits(owner, previews: false), "theme selection cannot grant preview consent")
        XCTAssertFalse(permits(owner, sounds: []), "a kind the person silenced stays silent")
    }

    func testAnOlderBrokerIsSentNoSoundName() {
        let current = RemoteNotificationBrokerCompatibility.themeSoundVersion
        XCTAssertEqual(RemoteNotificationBrokerCompatibility.themeSoundName(soundName, forBrokerVersion: current), soundName)
        XCTAssertNil(RemoteNotificationBrokerCompatibility.themeSoundName(soundName, forBrokerVersion: current - 1),
                     "a v3 broker refuses unknown envelope keys")
        XCTAssertNil(RemoteNotificationBrokerCompatibility.themeSoundName("../Sounds/evil.caf",
                                                                          forBrokerVersion: current))
        XCTAssertNil(RemoteNotificationBrokerCompatibility.themeSoundName(nil, forBrokerVersion: current))
    }

    func testTheDirectEnvelopeNamesTheSoundOnlyWhenItPlaysOne() {
        XCTAssertEqual(RemoteThemeSoundDelivery.apsSound(playsSound: true, themeSoundName: soundName), soundName)
        XCTAssertEqual(RemoteThemeSoundDelivery.apsSound(playsSound: true, themeSoundName: nil), "default")
        XCTAssertEqual(RemoteThemeSoundDelivery.apsSound(playsSound: true, themeSoundName: "beep.caf"), "default",
                       "an unrecognised name falls back to the default rather than to silence")
        XCTAssertNil(RemoteThemeSoundDelivery.apsSound(playsSound: false, themeSoundName: soundName), "silence wins")
    }
}
