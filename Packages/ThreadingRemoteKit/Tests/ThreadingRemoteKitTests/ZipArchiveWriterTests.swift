import Foundation
import XCTest

@testable import ThreadingRemoteKit

final class ZipArchiveWriterTests: XCTestCase {
    func testArchiveCarriesEveryNamedEntryAndItsDirectory() throws {
        let archive = try ZipArchiveWriter.archive(
            [
                .init(path: "diagnostics.json", data: Data("{}".utf8)),
                .init(path: "description.txt", data: Data("The screen froze".utf8)),
                .init(path: "screenshot.png", data: Data([0x89, 0x50, 0x4e, 0x47])),
            ],
            modified: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertTrue(archive.starts(with: [0x50, 0x4b, 0x03, 0x04]))
        for name in ["diagnostics.json", "description.txt", "screenshot.png"] {
            XCTAssertNotNil(archive.range(of: Data(name.utf8)), "missing \(name)")
        }
        XCTAssertNotNil(archive.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
        XCTAssertTrue(archive.suffix(22).starts(with: [0x50, 0x4b, 0x05, 0x06]))
    }

    func testChecksumAndEntryPathsFollowTheZipContract() {
        XCTAssertEqual(ZipArchiveWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(
            ZipArchiveWriter.Entry(path: "../../private/report.json", data: Data()).path,
            "private/report.json"
        )
    }

    #if os(macOS) || os(Linux)
    func testArchiveCanBeExpandedByTheSystemUnzip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveURL = root.appendingPathComponent("report.zip")
        let expandedURL = root.appendingPathComponent("expanded", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let diagnostics = Data("{\"status\":\"ready\"}".utf8)
        let description = Data(String(repeating: "日本語 🧵 diagnostics\n", count: 4096).utf8)
        let archive = try ZipArchiveWriter.archive(
            [
                .init(path: "diagnostics.json", data: diagnostics),
                .init(path: "日本語.txt", data: description),
            ],
            modified: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertLessThan(archive.count, description.count)
        try archive.write(to: archiveURL)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-qq", archiveURL.path, "-d", expandedURL.path]
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            unzip.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try unzip.run() }
            catch {
                unzip.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        XCTAssertEqual(status, 0)
        XCTAssertEqual(
            try Data(contentsOf: expandedURL.appendingPathComponent("diagnostics.json")),
            diagnostics
        )
        XCTAssertEqual(
            try Data(contentsOf: expandedURL.appendingPathComponent("日本語.txt")),
            description
        )
    }
    #endif
}
