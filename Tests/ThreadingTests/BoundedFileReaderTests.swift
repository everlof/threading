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
