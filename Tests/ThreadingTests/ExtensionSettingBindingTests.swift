import AppKit
import Metal
import ThreadingExtensionKit
import ThreadingRemoteKit
import XCTest
import os
@testable import Threading

/// Setting-bound surface inputs on the host: a shader input answered from the extension's own
/// settings store with no process round trip, a host-applied field that a render-only extension
/// never has to acknowledge, refusal at publication, and the constant the phone receives instead.
@MainActor
final class ExtensionSettingBindingTests: XCTestCase {

    private var cleanupURLs: [URL] = []
    /// A fixture `ExtensionManager` writes the shared settings registry from its initializer and
    /// the shared appearance registry on every enablement change; this puts both back.
    private var hostedState: HostedExtensionStateGuard?

    override func setUp() async throws {
        try await super.setUp()
        hostedState = HostedExtensionStateGuard()
    }

    override func tearDown() async throws {
        hostedState?.restore()
        hostedState = nil
        cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        cleanupURLs.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private static let identifier = "com.example.installed-test"

    private let comets = ExtensionSettingField(
        id: "perimeter-comets",
        title: "Perimeter comets",
        control: .toggle(defaultValue: true),
        appliedBy: .host
    )

    private let density = ExtensionSettingField(
        id: "density",
        title: "Density",
        control: .choice(
            defaultValue: "normal",
            options: [
                .init(id: "sparse", title: "Sparse", value: 0.2),
                .init(id: "normal", title: "Normal", value: 0.6),
                .init(id: "storm", title: "Storm", value: 1)
            ]
        ),
        appliedBy: .host
    )

    private let speed = ExtensionSettingField(
        id: "speed",
        title: "Speed",
        control: .integer(defaultValue: 40, minimum: 0, maximum: 100, step: 5),
        appliedBy: .host
    )

    /// Red, green and blue are the first three inputs, so a pixel reads three bindings at once.
    private static let colourFromInputs = """
    float4 threadingExtensionFragment(
        float2 uv,
        constant ThreadingSurfaceUniforms &uniforms
    ) {
        return float4(uniforms.values[0], uniforms.values[1], uniforms.values[2], 1.0);
    }
    """

    private func requireMetal() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
    }

    private func pixel(_ surface: ExtensionMetalSurfaceView) throws -> SurfaceSnapshotPixels.RGBA {
        let image = try XCTUnwrap(surface.snapshotImage(size: NSSize(width: 4, height: 4), time: 0))
        return try SurfaceSnapshotPixels.rgba(in: image, x: 1, y: 1)
    }

    private func temporaryDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ThreadingSettingBinding-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        cleanupURLs.append(url)
        return url
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// A native shell fixture that records every request line it reads and answers a settings
    /// request only when `answeringSettingIDs` names what to echo — a render-only extension
    /// passes none and never answers at all.
    private func makePackage(
        settings: ExtensionSettingsContribution,
        answeringSettingIDs: [String] = []
    ) throws -> URL {
        let root = temporaryDirectory("source")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let manifest = ExtensionManifest(
            identifier: Self.identifier,
            name: "Installed Test",
            version: "1.0.0",
            runtime: .native,
            executable: "bin/extension",
            capabilities: [.settings, .keyValueStorage],
            settings: settings
        )
        try manifest.validate()
        try JSONEncoder().encode(manifest).write(
            to: root.appendingPathComponent(ExtensionBundleInspector.manifestName)
        )
        let registration = String(
            decoding: try JSONEncoder().encode(ExtensionRegistration()),
            as: UTF8.self
        )
        let answer: String
        if answeringSettingIDs.isEmpty {
            answer = ":"
        } else {
            let ids = String(decoding: try JSONEncoder().encode(answeringSettingIDs), as: UTF8.self)
            answer = """
                request_id=${line#*\\"requestID\\":\\"}
                  request_id=${request_id%%\\"*}
                  printf '{"protocolVersion":1,"requestID":"%s","settingIDs":%s}\\n' "$request_id" \(shellQuoted(ids))
                """
        }
        let script = """
            #!/bin/sh
            case "$1" in
              --threading-register)
                printf '%s' \(shellQuoted(registration))
                ;;
              --threading-serve)
                printf '%s\\n' \(shellQuoted(registration))
                while IFS= read -r line; do
                  printf '%s\\n' "$line" >> "$THREADING_EXTENSION_KEY_VALUE_DIRECTORY/requests.jsonl"
                  \(answer)
                done
                ;;
              *)
                exit 64
                ;;
            esac
            """
        let executable = bin.appendingPathComponent("extension")
        try Data((script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return root
    }

    private func runningManager(
        settings: ExtensionSettingsContribution,
        answeringSettingIDs: [String] = []
    ) async throws -> (ExtensionManager, ExtensionPackageStore) {
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("store"))
        _ = try store.install(from: makePackage(
            settings: settings,
            answeringSettingIDs: answeringSettingIDs
        ))
        let manager = ExtensionManager(store: store)
        try manager.setEnabled(true, identifier: Self.identifier)
        let running = await waitUntil {
            if case .running = manager.installedExtensions.first?.status { return true }
            return false
        }
        XCTAssertTrue(running, "the fixture extension did not start")
        return (manager, store)
    }

    private func set(
        _ value: ExtensionJSONValue,
        _ field: ExtensionSettingField,
        on manager: ExtensionManager
    ) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            manager.setSetting(
                extensionIdentifier: Self.identifier,
                settingID: field.id,
                value: value
            ) { continuation.resume(returning: $0) }
        }
    }

    private func requestLog(_ store: ExtensionPackageStore) -> String? {
        try? String(
            contentsOf: store.storageStore.dataDirectory(for: Self.identifier)
                .appendingPathComponent("requests.jsonl"),
            encoding: .utf8
        )
    }

    // MARK: - Resolution on the surface

    /// A toggle, a valued choice and a mapped integer each reach their uniform, and a change
    /// is read once, when the notification says so — not per frame.
    func testSettingBindingsResolveFromTheProviderAndRefreshOnlyOnAChange() async throws {
        try requireMetal()
        var values: [String: Double] = ["perimeter-comets": 1, "density": 0.6, "speed": 40]
        var reads = 0
        let surface = try ExtensionMetalSurfaceView(
            specification: ExtensionMetalSurface(
                shaderResource: "Resources/rain.metal",
                inputs: [
                    .init(name: "comets", value: .setting("perimeter-comets", mapping: .identity)),
                    .init(name: "density", value: .setting("density", mapping: .identity)),
                    .init(name: "speed", value: .setting("speed", mapping: .init(inputMaximum: 100)))
                ]
            ),
            source: Self.colourFromInputs,
            signalProvider: { _, _ in nil },
            settingProvider: { fieldID in
                reads += 1
                return values[fieldID]
            }
        )
        try await surface.waitForPreparation()
        XCTAssertEqual(reads, 3, "each bound field is read once at mount")

        var colour = try pixel(surface)
        XCTAssertEqual(colour.red, 1, accuracy: 0.02)
        XCTAssertEqual(colour.green, 0.6, accuracy: 0.02)
        XCTAssertEqual(colour.blue, 0.4, accuracy: 0.02)
        _ = try pixel(surface)
        XCTAssertEqual(reads, 3, "a frame reads the cache, never the provider")

        values = ["perimeter-comets": 0, "density": 0.2, "speed": 85]
        XCTAssertEqual(try pixel(surface).red, 1, accuracy: 0.02, "nothing re-reads without a change")
        NotificationCenter.default.post(ExtensionSettingsValuesDidChange())
        colour = try pixel(surface)
        XCTAssertEqual(colour.red, 0, accuracy: 0.02)
        XCTAssertEqual(colour.green, 0.2, accuracy: 0.02)
        XCTAssertEqual(colour.blue, 0.85, accuracy: 0.02)
        XCTAssertEqual(reads, 6)
    }

    /// A field the provider cannot answer reads the binding's fallback, and a surface with no
    /// setting binding never asks the provider at all.
    func testAnUnreadableSettingReadsTheFallbackAndUnboundSurfacesNeverAsk() async throws {
        try requireMetal()
        let fallback = try ExtensionMetalSurfaceView(
            specification: ExtensionMetalSurface(
                shaderResource: "Resources/rain.metal",
                inputs: [.init(name: "x", value: .setting("gone", mapping: .init(fallback: 0.7)))]
            ),
            source: Self.colourFromInputs,
            signalProvider: { _, _ in nil },
            settingProvider: { _ in nil }
        )
        try await fallback.waitForPreparation()
        XCTAssertEqual(try pixel(fallback).red, 0.7, accuracy: 0.02)

        var asked = false
        let unbound = try ExtensionMetalSurfaceView(
            specification: ExtensionMetalSurface(
                shaderResource: "Resources/rain.metal",
                inputs: [.init(name: "x", value: .constant(0.5))]
            ),
            source: Self.colourFromInputs,
            signalProvider: { _, _ in nil },
            settingProvider: { _ in asked = true; return 1 }
        )
        try await unbound.waitForPreparation()
        NotificationCenter.default.post(ExtensionSettingsValuesDidChange())
        XCTAssertEqual(try pixel(unbound).red, 0.5, accuracy: 0.02)
        XCTAssertFalse(asked)
    }

    // MARK: - The store and the process

    /// The render-only pattern end to end: an extension whose process never answers a request
    /// owns a host-applied toggle. Flipping it persists, flips the mounted surface's uniform,
    /// sends the process nothing, and leaves it running — no rollback, no stop.
    func testAHostAppliedToggleFlipsAMountedSurfaceWithoutAnyProcessRequest() async throws {
        try requireMetal()
        let settings = ExtensionSettingsContribution(sections: [
            .init(id: "rain", page: .themes, title: "Rain", fields: [comets, density, speed])
        ])
        let (manager, store) = try await runningManager(settings: settings)
        defer { manager.terminateAll() }

        let surface = try ExtensionMetalSurfaceView(
            specification: ExtensionMetalSurface(
                shaderResource: "Resources/rain.metal",
                inputs: [
                    .init(name: "comets", value: .setting("perimeter-comets", mapping: .identity)),
                    .init(name: "density", value: .setting("density", mapping: .identity)),
                    .init(name: "speed", value: .setting("speed", mapping: .init(inputMaximum: 100)))
                ]
            ),
            source: Self.colourFromInputs,
            signalProvider: { _, _ in nil },
            settingProvider: {
                manager.surfaceSettingReading(extensionIdentifier: Self.identifier, fieldID: $0)
            }
        )
        try await surface.waitForPreparation()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView?.addSubview(surface)
        defer { surface.removeFromSuperview() }

        var colour = try pixel(surface)
        XCTAssertEqual(colour.red, 1, accuracy: 0.02, "the toggle's default is on")
        XCTAssertEqual(colour.green, 0.6, accuracy: 0.02, "the default option's value")
        XCTAssertEqual(colour.blue, 0.4, accuracy: 0.02)

        try await set(.bool(false), comets, on: manager).get()
        try await set(.string("storm"), density, on: manager).get()
        try await set(.integer(85), speed, on: manager).get()
        colour = try pixel(surface)
        XCTAssertEqual(colour.red, 0, accuracy: 0.02, "the toggle flipped the uniform")
        XCTAssertEqual(colour.green, 1, accuracy: 0.02)
        XCTAssertEqual(colour.blue, 0.85, accuracy: 0.02)

        XCTAssertEqual(
            manager.settingValue(extensionIdentifier: Self.identifier, field: comets),
            .bool(false),
            "a host-applied value is persisted, not rolled back"
        )
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(requestLog(store), "no request — not even the launch sync — reached the process")
        guard case .running = manager.installedExtensions.first?.status else {
            return XCTFail("the extension was stopped over a request it was never sent")
        }
    }

    /// A hybrid extension keeps its process-applied fields: the launch sync and a change carry
    /// those, and never the host-applied ones beside them.
    func testOnlyProcessAppliedFieldsReachAHybridExtensionsProcess() async throws {
        let refresh = ExtensionSettingField(
            id: "refresh",
            title: "Refresh on launch",
            control: .toggle(defaultValue: false)
        )
        let settings = ExtensionSettingsContribution(sections: [
            .init(id: "mixed", page: .general, fields: [comets, refresh])
        ])
        let (manager, store) = try await runningManager(
            settings: settings,
            answeringSettingIDs: [refresh.id]
        )
        defer { manager.terminateAll() }

        let synced = await waitUntil { self.requestLog(store)?.contains(#""refresh":false"#) == true }
        XCTAssertTrue(synced, "the process-applied field was not synced at launch")
        try await set(.bool(false), comets, on: manager).get()
        try await set(.bool(true), refresh, on: manager).get()

        let log = try XCTUnwrap(requestLog(store))
        XCTAssertTrue(log.contains(#""refresh":true"#))
        XCTAssertFalse(log.contains("perimeter-comets"), "a host-applied field reached the process: \(log)")
        XCTAssertEqual(manager.surfaceSettingReading(extensionIdentifier: Self.identifier, fieldID: comets.id), 0)
        XCTAssertNil(
            manager.surfaceSettingReading(extensionIdentifier: Self.identifier, fieldID: "missing"),
            "an undeclared field has no reading"
        )
    }

    // MARK: - Publication

    /// The host checks a binding against the publisher's own manifest settings: a declared
    /// numeric field is accepted, an undeclared or text field is refused with a reason.
    func testPublicationRefusesBindingsTheExtensionsSettingsCannotAnswer() throws {
        let caption = ExtensionSettingField(
            id: "caption",
            title: "Caption",
            control: .text(defaultValue: "", placeholder: nil, maximumLength: 20)
        )
        let settings = ExtensionSettingsContribution(sections: [
            .init(id: "rain", page: .themes, fields: [comets, caption])
        ])
        let registry = ComponentCustomizationRegistry()
        try registry.register(HostComponentContracts.sidebarBackdrop)
        let service = ExtensionHostService(
            registry: registry,
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1"))
        )
        let authorized = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.matrix",
            processGeneration: "one",
            order: 0,
            capabilities: [.componentCustomization, .customMetalSurfaces],
            settings: settings
        ))
        let bare = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.bare",
            processGeneration: "one",
            order: 0,
            capabilities: [.componentCustomization, .customMetalSurfaces]
        ))

        func publication(binding fieldID: String) -> ExtensionComponentPatchPublication {
            ExtensionComponentPatchPublication(patches: [ExtensionComponentPatch(
                id: "rain",
                target: .sidebarBackdrop(),
                hook: .overlay(
                    base: .customSurface(
                        .metal(ExtensionMetalSurface(
                            shaderResource: "Resources/rain.metal",
                            preferredFramesPerSecond: 24,
                            inputs: [.init(name: "x", value: .setting(fieldID, mapping: .identity))]
                        )),
                        accessibilityLabel: nil
                    ),
                    overlay: .proceed
                )
            )])
        }

        XCTAssertEqual(route(publication(binding: comets.id), token: authorized, through: service).status, 204)
        let undeclared = route(publication(binding: "missing"), token: authorized, through: service)
        XCTAssertEqual(undeclared.status, 422)
        XCTAssertTrue(String(decoding: undeclared.body, as: UTF8.self).contains("do not declare"))
        let text = route(publication(binding: caption.id), token: authorized, through: service)
        XCTAssertEqual(text.status, 422)
        XCTAssertTrue(String(decoding: text.body, as: UTF8.self).contains("text field"))
        XCTAssertEqual(
            route(publication(binding: comets.id), token: bare, through: service).status,
            422,
            "another extension's settings — or none — answer nothing"
        )
    }

    private func route(
        _ publication: ExtensionComponentPatchPublication,
        token authorization: ExtensionHostAuthorization,
        through service: ExtensionHostService
    ) -> HTTPResponse {
        let result = OSAllocatedUnfairLock<HTTPResponse?>(initialState: nil)
        service.route(
            HTTPRequest(
                method: "PUT",
                path: "/v1/component-patches",
                headers: [
                    "authorization": "Bearer \(authorization.connection.bearerToken)",
                    "content-type": "application/json",
                ],
                body: try! JSONEncoder().encode(publication)
            )
        ) { response in result.withLock { $0 = response } }
        return result.withLock { $0! }
    }

    // MARK: - The phone

    /// The phone has no access to the Mac's settings: a setting binding crosses the wire as the
    /// constant the Mac reads now, mapped exactly as the Mac maps it, and a surface still
    /// carrying a setting is not a valid projection.
    func testThePhoneReceivesTheSettingAsTheConstantTheMacReads() throws {
        let specification = ExtensionMetalSurface(
            shaderResource: "Resources/rain.metal",
            preferredFramesPerSecond: 24,
            inputs: [
                .init(name: "comets", value: .setting("perimeter-comets", mapping: .identity)),
                .init(name: "speed", value: .setting("speed", mapping: .init(inputMaximum: 100))),
                .init(name: "gone", value: .setting("gone", mapping: .init(fallback: 0.3))),
                .init(name: "dark", value: .signal(.themeDark, mapping: .identity)),
                .init(name: "fixed", value: .constant(0.25))
            ],
            texture: "Resources/rain.png"
        )
        let readings: [String: Double] = ["perimeter-comets": 0, "speed": 85]
        let resolved = RemoteThemeAssets.resolvingSettingInputs(specification) { readings[$0] }

        XCTAssertEqual(resolved.inputs.map(\.name), specification.inputs.map(\.name))
        XCTAssertEqual(resolved.inputs[0].value, .constant(0))
        XCTAssertEqual(resolved.inputs[1].value, .constant(0.85))
        XCTAssertEqual(resolved.inputs[2].value, .constant(0.3), "an unreadable field projects its fallback")
        XCTAssertEqual(resolved.inputs[3].value, specification.inputs[3].value, "signals stay live on the phone")
        XCTAssertEqual(resolved.inputs[4].value, .constant(0.25))
        XCTAssertEqual(resolved.texture, specification.texture)
        XCTAssertTrue(resolved.boundSettingIDs.isEmpty)

        let digest = String(repeating: "a", count: 64)
        XCTAssertFalse(RemoteThemeSurface(sourceDigest: digest, specification: specification).isValid)
        XCTAssertTrue(RemoteThemeSurface(sourceDigest: digest, specification: resolved).isValid)
    }
}
