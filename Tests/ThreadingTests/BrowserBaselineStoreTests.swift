import XCTest

@testable import Threading

/// The durable half of the visual-baseline workflow, tested without a browser.
///
/// Everything here is a pure function of bytes on disk or bytes in memory, which is deliberate: the
/// store's failure modes — a truncated write, a record from a newer build, a quota, a replacement
/// that must not destroy the last approved image — are exactly the ones that never reproduce
/// interactively and are trivial to provoke here.
@MainActor
final class BrowserBaselineStoreTests: XCTestCase {

    private var root: URL!
    private var store: BrowserBaselineStore!
    private var projectID: ProjectID!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BaselineStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = BrowserBaselineStore(root: root)
        projectID = ProjectID()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        store = nil
        projectID = nil
        super.tearDown()
    }

    // MARK: - Round trip

    func testStoresAndReloadsABaselineFromDisk() throws {
        let png = try Self.png(width: 4, height: 3, red: 200)
        let created = try store.createBaseline(
            Self.request(name: "Dashboard", png: png),
            in: projectID
        )
        XCTAssertEqual(created.name, "Dashboard")
        XCTAssertEqual(created.revisions.count, 1)
        XCTAssertEqual(created.activeRevision?.conditions.pixelWidth, 4)
        XCTAssertEqual(created.activeRevision?.conditions.pixelHeight, 3)

        // A second store over the same directory is exactly what the next launch is.
        let reloaded = BrowserBaselineStore(root: root)
        let listed = reloaded.baselines(for: projectID)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, created.id)
        XCTAssertEqual(listed.first?.name, "Dashboard")
        XCTAssertEqual(
            try reloaded.activePNG(of: created.id, in: projectID).data.count,
            png.count
        )
    }

    func testResolvesByExactUniqueNameAndRefusesADuplicate() throws {
        let png = try Self.png(width: 2, height: 2, red: 10)
        let created = try store.createBaseline(
            Self.request(name: "Sign in", png: png),
            in: projectID
        )
        // Case and surrounding whitespace are the same claim to whoever typed it.
        XCTAssertEqual(store.baseline(named: "  sign IN ", in: projectID)?.id, created.id)
        XCTAssertThrowsError(
            try store.createBaseline(Self.request(name: "SIGN IN", png: png), in: projectID)
        ) { error in
            XCTAssertEqual(error as? BrowserBaselineStoreError, .nameInUse("SIGN IN"))
        }
    }

    // MARK: - Revisions

    func testApprovalAddsARevisionAndKeepsTheOneItReplaced() throws {
        let first = try Self.png(width: 2, height: 2, red: 0)
        let second = try Self.png(width: 2, height: 2, red: 255)
        let created = try store.createBaseline(
            Self.request(name: "Header", png: first),
            in: projectID
        )
        let originalRevision = try XCTUnwrap(created.activeRevision).id

        let updated = try store.addRevision(
            Self.request(name: "Header", png: second),
            to: created.id,
            in: projectID
        )
        XCTAssertEqual(updated.revisions.count, 2)
        XCTAssertNotEqual(updated.activeRevisionID, originalRevision)

        // The point of immutable revisions: the last approved image is still readable.
        let previous = try store.pngData(
            forRevision: originalRevision,
            of: created.id,
            in: projectID
        )
        XCTAssertEqual(previous, first)

        let reverted = try store.activateRevision(
            originalRevision,
            of: created.id,
            in: projectID
        )
        XCTAssertEqual(reverted.activeRevisionID, originalRevision)
    }

    func testAgentMayNotDeleteAUserCapturedBaseline() throws {
        let png = try Self.png(width: 2, height: 2, red: 1)
        var request = Self.request(name: "Approved", png: png)
        request.provenance = .userCaptured
        let created = try store.createBaseline(request, in: projectID)

        XCTAssertThrowsError(
            try store.delete(created.id, in: projectID, requiresAgentOwnership: true)
        ) { error in
            XCTAssertEqual(error as? BrowserBaselineStoreError, .userOwned)
        }
        // The user's own route through the same call still works.
        XCTAssertNoThrow(try store.delete(created.id, in: projectID))
        XCTAssertTrue(store.baselines(for: projectID).isEmpty)
    }

    // MARK: - Attribution state

    func testAttributionStateIsStoredBesideThePixelsAndFlagged() throws {
        let png = try Self.png(width: 2, height: 2, red: 5)
        var request = Self.request(name: "With state", png: png)
        request.attributionJSON = Data(#"{"schema_version":1}"#.utf8)
        let created = try store.createBaseline(request, in: projectID)

        XCTAssertEqual(created.activeRevision?.hasAttribution, true)
        let stored = try XCTUnwrap(
            store.attributionJSON(
                forRevision: try XCTUnwrap(created.activeRevision).id,
                of: created.id,
                in: projectID
            )
        )
        XCTAssertEqual(stored, request.attributionJSON)

        // A revision captured without it says so rather than reporting an empty tree.
        let plain = try store.createBaseline(
            Self.request(name: "Without state", png: png),
            in: projectID
        )
        XCTAssertEqual(plain.activeRevision?.hasAttribution, false)
        XCTAssertNil(
            store.attributionJSON(
                forRevision: try XCTUnwrap(plain.activeRevision).id,
                of: plain.id,
                in: projectID
            )
        )
    }

    // MARK: - Failure states

    func testRejectsSomethingThatIsNotAPNG() throws {
        XCTAssertThrowsError(
            try store.createBaseline(
                Self.request(name: "Broken", png: Data("not an image".utf8)),
                in: projectID
            )
        ) { error in
            XCTAssertEqual(error as? BrowserBaselineStoreError, .invalidImage)
        }
        XCTAssertTrue(store.baselines(for: projectID).isEmpty)
    }

    func testACorruptRecordIsQuarantinedRatherThanListedOrDeleted() throws {
        let png = try Self.png(width: 2, height: 2, red: 9)
        let created = try store.createBaseline(
            Self.request(name: "Damaged", png: png),
            in: projectID
        )
        let record = root
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent(created.id.uuidString, isDirectory: true)
            .appendingPathComponent(BrowserBaselineDefaults.recordFileName)
        try Data("{ not json".utf8).write(to: record)

        let reloaded = BrowserBaselineStore(root: root)
        XCTAssertTrue(reloaded.baselines(for: projectID).isEmpty)
        XCTAssertFalse(reloaded.isWriteBlocked)

        // Moved aside, not destroyed: the bytes are still there to be looked at.
        let quarantine = root.appendingPathComponent(
            BrowserBaselineDefaults.quarantineDirectoryName,
            isDirectory: true
        )
        let contents = try FileManager.default.subpathsOfDirectory(atPath: quarantine.path)
        XCTAssertTrue(contents.contains { $0.hasSuffix(BrowserBaselineDefaults.imageFileName) })
    }

    func testARecordFromANewerBuildIsLeftAloneRatherThanQuarantined() throws {
        let png = try Self.png(width: 2, height: 2, red: 3)
        let created = try store.createBaseline(
            Self.request(name: "Future", png: png),
            in: projectID
        )
        let recordURL = root
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent(created.id.uuidString, isDirectory: true)
            .appendingPathComponent(BrowserBaselineDefaults.recordFileName)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: recordURL)) as? [String: Any]
        )
        json["schema_version"] = BrowserBaselineDefaults.schemaVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(to: recordURL)

        let reloaded = BrowserBaselineStore(root: root)
        XCTAssertTrue(reloaded.baselines(for: projectID).isEmpty)
        XCTAssertEqual(reloaded.unsupportedCount(for: projectID), 1)
        // Untouched, so a build that understands it still finds it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path))
    }

    func testWritesAreBlockedWhenDamagedDataCannotBeSetAside() throws {
        let png = try Self.png(width: 2, height: 2, red: 7)
        let created = try store.createBaseline(
            Self.request(name: "Unquarantinable", png: png),
            in: projectID
        )
        let record = root
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent(created.id.uuidString, isDirectory: true)
            .appendingPathComponent(BrowserBaselineDefaults.recordFileName)
        try Data("{".utf8).write(to: record)

        // A *file* where the quarantine directory has to go: the move cannot succeed, which is the
        // state the store refuses to write over.
        try Data().write(
            to: root.appendingPathComponent(BrowserBaselineDefaults.quarantineDirectoryName)
        )

        let reloaded = BrowserBaselineStore(root: root)
        XCTAssertTrue(reloaded.baselines(for: projectID).isEmpty)
        XCTAssertTrue(reloaded.isWriteBlocked)
        XCTAssertThrowsError(
            try reloaded.createBaseline(Self.request(name: "New", png: png), in: projectID)
        ) { error in
            XCTAssertEqual(error as? BrowserBaselineStoreError, .writesBlocked)
        }
    }

    func testAnExceededQuotaIsAVisibleRefusalRatherThanAnEviction() throws {
        let png = try Self.png(width: 2, height: 2, red: 4)
        var request = Self.request(name: "Huge", png: png)
        request.pngData = Data(count: BrowserBaselineDefaults.maximumImageBytes + 1)
        XCTAssertThrowsError(try store.createBaseline(request, in: projectID)) { error in
            guard case .imageTooLarge = error as? BrowserBaselineStoreError else {
                return XCTFail("Expected a size refusal, got \(error)")
            }
        }
    }

    // MARK: - Lifecycle

    func testRemovingAProjectTakesItsBaselinesAndLeavesOthersAlone() throws {
        let png = try Self.png(width: 2, height: 2, red: 6)
        let other = ProjectID()
        _ = try store.createBaseline(Self.request(name: "Kept", png: png), in: projectID)
        _ = try store.createBaseline(Self.request(name: "Dropped", png: png), in: other)

        store.retainOnly(projectIDs: [projectID])
        XCTAssertEqual(store.baselines(for: projectID).count, 1)
        XCTAssertTrue(BrowserBaselineStore(root: root).baselines(for: other).isEmpty)
    }

    // MARK: - Conditions

    func testConditionsReportTheDifferencesThatExplainAWholePageChange() {
        let baseline = Self.conditions(width: 800, height: 600, scheme: "light")
        let actual = Self.conditions(width: 800, height: 600, scheme: "dark")
        let differences = actual.differences(from: baseline)
        XCTAssertEqual(differences.count, 1)
        XCTAssertTrue(differences[0].contains("light"))
        XCTAssertTrue(differences[0].contains("dark"))
        XCTAssertTrue(actual.differences(from: actual).isEmpty)
    }

    // MARK: - Fixtures

    static func conditions(
        width: Int,
        height: Int,
        scheme: String = "light",
        kind: BrowserBaselineCaptureKind = .viewport
    ) -> BrowserBaselineConditions {
        BrowserBaselineConditions(
            url: "https://example.com/dashboard",
            origin: "https://example.com",
            captureKind: kind,
            pixelWidth: width,
            pixelHeight: height,
            viewportWidth: Double(width),
            viewportHeight: Double(height),
            documentWidth: Double(width),
            documentHeight: Double(height),
            scrollX: 0,
            scrollY: 0,
            pageZoom: 1,
            colorScheme: scheme,
            mediaType: "auto",
            userAgent: nil,
            browserContext: "shared",
            clipped: false,
            elementScope: nil
        )
    }

    static func request(name: String, png: Data) -> BrowserBaselineCaptureRequest {
        BrowserBaselineCaptureRequest(
            name: name,
            pngData: png,
            conditions: conditions(width: 4, height: 3),
            provenance: .agentCaptured,
            isAgentReadable: true
        )
    }

    /// A flat PNG of a known size, so a test can assert on dimensions the store reads back.
    static func png(width: Int, height: Int, red: Int) throws -> Data {
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaNonpremultiplied,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ))
        let bytes = try XCTUnwrap(representation.bitmapData)
        for index in 0..<(width * height) {
            bytes[index * 4] = UInt8(red)
            bytes[index * 4 + 1] = 0
            bytes[index * 4 + 2] = 0
            bytes[index * 4 + 3] = 255
        }
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }
}
