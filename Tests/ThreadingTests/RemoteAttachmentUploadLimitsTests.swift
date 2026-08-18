import XCTest
import ThreadingRemoteKit
@testable import Threading

/// The upload bounds the phone reads and the Mac enforces.
///
/// `RemoteAttachmentUploadLimits` lives in `ThreadingRemoteKit` so the composer can refuse a file
/// before spending a transfer on it and say why. That only helps while the two agree: a client
/// bound that is looser than the host's turns a clear local refusal into a failed upload, and one
/// that is tighter silently hides capability the Mac would have accepted. Neither side can import
/// the other's policy, so this file is the seam.
final class RemoteAttachmentUploadLimitsTests: XCTestCase {

    /// The per-file ceiling is the same one the download side already applies. A phone that
    /// pre-refuses at a different figure is describing a Mac that does not exist.
    func testPerFileCeilingMatchesTheHostAttachmentCeiling() {
        XCTAssertEqual(
            RemoteAttachmentUploadLimits.maximumBytesPerFile,
            RemoteAccessDefaults.maximumAttachmentBytes
        )
    }

    func testPerMessageCapMatchesWhatTheStoreWillStage() {
        XCTAssertEqual(
            RemoteAttachmentUploadLimits.maximumPerMessage,
            RemoteAttachmentUploadDefaults.maximumStagedUploadsPerSession
        )
    }

    /// One chunk, base64-encoded and wrapped in its JSON envelope, has to fit inside the whole
    /// request the server will read. Base64 costs 4/3; the rest of the budget carries the name,
    /// the type and the framing. Getting this wrong makes every upload fail at 413 rather than
    /// anywhere a person could act on.
    func testAChunkFitsInsideTheServersRequestCeiling() {
        let encoded = (RemoteAttachmentUploadClientDefaults.chunkBytes + 2) / 3 * 4
        XCTAssertLessThan(
            encoded,
            RemoteAccessDefaults.maximumRequestBytes,
            "a base64 chunk must leave room for the JSON envelope around it"
        )

        let envelopeHeadroom = RemoteAccessDefaults.maximumRequestBytes - encoded
        XCTAssertGreaterThan(
            envelopeHeadroom,
            16 * 1024,
            "the envelope carries a filename and a type identifier, both attacker-shaped lengths"
        )
    }

    /// Every extension the phone offers to pick must be one the host would actually keep.
    ///
    /// The asymmetry matters: offering less than the host accepts merely hides capability, while
    /// offering more spends a whole upload to reach a refusal the person cannot do anything
    /// about. So this asserts one direction only.
    func testEveryOfferedExtensionIsOneTheHostWouldKeep() {
        for fileExtension in RemoteAttachmentUploadLimits.offeredFileExtensions {
            let url = URL(fileURLWithPath: "/tmp/threading-offer-probe.\(fileExtension)")
            XCTAssertNotNil(
                AttachmentReferenceDetector.kind(for: url),
                "the picker offers .\(fileExtension) but the host would refuse it"
            )
        }
    }

    /// And the offered set may not quietly shrink to nothing through a typo: these are the kinds
    /// the feature exists for, so each has to still be reachable from a phone.
    func testTheOfferedSetStillCoversTheKindsPeopleActuallySend() {
        for fileExtension in ["png", "jpg", "heic", "pdf", "zip", "docx"] {
            XCTAssertTrue(
                RemoteAttachmentUploadLimits.offeredFileExtensions.contains(fileExtension),
                ".\(fileExtension) must remain pickable"
            )
        }
    }

    /// The declared chunk count is bounded, and the bound has to be reachable: the largest legal
    /// file divided by one chunk must still be inside it, or a 24 MB upload is unrepresentable.
    func testTheChunkCountCeilingCanCarryTheLargestLegalFile() {
        let needed = (RemoteAttachmentUploadLimits.maximumBytesPerFile
            + RemoteAttachmentUploadClientDefaults.chunkBytes - 1)
            / RemoteAttachmentUploadClientDefaults.chunkBytes
        XCTAssertLessThanOrEqual(needed, RemoteAttachmentUploadDefaults.maximumChunks)
    }
}
