import XCTest
@testable import Threading

/// Covers the cache that stands between this app and the agent CLIs' own settings files.
///
/// The behaviour worth pinning is not "it is fast". It is that speed was bought without buying
/// staleness: the file is stat'd on every single call, so a write by the CLI is picked up on the
/// very next read, and only the parse is skipped. A lifetime-based cache would have passed a
/// "does it cache" test while quietly answering with last minute's model list.
final class ProviderSettingsFileCacheTests: XCTestCase {

    // MARK: - Fixtures

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-settings-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private var file: URL { directory.appendingPathComponent("state.json") }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    /// Counts decodes so a test can assert on work avoided rather than on elapsed time, which
    /// would make it a benchmark and therefore flaky.
    private final class DecodeCounter {
        private(set) var count = 0
        func decode(_ url: URL) -> String? {
            count += 1
            guard let data = try? Data(contentsOf: url) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    // MARK: - Reuse

    func testAnUnchangedFileIsDecodedOnlyOnce() throws {
        try write("first", to: file)
        let cache = ProviderSettingsFileCache<String>()
        let counter = DecodeCounter()

        for _ in 0..<25 {
            XCTAssertEqual(cache.value(at: file, decode: counter.decode), "first")
        }

        XCTAssertEqual(counter.count, 1, "an unchanged file must be parsed once, not per call")
    }

    // MARK: - Freshness

    /// The whole point of checking identity rather than a lifetime: there is no window in which
    /// the app serves a model list the CLI has already replaced.
    func testARewrittenFileIsPickedUpOnTheNextRead() throws {
        try write("first", to: file)
        let cache = ProviderSettingsFileCache<String>()
        let counter = DecodeCounter()

        XCTAssertEqual(cache.value(at: file, decode: counter.decode), "first")

        // A different length moves the identity even if the clock's resolution does not.
        try write("second value", to: file)

        XCTAssertEqual(
            cache.value(at: file, decode: counter.decode),
            "second value",
            "a rewrite must be visible immediately, with no staleness window"
        )
        XCTAssertEqual(counter.count, 2)
    }

    /// Same byte count, different bytes: only the modification date separates these, which is why
    /// the identity carries it as well as the size.
    func testARewriteOfTheSameLengthIsStillNoticed() throws {
        try write("aaaa", to: file)
        let cache = ProviderSettingsFileCache<String>()
        let counter = DecodeCounter()
        XCTAssertEqual(cache.value(at: file, decode: counter.decode), "aaaa")

        // Push the timestamp forward explicitly rather than sleeping: the assertion is about the
        // identity being consulted, not about how fine-grained the filesystem clock happens to be.
        try write("bbbb", to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: file.path
        )

        XCTAssertEqual(cache.value(at: file, decode: counter.decode), "bbbb")
    }

    // MARK: - Absence

    func testAMissingFileAnswersNilWithoutDecoding() {
        let cache = ProviderSettingsFileCache<String>()
        let counter = DecodeCounter()

        XCTAssertNil(cache.value(at: file, decode: counter.decode))
        XCTAssertEqual(counter.count, 0, "a file that cannot be stat'd is never opened")
    }

    /// A login signed out and recreated at the same path must not answer from the old one.
    func testARemovedFileForgetsWhatItUsedToSay() throws {
        try write("first", to: file)
        let cache = ProviderSettingsFileCache<String>()
        let counter = DecodeCounter()
        XCTAssertEqual(cache.value(at: file, decode: counter.decode), "first")

        try FileManager.default.removeItem(at: file)
        XCTAssertNil(cache.value(at: file, decode: counter.decode))

        try write("recreated", to: file)
        XCTAssertEqual(
            cache.value(at: file, decode: counter.decode),
            "recreated",
            "a path reused by a new login reads as the new login"
        )
    }

    /// The CLIs rewrite these files in place — truncate, then write — so a read can land while
    /// the file exists but holds nothing. That must read as absent, and must not be remembered as
    /// the answer: the completed write moments later has to be decoded, not skipped.
    func testAFailedDecodeIsNotRememberedAsAnAnswer() throws {
        try write("first", to: file)
        let cache = ProviderSettingsFileCache<String>()

        XCTAssertEqual(cache.value(at: file, decode: { _ in "first" }), "first")

        try write("", to: file)
        XCTAssertNil(
            cache.value(at: file, decode: { _ in nil }),
            "a file caught mid-rewrite reads as absent"
        )

        try write("second value", to: file)
        var decodes = 0
        XCTAssertEqual(
            cache.value(at: file, decode: { _ in decodes += 1; return "second value" }),
            "second value"
        )
        XCTAssertEqual(decodes, 1, "the completed write must be decoded, not answered from a nil")
    }

    // MARK: - Bounds

    /// The key set comes from discovered accounts, so reaching the limit means paths are being
    /// generated. Starting again is bounded; growing without limit is not.
    func testTheCacheStaysBounded() throws {
        let cache = ProviderSettingsFileCache<String>(limit: 4)
        var urls: [URL] = []

        for index in 0..<12 {
            let url = directory.appendingPathComponent("file-\(index).json")
            try write("value-\(index)", to: url)
            urls.append(url)
            XCTAssertEqual(cache.value(at: url, decode: { _ in "value-\(index)" }), "value-\(index)")
        }

        // Every file still answers correctly; the only thing the bound costs is a re-decode.
        for (index, url) in urls.enumerated() {
            XCTAssertEqual(
                cache.value(at: url, decode: { _ in "value-\(index)" }),
                "value-\(index)"
            )
        }
    }

    func testInvalidateForcesAFreshDecode() throws {
        try write("first", to: file)
        let cache = ProviderSettingsFileCache<String>()
        let counter = DecodeCounter()

        XCTAssertEqual(cache.value(at: file, decode: counter.decode), "first")
        cache.invalidate()
        XCTAssertEqual(cache.value(at: file, decode: counter.decode), "first")
        XCTAssertEqual(counter.count, 2)
    }
}
