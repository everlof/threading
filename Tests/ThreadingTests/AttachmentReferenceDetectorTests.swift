import XCTest
@testable import Threading

final class AttachmentReferenceDetectorTests: XCTestCase {
    func testSupportedPathFormsKeepTheirWholeNames() {
        let cases: [(String, String)] = [
            ("saved ./output/shot.tiff:12:4", "./output/shot.tiff:12:4"),
            ("[report](output/my report.html)", "output/my report.html"),
            ("`output/my image.png`", "output/my image.png"),
            ("\"output/my image.png\"", "output/my image.png"),
            ("'output/my image.png'", "output/my image.png"),
            ("file:///tmp/my%20image.PNG", "file:///tmp/my%20image.PNG"),
            ("(.screenshots/capture.png)", ".screenshots/capture.png"),
            ("saved /tmp/åäö-🎉.png", "/tmp/åäö-🎉.png")
        ]
        for (text, expected) in cases {
            XCTAssertTrue(
                AttachmentReferenceDetector.candidates(in: text).contains(expected), text
            )
        }
    }

    func testSparseLongTokensDoNotRetryEverySuffix() {
        // The former expression spent seconds on just 16 KiB, with zero candidates. The
        // production read cap is 256 KiB. Include malformed suffixes and paths after the
        // rejected token, so a cheap answer cannot come from dropping the remainder.
        let token = String(repeating: "x.not-an-attachment", count: 14_000)
        let text = token + "\n/tmp/real.png\n`quoted image.tiff`"
        let started = DispatchTime.now().uptimeNanoseconds
        let candidates = AttachmentReferenceDetector.candidates(in: text)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        XCTAssertEqual(Set(candidates), ["/tmp/real.png", "quoted image.tiff", "image.tiff"])
        XCTAssertLessThan(elapsed, 1_000, "path-free tokens must not monopolize a scan worker")
        print("THREADING_PERF attachment-sparse-token bytes=\(text.utf8.count) match_ms=\(elapsed)")
    }

    func testCandidateLimitStillStopsBeforeFilesystemResolution() {
        let text = (0..<2_000).map { "./image-\($0).png" }.joined(separator: "\n")
        let candidates = AttachmentReferenceDetector.candidates(in: text)
        XCTAssertEqual(candidates.count, AttachmentReferenceDetector.maximumCandidatesPerScan)
        XCTAssertEqual(candidates.first, "./image-0.png")
        XCTAssertEqual(candidates.last, "./image-511.png")
    }
}
