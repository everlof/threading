import XCTest
import ThreadingRemoteKit
import Photos
import UIKit
import UniformTypeIdentifiers
import os
@testable import ThreadingMobile

final class RemoteAttachmentSharingTests: XCTestCase {
    @MainActor
    func testCopyPreservesOriginalImageBytesAndReplacesThePasteboard() async throws {
        let data = try imageData()
        let image = try await RemoteAttachmentImageExport.prepare(data: data, name: "../picture.png")
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        pasteboard.string = "old content"

        image.copy(to: pasteboard)

        XCTAssertEqual(image.name, "picture.png")
        XCTAssertEqual(image.typeIdentifier, UTType.png.identifier)
        XCTAssertEqual(pasteboard.data(forPasteboardType: UTType.png.identifier), data)
        XCTAssertTrue(pasteboard.hasImages)
        XCTAssertNotNil(pasteboard.image)
        XCTAssertNil(pasteboard.string)
        XCTAssertEqual(pasteboard.numberOfItems, 1)
    }

    func testImageExportRefusesInvalidAndOversizedData() async throws {
        for data in [Data("not an image".utf8), Data(repeating: 0, count: RemoteAttachmentUploadLimits.maximumBytesPerFile + 1)] {
            do {
                _ = try await RemoteAttachmentImageExport.prepare(data: data, name: "image.png")
                XCTFail("Invalid or oversized image must be refused")
            } catch is RemoteAttachmentImageExportError {}
        }
    }

    @MainActor
    func testPhotosReceivesOriginalBytesOnlyAfterAddAccess() async throws {
        let image = try await RemoteAttachmentImageExport.prepare(data: imageData(), name: "image.png")
        let received = OSAllocatedUnfairLock(initialState: [Data]())
        let library = RemoteAttachmentPhotoLibrary(
            requestAddAccess: { .authorized },
            addImage: { image in received.withLock { $0.append(image.data) } }
        )
        try await image.saveToPhotos(using: library)
        XCTAssertEqual(received.withLock { $0 }, [image.data])

        for status in [PHAuthorizationStatus.denied, .restricted, .notDetermined] {
            let deniedLibrary = RemoteAttachmentPhotoLibrary(
                requestAddAccess: { status },
                addImage: { _ in XCTFail("Photos must not be written without permission") }
            )
            do {
                try await image.saveToPhotos(using: deniedLibrary)
                XCTFail("Expected denied access")
            } catch RemoteAttachmentImageExportError.photosDenied {}
        }
    }

    @MainActor
    func testCancellingDuringPhotosPermissionDoesNotSave() async throws {
        let image = try await RemoteAttachmentImageExport.prepare(data: imageData(), name: "image.png")
        let task = Task {
            try await image.saveToPhotos(using: RemoteAttachmentPhotoLibrary(
                requestAddAccess: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .authorized
                },
                addImage: { _ in XCTFail("A withdrawn action must not save after permission returns") }
            ))
        }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func testBuiltAppExplainsAddOnlyPhotosAccess() {
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription"))
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription"))
    }

    @MainActor
    func testStressImageExportAtByteLimitWhenEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_ATTACHMENT_IMAGE_STRESS"] == "1"
        )
        // Padding keeps fixture manufacture outside the measured operation while exercising
        // the largest admitted encoded buffer. The worker inspects metadata, not its pixels.
        var data = try imageData()
        data.append(Data(repeating: 0, count: RemoteAttachmentUploadLimits.maximumBytesPerFile - data.count))
        var timings: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let image = try await RemoteAttachmentImageExport.prepare(data: data, name: "image.png")
            let duration = start.duration(to: .now)
            timings.append(Double(duration.components.seconds) * 1_000
                + Double(duration.components.attoseconds) / 1e15)
            XCTAssertEqual(image.data, data)
            XCTAssertEqual(image.typeIdentifier, UTType.png.identifier)
        }
        timings.sort()
        print("image export 24 MiB metadata preparation: median \(timings[2]) ms, max \(timings[4]) ms")
    }

    @MainActor
    private func imageData() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        }
        return try XCTUnwrap(image.pngData())
    }

    func testSharePlanUsesWholeFileWithinTheOrdinaryBound() {
        XCTAssertEqual(
            RemoteAttachmentSharePlan.resolve(
                kind: .pdf,
                byteCount: Int64(RemoteAttachmentUploadLimits.maximumBytesPerFile),
                offersVideoStreaming: false
            ),
            .wholeFile
        )
    }

    func testOnlyAnAdvertisedLargeMovieUsesRanges() {
        let overWholeFileLimit = Int64(RemoteAttachmentUploadLimits.maximumBytesPerFile + 1)
        XCTAssertEqual(
            RemoteAttachmentSharePlan.resolve(
                kind: .video,
                byteCount: overWholeFileLimit,
                offersVideoStreaming: true
            ),
            .streamedVideo
        )
        XCTAssertEqual(
            RemoteAttachmentSharePlan.resolve(
                kind: .video,
                byteCount: overWholeFileLimit,
                offersVideoStreaming: false
            ),
            .unavailable
        )
        XCTAssertEqual(
            RemoteAttachmentSharePlan.resolve(
                kind: .pdf,
                byteCount: overWholeFileLimit,
                offersVideoStreaming: true
            ),
            .unavailable
        )
    }

    func testStagedDataKeepsBytesAndOnlyTheFileName() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let stager = RemoteAttachmentShareStager(rootDirectory: root)
        let data = Data("share me".utf8)

        let staged = try await stager.stage(data: data, named: "../../report.pdf")

        XCTAssertEqual(staged.fileURL.lastPathComponent, "report.pdf")
        XCTAssertEqual(try Data(contentsOf: staged.fileURL), data)
        XCTAssertEqual(staged.fileURL.deletingLastPathComponent(), staged.directoryURL)
        XCTAssertEqual(staged.directoryURL.deletingLastPathComponent(), root)
    }

    func testStreamWritesExactBoundedRangesInOrder() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let stager = RemoteAttachmentShareStager(rootDirectory: root)
        let source = Data((0..<11).map(UInt8.init))
        let seenRanges = OSAllocatedUnfairLock(initialState: [Range<Int64>]())

        let staged = try await stager.stageStream(
            named: "movie.mp4",
            byteCount: Int64(source.count),
            chunkByteCount: 4
        ) { range in
            seenRanges.withLock { $0.append(range) }
            return source.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }

        XCTAssertEqual(
            seenRanges.withLock { $0 },
            [0..<4, 4..<8, 8..<11]
        )
        XCTAssertEqual(try Data(contentsOf: staged.fileURL), source)
    }

    func testAShortRangeRemovesThePartialStagingDirectory() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let stager = RemoteAttachmentShareStager(rootDirectory: root)

        do {
            _ = try await stager.stageStream(
                named: "movie.mp4",
                byteCount: 5,
                chunkByteCount: 4
            ) { _ in Data([0]) }
            XCTFail("Expected the incomplete range to be refused")
        } catch let error as RemoteAttachmentShareError {
            guard case .incompleteRange = error else {
                return XCTFail("Unexpected share error: \(error)")
            }
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testStressLargeStreamWhenEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_ATTACHMENT_SHARE_STRESS"] == "1"
        )
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let stager = RemoteAttachmentShareStager(rootDirectory: root)
        let stressBytes: Int64 = 256 * 1024 * 1024
        let chunkBytes = Int64(RemoteAttachmentVideo.maximumChunkBytes)
        let fetchCount = OSAllocatedUnfairLock(initialState: 0)

        let staged = try await stager.stageStream(
            named: "large-recording.mp4",
            byteCount: stressBytes,
            chunkByteCount: chunkBytes
        ) { range in
            fetchCount.withLock { $0 += 1 }
            return Data(repeating: UInt8(truncatingIfNeeded: range.lowerBound), count: range.count)
        }

        let values = try staged.fileURL.resourceValues(forKeys: [.fileSizeKey])
        XCTAssertEqual(values.fileSize, Int(stressBytes))
        XCTAssertEqual(fetchCount.withLock { $0 }, Int(stressBytes / chunkBytes))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "RemoteAttachmentSharingTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
