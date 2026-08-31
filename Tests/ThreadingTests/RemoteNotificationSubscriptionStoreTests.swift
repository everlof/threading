import XCTest
import ThreadingRemoteKit
@testable import Threading

@MainActor
final class RemoteNotificationSubscriptionStoreTests: XCTestCase {
    func testRegistrationSurvivesServiceRestartWhenCapabilityIsStillCurrent() throws {
        let store = ControllableNotificationSubscriptionStore()
        let authorization = ownerAuthorization()
        let first = RemoteNotificationService(subscriptionStore: store)

        XCTAssertEqual(
            first.register(registration(), deviceID: "phone-1", authorization: authorization),
            .registered(RemoteNotificationRegistrationResponseDTO(delivery: .live))
        )
        XCTAssertEqual(first.activeSubscriptionCount, 1)
        XCTAssertEqual(store.subscriptions.count, 1)

        first.reset()
        XCTAssertEqual(first.activeSubscriptionCount, 0)

        let restarted = RemoteNotificationService(subscriptionStore: store)
        XCTAssertEqual(restarted.activeSubscriptionCount, 0)
        XCTAssertEqual(restarted.activate(authorizations: [authorization]), 1)
        XCTAssertEqual(restarted.activeSubscriptionCount, 1)
    }

    func testRestoreRequiresTheSameCurrentDeviceBoundCapability() {
        let store = ControllableNotificationSubscriptionStore(
            subscriptions: [subscriptionRecord()]
        )
        let service = RemoteNotificationService(subscriptionStore: store)
        let expired = ownerAuthorization(expiresAt: Date(timeIntervalSinceNow: -1))
        let otherDevice = RemoteAuthorization(
            shareID: "owner-1",
            capability: .interact,
            scope: .allSessions,
            boundDeviceID: "phone-2"
        )

        XCTAssertEqual(service.activate(authorizations: [expired, otherDevice]), 0)
        XCTAssertEqual(service.activeSubscriptionCount, 0)
        XCTAssertTrue(store.subscriptions.isEmpty, "orphaned metadata should be pruned")
    }

    func testRegistrationRequiresADeviceBoundCapability() {
        let store = ControllableNotificationSubscriptionStore()
        let service = RemoteNotificationService(subscriptionStore: store)
        let unbound = RemoteAuthorization(
            shareID: "owner-1",
            capability: .interact,
            scope: .allSessions
        )

        XCTAssertEqual(
            service.register(registration(), deviceID: "phone-1", authorization: unbound),
            .invalid
        )
        XCTAssertTrue(store.subscriptions.isEmpty)
        XCTAssertEqual(service.activeSubscriptionCount, 0)
    }

    func testRevocationDropsDeliveryEvenWhenCleanupFails() {
        let store = ControllableNotificationSubscriptionStore()
        let authorization = ownerAuthorization()
        let service = RemoteNotificationService(subscriptionStore: store)
        XCTAssertEqual(
            service.register(registration(), deviceID: "phone-1", authorization: authorization),
            .registered(RemoteNotificationRegistrationResponseDTO(delivery: .live))
        )

        store.failNextSave = true
        service.revoke(shareID: authorization.shareID)

        XCTAssertEqual(service.activeSubscriptionCount, 0)
        XCTAssertEqual(store.subscriptions.count, 1, "failed cleanup leaves only inert metadata")

        let restarted = RemoteNotificationService(subscriptionStore: store)
        XCTAssertEqual(restarted.activate(authorizations: []), 0)
        XCTAssertTrue(store.subscriptions.isEmpty)
    }

    func testRegistrationRotatesTokenWithoutAddingASecondDeviceRecord() {
        let store = ControllableNotificationSubscriptionStore()
        let service = RemoteNotificationService(subscriptionStore: store)
        let authorization = ownerAuthorization()
        let oldToken = String(repeating: "ab", count: 32)
        let newToken = String(repeating: "cd", count: 32)

        XCTAssertEqual(
            service.register(
                registration(token: oldToken),
                deviceID: "phone-1",
                authorization: authorization
            ),
            .registered(RemoteNotificationRegistrationResponseDTO(delivery: .live))
        )
        XCTAssertEqual(
            service.register(
                registration(token: newToken),
                deviceID: "phone-1",
                authorization: authorization
            ),
            .registered(RemoteNotificationRegistrationResponseDTO(delivery: .live))
        )

        XCTAssertEqual(store.subscriptions.count, 1)
        XCTAssertEqual(store.subscriptions.first?.deviceToken, newToken)
    }

    func testHostedRegistrationPersistsOpaqueRecipientAndAdvertisesPush() {
        let store = ControllableNotificationSubscriptionStore()
        let service = RemoteNotificationService(subscriptionStore: store)
        service.configureHostedPushSender(isAvailable: { true }) { _, _, _ in
            RemoteAPNSDeliveryResult(statusCode: 200, reason: "", apnsID: nil)
        }
        let registrationID = "th_push_" + String(repeating: "a", count: 43)

        XCTAssertEqual(
            service.register(
                registration(hostedRegistrationID: registrationID),
                deviceID: "phone-1",
                authorization: ownerAuthorization()
            ),
            .registered(RemoteNotificationRegistrationResponseDTO(delivery: .push))
        )
        XCTAssertEqual(store.subscriptions.first?.hostedRegistrationID, registrationID)

        let restarted = RemoteNotificationService(subscriptionStore: store)
        restarted.configureHostedPushSender(isAvailable: { true }) { _, _, _ in
            RemoteAPNSDeliveryResult(statusCode: 200, reason: "", apnsID: nil)
        }
        XCTAssertEqual(restarted.activate(authorizations: [ownerAuthorization()]), 1)
    }

    func testHostedBrokerDoesNotClaimPushWithoutValidOpaqueRecipient() {
        let store = ControllableNotificationSubscriptionStore()
        let service = RemoteNotificationService(subscriptionStore: store)
        service.configureHostedPushSender(isAvailable: { true }) { _, _, _ in
            RemoteAPNSDeliveryResult(statusCode: 200, reason: "", apnsID: nil)
        }

        XCTAssertEqual(
            service.register(
                registration(),
                deviceID: "phone-1",
                authorization: ownerAuthorization()
            ),
            .registered(RemoteNotificationRegistrationResponseDTO(delivery: .live))
        )
        XCTAssertEqual(
            service.register(
                registration(hostedRegistrationID: "raw-apns-token"),
                deviceID: "phone-1",
                authorization: ownerAuthorization()
            ),
            .invalid
        )
    }

    func testFailedSaveNeverActivatesCandidateAndCanBeRetried() {
        let store = ControllableNotificationSubscriptionStore()
        let service = RemoteNotificationService(subscriptionStore: store)
        let authorization = ownerAuthorization()
        store.failNextSave = true

        XCTAssertEqual(
            service.register(registration(), deviceID: "phone-1", authorization: authorization),
            .persistenceUnavailable
        )
        XCTAssertEqual(service.activeSubscriptionCount, 0)
        XCTAssertTrue(store.subscriptions.isEmpty)

        XCTAssertEqual(
            service.register(registration(), deviceID: "phone-1", authorization: authorization),
            .registered(RemoteNotificationRegistrationResponseDTO(delivery: .live))
        )
        XCTAssertEqual(service.activeSubscriptionCount, 1)
    }

    func testUnreadableStoreBlocksRegistrationWithoutOverwritingIt() {
        let store = ControllableNotificationSubscriptionStore()
        store.loadError = TestStoreError.refused
        let service = RemoteNotificationService(subscriptionStore: store)

        XCTAssertNotNil(service.persistenceError)
        XCTAssertEqual(
            service.register(
                registration(),
                deviceID: "phone-1",
                authorization: ownerAuthorization()
            ),
            .persistenceUnavailable
        )
        XCTAssertEqual(store.saveCallCount, 0)
        XCTAssertEqual(service.activeSubscriptionCount, 0)
    }

    func testResetEverythingDeletesUnreadableStore() throws {
        let store = ControllableNotificationSubscriptionStore(
            subscriptions: [subscriptionRecord()]
        )
        store.loadError = TestStoreError.refused
        let service = RemoteNotificationService(subscriptionStore: store)

        try service.deleteAllForAppReset()

        XCTAssertTrue(store.subscriptions.isEmpty)
        XCTAssertNil(service.persistenceError)
        XCTAssertEqual(
            service.register(
                registration(),
                deviceID: "phone-1",
                authorization: ownerAuthorization()
            ),
            .registered(RemoteNotificationRegistrationResponseDTO(delivery: .live))
        )
    }

    func testValidationRejectsDuplicateKeysInvalidTokensAndSoundOutsideOptIn() {
        let record = subscriptionRecord()
        XCTAssertTrue(RemoteNotificationSubscriptionDefaults.isValid([record]))
        XCTAssertFalse(RemoteNotificationSubscriptionDefaults.isValid([record, record]))
        XCTAssertFalse(RemoteNotificationSubscriptionDefaults.isValid([
            RemoteNotificationSubscriptionRecord(
                shareID: record.shareID,
                deviceID: record.deviceID,
                deviceToken: "not-a-token",
                environment: record.environment,
                enabledKinds: record.enabledKinds,
                soundEnabledKinds: record.soundEnabledKinds
            ),
        ]))
        XCTAssertFalse(RemoteNotificationSubscriptionDefaults.isValid([
            RemoteNotificationSubscriptionRecord(
                shareID: record.shareID,
                deviceID: record.deviceID,
                deviceToken: record.deviceToken,
                environment: record.environment,
                enabledKinds: [.agentMessage],
                soundEnabledKinds: [.permissionRequest]
            ),
        ]))
    }

    func testValidationEnforcesTheAuthorizationStoreCardinalityBound() {
        let maximum = (0..<RemoteNotificationSubscriptionDefaults.maximumSubscriptions).map {
            RemoteNotificationSubscriptionRecord(
                shareID: "share-\($0)",
                deviceID: "phone-\($0)",
                deviceToken: String(repeating: "ab", count: 32),
                environment: .sandbox,
                enabledKinds: [.agentMessage],
                soundEnabledKinds: []
            )
        }

        XCTAssertTrue(RemoteNotificationSubscriptionDefaults.isValid(maximum))
        XCTAssertFalse(RemoteNotificationSubscriptionDefaults.isValid(maximum + [
            RemoteNotificationSubscriptionRecord(
                shareID: "overflow",
                deviceID: "overflow-phone",
                deviceToken: String(repeating: "cd", count: 32),
                environment: .sandbox,
                enabledKinds: [.agentMessage],
                soundEnabledKinds: []
            ),
        ]))
    }

    private func ownerAuthorization(
        expiresAt: Date? = nil
    ) -> RemoteAuthorization {
        RemoteAuthorization(
            shareID: "owner-1",
            capability: .interact,
            scope: .allSessions,
            expiresAt: expiresAt,
            boundDeviceID: "phone-1"
        )
    }

    private func registration(
        token: String = String(repeating: "ab", count: 32),
        hostedRegistrationID: String? = nil
    ) -> RemoteNotificationRegistrationDTO {
        RemoteNotificationRegistrationDTO(
            deviceToken: token,
            hostedRegistrationID: hostedRegistrationID,
            environment: .sandbox,
            enabledKinds: [.permissionRequest, .agentMessage],
            soundEnabledKinds: [.permissionRequest]
        )
    }

    private func subscriptionRecord() -> RemoteNotificationSubscriptionRecord {
        RemoteNotificationSubscriptionRecord(
            shareID: "owner-1",
            deviceID: "phone-1",
            deviceToken: String(repeating: "ab", count: 32),
            environment: .sandbox,
            enabledKinds: [.agentMessage, .permissionRequest],
            soundEnabledKinds: [.permissionRequest]
        )
    }
}

private enum TestStoreError: Error {
    case refused
}

private final class ControllableNotificationSubscriptionStore:
    RemoteNotificationSubscriptionPersisting
{
    var subscriptions: [RemoteNotificationSubscriptionRecord]
    var loadError: Error?
    var failNextSave = false
    private(set) var saveCallCount = 0

    init(subscriptions: [RemoteNotificationSubscriptionRecord] = []) {
        self.subscriptions = subscriptions
    }

    func load() throws -> [RemoteNotificationSubscriptionRecord] {
        if let loadError { throw loadError }
        return subscriptions
    }

    func save(_ subscriptions: [RemoteNotificationSubscriptionRecord]) throws {
        saveCallCount += 1
        if failNextSave {
            failNextSave = false
            throw TestStoreError.refused
        }
        self.subscriptions = subscriptions
    }

    func deleteAll() throws {
        subscriptions = []
        loadError = nil
    }
}
