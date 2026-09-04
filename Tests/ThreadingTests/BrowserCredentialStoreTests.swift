import XCTest
@testable import Threading

/// The test-account vault and the fence around it.
///
/// The fence is the whole feature: a stored credential may only ever be filled on the exact
/// origin it was stored for, and "exact" has to survive the hostnames that are *designed* to read
/// as something else.
final class BrowserCredentialStoreTests: XCTestCase {

    private var store: BrowserCredentialStore!

    override func setUp() {
        super.setUp()
        store = BrowserCredentialStore()
        try? store.deleteAll()
    }

    override func tearDown() {
        try? store.deleteAll()
        store = nil
        super.tearDown()
    }

    private func origin(_ string: String) throws -> BrowserOrigin {
        let url = try XCTUnwrap(URL(string: string))
        return try XCTUnwrap(BrowserOrigin(url: url))
    }

    // MARK: - Test Redirect

    /// The bundle is hosted in the app, so an unredirected round trip would leave real items — and
    /// possibly a system prompt — in the developer's own keychain. Asserted rather than trusted,
    /// for the same reason `PreferenceStore` exposes `isRedirected`.
    func testTheVaultRedirectsToAScratchServiceUnderTests() {
        XCTAssertTrue(BrowserCredentialStore.isRedirected)
        XCTAssertEqual(
            BrowserCredentialStore.resolvedService,
            BrowserCredentialStore.hostedTestService
        )
    }

    // MARK: - Round Trip

    func testACredentialSurvivesASaveAndComesBackWhole() throws {
        let identity = BrowserCredentialIdentity(
            originKey: try origin("http://localhost:3000").key,
            label: "admin"
        )
        try store.save(username: "root", password: "hunter2-test", for: identity)

        let secret = try store.secret(for: identity)
        XCTAssertEqual(secret.username, "root")
        XCTAssertEqual(secret.password, "hunter2-test")
    }

    /// Some staging sign-ins take one field. An absent username has to stay absent rather than
    /// coming back as an empty string the fill would then type into a field.
    func testAPasswordOnlyCredentialKeepsNoUsername() throws {
        let identity = BrowserCredentialIdentity(
            originKey: try origin("http://localhost:8080").key,
            label: "shared"
        )
        try store.save(username: "", password: "only-a-password", for: identity)

        XCTAssertNil(try store.secret(for: identity).username)
    }

    /// Saving twice must leave one item, not two answering for one account.
    func testSavingTheSameAccountTwiceReplacesIt() throws {
        let identity = BrowserCredentialIdentity(
            originKey: try origin("http://localhost:3000").key,
            label: "admin"
        )
        try store.save(username: "root", password: "first-password", for: identity)
        try store.save(username: "root", password: "second-password", for: identity)

        XCTAssertEqual(store.identities().count, 1)
        XCTAssertEqual(try store.secret(for: identity).password, "second-password")
    }

    /// The regression that motivated update-then-add: this used to delete first, so a failed add
    /// left the account with nothing after it had had a working credential a moment before.
    /// Asserted through the observable consequence — the old value survives until the new one has
    /// actually been written — because the failing add cannot be provoked from a test.
    func testUpdatingAnEntryNeverLeavesItWithoutAValue() throws {
        let identity = BrowserCredentialIdentity(
            originKey: try origin("http://localhost:3000").key,
            label: "admin"
        )
        try store.save(username: "root", password: "first-password", for: identity)

        for round in 1...5 {
            try store.save(username: "root", password: "password-\(round)", for: identity)
            // Never a window in which the account exists with no readable secret.
            XCTAssertEqual(store.identities(for: try origin("http://localhost:3000")).count, 1)
            XCTAssertEqual(try store.secret(for: identity).password, "password-\(round)")
        }
    }

    /// An update must change the value without disturbing the identity it is stored under.
    func testUpdatingKeepsOneItemUnderTheSameAccount() throws {
        let identity = BrowserCredentialIdentity(
            originKey: try origin("http://localhost:3000").key,
            label: "admin"
        )
        try store.save(username: "root", password: "one", for: identity)
        try store.save(username: "someone-else", password: "two", for: identity)

        XCTAssertEqual(store.identities().map(\.account), [identity.account])
        let secret = try store.secret(for: identity)
        XCTAssertEqual(secret.password, "two")
        XCTAssertEqual(secret.username, "someone-else")
    }

    func testDeletingRemovesOnlyTheNamedAccount() throws {
        let key = try origin("http://localhost:3000").key
        let admin = BrowserCredentialIdentity(originKey: key, label: "admin")
        let viewer = BrowserCredentialIdentity(originKey: key, label: "viewer")
        try store.save(username: "a", password: "admin-password", for: admin)
        try store.save(username: "v", password: "viewer-password", for: viewer)

        try store.delete(admin)

        XCTAssertEqual(store.identities().map(\.label), ["viewer"])
    }

    // MARK: - The Origin Fence

    /// `127.` is a legal subdomain label, so `127.evil.com` is a registrable domain anyone can
    /// own. `BrowserOrigin` parses the octets for exactly this reason; the vault must not undo
    /// that by matching on anything looser than the whole key.
    func testALoopbackLookalikeHostReachesNoLoopbackCredential() throws {
        let loopback = try origin("http://127.0.0.1:3000")
        try store.save(
            username: "root",
            password: "loopback-password",
            for: BrowserCredentialIdentity(originKey: loopback.key, label: "admin")
        )

        let lookalike = try origin("http://127.evil.com:3000")
        XCTAssertFalse(lookalike.isLocal, "the lookalike parsed as this machine")
        XCTAssertTrue(store.identities(for: lookalike).isEmpty)
        XCTAssertEqual(store.identities(for: loopback).map(\.label), ["admin"])
    }

    /// A subdomain is a different origin, and a suffix comparison is how that stops being true.
    func testASubdomainReachesNoParentCredential() throws {
        let parent = try origin("https://staging.example.com")
        try store.save(
            username: "root",
            password: "staging-password",
            for: BrowserCredentialIdentity(originKey: parent.key, label: "admin")
        )

        XCTAssertTrue(store.identities(for: try origin("https://evil.staging.example.com")).isEmpty)
        XCTAssertTrue(store.identities(for: try origin("https://example.com")).isEmpty)
    }

    /// Two servers on one host are two origins. This is the case a developer actually hits — an
    /// app on 3000 and an admin tool on 3001 — and it is also the one a looser key would merge.
    func testTwoPortsOnOneHostAreTwoOrigins() throws {
        let app = try origin("http://localhost:3000")
        let admin = try origin("http://localhost:3001")
        try store.save(
            username: "root",
            password: "app-password",
            for: BrowserCredentialIdentity(originKey: app.key, label: "app")
        )

        XCTAssertEqual(store.identities(for: app).map(\.label), ["app"])
        XCTAssertTrue(store.identities(for: admin).isEmpty)
    }

    /// A scheme change is an origin change: the same host over http is not the same place.
    func testHTTPAndHTTPSAreTwoOrigins() throws {
        let secure = try origin("https://staging.example.com")
        try store.save(
            username: "root",
            password: "secure-password",
            for: BrowserCredentialIdentity(originKey: secure.key, label: "admin")
        )

        XCTAssertTrue(store.identities(for: try origin("http://staging.example.com")).isEmpty)
    }

    // MARK: - Account Encoding

    /// One keychain account string carries both fields, so the split has to be on the *first*
    /// separator: an origin key cannot contain one, but a label is free text the user typed.
    func testALabelMayContainTheFieldSeparator() throws {
        let identity = BrowserCredentialIdentity(
            originKey: try origin("http://localhost:3000").key,
            label: "admin|owner"
        )
        let round = try XCTUnwrap(BrowserCredentialIdentity(account: identity.account))

        XCTAssertEqual(round.originKey, "http://localhost:3000")
        XCTAssertEqual(round.label, "admin|owner")
    }

    func testAMalformedAccountStringYieldsNoIdentity() {
        XCTAssertNil(BrowserCredentialIdentity(account: "http://localhost:3000"))
        XCTAssertNil(BrowserCredentialIdentity(account: "|admin"))
        XCTAssertNil(BrowserCredentialIdentity(account: "http://localhost:3000|"))
    }

    // MARK: - Provider

    /// The behaviour the app shipped with stays the default: Threading sees no password until the
    /// user has said otherwise.
    func testTheDefaultProviderHandsSignInToTheUser() {
        XCTAssertEqual(BrowserCredentialProvider.fallback, .systemAutoFill)
    }

    // MARK: - Which Keychain

    /// The two answers are two different guarantees, and the store must report the one it has.
    ///
    /// The data-protection keychain needs a `keychain-access-groups` entitlement backed by a real
    /// team identity, so an ad-hoc-signed Debug build cannot use it — every write returns
    /// `errSecMissingEntitlement`. That was found by this suite failing eight tests while the
    /// feature "worked". What must never happen is the weaker build quietly claiming the stronger
    /// promise, so the pair is asserted to agree rather than either being asserted outright.
    func testTheStoreReportsWhichKeychainItActuallyGot() {
        XCTAssertEqual(
            BrowserCredentialStore.isShellReachable,
            !BrowserCredentialStore.usesDataProtectionKeychain,
            "the vault's shell-reachability disagreed with the keychain it is using"
        )
    }
}

// MARK: - Submission Exemptions

/// The half of the feature that relaxes the *submission* guarantee rather than the fill.
@MainActor
final class BrowserSubmissionExemptionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        BrowserSubmissionExemptions.shared.revokeAll()
    }

    override func tearDown() {
        BrowserSubmissionExemptions.shared.revokeAll()
        super.tearDown()
    }

    private func origin(_ string: String) throws -> BrowserOrigin {
        try XCTUnwrap(BrowserOrigin(url: try XCTUnwrap(URL(string: string))))
    }

    func testNothingIsExemptUntilItIsGranted() throws {
        let sessionID = SessionID()
        XCTAssertFalse(
            BrowserSubmissionExemptions.shared.isExempt(
                try origin("http://localhost:3000"),
                for: sessionID
            )
        )
    }

    /// The same exact-origin rule the browser grant keeps, plus the calling session. An exemption
    /// that leaked across agents, ports, or hosts would end in a submitted form.
    func testAnExemptionIsBoundToOneSessionAndExactOrigin() throws {
        let sessionID = SessionID()
        let otherSessionID = SessionID()
        let app = try origin("http://localhost:3000")
        BrowserSubmissionExemptions.shared.exempt(app, for: sessionID)

        XCTAssertTrue(BrowserSubmissionExemptions.shared.isExempt(app, for: sessionID))
        XCTAssertFalse(BrowserSubmissionExemptions.shared.isExempt(app, for: otherSessionID))
        XCTAssertFalse(
            BrowserSubmissionExemptions.shared.isExempt(
                try origin("http://localhost:3001"),
                for: sessionID
            )
        )
        XCTAssertFalse(
            BrowserSubmissionExemptions.shared.isExempt(
                try origin("https://localhost:3000"),
                for: sessionID
            )
        )
        XCTAssertFalse(
            BrowserSubmissionExemptions.shared.isExempt(
                try origin("http://127.evil.com:3000"),
                for: sessionID
            )
        )
    }

    /// Revoking takes effect at the next submission, not the next launch, because membership is
    /// asked rather than captured.
    func testRevokingRestoresTheQuestion() throws {
        let sessionID = SessionID()
        let app = try origin("http://localhost:3000")
        BrowserSubmissionExemptions.shared.exempt(app, for: sessionID)
        let grant = try XCTUnwrap(BrowserSubmissionExemptions.shared.grants.first)
        BrowserSubmissionExemptions.shared.revoke(grant)

        XCTAssertFalse(BrowserSubmissionExemptions.shared.isExempt(app, for: sessionID))
        XCTAssertTrue(BrowserSubmissionExemptions.shared.grants.isEmpty)
    }

    func testRevokingOneSessionDoesNotRevokeAnotherSessionOnTheSameOrigin() throws {
        let firstSessionID = SessionID()
        let secondSessionID = SessionID()
        let app = try origin("http://localhost:3000")
        BrowserSubmissionExemptions.shared.exempt(app, for: firstSessionID)
        BrowserSubmissionExemptions.shared.exempt(app, for: secondSessionID)

        let firstGrant = try XCTUnwrap(
            BrowserSubmissionExemptions.shared.grants.first {
                $0.sessionID == firstSessionID
            }
        )
        BrowserSubmissionExemptions.shared.revoke(firstGrant)

        XCTAssertFalse(BrowserSubmissionExemptions.shared.isExempt(app, for: firstSessionID))
        XCTAssertTrue(BrowserSubmissionExemptions.shared.isExempt(app, for: secondSessionID))
    }

    /// Nothing about an exemption reaches `UserDefaults`. This is the assertion that keeps the
    /// store out of reach of `defaults write`, which is the whole reason it is process memory.
    func testAnExemptionIsNeverWrittenToAnyDefaultsDomain() throws {
        BrowserSubmissionExemptions.shared.exempt(
            try origin("http://localhost:3000"),
            for: SessionID()
        )

        for defaults in [UserDefaults.standard, PreferenceStore.shared] {
            let representation = defaults.dictionaryRepresentation()
            XCTAssertFalse(
                representation.values.contains { "\($0)".contains("localhost:3000") },
                "an exemption reached a defaults domain, where a shell could rewrite it"
            )
        }
    }
}

// MARK: - 1Password References

/// The reference validator, which is the security-relevant half of the 1Password provider.
///
/// Nothing here shells out: `op` may not be installed, and a test that depended on the user's own
/// vault would be untrustworthy in both directions. What is worth pinning is the parse.
final class OnePasswordReferenceTests: XCTestCase {

    func testAVaultAndItemReferenceIsAccepted() {
        XCTAssertTrue(OnePasswordCLI.isValidItemReference("op://Private/staging-admin"))
        XCTAssertTrue(OnePasswordCLI.isValidItemReference("  op://Team Vault/app login  "))
    }

    /// The item is what gets stored and the field names are appended by Threading. A reference
    /// that already names a field would let one entry read `.../password` where a username is
    /// expected — which is the whole reason this is checked where it is typed rather than at fill
    /// time, weeks later, as a sign-in that quietly hands back to the user.
    func testAReferenceThatNamesAFieldIsRefused() {
        XCTAssertFalse(OnePasswordCLI.isValidItemReference("op://Private/staging-admin/password"))
        XCTAssertFalse(OnePasswordCLI.isValidItemReference("op://Private/staging-admin/username"))
    }

    func testAnIncompleteOrForeignReferenceIsRefused() {
        XCTAssertFalse(OnePasswordCLI.isValidItemReference("op://Private"))
        XCTAssertFalse(OnePasswordCLI.isValidItemReference("op://"))
        XCTAssertFalse(OnePasswordCLI.isValidItemReference("op://Private/"))
        XCTAssertFalse(OnePasswordCLI.isValidItemReference("op:///item"))
        XCTAssertFalse(OnePasswordCLI.isValidItemReference("https://Private/item"))
        XCTAssertFalse(OnePasswordCLI.isValidItemReference("Private/item"))
        XCTAssertFalse(OnePasswordCLI.isValidItemReference(""))
    }

    /// References are stored under the same origin-and-account key the built-in vault uses, so
    /// the two providers need one lookup rather than one each.
    func testAReferenceIsKeyedByOriginAndAccountLikeTheVault() throws {
        let url = try XCTUnwrap(URL(string: "https://staging.example.com"))
        let origin = try XCTUnwrap(BrowserOrigin(url: url))
        let identity = BrowserCredentialIdentity(originKey: origin.key, label: "admin")

        XCTAssertEqual(identity.account, "https://staging.example.com|admin")
        XCTAssertEqual(BrowserCredentialIdentity(account: identity.account)?.label, "admin")
    }
}
