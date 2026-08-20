import Foundation
import XCTest
@testable import Threading

final class BoundedFileReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-file-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    func testReadsARegularFileAtTheExactLimit() throws {
        let expected = Data((0..<64).map(UInt8.init))
        let url = root.appendingPathComponent("exact.bin")
        try expected.write(to: url)

        XCTAssertEqual(
            try BoundedFileReader.read(url, maximumBytes: expected.count),
            expected
        )
    }

    func testRefusesOneBytePastTheLimitRatherThanReturningATruncatedPrefix() throws {
        let url = root.appendingPathComponent("large.bin")
        try Data(repeating: 0xA5, count: 65).write(to: url)

        XCTAssertThrowsError(try BoundedFileReader.read(url, maximumBytes: 64)) { error in
            XCTAssertEqual(
                error as? BoundedFileReadError,
                .exceedsLimit(maximumBytes: 64)
            )
        }
    }

    func testRefusesADirectoryBeforeOpeningItAsAByteStream() throws {
        XCTAssertThrowsError(try BoundedFileReader.read(root, maximumBytes: 64)) { error in
            XCTAssertEqual(error as? BoundedFileReadError, .notRegularFile)
        }
    }

    func testZeroLimitDistinguishesAnEmptyFileFromANonemptyOne() throws {
        let empty = root.appendingPathComponent("empty.bin")
        let nonempty = root.appendingPathComponent("nonempty.bin")
        try Data().write(to: empty)
        try Data([1]).write(to: nonempty)

        XCTAssertEqual(try BoundedFileReader.read(empty, maximumBytes: 0), Data())
        XCTAssertThrowsError(try BoundedFileReader.read(nonempty, maximumBytes: 0)) { error in
            XCTAssertEqual(
                error as? BoundedFileReadError,
                .exceedsLimit(maximumBytes: 0)
            )
        }
    }

    /// Reading many files in one loop must cost one file, not all of them.
    ///
    /// `FileHandle.read(upToCount:)` hands back autoreleased `NSData`, so without a pool per
    /// iteration every 64 KiB chunk that built a file survives until whatever is above the reader
    /// returns. The usage scan walks every transcript this machine has produced, and that turned
    /// a 4.4 GB cache directory into 4.4 GB of live `NSData` in a single pass: 72,893 chunks,
    /// most of a 14 GB peak. The caller here releases each file's bytes immediately, so anything
    /// this test sees growing is chunks that outlived their append.
    func testReadingManyFilesDoesNotRetainEveryFilesChunks() throws {
        let contents = Data(repeating: 0x41, count: 1_024 * 1_024)
        let urls: [URL] = try (0..<120).map { index in
            let url = root.appendingPathComponent("chunked-\(index).bin")
            try contents.write(to: url)
            return url
        }

        let baseline = Self.physicalFootprintBytes()
        try XCTSkipIf(baseline == 0, "Footprint is unavailable on this host.")
        for url in urls {
            let data = try BoundedFileReader.read(url, maximumBytes: 8 * 1_024 * 1_024)
            XCTAssertEqual(data.count, contents.count)
        }
        let growth = Self.positiveDifference(Self.physicalFootprintBytes(), baseline)

        // 120 MB was read. Unpooled, the chunks alone accounted for all of it; pooled, a file's
        // chunks are gone before the next file opens. The allowance is deliberately wide so this
        // fails on the regression rather than on a busy machine.
        XCTAssertLessThan(
            growth,
            40 * 1_024 * 1_024,
            "Reading 120 MB across 120 files grew the footprint by \(growth / 1_048_576) MB"
        )
    }

    private static func physicalFootprintBytes() -> UInt64 {
        let pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        return ProcessUtility.getResourceUsage(forPid: pid)?.memoryBytes ?? 0
    }

    private static func positiveDifference(_ larger: UInt64, _ smaller: UInt64) -> UInt64 {
        larger >= smaller ? larger - smaller : 0
    }

    func testShallowDirectoryReadStopsOneEntryPastTheAllowance() throws {
        for index in 0..<4 {
            try Data().write(to: root.appendingPathComponent("entry-\(index)"))
        }

        XCTAssertThrowsError(
            try BoundedDirectoryReader.shallowContents(of: root, maximumEntries: 3)
        ) { error in
            XCTAssertEqual(
                error as? BoundedDirectoryReadError,
                .exceedsLimit(maximumEntries: 3)
            )
        }
    }

    func testShallowDirectoryReadDoesNotDescendIntoChildren() throws {
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data().write(to: child.appendingPathComponent("nested"))

        XCTAssertEqual(
            try BoundedDirectoryReader.shallowContents(of: root, maximumEntries: 1)
                .map(\.lastPathComponent),
            ["child"]
        )
    }
}
