import CryptoKit
import Foundation
import XCTest
@testable import Threading

final class NativePluginDistributionTests: XCTestCase {
    func testManifestRequiresSignatureAndExactHostBuild() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let signed = try fixture.signedManifest()
        let distribution = try NativePluginDistribution.verify(signed, for: fixture.app)
        XCTAssertEqual(distribution.plugins.map(\.bundleIdentifier), ["codes.threading.plugin.devicelogs"])
        XCTAssertEqual(distribution.releaseTag, "v2.3.4")
        XCTAssertEqual(
            NativePluginDistribution.manifestURL(for: fixture.app)?.absoluteString,
            "https://github.com/everlof/threading/releases/download/v2.3.4/native-plugins-2.3.4.json"
        )

        try Data("changed host".utf8).write(to: fixture.executable)
        XCTAssertThrowsError(try NativePluginDistribution.verify(signed, for: fixture.app)) { error in
            XCTAssertEqual(error as? NativePluginDistribution.VerificationError, .wrongHostBuild)
        }
    }

    func testTamperedPayloadIsRejectedBeforeItsPluginEntryIsUsed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let data = try fixture.signedManifest()
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        var payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["payload"])))
        payload.append(0x20)
        envelope["payload"] = payload.base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: envelope)

        XCTAssertThrowsError(try NativePluginDistribution.verify(tampered, for: fixture.app)) { error in
            XCTAssertEqual(error as? NativePluginDistribution.VerificationError, .invalidSignature)
        }
    }

    func testSignedManifestCannotRedirectAnArchiveOutsideItsRelease() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signed = try fixture.signedManifest(
            archiveURL: "https://example.com/DeviceLogsPlugin-2.3.4.zip"
        )

        XCTAssertThrowsError(try NativePluginDistribution.verify(signed, for: fixture.app)) { error in
            XCTAssertEqual(error as? NativePluginDistribution.VerificationError, .invalidPluginEntry)
        }
    }

    private struct Fixture {
        let app: URL
        let executable: URL
        let key = Curve25519.Signing.PrivateKey()

        init() throws {
            app = FileManager.default.temporaryDirectory
                .appendingPathComponent("native-plugin-manifest-\(UUID().uuidString)/Threading.app")
            executable = app.appendingPathComponent("Contents/MacOS/Threading")
            let files: [(String, String)] = [
                ("Contents/MacOS/Threading", "host"),
                ("Contents/Frameworks/ThreadingDesignKit.framework/Versions/A/ThreadingDesignKit", "design"),
                ("Contents/Frameworks/ThreadingPluginKit.framework/Versions/A/ThreadingPluginKit", "plugin"),
            ]
            for (path, contents) in files {
                let url = app.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try Data(contents.utf8).write(to: url)
            }
            let plist: [String: String] = [
                "CFBundleIdentifier": "codes.threading",
                "CFBundleVersion": "2.3.4",
                "CFBundleExecutable": "Threading",
                "ThreadingBuildChannel": "release",
                "SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString(),
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
        }

        func remove() {
            try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
        }

        func signedManifest(
            archiveURL: String = "https://github.com/everlof/threading/releases/download/v2.3.4/DeviceLogsPlugin-2.3.4.zip"
        ) throws -> Data {
            let contents = app.appendingPathComponent("Contents")
            let host: [String: String] = [
                "bundleIdentifier": "codes.threading",
                "bundleVersion": "2.3.4",
                "buildChannel": "release",
                "executableSHA256": digest(executable),
                "designKitSHA256": digest(contents.appendingPathComponent(
                    "Frameworks/ThreadingDesignKit.framework/Versions/A/ThreadingDesignKit"
                )),
                "pluginKitSHA256": digest(contents.appendingPathComponent(
                    "Frameworks/ThreadingPluginKit.framework/Versions/A/ThreadingPluginKit"
                )),
            ]
            let plugin: [String: Any] = [
                "bundleIdentifier": "codes.threading.plugin.devicelogs",
                "bundleName": "DeviceLogsPlugin.bundle",
                "codeDirectoryHash": String(repeating: "b", count: 40),
                "archiveURL": archiveURL,
                "archiveSHA256": String(repeating: "a", count: 64),
                "archiveBytes": 123,
            ]
            let payload = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "host": host,
                "releaseTag": "v2.3.4",
                "plugins": [plugin],
            ], options: [.sortedKeys])
            let signature = try key.signature(for: payload)
            return try JSONSerialization.data(withJSONObject: [
                "payload": payload.base64EncodedString(),
                "signature": signature.base64EncodedString(),
            ])
        }

        private func digest(_ file: URL) -> String {
            let bytes = (try? Data(contentsOf: file)) ?? Data()
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }
}
