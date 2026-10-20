import AppKit
import Foundation
import WebKit
import XCTest
@testable import DeviceLogsPlugin

final class BluetoothProfileTests: XCTestCase {
    private func profile(identifier: String = "com.apple.bluetooth.logging", removal: Date? = nil) throws -> Data {
        var value: [String: Any] = [
            "PayloadType": "Configuration", "PayloadIdentifier": identifier,
            "PayloadContent": [["PayloadType": "com.apple.system.logging"]],
        ]
        value["RemovalDate"] = removal
        return try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    func testRejectsOtherProfilesExpiredAndOversizedFiles() throws {
        XCTAssertNoThrow(try BluetoothProfileInstaller.validate(profile()))
        XCTAssertThrowsError(try BluetoothProfileInstaller.validate(profile(identifier: "com.example.vpn")))
        XCTAssertThrowsError(try BluetoothProfileInstaller.validate(Data("<html>Sign in</html>".utf8)))
        XCTAssertThrowsError(try BluetoothProfileInstaller.validate(Data(repeating: 0, count: 1_048_577)))
        XCTAssertThrowsError(try BluetoothProfileInstaller.validate(profile(removal: Date(timeIntervalSince1970: 0)))) {
            XCTAssertEqual($0 as? BluetoothProfileInstaller.Failure, .expiredProfile)
        }
    }

    func testOptionalDownloadedAppleProfileDecodesItsSignedEnvelope() throws {
        guard let path = ProcessInfo.processInfo.environment["THREADING_BLUETOOTH_PROFILE_FIXTURE"] else {
            throw XCTSkip("Opt in with a locally downloaded Apple profile; never redistribute it as a fixture.")
        }
        XCTAssertNoThrow(try BluetoothProfileInstaller.validate(Data(contentsOf: URL(fileURLWithPath: path))))
    }

    func testDownloadAdmitsOnlyAppleHTTPSAndExpectedSmallProfile() throws {
        for raw in ["https://developer.apple.com/", "https://idmsa.apple.com/IDMSWebAuth/signin"] {
            XCTAssertTrue(BluetoothProfileDownloadPolicy.allows(URL(string: raw)))
        }
        for raw in ["http://apple.com/", "https://apple.com.example.com/", "https://evilapple.com/", "file:///tmp/profile", "https://apple.com:8443/", "https://user:secret@apple.com/"] {
            XCTAssertFalse(BluetoothProfileDownloadPolicy.allows(URL(string: raw)), raw)
        }
        func response(_ status: Int, _ size: Int) throws -> HTTPURLResponse {
            try XCTUnwrap(HTTPURLResponse(url: BluetoothProfileInstaller.profileDownloadURL,
                                        statusCode: status, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Length": String(size)]))
        }
        XCTAssertTrue(BluetoothProfileDownloadPolicy.accepts(try response(200, 8_000), filename: "iOSBluetoothLogging.mobileconfig"))
        XCTAssertFalse(BluetoothProfileDownloadPolicy.accepts(try response(403, 8_000), filename: "iOSBluetoothLogging.mobileconfig"))
        XCTAssertFalse(BluetoothProfileDownloadPolicy.accepts(try response(200, 1_048_577), filename: "iOSBluetoothLogging.mobileconfig"))
        XCTAssertFalse(BluetoothProfileDownloadPolicy.accepts(try response(200, 8_000), filename: "other.mobileconfig"))
    }

    func testInstallerPinsPhoneUsesSnapshotAndRemovesStaging() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("downloaded profile.mobileconfig")
        let bytes = try profile()
        try bytes.write(to: input)
        let arguments = directory.appendingPathComponent("args")
        let copied = directory.appendingPathComponent("bytes")
        let device = directory.appendingPathComponent("device")
        let tool = try script(in: directory, body: """
            printf '%s\\n' "$@" > '\(arguments.path)'
            printf '%s' "$PYMOBILEDEVICE3_UDID" > '\(device.path)'
            for arg do selected="$arg"; done
            cat "$selected" > '\(copied.path)'
            """)
        try BluetoothProfileInstaller.install(profileURL: input, deviceID: "exact-phone", preferredToolPath: tool.path).get()
        XCTAssertEqual(try Data(contentsOf: copied), bytes)
        XCTAssertEqual(try String(contentsOf: device), "exact-phone")
        let args = try String(contentsOf: arguments).split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(args.prefix(6)), ["--no-color", "profile", "install", "--udid", "exact-phone", "--"])
        let staged = try XCTUnwrap(args.last)
        XCTAssertNotEqual(staged, input.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: staged).deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
    }

    func testOptionalInstalledToolAcceptsProfileCommandBeforeContactingAPhone() throws {
        guard let tool = ProcessInfo.processInfo.environment["THREADING_BLUETOOTH_PROFILE_TOOL_FIXTURE"] else {
            throw XCTSkip("Set THREADING_BLUETOOTH_PROFILE_TOOL_FIXTURE to check the installed CLI parser.")
        }
        var arguments = BluetoothProfileInstaller.arguments(
            deviceID: "threading-test-no-device", profilePath: "/unused/synthetic.mobileconfig"
        )
        // Help exits in the real parser before device discovery or profile installation. Keep
        // every production option before it: a fake executable cannot catch misplaced flags.
        arguments.insert("--help", at: arguments.count - 2)
        let result = try XCTUnwrap(BoundedDeviceLogCommand.runResult(
            tool, arguments, deadline: 15, includeStandardError: true, maximumOutputBytes: 32_768
        ))
        XCTAssertEqual(result.exitStatus, 0, result.output)
        XCTAssertTrue(result.output.contains("PROFILES"))
    }

    func testInstallerReportsRejectionAndBoundsSilentChild() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("profile.mobileconfig")
        try profile().write(to: input)
        let tool = try script(in: directory, body: "echo 'Device is locked' >&2\nexit 7")
        let rejected = BluetoothProfileInstaller.install(profileURL: input, deviceID: "phone", preferredToolPath: tool.path)
        XCTAssertThrowsError(try rejected.get()) {
            XCTAssertEqual($0 as? BluetoothProfileInstaller.Failure, .rejected("Device is locked"))
        }
        _ = try script(in: directory, body: "exec /bin/sleep 30")
        let start = Date()
        let timedOut = BluetoothProfileInstaller.install(profileURL: input, deviceID: "phone", preferredToolPath: tool.path, deadline: 0.1)
        XCTAssertThrowsError(try timedOut.get()) {
            XCTAssertEqual($0 as? BluetoothProfileInstaller.Failure, .incomplete)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    @MainActor
    func testAuthBrowserUsesInjectedStoreHasNoScriptsAndCancellationSettlesOnce() throws {
        var completions = 0
        let browser = BluetoothProfileDownloadView(dataStore: .nonPersistent()) { result in
            completions += 1
            guard case .failure = result else { return XCTFail("cancel must never hand off a file") }
        }
        func findWebView(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(findWebView).first
        }
        let web = try XCTUnwrap(findWebView(browser))
        XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(web.configuration.userContentController.userScripts.isEmpty)
        // Catch optional delegate methods which compile but don't match WebKit's actor contract.
        XCTAssertTrue(browser.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")))
        XCTAssertTrue(browser.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationResponse:decisionHandler:")))
        XCTAssertTrue(browser.responds(to: NSSelectorFromString("download:willPerformHTTPRedirection:newRequest:decisionHandler:")))
        browser.cancel()
        browser.cancel()
        XCTAssertEqual(completions, 1)
        XCTAssertNil(web.navigationDelegate)
    }

    @MainActor
    func testOptionalAppleDownloadRedirectLoadsSignIn() async throws {
        guard ProcessInfo.processInfo.environment["THREADING_BLUETOOTH_AUTH_LIVE"] == "1" else {
            throw XCTSkip("Opt in to contact Apple's real sign-in page without entering credentials.")
        }
        var failure: Error?
        let browser = BluetoothProfileDownloadView(dataStore: .nonPersistent()) { result in
            if case .failure(let error) = result { failure = error }
        }
        defer { browser.cancel() }
        func findWebView(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(findWebView).first
        }
        let web = try XCTUnwrap(findWebView(browser))
        browser.start()
        let deadline = Date().addingTimeInterval(30)
        repeat {
            try await Task.sleep(nanoseconds: 100_000_000)
        } while failure == nil && (web.isLoading || web.url?.host != "idmsa.apple.com") && Date() < deadline
        XCTAssertNil(failure)
        XCTAssertEqual(web.url?.host, "idmsa.apple.com")
        XCTAssertFalse(web.isLoading)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func script(in directory: URL, body: String) throws -> URL {
        let url = directory.appendingPathComponent("fake-installer")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
