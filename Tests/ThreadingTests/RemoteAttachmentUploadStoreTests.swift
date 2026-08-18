import XCTest
import ThreadingRemoteKit
import UniformTypeIdentifiers
@testable import Threading

/// The one route through which a remote client can write a file the Mac will keep.
///
/// Everything here is a refusal, because that is what this type is for. Before it existed,
/// `docs/REMOTE_ACCESS.md` listed "phone-to-Mac attachment uploads" among the things deliberately
/// not exposed; the capability replaced that flat no with a bounded yes, and these are the bounds.
/// A regression in any one of them widens what a paired device can put on somebody's disk.
final class RemoteAttachmentUploadStoreTests: XCTestCase {

    // MARK: - Properties

    private var root: URL!
    private var store: RemoteAttachmentUploadStore!
    private let session = "11111111-1111-1111-1111-111111111111"
    private let otherSession = "22222222-2222-2222-2222-222222222222"
    private let device = "device-a"

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-store-tests-\(UUID().uuidString)", isDirectory: true)
        store = RemoteAttachmentUploadStore(root: root)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Accepting

    func testSingleChunkUploadCompletesAndStagesRealBytes() throws {
        let png = Self.onePixelPNG
        let result = try XCTUnwrap(accept(png))

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.receivedBytes, png.count)

        let claimed = try XCTUnwrap(
            store.claim(ids: [result.uploadID], sessionID: session, deviceID: device)
        )
        XCTAssertEqual(claimed.count, 1)
        XCTAssertEqual(try Data(contentsOf: claimed[0]), png)
    }

    /// The extension comes from the declared uniform type, never from the client's filename.
    /// A name is the one part of this request the network fully controls.
    func testStagedFileTakesItsExtensionFromTheDeclaredTypeNotTheName() throws {
        let result = try XCTUnwrap(accept(Self.onePixelPNG, name: "invoice.command"))
        let claimed = try XCTUnwrap(
            store.claim(ids: [result.uploadID], sessionID: session, deviceID: device)
        )
        XCTAssertEqual(claimed[0].pathExtension, "png")
        XCTAssertFalse(claimed[0].lastPathComponent.contains("command"))
    }

    /// Named under the shared generated prefix, which is what tells the attachments pane this is
    /// a file the app wrote rather than one the person already had a name for.
    func testStagedFileUsesTheSharedGeneratedPrefix() throws {
        let result = try XCTUnwrap(accept(Self.onePixelPNG))
        let claimed = try XCTUnwrap(
            store.claim(ids: [result.uploadID], sessionID: session, deviceID: device)
        )
        XCTAssertTrue(
            claimed[0].lastPathComponent.hasPrefix(ComposerAttachmentDefaults.generatedPrefix)
        )
    }

    func testMultipleChunksAssembleInOrder() throws {
        let whole = Data((0..<4096).map { UInt8($0 % 251) })
        let half = whole.count / 2

        let first = try XCTUnwrap(store.accept(
            request(chunk: whole.prefix(half), total: whole.count, index: 0, count: 2),
            sessionID: session,
            deviceID: device
        ))
        XCTAssertFalse(first.isComplete)
        XCTAssertEqual(first.receivedBytes, half)

        let second = try XCTUnwrap(store.accept(
            request(
                uploadID: first.uploadID,
                chunk: whole.suffix(from: half),
                total: whole.count,
                index: 1,
                count: 2
            ),
            sessionID: session,
            deviceID: device
        ))
        XCTAssertTrue(second.isComplete)

        let claimed = try XCTUnwrap(
            store.claim(ids: [second.uploadID], sessionID: session, deviceID: device)
        )
        XCTAssertEqual(try Data(contentsOf: claimed[0]), whole)
    }

    /// A lost response is retried by re-sending the same chunk. Appending it twice would corrupt
    /// the file silently, which is worse than any refusal.
    func testResendingTheLastChunkIsIdempotent() throws {
        let whole = Data(repeating: 0xAB, count: 2048)
        let half = whole.count / 2
        let first = try XCTUnwrap(store.accept(
            request(chunk: whole.prefix(half), total: whole.count, index: 0, count: 2),
            sessionID: session,
            deviceID: device
        ))

        let replay = try XCTUnwrap(store.accept(
            request(chunk: whole.prefix(half), total: whole.count, index: 0, count: 2)
                .replacingUploadID(with: first.uploadID),
            sessionID: session,
            deviceID: device
        ))
        XCTAssertEqual(replay.receivedBytes, half, "a replayed chunk must not append twice")
        XCTAssertFalse(replay.isComplete)
    }

    // MARK: - Refusing

    func testRefusesAChunkOutOfOrder() throws {
        let whole = Data(repeating: 1, count: 2048)
        let first = try XCTUnwrap(store.accept(
            request(chunk: whole.prefix(1024), total: whole.count, index: 0, count: 3),
            sessionID: session,
            deviceID: device
        ))
        XCTAssertNil(store.accept(
            request(
                uploadID: first.uploadID,
                chunk: whole.prefix(1024),
                total: whole.count,
                index: 2,
                count: 3
            ),
            sessionID: session,
            deviceID: device
        ), "chunk 2 must not be accepted while chunk 1 is missing")
    }

    func testRefusesADeclaredSizeOverTheCeiling() {
        XCTAssertNil(store.accept(
            request(
                chunk: Self.onePixelPNG,
                total: RemoteAttachmentUploadLimits.maximumBytesPerFile + 1,
                index: 0,
                count: 2
            ),
            sessionID: session,
            deviceID: device
        ))
    }

    /// A one-chunk upload claiming to be a larger file would otherwise be marked complete while
    /// short, and a truncated image would reach the agent as a real one.
    func testRefusesASingleChunkThatIsShorterThanItsDeclaredSize() {
        XCTAssertNil(store.accept(
            request(chunk: Self.onePixelPNG, total: Self.onePixelPNG.count + 10, index: 0, count: 1),
            sessionID: session,
            deviceID: device
        ))
    }

    func testRefusesATypeTheAttachmentsPaneWouldNotShow() {
        for mediaType in [
            UTType.unixExecutable.identifier,
            "public.shell-script",
            "not.a.real.type",
            "",
        ] {
            XCTAssertNil(store.accept(
                request(chunk: Self.onePixelPNG, mediaType: mediaType),
                sessionID: session,
                deviceID: device
            ), "should have refused \(mediaType)")
        }
    }

    func testRefusesMoreStagedUploadsThanOneMessageMayCarry() throws {
        for _ in 0..<RemoteAttachmentUploadLimits.maximumPerMessage {
            XCTAssertNotNil(accept(Self.onePixelPNG))
        }
        XCTAssertNil(accept(Self.onePixelPNG), "the per-session cap must refuse, not evict")
    }

    // MARK: - Ownership

    func testAnotherDeviceCannotAppendToOrClaimAnUpload() throws {
        let whole = Data(repeating: 7, count: 2048)
        let first = try XCTUnwrap(store.accept(
            request(chunk: whole.prefix(1024), total: whole.count, index: 0, count: 2),
            sessionID: session,
            deviceID: device
        ))

        XCTAssertNil(store.accept(
            request(
                uploadID: first.uploadID,
                chunk: whole.suffix(1024),
                total: whole.count,
                index: 1,
                count: 2
            ),
            sessionID: session,
            deviceID: "device-b"
        ), "an upload id leaked to another device must name nothing it can write to")

        let complete = try XCTUnwrap(accept(Self.onePixelPNG))
        XCTAssertNil(
            store.claim(ids: [complete.uploadID], sessionID: session, deviceID: "device-b")
        )
    }

    func testAnotherSessionCannotClaimAnUpload() throws {
        let result = try XCTUnwrap(accept(Self.onePixelPNG))
        XCTAssertNil(store.claim(ids: [result.uploadID], sessionID: otherSession, deviceID: device))
        XCTAssertNotNil(
            store.claim(ids: [result.uploadID], sessionID: session, deviceID: device),
            "the rightful session must still be able to claim it afterwards"
        )
    }

    // MARK: - Claiming

    func testClaimingIsAllOrNothing() throws {
        let good = try XCTUnwrap(accept(Self.onePixelPNG))
        XCTAssertNil(
            store.claim(ids: [good.uploadID, "not-an-upload"], sessionID: session, deviceID: device),
            "one unknown id refuses the whole claim"
        )
        XCTAssertNotNil(
            store.claim(ids: [good.uploadID], sessionID: session, deviceID: device),
            "a refused claim must leave staging exactly as it was, including marking nothing"
        )
    }

    func testRefusesTheSameUploadNamedTwiceInOneMessage() throws {
        let result = try XCTUnwrap(accept(Self.onePixelPNG))
        XCTAssertNil(store.claim(
            ids: [result.uploadID, result.uploadID],
            sessionID: session,
            deviceID: device
        ))
    }

    func testAnIncompleteUploadCannotBeClaimed() throws {
        let whole = Data(repeating: 3, count: 2048)
        let first = try XCTUnwrap(store.accept(
            request(chunk: whole.prefix(1024), total: whole.count, index: 0, count: 2),
            sessionID: session,
            deviceID: device
        ))
        XCTAssertNil(store.claim(ids: [first.uploadID], sessionID: session, deviceID: device))
    }

    /// A claim is a loan, and one file cannot be out on two at once. Without this, two submits
    /// racing for the same upload would both name a file only one of them still owns.
    func testAClaimedUploadCannotBeClaimedAgainWhileItIsOut() throws {
        let result = try XCTUnwrap(accept(Self.onePixelPNG))
        XCTAssertNotNil(store.claim(ids: [result.uploadID], sessionID: session, deviceID: device))
        XCTAssertNil(store.claim(ids: [result.uploadID], sessionID: session, deviceID: device))
    }

    /// A prompt the Mac refused leaves the phone's strip intact on purpose, so pressing send
    /// again has to find the same files still there rather than re-uploading every one.
    func testReleasingAfterARefusalMakesTheUploadSendableAgain() throws {
        let result = try XCTUnwrap(accept(Self.onePixelPNG))
        let lent = try XCTUnwrap(
            store.claim(ids: [result.uploadID], sessionID: session, deviceID: device)
        )

        store.release(ids: [result.uploadID])

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: lent[0].path),
            "a refused submission must not take the bytes with it"
        )
        XCTAssertNotNil(
            store.claim(ids: [result.uploadID], sessionID: session, deviceID: device),
            "the same draft has to be sendable a second time"
        )
    }

    /// Accepted means custody was taken through the attachment store, so what is left in staging
    /// is a duplicate. Keeping it would double every sent picture on disk until the reaper ran.
    func testDiscardingAfterAcceptanceRemovesTheStagedDuplicate() throws {
        let result = try XCTUnwrap(accept(Self.onePixelPNG))
        let lent = try XCTUnwrap(
            store.claim(ids: [result.uploadID], sessionID: session, deviceID: device)
        )

        store.discardClaimed(ids: [result.uploadID])

        XCTAssertFalse(FileManager.default.fileExists(atPath: lent[0].path))
        XCTAssertEqual(store.stagedCount, 0)
        XCTAssertNil(store.claim(ids: [result.uploadID], sessionID: session, deviceID: device))
    }

    /// The submission is asynchronous — it hops to the main actor and back — so a sweep can land
    /// while a prompt is on its way to naming these bytes. Reaping them there would delete a
    /// picture out from under a message that was already accepted.
    func testAnUploadOutOnLoanIsNotReaped() throws {
        let result = try XCTUnwrap(accept(Self.onePixelPNG))
        XCTAssertNotNil(store.claim(ids: [result.uploadID], sessionID: session, deviceID: device))

        store.reap(now: Date().addingTimeInterval(
            RemoteAttachmentUploadDefaults.stagedLifetime + 1
        ))

        XCTAssertEqual(store.stagedCount, 1)
    }

    /// Release restarts the clock rather than handing back an upload that is already past its
    /// deadline and would vanish on the very next sweep.
    func testReleaseRenewsTheLifetime() throws {
        let result = try XCTUnwrap(accept(Self.onePixelPNG))
        _ = store.claim(ids: [result.uploadID], sessionID: session, deviceID: device)

        let late = Date().addingTimeInterval(RemoteAttachmentUploadDefaults.stagedLifetime + 1)
        store.release(ids: [result.uploadID], now: late)
        store.reap(now: late)

        XCTAssertEqual(store.stagedCount, 1)
    }

    // MARK: - Reaping

    func testAbandonedUploadsAreReapedWithTheirBytes() throws {
        let result = try XCTUnwrap(accept(Self.onePixelPNG))
        XCTAssertEqual(store.stagedCount, 1)

        store.reap(now: Date().addingTimeInterval(
            RemoteAttachmentUploadDefaults.stagedLifetime + 1
        ))
        XCTAssertEqual(store.stagedCount, 0)
        XCTAssertNil(store.claim(ids: [result.uploadID], sessionID: session, deviceID: device))
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty ?? true,
            "reaping removes the staged bytes, not only the record of them"
        )
    }

    /// A transfer still making progress must not be reaped underneath itself, which is what a
    /// deadline fixed at creation would do to a large file on a slow connection.
    func testProgressExtendsAnUploadsLifetime() throws {
        let whole = Data(repeating: 9, count: 2048)
        let start = Date()
        let first = try XCTUnwrap(store.accept(
            request(chunk: whole.prefix(1024), total: whole.count, index: 0, count: 2),
            sessionID: session,
            deviceID: device
        ))

        let late = start.addingTimeInterval(RemoteAttachmentUploadDefaults.stagedLifetime - 1)
        _ = store.accept(
            request(
                uploadID: first.uploadID,
                chunk: whole.suffix(1024),
                total: whole.count,
                index: 1,
                count: 2
            ),
            sessionID: session,
            deviceID: device,
            now: late
        )

        store.reap(now: start.addingTimeInterval(
            RemoteAttachmentUploadDefaults.stagedLifetime + 1
        ))
        XCTAssertEqual(store.stagedCount, 1, "the second chunk pushed the deadline out")
    }

    func testDiscardAllRemovesEveryStagedByte() throws {
        _ = accept(Self.onePixelPNG)
        _ = accept(Self.onePixelPNG)
        store.discardAll()
        XCTAssertEqual(store.stagedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - Helpers

    @discardableResult
    private func accept(
        _ data: Data,
        name: String = "picture.png",
        mediaType: String = "public.png"
    ) -> RemoteAttachmentUploadResponseDTO? {
        store.accept(
            request(chunk: data, name: name, mediaType: mediaType),
            sessionID: session,
            deviceID: device
        )
    }

    private func request(
        uploadID: String? = nil,
        chunk: Data,
        name: String = "picture.png",
        mediaType: String = "public.png",
        total: Int? = nil,
        index: Int = 0,
        count: Int = 1
    ) -> RemoteAttachmentUploadRequestDTO {
        RemoteAttachmentUploadRequestDTO(
            uploadID: uploadID,
            name: name,
            mediaType: mediaType,
            totalBytes: total ?? chunk.count,
            chunkIndex: index,
            chunkCount: count,
            chunk: chunk.base64EncodedString()
        )
    }

    /// A real PNG, because the type gate reads bytes for anything ambiguous and a fixture of
    /// zeroes would pass a name check while proving nothing about the file.
    private static let onePixelPNG: Data = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """)!
}

// MARK: - Fixture Support

private extension RemoteAttachmentUploadRequestDTO {
    func replacingUploadID(with id: String) -> Self {
        Self(
            uploadID: id,
            name: name,
            mediaType: mediaType,
            totalBytes: totalBytes,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount,
            chunk: chunk
        )
    }
}
