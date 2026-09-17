import CryptoKit
import Foundation
import XCTest
@testable import Threading

/// The Linux binaries a host is given: fetched once, verified against digests this build was
/// compiled with, kept content-named, and pruned on the host when nothing runs them any more.
final class RemoteHostComponentTests: XCTestCase {

    private enum Fixture {
        static let binary = Data("#!/bin/sh\nexit 0\n".utf8)
        static let timeout: TimeInterval = 10
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/threading-components-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fetching

    /// The whole path: an asset is downloaded, both digests are checked, the binary lands
    /// executable under its own identifier, and the second ask costs no download at all.
    func testAVerifiedComponentIsFetchedOnceAndThenReused() throws {
        let asset = try gzippedAsset()
        let component = RemoteHostComponent(
            kind: .daemon,
            architecture: .arm64,
            assetName: asset.name,
            assetSHA256: asset.assetDigest,
            assetByteCount: asset.assetBytes.count,
            sha256: asset.binaryDigest
        )
        let server = StubComponentServer(assets: [asset.name: asset.assetBytes])
        let components = RemoteHostPublishedComponents(session: server.session, root: root)

        var reported: [Double] = []
        let binary = try components.fetch(
            component,
            from: server.url(for: asset.name),
            progress: { reported.append($0) }
        )
        XCTAssertEqual(binary.sha256, asset.binaryDigest)
        XCTAssertEqual(binary.kind, .daemon)
        XCTAssertEqual(try Data(contentsOf: binary.url), Fixture.binary)
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertTrue(binary.url.path.contains(component.installIdentifier),
                      "the cache is named by what is in it: \(binary.url.path)")
        let permissions = try FileManager.default.attributesOfItem(atPath: binary.url.path)[.posixPermissions]
        XCTAssertEqual((permissions as? NSNumber)?.intValue, RemoteHostComponentDefaults.binaryPermissions)
        XCTAssertEqual(reported.sorted(), reported, "progress only moves forward")

        XCTAssertNotNil(components.cachedURL(for: component))
        _ = try components.fetch(component, from: server.url(for: asset.name), progress: { _ in })
        XCTAssertEqual(server.requestCount, 1, "a component already held was downloaded again")
    }

    /// Bytes that are not the bytes this build expects are refused, and nothing is left behind for
    /// a later preparation to pick up as a component.
    func testAnAssetThatIsNotTheExpectedBytesIsRefusedAndLeavesNothing() throws {
        let asset = try gzippedAsset()
        let component = RemoteHostComponent(
            kind: .daemon,
            architecture: .arm64,
            assetName: asset.name,
            assetSHA256: String(repeating: "0", count: 64),
            assetByteCount: asset.assetBytes.count,
            sha256: asset.binaryDigest
        )
        let server = StubComponentServer(assets: [asset.name: asset.assetBytes])
        let components = RemoteHostPublishedComponents(session: server.session, root: root)

        XCTAssertThrowsError(try components.fetch(
            component,
            from: server.url(for: asset.name),
            progress: { _ in }
        )) { error in
            XCTAssertEqual(error as? RemoteHostComponentError, .digestMismatch)
        }
        XCTAssertNil(components.cachedURL(for: component))
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(left, [], "a refused download left \(left)")
    }

    /// A build that published nothing says so in those words, rather than failing as a download.
    func testABuildWithNoPublishedComponentSaysSo() {
        let components = RemoteHostPublishedComponents(session: .shared, root: root)
        XCTAssertThrowsError(try components.binary(.daemon, for: .amd64, progress: { _ in })) { error in
            XCTAssertEqual(error as? RemoteHostComponentError, .unpublished(.amd64))
        }
        XCTAssertEqual(
            RemoteHostComponentError.unpublished(.amd64).errorDescription,
            L10n.format("This build has no Linux components for %@ hosts.", "amd64")
        )
    }

    /// Whichever source is used, a preparation asks the same question. The developer's directory
    /// answers it from a local build.
    func testTheDeveloperDirectoryIsASourceLikeAnyOther() throws {
        let directory = root.appendingPathComponent("arm64", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(RemoteHostDefaults.daemonExecutableName)
        try Fixture.binary.write(to: file)

        let source = RemoteHostDirectoryComponents(directory: root)
        let binary = try source.binary(.daemon, for: .arm64, progress: { _ in })
        XCTAssertEqual(binary.url, file)
        XCTAssertEqual(binary.kind, .daemon)

        XCTAssertThrowsError(try source.binary(.bridge, for: .arm64, progress: { _ in }),
                             "a directory without the bridge has no bridge to give")
    }

    // MARK: - Pruning the host

    /// Every build a host was ever given is tens of megabytes. What runs now is kept; everything
    /// else in the two install roots goes — and a name that is not one of ours is left alone.
    func testPruningKeepsWhatRunsAndRefusesToTouchAnythingElse() throws {
        let script = RemoteHostInstallScripts.pruneScript(keeping: ["aaaabbbbccccdddd", "1111222233334444"])
        XCTAssertTrue(script.contains("keep=\"aaaabbbbccccdddd 1111222233334444\""))

        let home = root.appendingPathComponent("home", isDirectory: true)
        let daemons = home.appendingPathComponent(RemoteHostDefaults.remoteLibraryDirectory, isDirectory: true)
        let bridges = home.appendingPathComponent(RemoteHostDefaults.remoteBridgeLibraryDirectory, isDirectory: true)
        for directory in [
            daemons.appendingPathComponent("aaaabbbbccccdddd"),
            daemons.appendingPathComponent("deadbeefdeadbeef"),
            daemons.appendingPathComponent("notes-from-a-person"),
            bridges.appendingPathComponent("1111222233334444"),
            bridges.appendingPathComponent("5555666677778888")
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: directory.appendingPathComponent("threading-ptyd"))
        }

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script]
        shell.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        try shell.run()
        shell.waitUntilExit()
        XCTAssertEqual(shell.terminationStatus, 0)

        // `bridge` is the bridge's own root, which lives inside the daemon's; the sweep steps over
        // it by name rather than reading it as a stale install.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: daemons.path).sorted(),
                       ["aaaabbbbccccdddd", "bridge", "notes-from-a-person"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bridges.path).sorted(),
                       ["1111222233334444"])
    }

    /// The bridge's own root sits inside the daemon's, so the sweep must never read `bridge` as a
    /// stale install and take every bridge on the host with it.
    func testPruningNeverRemovesTheBridgeRootItself() throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bridges = home.appendingPathComponent(RemoteHostDefaults.remoteBridgeLibraryDirectory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: bridges.appendingPathComponent("1111222233334444"),
            withIntermediateDirectories: true
        )

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", RemoteHostInstallScripts.pruneScript(keeping: ["1111222233334444"])]
        shell.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        try shell.run()
        shell.waitUntilExit()

        XCTAssertTrue(FileManager.default.fileExists(atPath: bridges.appendingPathComponent("1111222233334444").path))
    }

    // MARK: - Helpers

    private func gzippedAsset() throws -> (name: String, assetBytes: Data, assetDigest: String, binaryDigest: String) {
        let plain = root.appendingPathComponent("payload")
        try Fixture.binary.write(to: plain)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-n", "-f", plain.path]
        try gzip.run()
        gzip.waitUntilExit()
        let asset = root.appendingPathComponent("payload.gz")
        let bytes = try Data(contentsOf: asset)
        try FileManager.default.removeItem(at: asset)
        return (
            name: "threading-ptyd-arm64.gz",
            assetBytes: bytes,
            assetDigest: RemoteHostComponentTests.digest(of: bytes),
            binaryDigest: RemoteHostComponentTests.digest(of: Fixture.binary)
        )
    }

    private static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A `URLSession` answering from memory, so the fetch is tested without a network.
private final class StubComponentServer: @unchecked Sendable {
    let session: URLSession
    private let lock = NSLock()
    private var served = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return served
    }

    init(assets: [String: Data]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubComponentProtocol.self]
        session = URLSession(configuration: configuration)
        StubComponentProtocol.assets = assets
        StubComponentProtocol.onRequest = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.served += 1
            self.lock.unlock()
        }
    }

    func url(for name: String) -> URL {
        URL(string: "https://components.invalid/\(name)")!
    }
}

private final class StubComponentProtocol: URLProtocol {
    nonisolated(unsafe) static var assets: [String: Data] = [:]
    nonisolated(unsafe) static var onRequest: (@Sendable () -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.onRequest?()
        let name = request.url?.lastPathComponent ?? ""
        guard let data = Self.assets[name], let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
