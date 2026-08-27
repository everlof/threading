import Security
import XCTest
@testable import Threading

final class RemoteCredentialKeychainStoreTests: XCTestCase {
    private enum Item {
        static let ownerService = "codes.threading.remote.owner-devices"
        static let ownerAccount = "owner-devices-v1"
        static let guestService = "codes.threading.remote-guest-shares"
        static let guestAccount = "guest-shares-v1"
    }

    func testOwnerDeviceRecordMovesToTheProtectedKeychainOnlyAfterValidation() throws {
        let keychain = RecordingKeychainItemAccess()
        let expected = ownerRecord()
        try RemoteOwnerDeviceKeychainStore(
            dataProtection: false,
            keychain: keychain
        ).save([expected])

        let protected = RemoteOwnerDeviceKeychainStore(
            dataProtection: true,
            keychain: keychain
        )
        XCTAssertEqual(try protected.load(), [expected])
        XCTAssertTrue(keychain.contains(
            service: Item.ownerService,
            account: Item.ownerAccount,
            dataProtection: true
        ))
        XCTAssertFalse(keychain.contains(
            service: Item.ownerService,
            account: Item.ownerAccount,
            dataProtection: false
        ))
    }

    func testGuestShareRecordMovesToTheProtectedKeychainOnlyAfterValidation() throws {
        let keychain = RecordingKeychainItemAccess()
        let expected = guestRecord()
        try RemoteGuestShareKeychainStore(
            dataProtection: false,
            keychain: keychain
        ).save([expected])

        let protected = RemoteGuestShareKeychainStore(
            dataProtection: true,
            keychain: keychain
        )
        XCTAssertEqual(try protected.load(), [expected])
        XCTAssertTrue(keychain.contains(
            service: Item.guestService,
            account: Item.guestAccount,
            dataProtection: true
        ))
        XCTAssertFalse(keychain.contains(
            service: Item.guestService,
            account: Item.guestAccount,
            dataProtection: false
        ))
    }

    func testProtectedEmptySentinelIgnoresALaterShellReachableOwnerItem() throws {
        let keychain = RecordingKeychainItemAccess()
        let protected = RemoteOwnerDeviceKeychainStore(
            dataProtection: true,
            keychain: keychain
        )
        XCTAssertEqual(try protected.load(), [])
        XCTAssertTrue(keychain.contains(
            service: Item.ownerService,
            account: Item.ownerAccount,
            dataProtection: true
        ))

        try RemoteOwnerDeviceKeychainStore(
            dataProtection: false,
            keychain: keychain
        ).save([ownerRecord()])

        XCTAssertEqual(try protected.load(), [])
        XCTAssertFalse(keychain.contains(
            service: Item.ownerService,
            account: Item.ownerAccount,
            dataProtection: false
        ))
    }

    func testCorruptLegacyOwnerItemFailsClosedAndRemainsUntouched() {
        let keychain = RecordingKeychainItemAccess()
        let corrupt = Data("not-an-owner-envelope".utf8)
        keychain.set(
            corrupt,
            service: Item.ownerService,
            account: Item.ownerAccount,
            dataProtection: false
        )

        XCTAssertThrowsError(try RemoteOwnerDeviceKeychainStore(
            dataProtection: true,
            keychain: keychain
        ).load()) { error in
            guard case RemoteOwnerDeviceStoreError.corrupt = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(keychain.value(
            service: Item.ownerService,
            account: Item.ownerAccount,
            dataProtection: false
        ), corrupt)
        XCTAssertFalse(keychain.contains(
            service: Item.ownerService,
            account: Item.ownerAccount,
            dataProtection: true
        ))
    }

    func testFutureLegacyOwnerItemFailsClosedAndRemainsUntouched() {
        let keychain = RecordingKeychainItemAccess()
        let future = Data(#"{"version":999,"devices":[]}"#.utf8)
        keychain.set(
            future,
            service: Item.ownerService,
            account: Item.ownerAccount,
            dataProtection: false
        )

        XCTAssertThrowsError(try RemoteOwnerDeviceKeychainStore(
            dataProtection: true,
            keychain: keychain
        ).load()) { error in
            guard case RemoteOwnerDeviceStoreError.unsupportedVersion(999) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(keychain.value(
            service: Item.ownerService,
            account: Item.ownerAccount,
            dataProtection: false
        ), future)
        XCTAssertFalse(keychain.contains(
            service: Item.ownerService,
            account: Item.ownerAccount,
            dataProtection: true
        ))
    }

    func testCorruptProtectedOwnerItemDoesNotDestroyAValidLegacyRecoveryCopy() throws {
        let keychain = RecordingKeychainItemAccess()
        try RemoteOwnerDeviceKeychainStore(
            dataProtection: false,
            keychain: keychain
        ).save([ownerRecord()])
        let legacyData = try XCTUnwrap(keychain.value(
            service: Item.ownerService,
            account: Item.ownerAccount,
            dataProtection: false
        ))
        keychain.set(
            Data("not-a-protected-envelope".utf8),
            service: Item.ownerService,
            account: Item.ownerAccount,
            dataProtection: true
        )

        XCTAssertThrowsError(try RemoteOwnerDeviceKeychainStore(
            dataProtection: true,
            keychain: keychain
        ).load()) { error in
            guard case RemoteOwnerDeviceStoreError.corrupt = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(keychain.value(
            service: Item.ownerService,
            account: Item.ownerAccount,
            dataProtection: false
        ), legacyData)
    }

    func testFailedProtectedPromotionLeavesTheLegacyOwnerItemIntact() throws {
        let keychain = RecordingKeychainItemAccess()
        let legacy = RemoteOwnerDeviceKeychainStore(
            dataProtection: false,
            keychain: keychain
        )
        try legacy.save([ownerRecord()])
        let legacyData = try XCTUnwrap(keychain.value(
            service: Item.ownerService,
            account: Item.ownerAccount,
            dataProtection: false
        ))
        keychain.failNextAdd(
            service: Item.ownerService,
            account: Item.ownerAccount,
            dataProtection: true,
            status: errSecAuthFailed
        )

        XCTAssertThrowsError(try RemoteOwnerDeviceKeychainStore(
            dataProtection: true,
            keychain: keychain
        ).load()) { error in
            guard case RemoteOwnerDeviceStoreError.keychain(errSecAuthFailed) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(keychain.value(
            service: Item.ownerService,
            account: Item.ownerAccount,
            dataProtection: false
        ), legacyData)
        XCTAssertFalse(keychain.contains(
            service: Item.ownerService,
            account: Item.ownerAccount,
            dataProtection: true
        ))
    }

    func testResetAttemptsBothProtectedAndLegacyGuestItems() throws {
        let keychain = RecordingKeychainItemAccess()
        let legacy = RemoteGuestShareKeychainStore(
            dataProtection: false,
            keychain: keychain
        )
        try legacy.save([guestRecord()])
        let legacyData = try XCTUnwrap(keychain.value(
            service: Item.guestService,
            account: Item.guestAccount,
            dataProtection: false
        ))

        let protected = RemoteGuestShareKeychainStore(
            dataProtection: true,
            keychain: keychain
        )
        try protected.save([guestRecord()])
        keychain.set(
            legacyData,
            service: Item.guestService,
            account: Item.guestAccount,
            dataProtection: false
        )

        try protected.deleteAll()

        XCTAssertFalse(keychain.contains(
            service: Item.guestService,
            account: Item.guestAccount,
            dataProtection: true
        ))
        XCTAssertFalse(keychain.contains(
            service: Item.guestService,
            account: Item.guestAccount,
            dataProtection: false
        ))
    }

    func testFallbackLoadDoesNotCreateAnEmptyLoginKeychainItem() throws {
        let keychain = RecordingKeychainItemAccess()
        XCTAssertEqual(try RemoteOwnerDeviceKeychainStore(
            dataProtection: false,
            keychain: keychain
        ).load(), [])
        XCTAssertFalse(keychain.contains(
            service: Item.ownerService,
            account: Item.ownerAccount,
            dataProtection: false
        ))
    }

    func testRemoteAndBrowserSurfacesReportTheSharedKeychainPolicy() {
        XCTAssertEqual(
            BrowserCredentialStore.usesDataProtectionKeychain,
            KeychainStoragePolicy.usesDataProtectionKeychain
        )
        XCTAssertEqual(
            BrowserCredentialStore.isShellReachable,
            KeychainStoragePolicy.isShellReachable
        )

        let login = RemoteCredentialStoragePresentation.resolve(isShellReachable: true)
        let protected = RemoteCredentialStoragePresentation.resolve(isShellReachable: false)
        XCTAssertEqual(login.title, L10n.string("Remote credentials"))
        XCTAssertEqual(
            login.detail,
            KeychainStoragePolicy.storageDescription(isShellReachable: true)
        )
        XCTAssertEqual(
            protected.detail,
            KeychainStoragePolicy.storageDescription(isShellReachable: false)
        )
        XCTAssertEqual(login.detail, L10n.string("""
            Stored in your login Keychain, and removed by Reset Everything. This build cannot \
            use the protected Keychain, so a command line on this Mac — including an agent's — \
            could add or delete entries here.
            """))
        XCTAssertEqual(protected.detail, L10n.string("""
            Stored in your protected Keychain, out of reach of the command line, and removed by \
            Reset Everything.
            """))
    }

    private func ownerRecord() -> RemoteOwnerDeviceRecord {
        RemoteOwnerDeviceRecord(
            id: "owner-1",
            token: String(repeating: "a", count: 43),
            deviceID: "phone-1",
            displayName: "Phone",
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: nil
        )
    }

    private func guestRecord() -> RemoteGuestShareRecord {
        RemoteGuestShareRecord(
            id: "share-1",
            sessionID: SessionID().uuidString,
            invitationToken: String(repeating: "b", count: 43),
            capability: .interact,
            canApprovePermissions: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_700_003_600),
            members: []
        )
    }
}

private final class RecordingKeychainItemAccess: KeychainItemAccessing {
    private struct Key: Hashable {
        let service: String
        let account: String
        let dataProtection: Bool
    }

    private var items: [Key: Data] = [:]
    private var addFailures: [Key: OSStatus] = [:]

    func data(matching query: [String: Any]) -> (status: OSStatus, data: Data?) {
        guard let key = key(from: query), let data = items[key] else {
            return (errSecItemNotFound, nil)
        }
        return (errSecSuccess, data)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        guard let key = key(from: query), items[key] != nil else {
            return errSecItemNotFound
        }
        guard let data = attributes[kSecValueData as String] as? Data else {
            return errSecParam
        }
        items[key] = data
        return errSecSuccess
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        guard let key = key(from: attributes),
              let data = attributes[kSecValueData as String] as? Data else {
            return errSecParam
        }
        if let status = addFailures.removeValue(forKey: key) {
            return status
        }
        guard items[key] == nil else { return errSecDuplicateItem }
        items[key] = data
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        guard let key = key(from: query), items.removeValue(forKey: key) != nil else {
            return errSecItemNotFound
        }
        return errSecSuccess
    }

    func set(_ data: Data, service: String, account: String, dataProtection: Bool) {
        items[Key(
            service: service,
            account: account,
            dataProtection: dataProtection
        )] = data
    }

    func value(service: String, account: String, dataProtection: Bool) -> Data? {
        items[Key(
            service: service,
            account: account,
            dataProtection: dataProtection
        )]
    }

    func contains(service: String, account: String, dataProtection: Bool) -> Bool {
        value(service: service, account: account, dataProtection: dataProtection) != nil
    }

    func failNextAdd(
        service: String,
        account: String,
        dataProtection: Bool,
        status: OSStatus
    ) {
        addFailures[Key(
            service: service,
            account: account,
            dataProtection: dataProtection
        )] = status
    }

    private func key(from query: [String: Any]) -> Key? {
        guard let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String,
              let dataProtection = query[kSecUseDataProtectionKeychain as String] as? Bool else {
            return nil
        }
        return Key(
            service: service,
            account: account,
            dataProtection: dataProtection
        )
    }
}
