import XCTest
import ThreadingRemoteKit
import os
@testable import ThreadingMobile

final class RemoteAttachmentSharingTests: XCTestCase {
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
