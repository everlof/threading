import AppKit
import Metal
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// Pins the first extension boundary end to end: an SDK value tree enters the app, and only
/// Threading-owned, themed controls leave the renderer.
@MainActor
final class ExtensionRendererTests: XCTestCase {

    override func tearDown() {
        AppThemeLibrary.apply(.system)
        AppThemePalette.set(.system)
        super.tearDown()
    }

    func testFixtureIsAValidExtensionContract() throws {
        XCTAssertNoThrow(try ExtensionExperimentFixture.manifest.validate())
        XCTAssertNoThrow(
            try ExtensionExperimentFixture.registration.validate(
                for: ExtensionExperimentFixture.manifest
            )
        )
    }

    func testRendererProducesAThemeSafeTreeAndRoutesActionsByIdentifier() throws {
        var actions: [String] = []
        let panel = try XCTUnwrap(ExtensionExperimentFixture.registration.panels.first)
        let host = try ExtensionNodeRenderer.render(panel.root) { actions.append($0) }

        XCTAssertEqual(ThemeBoundaryAudit.violations(in: host), [])

        let buttons = descendants(in: host).compactMap { $0 as? ThemedButton }
        let refresh = try XCTUnwrap(
            buttons.first { $0.accessibilityIdentifier() == "extension.action.refresh" }
        )
        let remove = try XCTUnwrap(
            buttons.first { $0.accessibilityIdentifier() == "extension.action.remove" }
        )
        let unavailable = try XCTUnwrap(
            buttons.first { $0.accessibilityIdentifier() == "extension.action.unavailable" }
        )

        XCTAssertTrue(refresh.isProminent)
        XCTAssertTrue(remove.isEnabled)
        XCTAssertFalse(unavailable.isEnabled)

        refresh.performClick()
        remove.performClick()
        unavailable.performClick()

        XCTAssertEqual(actions, ["refresh", "remove"])
    }

    func testRendererCoversEverySemanticLeaf() throws {
        let node = ExtensionNode.stack(
            axis: .vertical,
            spacing: .small,
            children: [
                .text("Heading", role: .heading),
                .text("Body", role: .body),
                .text("Detail", role: .detail),
                .text("let answer = 42", role: .code),
                .status("Neutral", role: .neutral),
                .status("Positive", role: .positive),
                .status("Warning", role: .warning),
                .status("Negative", role: .negative),
                .spacer(.tight),
                .divider
            ]
        )

        let host = try ExtensionNodeRenderer.render(node) { _ in }
        let identifiers = Set(
            descendants(in: host).compactMap { $0.accessibilityIdentifier() }
        )

        XCTAssertTrue(identifiers.contains("extension.text.heading"))
        XCTAssertTrue(identifiers.contains("extension.text.body"))
        XCTAssertTrue(identifiers.contains("extension.text.detail"))
        XCTAssertTrue(identifiers.contains("extension.text.code"))
        XCTAssertTrue(identifiers.contains("extension.status"))
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: host), [])
    }

    /// A summary keeps a compact surface compact; the second level is drawn only once the host
    /// reveals it, on a surface of the host's own.
    func testDisclosureKeepsItsDetailOffTheRowUntilTheHostRevealsIt() throws {
        let node = ExtensionNode.disclosure(
            id: "ci-checks",
            summary: .stack(
                axis: .horizontal,
                spacing: .small,
                children: [
                    .text("Checks", role: .compactDetail),
                    .flexibleSpacer,
                    .status("3 pending", role: .warning)
                ]
            ),
            detail: [
                .stack(
                    axis: .horizontal,
                    spacing: .small,
                    children: [
                        .text("build-ananke", role: .compactBody),
                        .flexibleSpacer,
                        .status("Running", role: .warning)
                    ]
                ),
                .button(id: "rerun", title: "Re-run", role: .standard, isEnabled: true)
            ]
        )

        var actions: [String] = []
        let host = try ExtensionNodeRenderer.render(node) { actions.append($0) }

        XCTAssertEqual(ThemeBoundaryAudit.violations(in: host), [])
        let disclosure = try XCTUnwrap(
            descendants(in: host).compactMap { $0 as? ExtensionDisclosureNodeView }.first
        )
        XCTAssertEqual(disclosure.accessibilityIdentifier(), "extension.disclosure.ci-checks")
        XCTAssertEqual(disclosure.accessibilityRole(), .button)
        XCTAssertFalse(disclosure.isAccessibilityExpanded())

        // The summary is in the row; nothing the detail says is.
        let rowText = descendants(in: host)
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(rowText.contains("Checks"))
        XCTAssertFalse(
            rowText.contains("build-ananke"),
            "the second level was drawn into the compact row"
        )
        XCTAssertNil(disclosure.detailContent)
        XCTAssertFalse(disclosure.isRevealed)
    }

    /// The revealed level is the one place a corner-card contribution may act, so the button it
    /// carries has to still reach the extension. It does because both levels are rendered in one
    /// pass by the host view that owns the action bridge — AppKit's `target` is weak, and a
    /// detail built by anything else hands back buttons whose action goes nowhere.
    func testDisclosureDetailKeepsTheHostActionBridge() throws {
        let node = ExtensionNode.disclosure(
            id: "ci-checks",
            summary: .status("3 pending", role: .warning),
            detail: [
                .button(id: "rerun", title: "Re-run", role: .standard, isEnabled: true)
            ]
        )

        var actions: [String] = []
        let host = try ExtensionNodeRenderer.render(node) { actions.append($0) }
        let disclosure = try XCTUnwrap(
            descendants(in: host).compactMap { $0 as? ExtensionDisclosureNodeView }.first
        )

        // Built with the summary rather than at reveal time, so the bridge is already live.
        let button = try XCTUnwrap(
            disclosure.detailViewsForTesting
                .flatMap { [$0] + descendants(in: $0) }
                .compactMap { $0 as? ThemedButton }
                .first { $0.accessibilityIdentifier() == "extension.action.rerun" }
        )
        button.performClick()

        XCTAssertEqual(actions, ["rerun"])
    }

    /// What the reveal puts on screen, asserted without one: the surface carries the extension's
    /// rows, a bounded width, a scroller for a list that outgrows a popover, and the hover
    /// bridge that lets the pointer cross into it — the detail is the one level that can carry
    /// a button, and a surface that closes as you reach for it would make that button a lie.
    func testDisclosureDetailSurfaceIsBoundedScrollableAndHoverBridged() throws {
        let rows = (0..<30).map { index in
            ExtensionNode.text("check-\(index)", role: .compactBody)
        }
        let node = ExtensionNode.disclosure(
            id: "ci-checks",
            summary: .status("30 pending", role: .warning),
            detail: rows
        )

        let host = try ExtensionNodeRenderer.render(node) { _ in }
        let disclosure = try XCTUnwrap(
            descendants(in: host).compactMap { $0 as? ExtensionDisclosureNodeView }.first
        )

        let surface = disclosure.makeDetailSurface().view
        surface.layoutSubtreeIfNeeded()
        let inside = descendants(in: surface)

        XCTAssertEqual(
            surface.fittingSize.width,
            ExtensionDisclosureDefaults.contentWidth + 2 * Design.Spacing.inset,
            accuracy: 0.5
        )
        let scroll = try XCTUnwrap(inside.compactMap { $0 as? ThemedScrollView }.first)
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertLessThanOrEqual(
            scroll.frame.height,
            ExtensionDisclosureDefaults.maximumContentHeight,
            "a second level grew past the height a popover should have"
        )
        XCTAssertNotNil(
            inside.first { $0 is HoverTrackingView } ?? (surface as? HoverTrackingView),
            "nothing bridges the pointer from the row into what it opened"
        )

        let drawn = Set(inside.compactMap { ($0 as? NSTextField)?.stringValue })
        XCTAssertTrue(drawn.contains("check-0"))
        XCTAssertTrue(drawn.contains("check-29"))
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: surface), [])
    }

    func testRendererSupportsCompactHStackImagesAndFlexibleSpace() throws {
        let node = ExtensionNode.stack(
            axis: .horizontal,
            spacing: .small,
            children: [
                .image(
                    .hostAsset("provider.codex"),
                    role: .identity,
                    accessibilityLabel: "Codex"
                ),
                .text("Deploy production", role: .compactBody),
                .flexibleSpacer,
                .status("CI passed", role: .positive)
            ]
        )

        var resolvedReferences: [ExtensionImageReference] = []
        let host = try ExtensionNodeRenderer.render(
            node,
            imageResolver: { reference in
                resolvedReferences.append(reference)
                return NSImage(size: NSSize(width: 32, height: 32))
            },
            onAction: { _ in }
        )
        let allViews = descendants(in: host)

        XCTAssertEqual(resolvedReferences, [.hostAsset("provider.codex")])
        XCTAssertNotNil(
            allViews.first {
                $0.accessibilityIdentifier() == "extension.image.identity"
            } as? NSImageView
        )
        let compact = try XCTUnwrap(
            allViews.first {
                $0.accessibilityIdentifier() == "extension.text.compactBody"
            } as? NSTextField
        )
        XCTAssertEqual(compact.maximumNumberOfLines, 1)
        XCTAssertEqual(compact.lineBreakMode, .byTruncatingTail)

        let spacer = try XCTUnwrap(
            allViews.first {
                $0.accessibilityIdentifier() == "extension.flexible-spacer"
            }
        )
        XCTAssertEqual(
            spacer.contentHuggingPriority(for: .horizontal),
            .defaultLow
        )
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: host), [])
    }

    func testRegistryLayersFamilyAndEntityPatchesWithoutIPC() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = sessionRowContract()
        try registry.register(contract)

        try registry.replacePatches(
            [
                ExtensionComponentPatch(
                    id: "family",
                    target: .init(
                        component: contract.id,
                        contractVersion: contract.version
                    ),
                    properties: [
                        .init(property: .title, value: .text("All sessions"))
                    ],
                    slots: [
                        .init(
                            slot: "after-title",
                            children: [.status("CI", role: .neutral)]
                        )
                    ],
                    replacement: .text("Family renderer", role: .compactBody)
                )
            ],
            from: .init(
                extensionIdentifier: "com.example.ci",
                processGeneration: "one",
                order: 0
            )
        )
        try registry.replacePatches(
            [
                ExtensionComponentPatch(
                    id: "entity",
                    target: .init(
                        component: contract.id,
                        contractVersion: contract.version,
                        entityID: "session-42"
                    ),
                    properties: [
                        .init(property: .title, value: .text("Deploy production"))
                    ],
                    slots: [
                        .init(
                            slot: "after-title",
                            children: [.status("Passed", role: .positive)]
                        )
                    ]
                )
            ],
            from: .init(
                extensionIdentifier: "com.example.entity",
                processGeneration: "one",
                order: 1
            )
        )

        let resolution = registry.customization(
            for: .init(
                component: contract.id,
                contractVersion: contract.version,
                entityID: "session-42"
            )
        )

        XCTAssertEqual(
            resolution.properties[.title],
            .text("Deploy production")
        )
        XCTAssertEqual(
            resolution.slots["after-title"],
            [
                .status("CI", role: .neutral),
                .status("Passed", role: .positive)
            ]
        )
        XCTAssertEqual(
            resolution.replacement,
            .text("Family renderer", role: .compactBody)
        )
        XCTAssertEqual(
            resolution.replacementExtensionIdentifier,
            "com.example.ci"
        )
    }

    func testTokenizedHostPublicationIsAtomicAndRevokedWithItsGeneration() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = sessionRowContract()
        try registry.register(contract)
        let service = ExtensionHostService(
            registry: registry,
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1"))
        )
        let authorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.ci",
            processGeneration: "generation-one",
            order: 0,
            capabilities: [.componentCustomization]
        ))
        let target = ExtensionComponentTarget(
            component: contract.id,
            contractVersion: contract.version,
            entityID: "session-42"
        )
        let accepted = ExtensionComponentPatchPublication(patches: [
            .init(
                id: "ci",
                target: target,
                slots: [
                    .init(
                        slot: "after-title",
                        children: [.status("Passed", role: .positive)]
                    )
                ]
            )
        ])

        let acceptedResponse = route(
            accepted,
            token: authorization.connection.bearerToken,
            through: service
        )
        XCTAssertEqual(acceptedResponse.status, 204)
        XCTAssertEqual(
            registry.customization(for: target).slots["after-title"],
            [.status("Passed", role: .positive)]
        )

        let invalid = ExtensionComponentPatchPublication(patches: [
            .init(
                id: "invalid",
                target: target,
                slots: [
                    .init(
                        slot: "private-slot",
                        children: [.status("Wrong", role: .negative)]
                    )
                ]
            )
        ])
        XCTAssertEqual(
            route(
                invalid,
                token: authorization.connection.bearerToken,
                through: service
            ).status,
            422
        )
        XCTAssertEqual(
            registry.customization(for: target).slots["after-title"],
            [.status("Passed", role: .positive)],
            "an invalid replacement publication must leave the old accepted value intact"
        )

        service.revoke(
            extensionIdentifier: "com.example.ci",
            processGeneration: "generation-one"
        )
        XCTAssertTrue(registry.customization(for: target).isEmpty)
        XCTAssertEqual(
            route(
                accepted,
                token: authorization.connection.bearerToken,
                through: service
            ).status,
            401,
            "a stopped generation's bearer token must be unusable"
        )
    }

    func testTheHostAnswersAnInheritedSocketWithTheSameRouterAsLoopback() async throws {
        let registry = ComponentCustomizationRegistry()
        let contract = sessionRowContract()
        try registry.register(contract)
        let service = ExtensionHostService(
            registry: registry,
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1"))
        )

        let authorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.ci",
            processGeneration: "generation-one",
            order: 0,
            capabilities: [.componentCustomization],
            transport: .descriptor
        ))
        let childDescriptor = try XCTUnwrap(authorization.childDescriptor)
        defer {
            ExtensionHostDescriptorTransport.forget(descriptor: childDescriptor)
            close(childDescriptor)
        }

        // A descriptor-mode extension is told a descriptor and nothing else. Handing it a port
        // as well would defeat the reason the runner variant holds no network entitlement.
        XCTAssertEqual(
            authorization.environment[ExtensionHostConnection.descriptorEnvironmentKey],
            String(ExtensionHostDescriptorConnection.childDescriptorNumber)
        )
        XCTAssertNil(authorization.environment[ExtensionHostConnection.urlEnvironmentKey])

        let target = ExtensionComponentTarget(
            component: contract.id,
            contractVersion: contract.version,
            entityID: "session-42"
        )
        let client = ExtensionHostClient(connection: ExtensionHostConnection(
            baseURL: ExtensionHostConnection.descriptorBaseURL,
            bearerToken: authorization.connection.bearerToken,
            descriptor: childDescriptor
        ))

        try await client.publishComponentPatches([
            .init(
                id: "ci",
                target: target,
                slots: [
                    .init(
                        slot: "after-title",
                        children: [.status("Passed", role: .positive)]
                    )
                ]
            )
        ])
        XCTAssertEqual(
            registry.customization(for: target).slots["after-title"],
            [.status("Passed", role: .positive)]
        )

        // The socket is kept open across calls, so a second exchange must pair correctly with
        // its own response rather than reading the first one's remainder.
        try await client.publishComponentPatches([
            .init(
                id: "ci",
                target: target,
                slots: [
                    .init(
                        slot: "after-title",
                        children: [.status("Failed", role: .negative)]
                    )
                ]
            )
        ])
        XCTAssertEqual(
            registry.customization(for: target).slots["after-title"],
            [.status("Failed", role: .negative)]
        )

        // The same router enforces the same contract on either carrier.
        do {
            try await client.publishComponentPatches([
                .init(
                    id: "invalid",
                    target: target,
                    slots: [
                        .init(
                            slot: "private-slot",
                            children: [.status("Wrong", role: .negative)]
                        )
                    ]
                )
            ])
            XCTFail("an undeclared slot must be refused over the descriptor transport too")
        } catch let error as ExtensionHostClientError {
            guard case .rejected(let status, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(status, 422)
        }
        XCTAssertEqual(
            registry.customization(for: target).slots["after-title"],
            [.status("Failed", role: .negative)]
        )
    }

    /// The whole chain, in one test: a contained extension reaching the host it cannot see.
    ///
    /// Threading spawns the signed helper, the helper `execve`s the extension in place, and the
    /// extension speaks the broker protocol on the descriptor it inherited *through* that exec —
    /// to a host that authenticates it by a token it never chose. Every piece of that has its
    /// own test; this is the one that fails if they stop composing.
    func testAContainedExtensionReachesTheHostOverTheInheritedDescriptor() throws {
        let policy = HelperLaunchPolicy()
        try XCTSkipUnless(
            policy.helperURL(for: []) != nil,
            "no built helper in this bundle — run through the app-hosted test target"
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingChainStorage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ExtensionStorageStore(rootURL: root)
        let identifier = "codes.threading.tests.chain"

        // Something for the extension to find, written the way the host writes it.
        try storage.setKeyValue(
            .string("from-the-host"),
            extensionIdentifier: identifier,
            key: "greeting"
        )

        let service = ExtensionHostService(
            registry: ComponentCustomizationRegistry(),
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1")),
            keyValueStore: storage
        )
        let authorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: identifier,
            processGeneration: "generation-one",
            order: 0,
            capabilities: [.keyValueStorage],
            transport: .descriptor
        ))
        let childDescriptor = try XCTUnwrap(authorization.childDescriptor)

        let installRoot = try XCTUnwrap(ExtensionRunnerValidator.installRootPath())
        let package = URL(fileURLWithPath: installRoot, isDirectory: true)
            .appendingPathComponent(
                "codes.threading.tests.\(UUID().uuidString).threadingextension",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: package) }
        try FileManager.default.createDirectory(
            at: package.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(ExtensionManifest(
            identifier: identifier,
            name: "Chain Probe",
            version: "0.1.0",
            runtime: .native,
            executable: "bin/extension",
            capabilities: [.keyValueStorage]
        )).write(to: package.appendingPathComponent(ExtensionBundleInspector.manifestName))

        // The extension speaks the broker's HTTP itself. That is the point: it proves the
        // descriptor carries a working host connection, not merely that it carries bytes.
        let executable = package.appendingPathComponent("bin/extension")
        try Data("""
        #!/bin/bash
        printf 'GET /v1/storage/kv HTTP/1.1\\r\\nAuthorization: Bearer %s\\r\\nContent-Length: 0\\r\\n\\r\\n' \\
            "$THREADING_EXTENSION_HOST_TOKEN" >&3
        body=""
        while IFS= read -r -d '' -n 1 c <&3; do
            body="$body$c"
            case "$body" in *'}') break;; esac
        done
        body=${body//$'\\r'/}
        body=${body//$'\\n'/}
        printf 'hostFd=%s\\n' "$THREADING_EXTENSION_HOST_FD"
        printf 'response=%s\\n' "$body"

        """.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let stdout = Pipe()
        let stderr = Pipe()
        let child = try policy.spawn(
            ExtensionLaunchRequest(
                bundle: try ExtensionBundleInspector.inspect(at: package),
                arguments: ["--threading-serve"],
                additionalEnvironment: authorization.environment,
                standardOutput: .pipe(stdout),
                standardError: .pipe(stderr),
                extraDescriptors: [
                    ExtensionHostDescriptorConnection.childDescriptorNumber: childDescriptor
                ]
            )
        )

        let report = try asAnExtensionProcess { () -> String in
            let output = String(
                decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            child.waitUntilExit()
            return output
        }
        let diagnostics = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let transcript = "status \(child.terminationStatus)\nout: \(report)\nerr: \(diagnostics)"

        XCTAssertTrue(
            report.contains(
                "hostFd=\(ExtensionHostDescriptorConnection.childDescriptorNumber)"
            ),
            transcript
        )
        XCTAssertTrue(report.contains("\"greeting\""), transcript)
        XCTAssertTrue(report.contains("from-the-host"), transcript)
    }

    func testBrokeredKeyValueStorageRoundTripsThroughTheHostAndPersists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingBrokeredKV-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ExtensionStorageStore(rootURL: root)

        let service = ExtensionHostService(
            registry: ComponentCustomizationRegistry(),
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1")),
            keyValueStore: storage
        )
        let authorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.kv",
            processGeneration: "generation-one",
            order: 0,
            capabilities: [.keyValueStorage],
            transport: .descriptor
        ))
        let childDescriptor = try XCTUnwrap(authorization.childDescriptor)
        defer {
            ExtensionHostDescriptorTransport.forget(descriptor: childDescriptor)
            close(childDescriptor)
        }

        // A descriptor-mode launch grants no writable path, so the manifest's storage
        // capability is what earns a broker token rather than a directory.
        XCTAssertNil(
            try storage.environment(
                for: ExtensionManifest(
                    identifier: "com.example.kv",
                    name: "KV",
                    version: "1.0.0",
                    runtime: .native,
                    executable: "bin/kv",
                    capabilities: [.keyValueStorage, .cacheStorage]
                ),
                transport: .descriptor
            )[ExtensionStorageEnvironment.keyValueDirectory]
        )

        let environment = [
            ExtensionHostConnection.descriptorEnvironmentKey: String(childDescriptor),
            ExtensionHostConnection.tokenEnvironmentKey: authorization.connection.bearerToken
        ]
        let observed = try asAnExtensionProcess { () -> [[String]] in
            let store = try ExtensionKeyValueStore(environment: environment)
            var stages = [store.keys()]

            try store.set(["runs": 3], forKey: "counters")
            try store.setJSONValue(.string("passing"), forKey: "status")
            stages.append(store.keys())
            XCTAssertEqual(try store.jsonValue(forKey: "status"), .string("passing"))

            try store.removeValue(forKey: "status")
            stages.append(store.keys())
            return stages
        }
        XCTAssertEqual(observed, [[], ["counters", "status"], ["counters"]])

        // The host wrote it where the directory backing would have, so a launcher change does
        // not strand an extension's existing state.
        let onDisk = try ExtensionKeyValueStore(
            directoryURL: storage.dataDirectory(for: "com.example.kv")
        )
        XCTAssertEqual(onDisk.keys(), ["counters"])
        XCTAssertEqual(try onDisk.value(forKey: "counters", as: [String: Int].self), ["runs": 3])
    }

    func testBrokeredStorageWorkDoesNotBlockTheMainActor() throws {
        let storage = BlockingExtensionKeyValueStore()
        let service = ExtensionHostService(
            registry: ComponentCustomizationRegistry(),
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1")),
            keyValueStore: storage
        )
        let authorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.slow-storage",
            processGeneration: "generation-one",
            order: 0,
            capabilities: [.keyValueStorage],
            transport: .descriptor
        ))
        let childDescriptor = try XCTUnwrap(authorization.childDescriptor)
        defer {
            ExtensionHostDescriptorTransport.forget(descriptor: childDescriptor)
            close(childDescriptor)
        }

        let answered = expectation(description: "storage response")
        var response: HTTPResponse?
        service.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/storage/kv",
                headers: [
                    "authorization": "Bearer \(authorization.connection.bearerToken)"
                ],
                body: Data()
            )
        ) {
            response = $0
            answered.fulfill()
        }

        XCTAssertEqual(
            storage.entered.wait(timeout: .now() + 1),
            .success,
            "the request never reached storage"
        )
        XCTAssertNil(
            response,
            "the response cannot arrive while the deliberately blocked store is still working"
        )
        // Reaching this line on the main actor is the assertion: the old implementation called
        // the store inline and could not return from `route` until this signal already existed.
        storage.release.signal()
        wait(for: [answered], timeout: 2)
        XCTAssertEqual(response?.status, 200)
    }

    func testBrokeredCacheStorageRoundTripsAndRefusesTraversalAndOversizedEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingBrokeredCache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ExtensionStorageStore(rootURL: root)

        let service = ExtensionHostService(
            registry: ComponentCustomizationRegistry(),
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1")),
            cacheStore: storage
        )
        let authorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.cache",
            processGeneration: "generation-one",
            order: 0,
            capabilities: [.cacheStorage],
            transport: .descriptor
        ))
        let childDescriptor = try XCTUnwrap(authorization.childDescriptor)
        defer {
            ExtensionHostDescriptorTransport.forget(descriptor: childDescriptor)
            close(childDescriptor)
        }
        let environment = [
            ExtensionHostConnection.descriptorEnvironmentKey: String(childDescriptor),
            ExtensionHostConnection.tokenEnvironmentKey: authorization.connection.bearerToken
        ]

        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        let observed = try asAnExtensionProcess { () -> (miss: Bool, names: [String], value: Data?, afterRemoval: [String]) in
            let cache = try ExtensionCacheStore(environment: environment)
            let miss = try cache.data(forName: "index.bin") == nil

            try cache.setData(payload, forName: "index.bin")
            let names = try cache.names()
            let value = try cache.data(forName: "index.bin")

            // A traversal attempt is refused on the extension's side and, independently, by the
            // host — the broker takes a name from a request body, so trusting it would make the
            // cache an arbitrary-write primitive.
            XCTAssertThrowsError(try cache.setData(payload, forName: "../escaped")) {
                XCTAssertEqual($0 as? ExtensionStorageError, .invalidName)
            }
            XCTAssertThrowsError(try cache.data(forName: "..")) {
                XCTAssertEqual($0 as? ExtensionStorageError, .invalidName)
            }
            XCTAssertThrowsError(
                try cache.setData(
                    Data(count: ExtensionCacheStore.maximumEntryBytes + 1),
                    forName: "huge.bin"
                )
            ) {
                XCTAssertEqual(
                    $0 as? ExtensionStorageError,
                    .quotaExceeded(maximumBytes: ExtensionCacheStore.maximumEntryBytes)
                )
            }

            try cache.removeData(forName: "index.bin")
            return (miss, names, value, try cache.names())
        }

        XCTAssertTrue(observed.miss, "a cache miss is an answer, not an error")
        XCTAssertEqual(observed.names, ["index.bin"])
        XCTAssertEqual(observed.value, payload)
        XCTAssertEqual(observed.afterRemoval, [])

        // The host wrote it inside the extension's own cache directory and nowhere else.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: storage.cachesURL.appendingPathComponent("escaped").path
            )
        )
    }

    func testBrokeredStorageIsRefusedWithoutTheCapabilityAndAfterRevocation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingBrokeredKV-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ExtensionStorageStore(rootURL: root)
        let service = ExtensionHostService(
            registry: ComponentCustomizationRegistry(),
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1")),
            keyValueStore: storage
        )

        // A component-only extension reaches the same broker and must still be refused storage.
        let authorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.ui-only",
            processGeneration: "generation-one",
            order: 0,
            capabilities: [.componentCustomization],
            transport: .descriptor
        ))
        let childDescriptor = try XCTUnwrap(authorization.childDescriptor)
        defer {
            ExtensionHostDescriptorTransport.forget(descriptor: childDescriptor)
            close(childDescriptor)
        }
        let environment = [
            ExtensionHostConnection.descriptorEnvironmentKey: String(childDescriptor),
            ExtensionHostConnection.tokenEnvironmentKey: authorization.connection.bearerToken
        ]
        XCTAssertThrowsError(
            try asAnExtensionProcess { try ExtensionKeyValueStore(environment: environment) }
        ) { error in
            XCTAssertEqual(
                error as? ExtensionStorageError,
                .unavailable("persistent key-value storage")
            )
        }

        // Over loopback the same capability set earns no authorization at all, because storage
        // is a granted directory there rather than broker traffic.
        XCTAssertNil(try service.authorize(
            extensionIdentifier: "com.example.kv",
            processGeneration: "generation-one",
            order: 0,
            capabilities: [.keyValueStorage],
            transport: .loopback
        ))
    }

    func testRevokingAGenerationClosesItsInheritedSocket() async throws {
        let registry = ComponentCustomizationRegistry()
        let contract = sessionRowContract()
        try registry.register(contract)
        let service = ExtensionHostService(
            registry: registry,
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1"))
        )
        let authorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.ci",
            processGeneration: "generation-one",
            order: 0,
            capabilities: [.componentCustomization],
            transport: .descriptor
        ))
        let childDescriptor = try XCTUnwrap(authorization.childDescriptor)
        defer {
            ExtensionHostDescriptorTransport.forget(descriptor: childDescriptor)
            close(childDescriptor)
        }
        let client = ExtensionHostClient(connection: ExtensionHostConnection(
            baseURL: ExtensionHostConnection.descriptorBaseURL,
            bearerToken: authorization.connection.bearerToken,
            descriptor: childDescriptor
        ))
        try await client.publishComponentPatches([])

        service.revoke(
            extensionIdentifier: "com.example.ci",
            processGeneration: "generation-one"
        )

        // Revocation is a close, not a 401: the child learns immediately rather than on its
        // next call, and it cannot mistake the answer for a transient failure.
        do {
            try await client.publishComponentPatches([])
            XCTFail("a revoked generation must not reach the host")
        } catch let error as ExtensionHostClientError {
            XCTAssertEqual(error, .hostClosed)
        }
    }

    func testHostConnectionRequiresTheComponentCapability() throws {
        let registry = ComponentCustomizationRegistry()
        let service = ExtensionHostService(
            registry: registry,
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1"))
        )
        XCTAssertNil(try service.authorize(
            extensionIdentifier: "com.example.panel",
            processGeneration: "generation-one",
            order: 0,
            capabilities: [.panels]
        ))
        XCTAssertNil(try service.authorize(
            extensionIdentifier: "com.example.unplaced-metal",
            processGeneration: "generation-one",
            order: 0,
            capabilities: [.customMetalSurfaces]
        ))
    }

    func testHostClientStoresSecretsInAnExtensionScopedBroker() async throws {
        let secretStore = TestExtensionSecretStore()
        let registry = ComponentCustomizationRegistry()
        let service = ExtensionHostService(
            registry: registry,
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1")),
            secretStore: secretStore
        )
        await withCheckedContinuation { continuation in
            service.start(registry: registry) {
                continuation.resume()
            }
        }
        defer { service.stop() }

        let firstAuthorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.first",
            processGeneration: "first-one",
            order: 0,
            capabilities: [.secrets]
        ))
        let first = ExtensionHostClient(connection: firstAuthorization.connection)

        let readOnlyAuthorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.read-only",
            processGeneration: "read-only-one",
            order: 2,
            capabilities: [.hostProjectsRead]
        ))
        XCTAssertEqual(
            get(
                "/v1/secrets/api-token",
                token: readOnlyAuthorization.connection.bearerToken,
                through: service
            ).status,
            403
        )

        let initiallyMissing = try await first.secret(forKey: "api-token")
        XCTAssertNil(initiallyMissing)
        try await first.setSecret("top-secret", forKey: "api-token")
        let stored = try await first.secret(forKey: "api-token")
        let firstKeys = try await first.secretKeys()
        XCTAssertEqual(stored, "top-secret")
        XCTAssertEqual(firstKeys, ["api-token"])

        let secondAuthorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.second",
            processGeneration: "second-one",
            order: 1,
            capabilities: [.secrets]
        ))
        let second = ExtensionHostClient(connection: secondAuthorization.connection)
        let isolated = try await second.secret(forKey: "api-token")
        XCTAssertNil(
            isolated,
            "the bearer identity, not a caller-supplied namespace, scopes Keychain values"
        )

        try await first.removeSecret(forKey: "api-token")
        let removed = try await first.secret(forKey: "api-token")
        let finalKeys = try await first.secretKeys()
        XCTAssertNil(removed)
        XCTAssertEqual(finalKeys, [])
    }

    func testBrokeredServiceRequiresAnExactDeclaredDependencyAndVerifiedCaller() throws {
        let router = TestExtensionServiceRouter()
        router.result = .success(ExtensionServiceResponse(
            requestID: "provider-request",
            serviceID: "status",
            serviceVersion: 2,
            value: .object(["state": .string("passed")])
        ))
        let service = ExtensionHostService(
            registry: ComponentCustomizationRegistry(),
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1")),
            serviceRouter: router
        )
        let dependency = ExtensionServiceDependency(
            providerIdentifier: "com.example.provider",
            serviceID: "status",
            version: 2
        )
        let authorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.consumer",
            processGeneration: "consumer-one",
            order: 0,
            capabilities: [.servicesConsume],
            serviceDependencies: [dependency]
        ))
        let token = authorization.connection.bearerToken

        let response = routeService(
            providerIdentifier: dependency.providerIdentifier,
            serviceID: dependency.serviceID,
            call: .init(
                serviceVersion: dependency.version,
                arguments: .object(["projectID": .string("project-1")])
            ),
            token: token,
            through: service
        )
        XCTAssertEqual(response.status, 200)
        let result = try JSONDecoder().decode(
            ExtensionServiceCallResult.self,
            from: response.body
        )
        XCTAssertEqual(result.value, .object(["state": .string("passed")]))
        XCTAssertEqual(router.calls.count, 1)
        XCTAssertEqual(router.calls[0].caller, "com.example.consumer")
        XCTAssertEqual(router.calls[0].provider, "com.example.provider")

        let undeclared = routeService(
            providerIdentifier: dependency.providerIdentifier,
            serviceID: dependency.serviceID,
            call: .init(serviceVersion: 1),
            token: token,
            through: service
        )
        XCTAssertEqual(undeclared.status, 403)
        XCTAssertEqual(router.calls.count, 1)

        service.revoke(
            extensionIdentifier: "com.example.consumer",
            processGeneration: "consumer-one"
        )
        XCTAssertEqual(
            routeService(
                providerIdentifier: dependency.providerIdentifier,
                serviceID: dependency.serviceID,
                call: .init(serviceVersion: dependency.version),
                token: token,
                through: service
            ).status,
            401
        )
    }

    func testPrimitiveIdentityRegistryRequiresAnExplicitWinnerWhenResolversConflict() throws {
        let suite = "ExtensionIdentityResolverTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ExtensionIdentityResolverRegistry(defaults: defaults)
        let first = ComponentCustomizationSource(
            extensionIdentifier: "com.example.first",
            processGeneration: "one",
            order: 0
        )
        let second = ComponentCustomizationSource(
            extensionIdentifier: "com.example.second",
            processGeneration: "one",
            order: 1
        )
        try registry.replace(
            .init(providerIcons: [
                .init(providerID: "codex", image: .systemSymbol("terminal"))
            ]),
            from: first
        )
        XCTAssertEqual(
            registry.providerIcon(providerID: "codex"),
            .init(image: .systemSymbol("terminal"), extensionIdentifier: "com.example.first")
        )

        try registry.replace(
            .init(providerIcons: [
                .init(providerID: "codex", image: .systemSymbol("hammer"))
            ]),
            from: second
        )
        XCTAssertNil(registry.providerIcon(providerID: "codex"))
        XCTAssertEqual(
            registry.providerCandidates(),
            ["com.example.first", "com.example.second"]
        )

        registry.selectProviderExtension("com.example.second")
        XCTAssertEqual(
            registry.providerIcon(providerID: "codex"),
            .init(image: .systemSymbol("hammer"), extensionIdentifier: "com.example.second")
        )
        registry.remove(
            extensionIdentifier: "com.example.second",
            processGeneration: "one"
        )
        XCTAssertEqual(
            registry.providerIcon(providerID: "codex")?.extensionIdentifier,
            "com.example.first"
        )
    }

    func testPrimitiveIdentityHostAPIsAreCapabilityGatedAndRevoked() throws {
        let snapshots = TestExtensionHostSnapshotProvider(
            providers: [
                .init(
                    id: "codex",
                    displayName: "Codex",
                    image: .hostAsset("identity.provider.codex")
                )
            ],
            accounts: [
                .init(
                    id: "codex:standard",
                    providerID: "codex",
                    displayName: "Default",
                    isDefault: true,
                    hasUserSelectedImage: false
                )
            ]
        )
        let identityRegistry = ExtensionIdentityResolverRegistry()
        let service = ExtensionHostService(
            registry: ComponentCustomizationRegistry(),
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1")),
            snapshotProvider: snapshots,
            identityRegistry: identityRegistry
        )
        let authorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.icons",
            processGeneration: "one",
            order: 0,
            capabilities: [
                .hostProvidersRead,
                .hostAccountsPresentationRead,
                .hostEvents,
                .providerIconResolver
            ]
        ))
        let token = authorization.connection.bearerToken

        let providers: ExtensionProviderSnapshotPage = try decodedGET(
            "/v1/providers",
            token: token,
            through: service
        )
        XCTAssertEqual(providers.providers.map(\.id), ["codex"])
        let accounts: ExtensionAccountSnapshotPage = try decodedGET(
            "/v1/accounts",
            token: token,
            through: service
        )
        XCTAssertEqual(accounts.accounts.map(\.id), ["codex:standard"])
        snapshots.accounts[0] = .init(
            id: "codex:standard",
            providerID: "codex",
            displayName: "Renamed",
            isDefault: true,
            hasUserSelectedImage: false
        )
        service.refreshSnapshotJournal()
        let identityEvents: ExtensionHostEventPage = try decodedGET(
            "/v1/events?after=\(accounts.cursor)",
            token: token,
            through: service
        )
        XCTAssertEqual(identityEvents.events.map(\.kind), [.accountChanged])

        let publication = ExtensionIdentityResolutionPublication(
            providerIcons: [
                .init(providerID: "codex", image: .systemSymbol("terminal.fill"))
            ]
        )
        XCTAssertEqual(
            routeIdentity(publication, token: token, through: service).status,
            204
        )
        XCTAssertEqual(
            identityRegistry.providerIcon(providerID: "codex")?.image,
            .systemSymbol("terminal.fill")
        )

        let forbiddenAccountPublication = ExtensionIdentityResolutionPublication(
            accountIcons: [
                .init(accountID: "codex:standard", image: .systemSymbol("person.fill"))
            ]
        )
        XCTAssertEqual(
            routeIdentity(forbiddenAccountPublication, token: token, through: service).status,
            403
        )

        service.revoke(
            extensionIdentifier: "com.example.icons",
            processGeneration: "one"
        )
        XCTAssertNil(identityRegistry.providerIcon(providerID: "codex"))
    }

    func testSessionIdentityCapabilityPublishesOnlyItsNarrowComponent() throws {
        let registry = ComponentCustomizationRegistry()
        try registry.register(HostComponentContracts.sidebarSessionIdentity)
        try registry.register(HostComponentContracts.sidebarSessionRow)
        let service = ExtensionHostService(
            registry: registry,
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1"))
        )
        let authorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.identity-layout",
            processGeneration: "one",
            order: 0,
            capabilities: [.sessionIdentityRenderer]
        ))
        let token = authorization.connection.bearerToken
        let identityTarget = ExtensionComponentTarget.sessionIdentity()
        let identityPatch = ExtensionComponentPatch(
            id: "identity-layout",
            target: identityTarget,
            replacement: .stack(
                axis: .horizontal,
                spacing: .tight,
                children: [
                    .image(
                        ExtensionSessionIdentityAsset.providerImage,
                        role: .identity,
                        accessibilityLabel: "Provider"
                    )
                ]
            )
        )

        XCTAssertEqual(
            route(
                .init(patches: [identityPatch]),
                token: token,
                through: service
            ).status,
            204
        )
        XCTAssertEqual(
            registry.customization(for: .sessionIdentity(
                sessionID: "session-42"
            )).replacement,
            identityPatch.replacement
        )

        let rowPatch = ExtensionComponentPatch(
            id: "row-layout",
            target: .init(
                component: HostComponentContracts.sidebarSessionRow.id,
                contractVersion: 1
            ),
            replacement: .stack(
                axis: .horizontal,
                spacing: .tight,
                children: [.text("Not allowed", role: .compactBody)]
            )
        )
        XCTAssertEqual(
            route(
                .init(patches: [rowPatch]),
                token: token,
                through: service
            ).status,
            403
        )
        XCTAssertNil(
            registry.customization(for: rowPatch.target).replacement
        )
    }

    func testRealSessionRowUsesPrimitiveProviderResolverAndFallsBackAfterRemoval() throws {
        let previous = ExtensionIdentityResolverProviderSlot.shared.provider
        defer { ExtensionIdentityResolverProviderSlot.shared.provider = previous }

        let identityRegistry = ExtensionIdentityResolverRegistry()
        ExtensionIdentityResolverProviderSlot.shared.provider = identityRegistry
        let source = ComponentCustomizationSource(
            extensionIdentifier: "com.example.icons",
            processGeneration: "one",
            order: 0
        )
        try identityRegistry.replace(
            .init(providerIcons: [
                .init(providerID: "codex", image: .systemSymbol("hammer.fill"))
            ]),
            from: source
        )

        let session = AgentSession(kind: .codex, title: "Identity")
        let row = SessionRowView(customizationLookup: { _ in .empty })
        row.configure(with: session, activity: .idle)
        let icon = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "sidebar.session.identity"
            } as? NSImageView
        )
        XCTAssertEqual(icon.image?.accessibilityDescription, "hammer.fill")

        identityRegistry.remove(
            extensionIdentifier: source.extensionIdentifier,
            processGeneration: source.processGeneration
        )
        row.configure(with: session, activity: .idle)
        XCTAssertNotEqual(icon.image?.accessibilityDescription, "hammer.fill")
    }

    /// The ⋯ sits at the row's trailing edge whatever the row is made of.
    ///
    /// It was an arranged view of the row's stack, which pushes its last view to the edge only by
    /// stretching something to that view's left — and stretching by hugging needs a view with an
    /// intrinsic size to hug. A row whose content an extension has replaced may have none, and
    /// there the stack packed everything leading and left the ⋯ resting against the title. Two
    /// rows side by side then put the same control in two places, which reads as a bug in the app
    /// rather than in a layout rule nobody can see.
    func testTheRowsActionsStayAtItsTrailingEdgeWhateverTheContentIs() throws {
        let width: CGFloat = 260

        func frame(
            of identifier: String,
            customization: @escaping ComponentCustomizationHost.Lookup
        ) throws -> NSRect {
            let row = SessionRowView(customizationLookup: customization)
            row.configure(with: AgentSession(kind: .claude, title: "A session"), activity: .idle)
            row.frame = NSRect(x: 0, y: 0, width: width, height: SidebarDefaults.rowHeight)
            row.layoutSubtreeIfNeeded()

            let actions = try XCTUnwrap(
                descendants(in: row).first { $0.accessibilityIdentifier() == identifier }
            )
            return actions.convert(actions.bounds, to: row)
        }

        func actionsFrame(
            customization: @escaping ComponentCustomizationHost.Lookup
        ) throws -> NSRect {
            try frame(of: "sidebar.session.actions", customization: customization)
        }

        let native = try actionsFrame { _ in .empty }

        // A replacement with no intrinsic width of its own: the shape the stack could not stretch.
        let registry = ComponentCustomizationRegistry()
        try registry.register(HostComponentContracts.sidebarSessionRow)
        try registry.replacePatches(
            [
                .init(
                    id: "row-layout",
                    target: .init(
                        component: HostComponentContracts.sidebarSessionRow.id,
                        contractVersion: HostComponentContracts.sidebarSessionRow.version
                    ),
                    replacement: ExtensionNode.stack(
                        axis: .horizontal,
                        spacing: .tight,
                        children: [ExtensionNode.text("Replaced", role: .compactBody)]
                    )
                )
            ],
            from: ComponentCustomizationSource(
                extensionIdentifier: "com.example.row-layout",
                processGeneration: "one",
                order: 0
            )
        )
        let customized = try actionsFrame(customization: registry.customization(for:))

        XCTAssertEqual(
            native.maxX,
            customized.maxX,
            accuracy: 0.5,
            "the ⋯ moved when the row's content did — it is no longer pinned to the row"
        )
        // Measured against the slot the *pair* occupies, not one button's width: the ⋯ is the
        // inboard of the two now, so the archive button is what reaches the row's edge.
        XCTAssertGreaterThan(
            native.maxX,
            width - SidebarRowDefaults.sessionTrailingSlotWidth
                - SidebarRowDefaults.trailingInset - 1,
            "the ⋯ is not in the row's trailing slot"
        )

        // And the outermost of the pair really does reach the edge, so "trailing" is a fact
        // about the row rather than about whichever button happens to be checked.
        let archive = try frame(of: "sidebar.session.archive") { _ in .empty }
        XCTAssertGreaterThan(
            archive.maxX,
            width - SidebarRowDefaults.trailingSlotSize - SidebarRowDefaults.trailingInset - 1,
            "the archive button is not at the row's trailing edge"
        )
    }

    func testRealSessionRowComposesResolvedIdentityWithoutReplacingTheRow() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = HostComponentContracts.sidebarSessionIdentity
        try registry.register(contract)
        let session = AgentSession(kind: .codex, title: "Composed identity")
        let target = ExtensionComponentTarget.sessionIdentity(
            sessionID: session.id.uuidString.lowercased()
        )
        let source = ComponentCustomizationSource(
            extensionIdentifier: "com.example.identity-layout",
            processGeneration: "one",
            order: 0
        )
        try registry.replacePatches(
            [
                .init(
                    id: "identity-layout",
                    target: target,
                    replacement: .stack(
                        axis: .horizontal,
                        spacing: .tight,
                        children: [
                            .image(
                                ExtensionSessionIdentityAsset.providerImage,
                                role: .identity,
                                accessibilityLabel: "Resolved provider"
                            ),
                            .image(
                                .systemSymbol("person.crop.circle.fill"),
                                role: .icon,
                                accessibilityLabel: "Resolved account"
                            )
                        ]
                    )
                )
            ],
            from: source
        )

        let row = SessionRowView(customizationLookup: registry.customization(for:))
        row.frame = NSRect(x: 0, y: 0, width: 500, height: 26)
        row.configure(with: session, activity: .dormant)
        row.layoutSubtreeIfNeeded()

        let nativeIdentity = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier()
                    == "sidebar.session.identity.default-content"
            }
        )
        XCTAssertTrue(nativeIdentity.isHidden)
        let nativeRow = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "sidebar.session.default-content"
            }
        )
        XCTAssertFalse(nativeRow.isHidden)
        XCTAssertNotNil(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "sidebar.session.title"
            }
        )
        XCTAssertNotNil(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "sidebar.session.trailing"
            }
        )
        let replacement = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "extension.component.replacement"
            }
        )
        XCTAssertEqual(replacement.alphaValue, AgentIconDefaults.dormantAlpha)
        let identityContainer = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "sidebar.session.identity.content"
            }
        )
        XCTAssertEqual(
            identityContainer.frame.width,
            18 + Design.Spacing.tight + 14,
            accuracy: 0.5,
            "the hidden native 16pt identity must not constrain a wider replacement"
        )
        let renderedImages = descendants(in: replacement).compactMap {
            $0 as? NSImageView
        }
        XCTAssertEqual(renderedImages.count, 2)

        registry.removePatches(
            extensionIdentifier: source.extensionIdentifier,
            processGeneration: source.processGeneration
        )
        XCTAssertFalse(nativeIdentity.isHidden)
        XCTAssertNil(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "extension.component.replacement"
            }
        )
    }

    func testHostSnapshotsRequireCapabilitiesAndRedactRepositoryMetadataSeparately() throws {
        let provider = TestExtensionHostSnapshotProvider(
            projects: [
                .init(
                    id: "project-1",
                    displayName: "Threading",
                    repository: .init(
                        remoteHost: "github.com",
                        repositoryPath: "everlof/threading",
                        branch: "main",
                        headRevision: String(repeating: "a", count: 40)
                    )
                )
            ]
        )
        let service = ExtensionHostService(
            registry: ComponentCustomizationRegistry(),
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1")),
            snapshotProvider: provider
        )
        let projectsOnly = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.reader",
            processGeneration: "one",
            order: 0,
            capabilities: [.hostProjectsRead]
        ))

        let redacted: ExtensionProjectSnapshotPage = try decodedGET(
            "/v1/projects",
            token: projectsOnly.connection.bearerToken,
            through: service
        )
        XCTAssertEqual(redacted.projects.first?.displayName, "Threading")
        XCTAssertNil(redacted.projects.first?.repository)

        let forbidden = get(
            "/v1/sessions",
            token: projectsOnly.connection.bearerToken,
            through: service
        )
        XCTAssertEqual(forbidden.status, 403)

        let withRepository = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.repo-reader",
            processGeneration: "one",
            order: 1,
            capabilities: [.hostProjectsRead, .hostRepositoriesRead]
        ))
        let visible: ExtensionProjectSnapshotPage = try decodedGET(
            "/v1/projects",
            token: withRepository.connection.bearerToken,
            through: service
        )
        XCTAssertEqual(visible.projects.first?.repository?.remoteHost, "github.com")
        XCTAssertEqual(visible.projects.first?.repository?.repositoryPath, "everlof/threading")
    }

    func testSessionRuntimeBrokerIsSeparatelyGatedAndBoundToAKnownSession() throws {
        let runtime = ExtensionSessionRuntimeSnapshot(
            sessionID: "session-1",
            processGroups: [
                .init(
                    origin: .agent,
                    processes: [
                        .init(
                            processIdentifier: 42,
                            command: "node",
                            memoryBytes: 12_582_912,
                            cpuPercent: 7.5
                        )
                    ]
                )
            ],
            portGroups: [
                .init(
                    origin: .shell,
                    ports: [
                        .init(
                            port: 5173,
                            processIdentifier: 84,
                            command: "vite",
                            address: "127.0.0.1",
                            isIPv6: false,
                            interface: .localhost,
                            isReachableViaLocalhost: true
                        )
                    ]
                )
            ]
        )
        let provider = TestExtensionHostSnapshotProvider(
            sessions: [
                .init(
                    id: "session-1",
                    projectID: "project-1",
                    providerID: "codex",
                    displayTitle: "Runtime",
                    activity: .working,
                    isSideChat: false,
                    isArchived: false,
                    usesNativeUI: true
                )
            ],
            runtimeSnapshots: ["session-1": runtime]
        )
        let service = ExtensionHostService(
            registry: ComponentCustomizationRegistry(),
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1")),
            snapshotProvider: provider
        )
        let sessionsOnly = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.sessions",
            processGeneration: "one",
            order: 0,
            capabilities: [.hostSessionsRead]
        ))
        XCTAssertEqual(
            get(
                "/v1/sessions/session-1/runtime",
                token: sessionsOnly.connection.bearerToken,
                through: service
            ).status,
            403
        )

        let runtimeReader = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.runtime",
            processGeneration: "one",
            order: 1,
            capabilities: [.hostSessionRuntimeRead]
        ))
        let result: ExtensionSessionRuntimeSnapshot = try decodedGET(
            "/v1/sessions/session-1/runtime",
            token: runtimeReader.connection.bearerToken,
            through: service
        )
        XCTAssertEqual(result, runtime)
        XCTAssertEqual(provider.runtimeRequests, ["session-1"])
        XCTAssertEqual(result.processGroups.first?.processes.first?.command, "node")
        XCTAssertEqual(result.portGroups.first?.ports.first?.interface, .localhost)

        XCTAssertEqual(
            get(
                "/v1/sessions/not-a-session/runtime",
                token: runtimeReader.connection.bearerToken,
                through: service
            ).status,
            404
        )
        XCTAssertEqual(
            provider.runtimeRequests,
            ["session-1"],
            "unknown IDs must be rejected before the process reader is asked"
        )
    }

    func testHostEventCursorReportsChangesAndRemovalsWithoutLosingTheSnapshotBoundary() throws {
        let provider = TestExtensionHostSnapshotProvider(
            projects: [.init(id: "project-1", displayName: "Threading")],
            sessions: [
                .init(
                    id: "session-1",
                    projectID: "project-1",
                    providerID: "codex",
                    displayTitle: "Initial",
                    activity: .idle,
                    isSideChat: false,
                    isArchived: false,
                    usesNativeUI: false
                )
            ]
        )
        let service = ExtensionHostService(
            registry: ComponentCustomizationRegistry(),
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1")),
            snapshotProvider: provider
        )
        let authorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.events",
            processGeneration: "one",
            order: 0,
            capabilities: [.hostSessionsRead, .hostEvents]
        ))
        let token = authorization.connection.bearerToken
        let baseline: ExtensionSessionSnapshotPage = try decodedGET(
            "/v1/sessions",
            token: token,
            through: service
        )
        XCTAssertEqual(baseline.cursor, 0)

        provider.sessions[0] = .init(
            id: "session-1",
            projectID: "project-1",
            providerID: "codex",
            displayTitle: "Working",
            activity: .working,
            isSideChat: false,
            isArchived: false,
            usesNativeUI: false
        )
        service.refreshSnapshotJournal()
        provider.sessions.removeAll()
        service.refreshSnapshotJournal()

        let first: ExtensionHostEventPage = try decodedGET(
            "/v1/events?after=\(baseline.cursor)&limit=1",
            token: token,
            through: service
        )
        XCTAssertEqual(first.events.map(\.kind), [.sessionChanged])
        XCTAssertTrue(first.hasMore)

        let second: ExtensionHostEventPage = try decodedGET(
            "/v1/events?after=\(first.nextCursor)&limit=10",
            token: token,
            through: service
        )
        XCTAssertEqual(second.events.map(\.kind), [.sessionRemoved])
        XCTAssertEqual(second.events.first?.projectID, "project-1")
        XCTAssertFalse(second.hasMore)

        let empty: ExtensionHostEventPage = try decodedGET(
            "/v1/events?after=\(second.nextCursor)",
            token: token,
            through: service
        )
        XCTAssertTrue(empty.events.isEmpty)
        XCTAssertEqual(empty.nextCursor, second.nextCursor)
    }

    func testRepositoryRemoteSanitizerDropsCredentialsAndLocalPaths() {
        XCTAssertEqual(
            ExtensionRepositoryIdentity(
                remote: "https://token:secret@GitHub.com/mjukis/Threading.git"
            ),
            .init(host: "github.com", path: "mjukis/Threading")
        )
        XCTAssertEqual(
            ExtensionRepositoryIdentity(remote: "git@gitlab.com:team/app.git"),
            .init(host: "gitlab.com", path: "team/app")
        )
        XCTAssertNil(ExtensionRepositoryIdentity(remote: "/Users/example/private.git"))
        XCTAssertNil(ExtensionRepositoryIdentity(remote: "../private.git"))
    }

    func testSDKClientPublishesThroughTheRealLoopbackListener() async throws {
        let registry = ComponentCustomizationRegistry()
        let contract = sessionRowContract()
        try registry.register(contract)
        let service = ExtensionHostService(
            registry: registry,
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1"))
        )
        await withCheckedContinuation { continuation in
            service.start(registry: registry) {
                continuation.resume()
            }
        }
        defer { service.stop() }

        let authorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.network-ci",
            processGeneration: "generation-network",
            order: 0,
            capabilities: [.componentCustomization]
        ))
        let target = ExtensionComponentTarget(
            component: contract.id,
            contractVersion: contract.version,
            entityID: "session-network"
        )
        let client = ExtensionHostClient(connection: authorization.connection)
        try await client.publishComponentPatches([
            .init(
                id: "network-ci",
                target: target,
                properties: [
                    .init(property: .title, value: .text("Published over HTTP"))
                ]
            )
        ])

        XCTAssertEqual(
            registry.customization(for: target).properties[.title],
            .text("Published over HTTP")
        )
    }

    func testSDKClientReadsSnapshotsAndEventsThroughTheRealLoopbackListener() async throws {
        let provider = TestExtensionHostSnapshotProvider(
            projects: [.init(id: "project-network", displayName: "Network project")],
            sessions: [
                .init(
                    id: "session-network",
                    projectID: "project-network",
                    providerID: "claude",
                    displayTitle: "Network session",
                    activity: .idle,
                    isSideChat: false,
                    isArchived: false,
                    usesNativeUI: true
                )
            ],
            providers: [
                .init(
                    id: "claude",
                    displayName: "Claude Code",
                    image: .hostAsset("identity.provider.claude")
                )
            ],
            accounts: [
                .init(
                    id: "claude:standard",
                    providerID: "claude",
                    displayName: "Default",
                    isDefault: true,
                    hasUserSelectedImage: false
                )
            ]
        )
        let registry = ComponentCustomizationRegistry()
        let service = ExtensionHostService(
            registry: registry,
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1")),
            snapshotProvider: provider
        )
        await withCheckedContinuation { continuation in
            service.start(registry: registry) {
                continuation.resume()
            }
        }
        defer { service.stop() }

        let authorization = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.network-reader",
            processGeneration: "generation-network",
            order: 0,
            capabilities: [
                .hostProjectsRead,
                .hostSessionsRead,
                .hostProvidersRead,
                .hostAccountsPresentationRead,
                .hostEvents
            ]
        ))
        let client = ExtensionHostClient(connection: authorization.connection)

        let projects = try await client.projects()
        XCTAssertEqual(projects.projects.map(\.id), ["project-network"])
        let project = try await client.project(id: "project-network")
        XCTAssertEqual(project.project.displayName, "Network project")
        let session = try await client.session(id: "session-network")
        XCTAssertEqual(session.session.activity, .idle)
        let providers = try await client.providers()
        XCTAssertEqual(providers.providers.map(\.id), ["claude"])
        let providerResult = try await client.provider(id: "claude")
        XCTAssertEqual(providerResult.provider.displayName, "Claude Code")
        let accounts = try await client.accounts()
        XCTAssertEqual(accounts.accounts.map(\.id), ["claude:standard"])
        let account = try await client.account(id: "claude:standard")
        XCTAssertEqual(account.account.providerID, "claude")

        provider.sessions[0] = .init(
            id: "session-network",
            projectID: "project-network",
            providerID: "claude",
            displayTitle: "Network session",
            activity: .working,
            isSideChat: false,
            isArchived: false,
            usesNativeUI: true
        )
        service.refreshSnapshotJournal()
        let events = try await client.events(after: projects.cursor)
        XCTAssertEqual(events.events.map(\.kind), [.sessionChanged])
    }

    func testRegistryRequiresAnExplicitWinnerForReplacementConflicts() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = sessionRowContract()
        try registry.register(contract)

        for (index, identifier) in ["com.example.first", "com.example.second"].enumerated() {
            try registry.replacePatches(
                [
                    .init(
                        id: "renderer",
                        target: .init(
                            component: contract.id,
                            contractVersion: contract.version
                        ),
                        replacement: .text(identifier, role: .compactBody)
                    )
                ],
                from: .init(
                    extensionIdentifier: identifier,
                    processGeneration: "one",
                    order: index
                )
            )
        }

        let target = ExtensionComponentTarget(
            component: contract.id,
            contractVersion: contract.version,
            entityID: "session-42"
        )
        var resolution = registry.customization(for: target)
        XCTAssertNil(resolution.replacement)
        XCTAssertEqual(
            resolution.replacementCandidates,
            ["com.example.first", "com.example.second"]
        )

        registry.selectReplacementExtension(
            "com.example.second",
            for: contract.id
        )
        resolution = registry.customization(for: target)
        XCTAssertEqual(
            resolution.replacement,
            .text("com.example.second", role: .compactBody)
        )
    }

    func testRegistryRejectsInvalidBatchWithoutLosingPreviousGeneration() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = sessionRowContract()
        let source = ComponentCustomizationSource(
            extensionIdentifier: "com.example.ci",
            processGeneration: "one",
            order: 0
        )
        let target = ExtensionComponentTarget(
            component: contract.id,
            contractVersion: contract.version,
            entityID: "session-42"
        )
        try registry.register(contract)
        try registry.replacePatches(
            [
                .init(
                    id: "valid",
                    target: target,
                    properties: [
                        .init(property: .title, value: .text("Still here"))
                    ]
                )
            ],
            from: source
        )

        XCTAssertThrowsError(
            try registry.replacePatches(
                [
                    .init(
                        id: "invalid",
                        target: target,
                        slots: [
                            .init(
                                slot: "private-slot",
                                children: [.status("No", role: .negative)]
                            )
                        ]
                    )
                ],
                from: source
            )
        )

        XCTAssertEqual(
            registry.customization(for: target).properties[.title],
            .text("Still here")
        )
    }

    func testCustomizationHostRestoresNativeContentWhenGenerationDisappears() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = sessionRowContract()
        let source = ComponentCustomizationSource(
            extensionIdentifier: "com.example.ci",
            processGeneration: "one",
            order: 0
        )
        let target = ExtensionComponentTarget(
            component: contract.id,
            contractVersion: contract.version,
            entityID: "session-42"
        )
        try registry.register(contract)
        try registry.replacePatches(
            [
                .init(
                    id: "replacement",
                    target: target,
                    slots: [
                        .init(
                            slot: "after-title",
                            children: [.status("Passed", role: .positive)]
                        )
                    ],
                    replacement: .stack(
                        axis: .horizontal,
                        spacing: .small,
                        children: [
                            .text("Deploy production", role: .compactBody),
                            .flexibleSpacer,
                            .status("CI passed", role: .positive)
                        ]
                    )
                )
            ],
            from: source
        )

        let native = NSTextField(labelWithString: "Native session row")
        let content = ComponentContentContainer(defaultContent: native)
        let slot = NSStackView()
        slot.orientation = .horizontal
        let host = ComponentCustomizationHost(
            target: target,
            contentContainer: content,
            slots: ["after-title": slot],
            lookup: registry.customization(for:)
        )

        host.refresh()
        XCTAssertTrue(native.isHidden)
        XCTAssertNotNil(content.replacementContent)
        XCTAssertEqual(slot.arrangedSubviews.count, 1)

        registry.removePatches(
            extensionIdentifier: source.extensionIdentifier,
            processGeneration: source.processGeneration
        )

        XCTAssertFalse(native.isHidden)
        XCTAssertNil(content.replacementContent)
        XCTAssertTrue(slot.arrangedSubviews.isEmpty)
    }

    func testComposableHooksWrapProceedInStableOrderAndRevokeByGeneration() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = HostComponentContracts.applicationMainWindow
        let target = ExtensionComponentTarget(
            component: contract.id,
            contractVersion: contract.version
        )
        let first = ComponentCustomizationSource(
            extensionIdentifier: "com.example.first",
            processGeneration: "one",
            order: 0
        )
        let second = ComponentCustomizationSource(
            extensionIdentifier: "com.example.second",
            processGeneration: "one",
            order: 1
        )
        try registry.register(contract)
        try registry.replacePatches([
            .init(
                id: "first-hook",
                target: target,
                hook: .overlay(
                    base: .proceed,
                    overlay: .status("First", role: .neutral)
                )
            )
        ], from: first)
        try registry.replacePatches([
            .init(
                id: "second-hook",
                target: target,
                hook: .overlay(
                    base: .proceed,
                    overlay: .status("Second", role: .positive)
                )
            )
        ], from: second)

        XCTAssertEqual(
            registry.customization(for: target).hooks.map(\.extensionIdentifier),
            ["com.example.first", "com.example.second"]
        )

        let native = NSView()
        native.setAccessibilityIdentifier("native.window")
        let content = ComponentContentContainer(defaultContent: native)
        let host = ComponentCustomizationHost(
            target: target,
            contentContainer: content,
            lookup: registry.customization(for:)
        )
        host.refresh()

        XCTAssertFalse(native.isHidden)
        XCTAssertNotNil(native.superview)
        XCTAssertEqual(
            descendants(in: content).filter {
                $0.accessibilityIdentifier().hasPrefix("extension.component.hook.")
            }.count,
            2
        )

        registry.removePatches(
            extensionIdentifier: first.extensionIdentifier,
            processGeneration: first.processGeneration
        )
        XCTAssertFalse(native.isHidden)
        XCTAssertEqual(registry.customization(for: target).hooks.count, 1)
    }

    func testMetalSurfaceHookRequiresItsOwnCapability() throws {
        let registry = ComponentCustomizationRegistry()
        try registry.register(HostComponentContracts.applicationMainWindow)
        let service = ExtensionHostService(
            registry: registry,
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1"))
        )
        let patch = ExtensionComponentPatch(
            id: "metal-hook",
            target: .init(component: .applicationMainWindow, contractVersion: 1),
            hook: .overlay(
                base: .proceed,
                overlay: .customSurface(
                    .metal(ExtensionMetalSurface(
                        shaderResource: "Resources/effect.metal"
                    )),
                    accessibilityLabel: nil
                )
            )
        )
        let ordinary = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.ordinary",
            processGeneration: "one",
            order: 0,
            capabilities: [.componentCustomization]
        ))
        XCTAssertEqual(
            route(.init(patches: [patch]), token: ordinary.connection.bearerToken, through: service)
                .status,
            403
        )

        let metal = try XCTUnwrap(try service.authorize(
            extensionIdentifier: "com.example.metal",
            processGeneration: "one",
            order: 0,
            capabilities: [.componentCustomization, .customMetalSurfaces]
        ))
        XCTAssertEqual(
            route(.init(patches: [patch]), token: metal.connection.bearerToken, through: service)
                .status,
            204
        )
    }

    func testUnavailableCustomSurfaceSkipsTheWholeHook() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = HostComponentContracts.applicationMainWindow
        let target = ExtensionComponentTarget(
            component: contract.id,
            contractVersion: contract.version
        )
        try registry.register(contract)
        try registry.replacePatches([
            .init(
                id: "missing-surface",
                target: target,
                hook: .overlay(
                    base: .proceed,
                    overlay: .customSurface(
                        .metal(ExtensionMetalSurface(
                            shaderResource: "Resources/missing.metal"
                        )),
                        accessibilityLabel: nil
                    )
                )
            )
        ], from: .init(
            extensionIdentifier: "com.example.missing",
            processGeneration: "one",
            order: 0
        ))

        let native = NSView()
        let content = ComponentContentContainer(defaultContent: native)
        let host = ComponentCustomizationHost(
            target: target,
            contentContainer: content,
            lookup: registry.customization(for:)
        )
        host.refresh()

        XCTAssertNil(content.replacementContent)
        XCTAssertTrue(native.superview === content)
        XCTAssertFalse(native.isHidden)
    }

    func testUsageRainShaderCompilesAgainstTheHostSurfaceABI() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repository.appendingPathComponent(
            "ThreadingExtensionKit/Examples/RainWindowExtension/Resources/usage-rain.metal"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let specification = ExtensionMetalSurface(
            shaderResource: "Resources/usage-rain.metal",
            inputs: [
                .init(name: "density", value: .constant(0.5)),
                .init(name: "opacity", value: .constant(0.46)),
                .init(name: "speed", value: .constant(1))
            ]
        )

        let surface = try ExtensionMetalSurfaceView(
            specification: specification,
            source: source,
            signalProvider: { _ in nil }
        )
        XCTAssertNil(surface.hitTest(.zero))
        XCTAssertEqual(surface.preferredFramesPerSecond, 60)
    }

    func testRendersUsageRainAcrossTheRealMainWindow() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent(
                "ThreadingExtensionKit/Examples/RainWindowExtension/Resources/usage-rain.metal"
            ),
            encoding: .utf8
        )
        let specification = ExtensionMetalSurface(
            shaderResource: "Resources/usage-rain.metal",
            inputs: [
                .init(name: "density", value: .constant(0.86)),
                .init(name: "opacity", value: .constant(0.52)),
                .init(name: "speed", value: .constant(1.18))
            ]
        )
        let surface = try ExtensionMetalSurfaceView(
            specification: specification,
            source: source,
            signalProvider: { _ in nil }
        )

        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1_280, height: 800))
        window.contentView?.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(
            WindowSnapshot.capture(window: window, annotating: nil)
        )
        let rain = try XCTUnwrap(
            surface.snapshotImage(size: representation.size, time: 4.7)
        )
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: representation))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        rain.draw(
            in: NSRect(origin: .zero, size: representation.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )
        let data = try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )
        try data.write(to: output.appendingPathComponent("usage-rain-main-window.png"))
    }

    func testRealSessionRowComposesEntitySlotAndClearsItOnReuse() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = HostComponentContracts.sidebarSessionRow
        let source = ComponentCustomizationSource(
            extensionIdentifier: "com.example.ci",
            processGeneration: "one",
            order: 0
        )
        let customizedSession = AgentSession(kind: .codex, title: "Deploy production")
        let ordinarySession = AgentSession(kind: .claude, title: "Write documentation")
        let target = ExtensionComponentTarget(
            component: contract.id,
            contractVersion: contract.version,
            entityID: customizedSession.id.uuidString.lowercased()
        )
        try registry.register(contract)

        let row = SessionRowView(customizationLookup: registry.customization(for:))
        row.frame = NSRect(x: 0, y: 0, width: 420, height: SidebarDefaults.rowHeight)
        row.configure(with: customizedSession, activity: .idle)

        let slot = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "sidebar.session.slot.after-title"
            } as? NSStackView
        )
        let trailing = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "sidebar.session.trailing"
            }
        )
        XCTAssertTrue(slot.isHidden)
        XCTAssertTrue(slot.arrangedSubviews.isEmpty)

        try registry.replacePatches(
            [
                .init(
                    id: "build-status",
                    target: target,
                    slots: [
                        .init(
                            slot: "after-title",
                            children: [.status("CI passed", role: .positive)]
                        )
                    ]
                )
            ],
            from: source
        )

        XCTAssertFalse(slot.isHidden)
        XCTAssertEqual(slot.arrangedSubviews.count, 1)
        XCTAssertEqual(
            slot.arrangedSubviews.first?.accessibilityIdentifier(),
            "extension.component.slot.after-title"
        )
        XCTAssertTrue(
            descendants(in: trailing).contains {
                $0.accessibilityIdentifier() == "sidebar.session.status"
            }
        )
        XCTAssertTrue(
            descendants(in: trailing).contains {
                $0.accessibilityIdentifier() == "sidebar.session.actions"
            }
        )

        row.configure(with: ordinarySession, activity: .dormant)
        XCTAssertTrue(slot.isHidden)
        XCTAssertTrue(slot.arrangedSubviews.isEmpty)

        row.configure(with: customizedSession, activity: .working)
        XCTAssertFalse(slot.isHidden)
        XCTAssertEqual(slot.arrangedSubviews.count, 1)

        registry.removePatches(
            extensionIdentifier: source.extensionIdentifier,
            processGeneration: source.processGeneration
        )
        XCTAssertTrue(slot.isHidden)
        XCTAssertTrue(slot.arrangedSubviews.isEmpty)
        XCTAssertFalse(
            try XCTUnwrap(
                descendants(in: row).first {
                    $0.accessibilityIdentifier() == "sidebar.session.default-content"
                }
            ).isHidden
        )
    }

    func testRealSessionRowAppliesAndRestoresPropertyPatches() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = HostComponentContracts.sidebarSessionRow
        let source = ComponentCustomizationSource(
            extensionIdentifier: "com.example.presentation",
            processGeneration: "one",
            order: 0
        )
        let session = AgentSession(kind: .codex, title: "Native title")
        let target = ExtensionComponentTarget(
            component: contract.id,
            contractVersion: contract.version,
            entityID: session.id.uuidString.lowercased()
        )
        try registry.register(contract)

        let row = SessionRowView(customizationLookup: registry.customization(for:))
        row.configure(with: session, activity: .idle)
        let title = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "sidebar.session.title"
            } as? MorphingTitleLabel
        )
        let icon = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "sidebar.session.identity"
            } as? NSImageView
        )
        let nativeImage = icon.image

        try registry.replacePatches(
            [
                .init(
                    id: "presentation",
                    target: target,
                    properties: [
                        .init(property: .title, value: .text("Patched title")),
                        .init(property: .toolTip, value: .text("Build 42")),
                        .init(
                            property: .identityImage,
                            value: .image(.systemSymbol("hammer.fill"))
                        )
                    ]
                )
            ],
            from: source
        )

        XCTAssertEqual(title.stringValue, "Patched title")
        XCTAssertEqual(row.toolTip, "Build 42")
        XCTAssertNotEqual(icon.image, nativeImage)

        registry.removePatches(
            extensionIdentifier: source.extensionIdentifier,
            processGeneration: source.processGeneration
        )
        XCTAssertEqual(title.stringValue, "Native title")
        XCTAssertNil(row.toolTip)
        XCTAssertEqual(icon.image, nativeImage)
    }

    func testRealSessionRowReplacesOnlyContentAndRoutesSemanticActions() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = HostComponentContracts.sidebarSessionRow
        let source = ComponentCustomizationSource(
            extensionIdentifier: "com.example.ci",
            processGeneration: "one",
            order: 0
        )
        let customizedSession = AgentSession(kind: .codex, title: "Native title")
        let ordinarySession = AgentSession(kind: .claude, title: "Ordinary row")
        let target = ExtensionComponentTarget(
            component: contract.id,
            contractVersion: contract.version,
            entityID: customizedSession.id.uuidString.lowercased()
        )
        try registry.register(contract)

        let row = SessionRowView(customizationLookup: registry.customization(for:))
        var actions: [ComponentCustomizationAction] = []
        row.onCustomizationAction = { actions.append($0) }
        row.configure(with: customizedSession, activity: .working)

        try registry.replacePatches(
            [
                .init(
                    id: "replacement",
                    target: target,
                    replacement: .stack(
                        axis: .horizontal,
                        spacing: .small,
                        children: [
                            .image(
                                .hostAsset("session.provider-image"),
                                role: .identity,
                                accessibilityLabel: "Agent"
                            ),
                            .text("Deploy production", role: .compactBody),
                            .flexibleSpacer,
                            .status("Passed", role: .positive),
                            .button(
                                id: "inspect-build",
                                title: "Details",
                                role: .standard,
                                isEnabled: true
                            )
                        ]
                    )
                )
            ],
            from: source
        )

        let defaultContent = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "sidebar.session.default-content"
            }
        )
        XCTAssertTrue(defaultContent.isHidden)
        XCTAssertNotNil(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "extension.component.replacement"
            }
        )
        XCTAssertNotNil(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "sidebar.session.trailing"
            }
        )

        let button = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "extension.action.inspect-build"
            } as? ThemedButton
        )
        button.performClick()
        XCTAssertEqual(
            actions,
            [
                ComponentCustomizationAction(
                    target: target,
                    extensionIdentifier: source.extensionIdentifier,
                    actionID: "inspect-build"
                )
            ]
        )

        row.configure(with: ordinarySession, activity: .dormant)
        XCTAssertFalse(defaultContent.isHidden)
        XCTAssertNil(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "extension.component.replacement"
            }
        )

        row.configure(with: customizedSession, activity: .idle)
        XCTAssertTrue(defaultContent.isHidden)
        registry.removePatches(
            extensionIdentifier: source.extensionIdentifier,
            processGeneration: source.processGeneration
        )
        XCTAssertFalse(defaultContent.isHidden)
    }

    func testRealSessionRowRejectsNonCompactReplacementAtomically() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = HostComponentContracts.sidebarSessionRow
        let source = ComponentCustomizationSource(
            extensionIdentifier: "com.example.ci",
            processGeneration: "one",
            order: 0
        )
        let target = ExtensionComponentTarget(
            component: contract.id,
            contractVersion: contract.version,
            entityID: "session-42"
        )
        try registry.register(contract)
        try registry.replacePatches(
            [
                .init(
                    id: "valid",
                    target: target,
                    replacement: .stack(
                        axis: .horizontal,
                        spacing: .small,
                        children: [
                            .text("Valid compact row", role: .compactBody)
                        ]
                    )
                )
            ],
            from: source
        )

        XCTAssertThrowsError(
            try registry.replacePatches(
                [
                    .init(
                        id: "invalid",
                        target: target,
                        replacement: .stack(
                            axis: .vertical,
                            spacing: .large,
                            children: [
                                .text("Multiline body", role: .body),
                                .button(
                                    id: "delete",
                                    title: "Delete",
                                    role: .destructive,
                                    isEnabled: true
                                )
                            ]
                        )
                    )
                ],
                from: source
            )
        )

        XCTAssertEqual(
            registry.customization(for: target).replacement,
            .stack(
                axis: .horizontal,
                spacing: .small,
                children: [.text("Valid compact row", role: .compactBody)]
            )
        )
    }

    func testRealProjectRowComposesEntitySlotAndDeactivatesForHeadings() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = HostComponentContracts.sidebarProjectRow
        let source = ComponentCustomizationSource(
            extensionIdentifier: "com.example.ci",
            processGeneration: "one",
            order: 0
        )
        let customizedProject = Project(
            name: "Threading",
            folderURL: URL(fileURLWithPath: "/tmp/Threading")
        )
        let ordinaryProject = Project(
            name: "Other",
            folderURL: URL(fileURLWithPath: "/tmp/Other")
        )
        let target = ExtensionComponentTarget(
            component: contract.id,
            contractVersion: contract.version,
            entityID: customizedProject.id.uuidString.lowercased()
        )
        try registry.register(contract)

        let row = ProjectRowView(customizationLookup: registry.customization(for:))
        row.frame = NSRect(x: 0, y: 0, width: 420, height: SidebarDefaults.rowHeight)
        row.configure(
            with: customizedProject,
            collapsedSessionCount: 3
        )

        let slot = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "sidebar.project.slot.after-title"
            } as? NSStackView
        )
        let trailing = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "sidebar.project.trailing"
            }
        )
        XCTAssertTrue(slot.isHidden)

        try registry.replacePatches(
            [
                .init(
                    id: "project-build",
                    target: target,
                    slots: [
                        .init(
                            slot: "after-title",
                            children: [.status("CI passed", role: .positive)]
                        )
                    ]
                )
            ],
            from: source
        )

        XCTAssertFalse(slot.isHidden)
        XCTAssertEqual(slot.arrangedSubviews.count, 1)
        XCTAssertNotNil(
            descendants(in: trailing).first {
                $0.accessibilityIdentifier() == "sidebar.project.count"
            }
        )
        XCTAssertNotNil(
            descendants(in: trailing).first {
                $0.accessibilityIdentifier() == "sidebar.project.actions"
            }
        )

        row.configure(with: ordinaryProject)
        XCTAssertTrue(slot.isHidden)
        XCTAssertTrue(slot.arrangedSubviews.isEmpty)

        try registry.replacePatches(
            [
                .init(
                    id: "family-build",
                    target: .init(
                        component: contract.id,
                        contractVersion: contract.version
                    ),
                    slots: [
                        .init(
                            slot: "after-title",
                            children: [.status("Must not reach headings", role: .warning)]
                        )
                    ]
                )
            ],
            from: source
        )
        row.configureAsRepository(named: "Repository heading", count: 2)
        let title = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "sidebar.project.title"
            } as? MorphingTitleLabel
        )
        XCTAssertEqual(title.stringValue, "Repository heading")
        XCTAssertTrue(slot.isHidden)
        XCTAssertTrue(slot.arrangedSubviews.isEmpty)
    }

    func testRealProjectRowReplacesOnlyContentAndRoutesSemanticActions() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = HostComponentContracts.sidebarProjectRow
        let source = ComponentCustomizationSource(
            extensionIdentifier: "com.example.ci",
            processGeneration: "one",
            order: 0
        )
        let project = Project(
            name: "Native project",
            folderURL: URL(fileURLWithPath: "/tmp/NativeProject")
        )
        let target = ExtensionComponentTarget(
            component: contract.id,
            contractVersion: contract.version,
            entityID: project.id.uuidString.lowercased()
        )
        try registry.register(contract)

        let row = ProjectRowView(customizationLookup: registry.customization(for:))
        var actions: [ComponentCustomizationAction] = []
        row.onCustomizationAction = { actions.append($0) }
        row.configure(with: project, collapsedSessionCount: 4)

        try registry.replacePatches(
            [
                .init(
                    id: "project-renderer",
                    target: target,
                    replacement: .stack(
                        axis: .horizontal,
                        spacing: .small,
                        children: [
                            .image(
                                .hostAsset("project.image"),
                                role: .identity,
                                accessibilityLabel: "Project"
                            ),
                            .text("Release pipeline", role: .compactBody),
                            .flexibleSpacer,
                            .status("Passed", role: .positive),
                            .button(
                                id: "inspect-project-build",
                                title: "Details",
                                role: .standard,
                                isEnabled: true
                            )
                        ]
                    )
                )
            ],
            from: source
        )

        let defaultContent = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "sidebar.project.default-content"
            }
        )
        XCTAssertTrue(defaultContent.isHidden)
        XCTAssertNotNil(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "extension.component.replacement"
            }
        )
        let trailing = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "sidebar.project.trailing"
            }
        )
        XCTAssertFalse(trailing.isHidden)
        XCTAssertNotNil(
            descendants(in: trailing).first {
                $0.accessibilityIdentifier() == "sidebar.project.count"
            }
        )
        XCTAssertNotNil(
            descendants(in: trailing).first {
                $0.accessibilityIdentifier() == "sidebar.project.actions"
            }
        )

        let button = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier()
                    == "extension.action.inspect-project-build"
            } as? ThemedButton
        )
        button.performClick()
        XCTAssertEqual(
            actions,
            [
                ComponentCustomizationAction(
                    target: target,
                    extensionIdentifier: source.extensionIdentifier,
                    actionID: "inspect-project-build"
                )
            ]
        )

        row.configureAsBranch(named: "main", collapsedSessionCount: 2)
        XCTAssertFalse(defaultContent.isHidden)
        XCTAssertNil(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "extension.component.replacement"
            }
        )
    }

    func testProjectHoverCardComposesMultipleHooksAroundNativeContentAndRoutesActions() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = HostComponentContracts.sidebarProjectHoverCard
        let project = Project(
            name: "Native project",
            folderURL: URL(fileURLWithPath: "/tmp/NativeProject")
        )
        let target = ExtensionComponentTarget.projectHoverCard(
            projectID: project.id.uuidString.lowercased()
        )
        let inner = ComponentCustomizationSource(
            extensionIdentifier: "com.example.ci",
            processGeneration: "one",
            order: 0
        )
        let outer = ComponentCustomizationSource(
            extensionIdentifier: "com.example.owner",
            processGeneration: "one",
            order: 1
        )
        try registry.register(contract)
        try registry.replacePatches(
            [
                .init(
                    id: "ci-details",
                    target: target,
                    hook: .stack(
                        axis: .vertical,
                        spacing: .small,
                        children: [
                            .proceed,
                            .divider,
                            .status("CI passed", role: .positive),
                            .button(
                                id: "open-build",
                                title: "Open Build",
                                role: .standard,
                                isEnabled: true
                            )
                        ]
                    )
                )
            ],
            from: inner
        )
        try registry.replacePatches(
            [
                .init(
                    id: "ownership",
                    target: target,
                    hook: .stack(
                        axis: .vertical,
                        spacing: .small,
                        children: [
                            .text("Owned by Runtime", role: .detail),
                            .proceed
                        ]
                    )
                )
            ],
            from: outer
        )

        let row = ProjectRowView(
            customizationLookup: registry.customization(for:),
            projectHoverContentProvider: { _ in
                self.labelController("Native SCC content")
            }
        )
        var actions: [ComponentCustomizationAction] = []
        row.onCustomizationAction = { actions.append($0) }

        let controller = try XCTUnwrap(row.makeProjectHoverCard(for: project))
        let card = controller.view
        card.frame = NSRect(origin: .zero, size: card.fittingSize)
        card.layoutSubtreeIfNeeded()

        let labels = descendants(in: card)
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains("Native SCC content"))
        XCTAssertTrue(labels.contains("CI passed"))
        XCTAssertTrue(labels.contains("Owned by Runtime"))
        XCTAssertEqual(card.fittingSize.width, ProjectPopoverDefaults.width, accuracy: 0.5)
        XCTAssertEqual(
            Set(
                descendants(in: card).compactMap {
                    $0.accessibilityIdentifier().hasPrefix(
                        "extension.component.hook."
                    ) == true
                        ? $0.accessibilityIdentifier()
                        : nil
                }
            ),
            [
                "extension.component.hook.com.example.ci",
                "extension.component.hook.com.example.owner"
            ]
        )

        let button = try XCTUnwrap(
            descendants(in: card).first {
                $0.accessibilityIdentifier() == "extension.action.open-build"
            } as? ThemedButton
        )
        button.performClick()
        XCTAssertEqual(
            actions,
            [
                ComponentCustomizationAction(
                    target: target,
                    extensionIdentifier: inner.extensionIdentifier,
                    actionID: "open-build"
                )
            ]
        )

        registry.removePatches(
            extensionIdentifier: inner.extensionIdentifier,
            processGeneration: inner.processGeneration
        )
        let refreshedLabels = descendants(in: card)
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(refreshedLabels.contains("Native SCC content"))
        XCTAssertFalse(refreshedLabels.contains("CI passed"))
        XCTAssertTrue(refreshedLabels.contains("Owned by Runtime"))
    }

    func testProjectHoverCardCanReplaceNativeContentOrCreateAnExtensionOnlyCard() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = HostComponentContracts.sidebarProjectHoverCard
        let project = Project(
            name: "Project",
            folderURL: URL(fileURLWithPath: "/tmp/Project")
        )
        let target = ExtensionComponentTarget.projectHoverCard(
            projectID: project.id.uuidString.lowercased()
        )
        let source = ComponentCustomizationSource(
            extensionIdentifier: "com.example.project-card",
            processGeneration: "one",
            order: 0
        )
        try registry.register(contract)
        try registry.replacePatches(
            [
                .init(
                    id: "custom-card",
                    target: target,
                    replacement: .stack(
                        axis: .vertical,
                        spacing: .small,
                        children: [
                            .text("Custom project card", role: .heading),
                            .status("Healthy", role: .positive)
                        ]
                    )
                )
            ],
            from: source
        )
        registry.selectReplacementExtension(
            source.extensionIdentifier,
            for: contract.id
        )

        let withNative = ProjectRowView(
            customizationLookup: registry.customization(for:),
            projectHoverContentProvider: { _ in
                self.labelController("Native SCC content")
            }
        )
        let replaced = try XCTUnwrap(withNative.makeProjectHoverCard(for: project))
        _ = replaced.view
        let replacementLabels = descendants(in: replaced.view)
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(replacementLabels.contains("Custom project card"))
        let retainedNativeLabel = try XCTUnwrap(
            descendants(in: replaced.view).first {
                ($0 as? NSTextField)?.stringValue == "Native SCC content"
            }
        )
        XCTAssertTrue(
            retainedNativeLabel.superview?.isHidden == true,
            "replacement should hide, but retain, the exact native subtree for fallback"
        )

        let extensionOnly = ProjectRowView(
            customizationLookup: registry.customization(for:),
            projectHoverContentProvider: { _ in nil }
        )
        let created = try XCTUnwrap(extensionOnly.makeProjectHoverCard(for: project))
        _ = created.view
        XCTAssertTrue(
            descendants(in: created.view)
                .compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("Custom project card")
        )

        registry.removePatches(
            extensionIdentifier: source.extensionIdentifier,
            processGeneration: source.processGeneration
        )
        XCTAssertNil(extensionOnly.makeProjectHoverCard(for: project))
    }

    func testSessionHoverCardReusesCompositionHostForHooksReplacementAndActions() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = HostComponentContracts.sidebarSessionHoverCard
        let session = AgentSession(kind: .codex, title: "Native session")
        let info = SessionInfoPopoverViewController.Info(session: session, activity: .idle)
        let target = ExtensionComponentTarget.sessionHoverCard(
            sessionID: session.id.uuidString.lowercased()
        )
        let hookSource = ComponentCustomizationSource(
            extensionIdentifier: "com.example.preview",
            processGeneration: "one",
            order: 0
        )
        try registry.register(contract)
        try registry.replacePatches(
            [
                .init(
                    id: "preview-details",
                    target: target,
                    hook: .stack(
                        axis: .vertical,
                        spacing: .small,
                        children: [
                            .proceed,
                            .divider,
                            .status("Preview ready", role: .positive),
                            .button(
                                id: "open-preview",
                                title: "Open Preview",
                                role: .standard,
                                isEnabled: true
                            )
                        ]
                    )
                )
            ],
            from: hookSource
        )

        let row = SessionRowView(
            customizationLookup: registry.customization(for:),
            sessionHoverContentProvider: { _ in
                self.labelController("Native session details")
            }
        )
        var actions: [ComponentCustomizationAction] = []
        row.onCustomizationAction = { actions.append($0) }
        let hooked = try XCTUnwrap(
            row.makeSessionHoverCard(info: info, sessionID: session.id)
        )
        _ = hooked.view
        let hookedLabels = descendants(in: hooked.view)
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(hookedLabels.contains("Native session details"))
        XCTAssertTrue(hookedLabels.contains("Preview ready"))
        XCTAssertEqual(
            hooked.view.fittingSize.width,
            SessionPopoverDefaults.width,
            accuracy: 0.5
        )

        let button = try XCTUnwrap(
            descendants(in: hooked.view).first {
                $0.accessibilityIdentifier() == "extension.action.open-preview"
            } as? ThemedButton
        )
        button.performClick()
        XCTAssertEqual(
            actions,
            [
                ComponentCustomizationAction(
                    target: target,
                    extensionIdentifier: hookSource.extensionIdentifier,
                    actionID: "open-preview"
                )
            ]
        )

        registry.removePatches(
            extensionIdentifier: hookSource.extensionIdentifier,
            processGeneration: hookSource.processGeneration
        )
        let replacementSource = ComponentCustomizationSource(
            extensionIdentifier: "com.example.session-card",
            processGeneration: "one",
            order: 0
        )
        try registry.replacePatches(
            [
                .init(
                    id: "replacement",
                    target: target,
                    replacement: .text("Custom session card", role: .heading)
                )
            ],
            from: replacementSource
        )
        registry.selectReplacementExtension(
            replacementSource.extensionIdentifier,
            for: contract.id
        )

        let extensionOnly = SessionRowView(
            customizationLookup: registry.customization(for:),
            sessionHoverContentProvider: { _ in nil }
        )
        let replaced = try XCTUnwrap(
            extensionOnly.makeSessionHoverCard(info: info, sessionID: session.id)
        )
        _ = replaced.view
        XCTAssertTrue(
            descendants(in: replaced.view)
                .compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("Custom session card")
        )

        registry.removePatches(
            extensionIdentifier: replacementSource.extensionIdentifier,
            processGeneration: replacementSource.processGeneration
        )
        XCTAssertNil(
            extensionOnly.makeSessionHoverCard(info: info, sessionID: session.id)
        )
    }

    func testAccountUsagePopoverKeepsHoverShellWhileContentIsCustomized() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = HostComponentContracts.toolbarAccountUsagePopover
        let account = AgentAccount(
            provider: .codex,
            handle: .standard,
            configPath: "/tmp/codex"
        )
        let target = ExtensionComponentTarget.accountUsagePopover(
            accountID: account.id.rawValue
        )
        let source = ComponentCustomizationSource(
            extensionIdentifier: "com.example.budget",
            processGeneration: "one",
            order: 0
        )
        try registry.register(contract)
        try registry.replacePatches(
            [
                .init(
                    id: "budget-details",
                    target: target,
                    hook: .stack(
                        axis: .vertical,
                        spacing: .small,
                        children: [
                            .proceed,
                            .divider,
                            .status("Team budget available", role: .neutral),
                            .button(
                                id: "open-budget",
                                title: "Open Budget",
                                role: .standard,
                                isEnabled: true
                            )
                        ]
                    )
                )
            ],
            from: source
        )

        let item = AccountUsageItemView(
            customizationLookup: registry.customization(for:),
            usagePopoverContentProvider: { _ in
                self.labelController("Native usage windows")
            }
        )
        var actions: [ComponentCustomizationAction] = []
        item.onCustomizationAction = { actions.append($0) }
        let controller = try XCTUnwrap(item.makeAccountUsagePopover(for: account))
        _ = controller.view
        XCTAssertTrue(controller.view is HoverTrackingView)
        XCTAssertEqual(
            controller.view.fittingSize.width,
            UsagePopoverDefaults.width,
            accuracy: 0.5
        )
        let labels = descendants(in: controller.view)
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains("Native usage windows"))
        XCTAssertTrue(labels.contains("Team budget available"))

        let button = try XCTUnwrap(
            descendants(in: controller.view).first {
                $0.accessibilityIdentifier() == "extension.action.open-budget"
            } as? ThemedButton
        )
        button.performClick()
        XCTAssertEqual(
            actions,
            [
                ComponentCustomizationAction(
                    target: target,
                    extensionIdentifier: source.extensionIdentifier,
                    actionID: "open-budget"
                )
            ]
        )

        registry.removePatches(
            extensionIdentifier: source.extensionIdentifier,
            processGeneration: source.processGeneration
        )
        let replacementSource = ComponentCustomizationSource(
            extensionIdentifier: "com.example.usage-card",
            processGeneration: "one",
            order: 0
        )
        try registry.replacePatches(
            [
                .init(
                    id: "usage-replacement",
                    target: target,
                    replacement: .text("Custom usage card", role: .heading)
                )
            ],
            from: replacementSource
        )
        registry.selectReplacementExtension(
            replacementSource.extensionIdentifier,
            for: contract.id
        )

        let extensionOnly = AccountUsageItemView(
            customizationLookup: registry.customization(for:),
            usagePopoverContentProvider: { _ in nil }
        )
        let replaced = try XCTUnwrap(
            extensionOnly.makeAccountUsagePopover(for: account)
        )
        _ = replaced.view
        XCTAssertTrue(replaced.view is HoverTrackingView)
        XCTAssertTrue(
            descendants(in: replaced.view)
                .compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("Custom usage card")
        )
    }

    func testEveryProductPopoverIsNamedAndHasAnExplicitExtensionBoundary() throws {
        for id in HostPopoverID.allCases {
            switch id.exposure {
            case .component(let componentID):
                let contract = try XCTUnwrap(
                    ThreadingComponentCatalog.entry(id: componentID)?.contract
                )
                XCTAssertEqual(id.rawValue, componentID.rawValue)
                XCTAssertTrue(
                    contract.hostOwnedBehavior.contains(.presentationLifecycle)
                )
                XCTAssertTrue(contract.hostOwnedBehavior.contains(.popoverChrome))
            case .hostOnly(let reason):
                XCTAssertFalse(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }

        // Existing tests are in a fixed target, so this source audit runs even when the new
        // popover's own test file was forgotten. Construction is legal only in the named
        // factory; every call site must choose a catalogue ID.
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { repositoryRoot.deleteLastPathComponent() }
        let sourceRoot = repositoryRoot.appendingPathComponent("Sources/Threading")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: nil
            )
        )
        let initializer = try NSRegularExpression(pattern: #"\bNSPopover\s*\("#)
        var filesWithRawConstruction: [String] = []

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            if initializer.firstMatch(in: source, range: range) != nil {
                filesWithRawConstruction.append(
                    url.path.replacingOccurrences(
                        of: sourceRoot.path + "/",
                        with: ""
                    )
                )
            }
        }

        XCTAssertEqual(
            filesWithRawConstruction,
            ["UI/Extensions/HostPopoverCatalog.swift"]
        )
    }

    func testComposerAccessoryHooksPreserveNativeInputsAndRouteActions() throws {
        let registry = ComponentCustomizationRegistry()
        try registry.register(HostComponentContracts.composerSessionStart)
        try registry.register(HostComponentContracts.composerConversationReply)

        let projectID = ProjectID()
        let session = AgentSession(kind: .codex, title: "Composer")
        let project = Project(
            name: "Composer",
            folderURL: URL(fileURLWithPath: "/tmp/Composer")
        )
        let source = ComponentCustomizationSource(
            extensionIdentifier: "com.example.composer",
            processGeneration: "one",
            order: 0
        )
        let startTarget = ExtensionComponentTarget.sessionStartComposer(
            projectID: projectID.uuidString.lowercased()
        )
        let replyTarget = ExtensionComponentTarget.conversationReplyComposer(
            sessionID: session.id.uuidString.lowercased()
        )
        try registry.replacePatches(
            [
                .init(
                    id: "start-template",
                    target: startTarget,
                    hook: .stack(
                        axis: .horizontal,
                        spacing: .small,
                        children: [
                            .button(
                                id: "insert-template",
                                title: "Template",
                                role: .standard,
                                isEnabled: true
                            ),
                            .proceed
                        ]
                    )
                ),
                .init(
                    id: "reply-context",
                    target: replyTarget,
                    hook: .stack(
                        axis: .horizontal,
                        spacing: .small,
                        children: [
                            .proceed,
                            .button(
                                id: "attach-context",
                                title: "Context",
                                role: .standard,
                                isEnabled: true
                            )
                        ]
                    )
                )
            ],
            from: source
        )

        let startComposer = SessionComposerViewController(
            customizationLookup: registry.customization(for:)
        )
        var startActions: [ComponentCustomizationAction] = []
        startComposer.onCustomizationAction = { startActions.append($0) }
        _ = startComposer.view
        startComposer.updatePromptCustomization(for: projectID)
        let startPrompt = try XCTUnwrap(
            descendants(in: startComposer.view).first { $0 is PromptView } as? PromptView
        )
        XCTAssertNotNil(startPrompt.onSubmit)
        XCTAssertNotNil(startPrompt.onChange)
        let template = try XCTUnwrap(
            descendants(in: startComposer.view).first {
                $0.accessibilityIdentifier() == "extension.action.insert-template"
            } as? ThemedButton
        )
        template.performClick()
        XCTAssertEqual(
            startActions,
            [
                ComponentCustomizationAction(
                    target: startTarget,
                    extensionIdentifier: source.extensionIdentifier,
                    actionID: "insert-template"
                )
            ]
        )

        let replyComposer = ConversationViewController(
            agentSession: session,
            project: project,
            customizationLookup: registry.customization(for:)
        )
        var replyActions: [ComponentCustomizationAction] = []
        replyComposer.onCustomizationAction = { replyActions.append($0) }
        _ = replyComposer.view
        let replyPrompt = try XCTUnwrap(
            descendants(in: replyComposer.view).first { $0 is PromptView } as? PromptView
        )
        XCTAssertNotNil(replyPrompt.onSubmit)
        let context = try XCTUnwrap(
            descendants(in: replyComposer.view).first {
                $0.accessibilityIdentifier() == "extension.action.attach-context"
            } as? ThemedButton
        )
        context.performClick()
        XCTAssertEqual(
            replyActions,
            [
                ComponentCustomizationAction(
                    target: replyTarget,
                    extensionIdentifier: source.extensionIdentifier,
                    actionID: "attach-context"
                )
            ]
        )

        registry.removePatches(
            extensionIdentifier: source.extensionIdentifier,
            processGeneration: source.processGeneration
        )
        XCTAssertNil(
            descendants(in: startComposer.view).first {
                $0.accessibilityIdentifier() == "extension.action.insert-template"
            }
        )
        XCTAssertNil(
            descendants(in: replyComposer.view).first {
                $0.accessibilityIdentifier() == "extension.action.attach-context"
            }
        )
        XCTAssertTrue(
            descendants(in: startComposer.view).contains { $0 === startPrompt }
        )
        XCTAssertTrue(
            descendants(in: replyComposer.view).contains { $0 === replyPrompt }
        )
    }

    func testConversationRowHooksRetainNativeStateAndPermissionAuthority() throws {
        let registry = ComponentCustomizationRegistry()
        for contract in [
            HostComponentContracts.conversationUserMessage,
            HostComponentContracts.conversationAssistantMessage,
            HostComponentContracts.conversationToolCall,
            HostComponentContracts.conversationPermissionCard
        ] {
            try registry.register(contract)
        }

        let session = AgentSession(kind: .codex, title: "Custom rows")
        let project = Project(
            name: "Custom rows",
            folderURL: URL(fileURLWithPath: "/tmp/CustomRows")
        )
        let sessionID = session.id.uuidString.lowercased()
        let source = ComponentCustomizationSource(
            extensionIdentifier: "com.example.conversation-rows",
            processGeneration: "one",
            order: 0
        )
        try registry.replacePatches(
            [
                .init(
                    id: "user-note",
                    target: .conversationUserMessage(sessionID: sessionID),
                    hook: .stack(
                        axis: .vertical,
                        spacing: .small,
                        children: [
                            .proceed,
                            .button(
                                id: "track-turn",
                                title: "Track turn",
                                role: .standard,
                                isEnabled: true
                            )
                        ]
                    )
                ),
                .init(
                    id: "assistant-note",
                    target: .conversationAssistantMessage(sessionID: sessionID),
                    hook: .stack(
                        axis: .vertical,
                        spacing: .small,
                        children: [
                            .proceed,
                            .status("Saved answer", role: .positive)
                        ]
                    )
                ),
                .init(
                    id: "tool-note",
                    target: .conversationToolCall(sessionID: sessionID),
                    hook: .stack(
                        axis: .vertical,
                        spacing: .small,
                        children: [
                            .status("Development environment", role: .neutral),
                            .proceed
                        ]
                    )
                ),
                .init(
                    id: "permission-note",
                    target: .conversationPermissionCard(sessionID: sessionID),
                    hook: .stack(
                        axis: .vertical,
                        spacing: .small,
                        children: [
                            .status("Workspace policy applies", role: .warning),
                            .proceed
                        ]
                    )
                )
            ],
            from: source
        )

        let controller = ConversationViewController(
            agentSession: session,
            project: project,
            customizationLookup: registry.customization(for:)
        )
        var actions: [ComponentCustomizationAction] = []
        controller.onCustomizationAction = { actions.append($0) }
        controller.isVisible = true
        _ = controller.view

        for event in [
            StreamEvent.userMessage("Keep this exact user message"),
            StreamEvent.assistantMessage(blocks: [
                .text("Keep this exact assistant message"),
                .toolUse(
                    id: "tool-1",
                    tool: .bash,
                    input: ["command": "pwd"]
                )
            ])
        ] {
            for change in controller.timeline.apply(event) {
                controller.apply(change)
            }
        }

        var permissionDecision: PermissionDecision?
        controller.presentPermission(
            PermissionRequest(
                sessionID: session.id,
                toolName: "Bash",
                input: ["command": "touch protected.txt"]
            )
        ) {
            permissionDecision = $0
        }

        let wrappers = descendants(in: controller.view).compactMap {
            $0 as? ConversationRowCustomizationView
        }
        XCTAssertEqual(wrappers.count, 4)

        func wrapper(
            _ component: ExtensionComponentID
        ) throws -> ConversationRowCustomizationView {
            try XCTUnwrap(wrappers.first { $0.target.component == component })
        }

        let user = try wrapper(.conversationUserMessage)
        let assistant = try wrapper(.conversationAssistantMessage)
        let tool = try wrapper(.conversationToolCall)
        let permission = try wrapper(.conversationPermissionCard)

        XCTAssertTrue(
            descendants(in: user.nativeContent)
                .compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("Keep this exact user message")
        )
        XCTAssertTrue(assistant.nativeContent is MarkdownView)
        XCTAssertTrue(tool.nativeContent is ToolCallView)
        XCTAssertTrue(permission.nativeContent is PermissionRequestView)

        let actionButton = try XCTUnwrap(
            descendants(in: user).first {
                $0.accessibilityIdentifier() == "extension.action.track-turn"
            } as? ThemedButton
        )
        actionButton.performClick()
        XCTAssertEqual(
            actions,
            [
                ComponentCustomizationAction(
                    target: .conversationUserMessage(sessionID: sessionID),
                    extensionIdentifier: source.extensionIdentifier,
                    actionID: "track-turn"
                )
            ]
        )

        for change in controller.timeline.apply(.toolResults([
            ToolResult(toolUseID: "tool-1", text: "tool output", isError: false)
        ])) {
            controller.apply(change)
        }
        XCTAssertTrue(
            descendants(in: tool.nativeContent)
                .compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("tool output")
        )

        let permissionButtons = descendants(in: permission.nativeContent)
            .compactMap { $0 as? ThemedButton }
            .map(\.title)
        XCTAssertEqual(permissionButtons, ["Allow", "Allow for Session", "Deny"])

        registry.removePatches(
            extensionIdentifier: source.extensionIdentifier,
            processGeneration: source.processGeneration
        )

        for row in [user, assistant, tool, permission] {
            XCTAssertTrue(descendants(in: row).contains { $0 === row.nativeContent })
        }
        XCTAssertNil(
            descendants(in: controller.view).first {
                $0.accessibilityIdentifier().hasPrefix("extension.action.")
            }
        )
        XCTAssertFalse(
            descendants(in: controller.view)
                .compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("Workspace policy applies")
        )

        controller.activePermissionCard?.resolve(.deny(reason: "Test cleanup"))
        if case .deny = permissionDecision {
            // Expected: the host-owned card still settles after its extension annotation leaves.
        } else {
            XCTFail("The native permission decision callback was not preserved.")
        }
    }

    func testRealProjectRowAppliesAndRestoresPropertyPatches() throws {
        let registry = ComponentCustomizationRegistry()
        let contract = HostComponentContracts.sidebarProjectRow
        let source = ComponentCustomizationSource(
            extensionIdentifier: "com.example.presentation",
            processGeneration: "one",
            order: 0
        )
        let project = Project(
            name: "Native project",
            folderURL: URL(fileURLWithPath: "/tmp/NativeProject")
        )
        let target = ExtensionComponentTarget(
            component: contract.id,
            contractVersion: contract.version,
            entityID: project.id.uuidString.lowercased()
        )
        try registry.register(contract)

        let row = ProjectRowView(customizationLookup: registry.customization(for:))
        row.configure(with: project)
        let title = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "sidebar.project.title"
            } as? MorphingTitleLabel
        )
        let icon = try XCTUnwrap(
            descendants(in: row).first {
                $0.accessibilityIdentifier() == "sidebar.project.identity"
            } as? NSImageView
        )
        let nativeImage = icon.image

        try registry.replacePatches(
            [
                .init(
                    id: "presentation",
                    target: target,
                    properties: [
                        .init(property: .title, value: .text("Patched project")),
                        .init(property: .toolTip, value: .text("Build 481")),
                        .init(
                            property: .identityImage,
                            value: .image(.systemSymbol("hammer.fill"))
                        )
                    ]
                )
            ],
            from: source
        )

        XCTAssertEqual(title.stringValue, "Patched project")
        XCTAssertEqual(row.toolTip, "Build 481")
        XCTAssertNotEqual(icon.image, nativeImage)

        registry.removePatches(
            extensionIdentifier: source.extensionIdentifier,
            processGeneration: source.processGeneration
        )
        XCTAssertEqual(title.stringValue, "Native project")
        XCTAssertEqual(row.toolTip, "/tmp/NativeProject")
        XCTAssertEqual(icon.image, nativeImage)
    }

    func testRendererRejectsAnUnreasonablyDeepTree() {
        var node = ExtensionNode.text("leaf", role: .body)
        for _ in 0..<25 {
            node = .stack(axis: .vertical, spacing: .none, children: [node])
        }

        XCTAssertThrowsError(try ExtensionNodeRenderer.render(node) { _ in }) { error in
            XCTAssertEqual(
                error as? ExtensionNodeRenderer.RenderError,
                .tooDeep(maximum: 24)
            )
        }
    }

    func testRendererRejectsAnUnreasonablyLargeTree() {
        let node = ExtensionNode.stack(
            axis: .vertical,
            spacing: .none,
            children: Array(repeating: .divider, count: 500)
        )

        XCTAssertThrowsError(try ExtensionNodeRenderer.render(node) { _ in }) { error in
            XCTAssertEqual(
                error as? ExtensionNodeRenderer.RenderError,
                .tooManyNodes(maximum: 500)
            )
        }
    }

    func testComponentGalleryContainsTheLiveExtensionExperiment() throws {
        let controller = ComponentGalleryViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 760),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()

        let loadButton = try XCTUnwrap(
            descendants(in: controller.view).first {
                $0.accessibilityIdentifier() == "gallery.extension.load"
            }
        )
        XCTAssertTrue(loadButton is ThemedButton)
        let identifiers = Set(
            descendants(in: controller.view).compactMap {
                $0.accessibilityIdentifier()
            }
        )
        XCTAssertTrue(
            identifiers.contains("gallery.extension.component.default")
        )
        XCTAssertTrue(
            identifiers.contains("gallery.extension.component.slot")
        )
        XCTAssertTrue(
            identifiers.contains("gallery.extension.component.replacement")
        )
        XCTAssertTrue(
            identifiers.contains("gallery.extension.component.invalid")
        )
        XCTAssertTrue(
            identifiers.contains("gallery.extension.component.session-row")
        )
        XCTAssertTrue(
            identifiers.contains(
                "gallery.extension.component.session-row-replacement"
            )
        )
        XCTAssertTrue(
            identifiers.contains(
                "gallery.extension.component.project-session-ci"
            )
        )
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])

        let sessionRow = try XCTUnwrap(
            descendants(in: controller.view).first {
                $0.accessibilityIdentifier()
                    == "gallery.extension.component.session-row-replacement"
            }
        )
        sessionRow.layoutSubtreeIfNeeded()
        let rendered = try XCTUnwrap(
            sessionRow.bitmapImageRepForCachingDisplay(in: sessionRow.bounds)
        )
        sessionRow.cacheDisplay(in: sessionRow.bounds, to: rendered)
        let png = try XCTUnwrap(rendered.representation(using: .png, properties: [:]))
        XCTAssertFalse(png.isEmpty)

        if let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try png.write(
                to: directory.appendingPathComponent("session-row-replacement.png")
            )
        }
    }

    func testComponentAuthoringServiceListsDescribesAndValidatesFromOneCatalogue() throws {
        let list = try ExtensionComponentAuthoringService.listJSON()
        XCTAssertTrue(list.contains(#""sidebar.session-row""#))
        XCTAssertTrue(list.contains(#""sidebar.session-identity""#))

        let description = try ExtensionComponentAuthoringService.describeJSON(
            componentID: "sidebar.session-identity",
            version: 1
        )
        XCTAssertTrue(description.contains(#""session.provider-image""#))
        XCTAssertTrue(description.contains(#""patchSchema""#))

        let patch = ThreadingComponentCatalog.entries.first {
            $0.contract.id == .sidebarSessionIdentity
        }!.examplePatch
        let patchJSON = String(
            decoding: try JSONEncoder().encode(patch),
            as: UTF8.self
        )
        let validation = try ExtensionComponentAuthoringService.validateJSON(patchJSON)
        XCTAssertTrue(validation.contains(#""valid" : true"#))
        XCTAssertTrue(validation.contains(#""two-part-session-identity""#))
    }

    func testComponentAuthoringServiceRejectsAndPreviewsWithTheRuntimeRules() throws {
        let invalid = ExtensionComponentPatch(
            id: "wrong-axis",
            target: .sessionIdentity(),
            replacement: .stack(
                axis: .vertical,
                spacing: .small,
                children: [
                    .image(
                        .hostAsset("session.provider-image"),
                        role: .identity,
                        accessibilityLabel: "Provider"
                    )
                ]
            )
        )
        let invalidJSON = String(
            decoding: try JSONEncoder().encode(invalid),
            as: UTF8.self
        )
        XCTAssertThrowsError(
            try ExtensionComponentAuthoringService.validateJSON(invalidJSON)
        )
        XCTAssertThrowsError(
            try ExtensionComponentAuthoringService.preview(invalidJSON)
        )

        let patch = try XCTUnwrap(
            ThreadingComponentCatalog.entries.first {
                $0.contract.id == .sidebarSessionIdentity
            }?.examplePatch
        )
        let patchJSON = String(
            decoding: try JSONEncoder().encode(patch),
            as: UTF8.self
        )
        let preview = try ExtensionComponentAuthoringService.preview(patchJSON)
        defer { try? FileManager.default.removeItem(at: preview.url) }

        XCTAssertEqual(preview.componentID, "sidebar.session-identity")
        XCTAssertEqual(preview.image.size, NSSize(width: 520, height: 156))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.url.path))
        XCTAssertGreaterThan(
            (try preview.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
            0
        )
    }

    func testProductionExtensionPanelRoutesContextAndFallsBackWhenProviderStops() throws {
        let initial = ExtensionPanel(
            id: "build-status",
            title: "Build Status",
            root: .button(
                id: "refresh",
                title: "Refresh",
                role: .primary,
                isEnabled: true
            )
        )
        let updated = ExtensionPanel(
            id: initial.id,
            title: initial.title,
            root: .status("Passed", role: .positive)
        )
        let router = TestExtensionPanelRouter(
            item: .init(
                extensionIdentifier: "com.example.ci",
                extensionName: "CI",
                processGeneration: "generation-one",
                panel: initial
            )
        )
        router.result = .success(.init(
            requestID: "response",
            panel: updated,
            message: "Build refreshed."
        ))
        let context = ExtensionCommandContext(
            projectID: "project-1",
            sessionID: "session-1"
        )
        let controller = ExtensionPanelViewController(
            extensionIdentifier: "com.example.ci",
            panelID: initial.id,
            title: initial.title,
            context: context,
            router: router
        )
        _ = controller.view

        let refresh = try XCTUnwrap(
            descendants(in: controller.view)
                .compactMap { $0 as? ThemedButton }
                .first { $0.accessibilityIdentifier() == "extension.action.refresh" }
        )
        refresh.performClick()

        XCTAssertEqual(router.actions.map(\.context), [context])
        XCTAssertTrue(
            descendants(in: controller.view)
                .compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("Passed")
        )
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])

        router.item = nil
        NotificationCenter.default.post(ExtensionsDidChange())
        XCTAssertTrue(
            descendants(in: controller.view).contains {
                $0.accessibilityIdentifier() == "extension.panel.unavailable"
            }
        )
    }

    func testProductionExtensionPanelLoadsContextOncePerProcessGeneration() throws {
        let initial = ExtensionPanel(
            id: "session-info",
            title: "Session Info",
            root: .status("Loading", role: .neutral),
            loadActionID: "load-session"
        )
        let loaded = ExtensionPanel(
            id: initial.id,
            title: initial.title,
            root: .text("Current session", role: .heading),
            loadActionID: initial.loadActionID
        )
        let router = TestExtensionPanelRouter(
            item: .init(
                extensionIdentifier: "com.example.session-info",
                extensionName: "Session Info",
                processGeneration: "generation-one",
                panel: initial
            )
        )
        router.result = .success(.init(requestID: "response", panel: loaded))
        let context = ExtensionCommandContext(
            projectID: "project-1",
            sessionID: "session-1"
        )
        let controller = ExtensionPanelViewController(
            extensionIdentifier: "com.example.session-info",
            panelID: initial.id,
            title: initial.title,
            context: context,
            router: router
        )

        _ = controller.view

        XCTAssertEqual(router.actions.map(\.actionID), ["load-session"])
        XCTAssertEqual(router.actions.map(\.context), [context])
        XCTAssertTrue(
            descendants(in: controller.view)
                .compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("Current session")
        )

        NotificationCenter.default.post(ExtensionsDidChange())
        XCTAssertEqual(router.actions.map(\.actionID), ["load-session"])

        router.item = .init(
            extensionIdentifier: "com.example.session-info",
            extensionName: "Session Info",
            processGeneration: "generation-two",
            panel: initial
        )
        NotificationCenter.default.post(ExtensionsDidChange())
        XCTAssertEqual(
            router.actions.map(\.actionID),
            ["load-session", "load-session"]
        )
    }

    func testProductionExtensionPanelHostsCompanionPixelsWithSemanticFallback() throws {
        let panel = ExtensionPanel(
            id: "device",
            title: "Device",
            root: .status("Device display unavailable", role: .neutral),
            remoteSurface: .init(companionID: "worker", surfaceID: "device")
        )
        let router = TestExtensionPanelRouter(
            item: .init(
                extensionIdentifier: "com.example.device",
                extensionName: "Device",
                processGeneration: "generation-one",
                panel: panel
            )
        )
        router.remoteDefinition = .init(
            id: "device",
            title: "Device",
            accessibilityLabel: "Live device display",
            maximumWidth: 1_280,
            maximumHeight: 800,
            acceptsPointer: true,
            acceptsKeyboard: true
        )
        let context = ExtensionCommandContext(
            projectID: "project-1",
            sessionID: "session-1"
        )
        let controller = ExtensionPanelViewController(
            extensionIdentifier: "com.example.device",
            panelID: panel.id,
            title: panel.title,
            context: context,
            router: router
        )
        controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let surface = try XCTUnwrap(
            descendants(in: controller.view)
                .compactMap { $0 as? ExtensionRemoteSurfaceView }
                .first
        )
        XCTAssertEqual(router.remoteContexts, [context])
        XCTAssertEqual(router.remoteViewports.first?.isVisible, false)
        XCTAssertEqual(surface.accessibilityLabel(), "Live device display")
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])

        XCTAssertTrue(surface.remoteSurfaceDidReceive(.init(
            metadata: .init(
                presentationID: try XCTUnwrap(surface.subscription?.presentationID),
                sequence: 1,
                width: 2,
                height: 2,
                bytesPerRow: 8,
                payloadLength: 16
            ),
            pixels: Data(repeating: 0xFF, count: 16)
        )) == false, "an off-window panel accepts the frame but reports it dropped")
        XCTAssertNotNil(surface.layer?.contents)

        surface.remoteSurfaceDidDisconnect(message: "Worker stopped.")
        XCTAssertTrue(
            descendants(in: controller.view).contains {
                $0.accessibilityIdentifier() == "extension.remote-surface.fallback"
            }
        )
        XCTAssertTrue(
            descendants(in: controller.view)
                .compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("Device display unavailable")
        )
    }

    func testCornerCardShowsExtensionRowsAndRestoresItsSingleLine() throws {
        let registry = ComponentCustomizationRegistry()
        try registry.register(HostComponentContracts.sessionCornerCard)

        let sessionID = SessionID()
        let publicSessionID = sessionID.uuidString.lowercased()
        let source = ComponentCustomizationSource(
            extensionIdentifier: "com.example.checks",
            processGeneration: "one",
            order: 0
        )
        try registry.replacePatches(
            [
                .init(
                    id: "checks-row",
                    target: .sessionCornerCard(sessionID: publicSessionID),
                    slots: [
                        .init(
                            slot: "top-trailing",
                            children: [
                                .stack(
                                    axis: .horizontal,
                                    spacing: .small,
                                    children: [
                                        .text("Checks", role: .compactDetail),
                                        .flexibleSpacer,
                                        .status("Successful", role: .positive)
                                    ]
                                )
                            ]
                        )
                    ]
                )
            ],
            from: source
        )

        let card = GitStatusOverlayView(
            customizationLookup: registry.customization(for:)
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        container.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: Design.Spacing.inset
            ),
            card.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -Design.Spacing.inset
            )
        ])

        // A bound slot on a card with no checkout reading renders nothing the user can see:
        // extension rows ride the card's own visibility.
        card.showSession(publicSessionID)
        container.layoutSubtreeIfNeeded()
        XCTAssertTrue(card.isHidden)

        let reading = GitChangeMonitor.Reading(
            branch: "main",
            summary: GitChangeSummary(files: 2, added: 35, removed: 1)
        )
        card.update(with: reading)
        container.layoutSubtreeIfNeeded()
        XCTAssertFalse(card.isHidden)

        // What the same reading is worth on a card with no slot bound to it: the card stacks
        // one row per fact, so "its own height" is no longer a single constant.
        let native = GitStatusOverlayView()
        native.update(with: reading)
        let nativeHeight = native.fittingSize.height

        let row = try XCTUnwrap(descendants(in: card).first {
            $0.accessibilityIdentifier() == "extension.component.slot.top-trailing"
        })
        XCTAssertGreaterThan(
            card.frame.height,
            nativeHeight,
            "A card with an extension row grows below its summary line"
        )
        XCTAssertEqual(
            row.frame.width,
            card.frame.width - 2 * Design.Spacing.medium,
            accuracy: 0.5,
            "A row stretches to the card's width so a flexible spacer holds name and state apart"
        )

        // Revoking the generation restores the exact single-line card.
        registry.removePatches(
            extensionIdentifier: source.extensionIdentifier,
            processGeneration: source.processGeneration
        )
        container.layoutSubtreeIfNeeded()
        XCTAssertNil(descendants(in: card).first {
            $0.accessibilityIdentifier() == "extension.component.slot.top-trailing"
        })
        XCTAssertEqual(
            card.frame.height,
            nativeHeight,
            accuracy: 0.5,
            "An empty slot reproduces the card's own height exactly"
        )

        // Family-wide rows decorate the bound session, and detaching the slot between
        // sessions removes them without touching the native summary.
        try registry.replacePatches(
            [
                .init(
                    id: "family-row",
                    target: .sessionCornerCard(),
                    slots: [
                        .init(
                            slot: "top-trailing",
                            children: [.status("All sessions", role: .neutral)]
                        )
                    ]
                )
            ],
            from: source
        )
        container.layoutSubtreeIfNeeded()
        XCTAssertNotNil(descendants(in: card).first {
            $0.accessibilityIdentifier() == "extension.component.slot.top-trailing"
        })

        card.showSession(nil)
        container.layoutSubtreeIfNeeded()
        XCTAssertNil(descendants(in: card).first {
            $0.accessibilityIdentifier() == "extension.component.slot.top-trailing"
        })
        XCTAssertEqual(card.frame.height, nativeHeight, accuracy: 0.5)
        XCTAssertFalse(card.isHidden, "Detaching the slot never hides the native summary")
    }

    func testDisplayChromeAddsSessionStatusWithoutTakingTabAuthority() throws {
        let registry = ComponentCustomizationRegistry()
        try registry.register(HostComponentContracts.displayPaneHeader)
        try registry.register(HostComponentContracts.displayTabHeader)

        let sessionID = SessionID()
        let publicSessionID = sessionID.uuidString.lowercased()
        let source = ComponentCustomizationSource(
            extensionIdentifier: "com.example.display-status",
            processGeneration: "one",
            order: 0
        )
        try registry.replacePatches(
            [
                .init(
                    id: "pane-status",
                    target: .displayPaneHeader(sessionID: publicSessionID),
                    hook: .stack(
                        axis: .horizontal,
                        spacing: .small,
                        children: [
                            .status("Development", role: .neutral),
                            .button(
                                id: "refresh",
                                title: "Refresh",
                                role: .standard,
                                isEnabled: true
                            ),
                            .proceed
                        ]
                    )
                ),
                .init(
                    id: "tab-status",
                    target: .displayTabHeader(sessionID: publicSessionID),
                    slots: [
                        .init(
                            slot: "after-title",
                            children: [.status("Live", role: .positive)]
                        )
                    ]
                )
            ],
            from: source
        )

        let controller = DisplayPaneController(
            customizationLookup: registry.customization(for:)
        )
        var actions: [ComponentCustomizationAction] = []
        controller.onCustomizationAction = { actions.append($0) }
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
        controller.showSession(sessionID)
        controller.addContentTab(
            DisplayContent(
                body: .html("<p>First</p>"),
                title: "First",
                subtitle: "First document"
            ),
            for: sessionID
        )
        controller.addContentTab(
            DisplayContent(
                body: .html("<p>Second</p>"),
                title: "Second",
                subtitle: "Second document"
            ),
            for: sessionID
        )
        controller.view.layoutSubtreeIfNeeded()

        let pane = try XCTUnwrap(
            descendants(in: controller.view).first {
                $0 is DisplayPaneHeaderCustomizationView
            } as? DisplayPaneHeaderCustomizationView
        )
        let refresh = try XCTUnwrap(
            descendants(in: pane).first {
                $0.accessibilityIdentifier() == "extension.action.refresh"
            } as? ThemedButton
        )
        refresh.performClick()
        XCTAssertEqual(
            actions,
            [
                ComponentCustomizationAction(
                    target: .displayPaneHeader(sessionID: publicSessionID),
                    extensionIdentifier: source.extensionIdentifier,
                    actionID: "refresh"
                )
            ]
        )

        var tabs = descendants(in: controller.view).compactMap {
            $0 as? DisplayTabHeaderCustomizationView
        }
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(Set(tabs.map(\.target)), [
            .displayTabHeader(sessionID: publicSessionID)
        ])
        XCTAssertTrue(tabs.allSatisfy {
            descendants(in: $0.nativeContent)
                .compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("Live")
        })

        let first = try XCTUnwrap(tabs.first { $0.nativeContent.title == "First" })
        first.nativeContent.onSelect?()
        tabs = descendants(in: controller.view).compactMap {
            $0 as? DisplayTabHeaderCustomizationView
        }
        XCTAssertTrue(
            try XCTUnwrap(tabs.first { $0.nativeContent.title == "First" })
                .nativeContent.isSelected
        )

        let second = try XCTUnwrap(tabs.first { $0.nativeContent.title == "Second" })
        second.nativeContent.onClose?()
        tabs = descendants(in: controller.view).compactMap {
            $0 as? DisplayTabHeaderCustomizationView
        }
        XCTAssertEqual(tabs.map(\.nativeContent.title), ["First"])

        let retainedNativeTab = try XCTUnwrap(tabs.first?.nativeContent)
        registry.removePatches(
            extensionIdentifier: source.extensionIdentifier,
            processGeneration: source.processGeneration
        )

        XCTAssertTrue(descendants(in: controller.view).contains { $0 === retainedNativeTab })
        XCTAssertNil(
            descendants(in: controller.view).first {
                $0.accessibilityIdentifier() == "extension.action.refresh"
            }
        )
        XCTAssertFalse(
            descendants(in: retainedNativeTab)
                .compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("Live")
        )

        retainedNativeTab.onClose?()
    }

    func testExtensionPanelTabPersistenceKeepsOnlyStableContributionIdentity() throws {
        let tab = PersistedTab(
            id: UUID().uuidString,
            kind: .extensionPanel,
            title: "Build Status",
            subtitle: "",
            url: nil,
            html: nil,
            cacheFile: nil,
            extensionIdentifier: "com.example.ci",
            extensionPanelID: "build-status"
        )
        let panel = PersistedPanel(
            tabs: [tab],
            activeTabID: tab.id,
            observedSignature: "previous"
        )
        let decoded = try JSONDecoder().decode(
            PersistedPanel.self,
            from: JSONEncoder().encode(panel)
        )

        XCTAssertEqual(decoded.tabs.first?.kind, .extensionPanel)
        XCTAssertEqual(decoded.tabs.first?.extensionIdentifier, "com.example.ci")
        XCTAssertEqual(decoded.tabs.first?.extensionPanelID, "build-status")
        XCTAssertTrue(decoded.signature.contains("com.example.ci/build-status"))
        XCTAssertTrue(decoded.agentDescription.contains("extension panel \"Build Status\""))
    }

    private func descendants(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private func labelController(_ text: String) -> NSViewController {
        let controller = NSViewController()
        let root = NSView()
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: root.topAnchor),
            label.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])
        controller.view = root
        return controller
    }

    /// Runs extension-side work the way an extension actually runs it: not on the host's main
    /// thread.
    ///
    /// Brokered storage is synchronous, and the host routes on the main actor. In production
    /// those are different processes, so an extension blocking on a reply is nobody else's
    /// problem. In a test both ends share one process, and a call made *from* the main thread
    /// would deadlock against the router it is waiting for.
    private func asAnExtensionProcess<Value>(
        timeout: TimeInterval = 10,
        _ work: @escaping @Sendable () throws -> Value
    ) throws -> Value {
        let finished = expectation(description: "extension-side work")
        let box = ResultBox<Value>()
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = Result { try work() }
            finished.fulfill()
        }
        wait(for: [finished], timeout: timeout)
        return try XCTUnwrap(box.value).get()
    }

    private final class ResultBox<Value>: @unchecked Sendable {
        var value: Result<Value, Error>?
    }

    private func route(
        _ publication: ExtensionComponentPatchPublication,
        token: String,
        through service: ExtensionHostService
    ) -> HTTPResponse {
        var result: HTTPResponse?
        service.route(
            HTTPRequest(
                method: "PUT",
                path: "/v1/component-patches",
                headers: [
                    "authorization": "Bearer \(token)",
                    "content-type": "application/json"
                ],
                body: try! JSONEncoder().encode(publication)
            )
        ) {
            result = $0
        }
        return result!
    }

    private func routeIdentity(
        _ publication: ExtensionIdentityResolutionPublication,
        token: String,
        through service: ExtensionHostService
    ) -> HTTPResponse {
        var result: HTTPResponse?
        service.route(
            HTTPRequest(
                method: "PUT",
                path: "/v1/identity-resolutions",
                headers: [
                    "authorization": "Bearer \(token)",
                    "content-type": "application/json"
                ],
                body: try! JSONEncoder().encode(publication)
            )
        ) {
            result = $0
        }
        return result!
    }

    private func get(
        _ path: String,
        token: String,
        through service: ExtensionHostService
    ) -> HTTPResponse {
        var result: HTTPResponse?
        service.route(
            HTTPRequest(
                method: "GET",
                path: path,
                headers: ["authorization": "Bearer \(token)"],
                body: Data()
            )
        ) {
            result = $0
        }
        return result!
    }

    private func decodedGET<Value: Decodable>(
        _ path: String,
        token: String,
        through service: ExtensionHostService
    ) throws -> Value {
        let response = get(path, token: token, through: service)
        XCTAssertEqual(response.status, 200)
        return try JSONDecoder().decode(Value.self, from: response.body)
    }

    private func routeService(
        providerIdentifier: String,
        serviceID: String,
        call: ExtensionServiceCall,
        token: String,
        through service: ExtensionHostService
    ) -> HTTPResponse {
        var result: HTTPResponse?
        service.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/services/\(providerIdentifier)/\(serviceID)",
                headers: [
                    "authorization": "Bearer \(token)",
                    "content-type": "application/json"
                ],
                body: try! JSONEncoder().encode(call)
            )
        ) {
            result = $0
        }
        return result!
    }

    private func sessionRowContract() -> ExtensionComponentContract {
        ExtensionComponentContract(
            id: "sidebar.session-row",
            version: 1,
            context: .sessionPresentation,
            properties: [.title, .identityImage, .toolTip],
            slots: [
                .init(id: "after-title", maximumInlineItems: 2)
            ],
            replacement: .contentOnly,
            hostOwnedBehavior: [
                .selection,
                .dragAndDrop,
                .rowActions,
                .activityState,
                .accessibilityContainer
            ]
        )
    }
}

@MainActor
private final class TestExtensionHostSnapshotProvider:
    ExtensionHostSnapshotProviding,
    ExtensionSessionRuntimeSnapshotProviding
{
    var projects: [ExtensionProjectSnapshot]
    var sessions: [ExtensionSessionSnapshot]
    var providers: [ExtensionProviderSnapshot]
    var accounts: [ExtensionAccountSnapshot]
    var runtimeSnapshots: [String: ExtensionSessionRuntimeSnapshot]
    var runtimeRequests: [String] = []

    init(
        projects: [ExtensionProjectSnapshot] = [],
        sessions: [ExtensionSessionSnapshot] = [],
        providers: [ExtensionProviderSnapshot] = [],
        accounts: [ExtensionAccountSnapshot] = [],
        runtimeSnapshots: [String: ExtensionSessionRuntimeSnapshot] = [:]
    ) {
        self.projects = projects
        self.sessions = sessions
        self.providers = providers
        self.accounts = accounts
        self.runtimeSnapshots = runtimeSnapshots
    }

    func projectSnapshots() -> [ExtensionProjectSnapshot] {
        projects
    }

    func sessionSnapshots() -> [ExtensionSessionSnapshot] {
        sessions
    }

    func providerSnapshots() -> [ExtensionProviderSnapshot] {
        providers
    }

    func accountSnapshots() -> [ExtensionAccountSnapshot] {
        accounts
    }

    func sessionRuntimeSnapshot(
        for sessionID: String,
        completion: @escaping @MainActor (ExtensionSessionRuntimeSnapshot) -> Void
    ) {
        runtimeRequests.append(sessionID)
        completion(
            runtimeSnapshots[sessionID]
                ?? .init(sessionID: sessionID, processGroups: [], portGroups: [])
        )
    }
}

private final class BlockingExtensionKeyValueStore:
    ExtensionKeyValueStoring,
    @unchecked Sendable
{
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func keyValues(extensionIdentifier: String) throws -> [String: ExtensionJSONValue] {
        entered.signal()
        release.wait()
        return [:]
    }

    func setKeyValue(
        _ value: ExtensionJSONValue,
        extensionIdentifier: String,
        key: String
    ) throws {}

    func removeKeyValue(extensionIdentifier: String, key: String) throws {}
}

@MainActor
private final class TestExtensionServiceRouter: ExtensionServiceRouting {
    struct Call {
        let provider: String
        let serviceID: String
        let version: Int
        let caller: String
        let arguments: ExtensionJSONValue
    }

    var calls: [Call] = []
    var result: Result<ExtensionServiceResponse, Error> = .failure(
        ExtensionServiceBrokerError.providerUnavailable("test")
    )

    func invokeService(
        providerIdentifier: String,
        serviceID: String,
        serviceVersion: Int,
        callerExtensionIdentifier: String,
        arguments: ExtensionJSONValue,
        completion: @escaping @MainActor @Sendable (
            Result<ExtensionServiceResponse, Error>
        ) -> Void
    ) {
        calls.append(.init(
            provider: providerIdentifier,
            serviceID: serviceID,
            version: serviceVersion,
            caller: callerExtensionIdentifier,
            arguments: arguments
        ))
        completion(result)
    }
}

@MainActor
private final class TestExtensionPanelRouter: ExtensionPanelRouting {
    struct Action {
        let extensionIdentifier: String
        let panelID: String
        let actionID: String
        let context: ExtensionCommandContext
    }

    var item: ExtensionPanelInventoryItem?
    var actions: [Action] = []
    var result: Result<ExtensionActionResponse, Error> = .failure(
        ExtensionProcessError.notRunning
    )
    var remoteDefinition: ExtensionRemoteSurface?
    var remoteContexts: [ExtensionCommandContext] = []
    var remoteViewports: [ExtensionRemoteSurfaceViewport] = []
    var remoteInputs: [ExtensionRemoteSurfaceInput] = []
    var remoteCancellations = 0

    init(item: ExtensionPanelInventoryItem?) {
        self.item = item
    }

    var extensionPanelInventory: [ExtensionPanelInventoryItem] {
        item.map { [$0] } ?? []
    }

    func registeredPanel(
        extensionIdentifier: String,
        panelID: String
    ) -> ExtensionPanelInventoryItem? {
        guard item?.extensionIdentifier == extensionIdentifier,
              item?.panel.id == panelID else {
            return nil
        }
        return item
    }

    func extensionImageResourceURL(
        extensionIdentifier: String,
        relativePath: String
    ) -> URL? {
        nil
    }

    func invokePanelAction(
        extensionIdentifier: String,
        panelID: String,
        actionID: String,
        context: ExtensionCommandContext,
        completion: @escaping (Result<ExtensionActionResponse, Error>) -> Void
    ) -> Bool {
        actions.append(.init(
            extensionIdentifier: extensionIdentifier,
            panelID: panelID,
            actionID: actionID,
            context: context
        ))
        completion(result)
        return true
    }

    func connectRemoteSurface(
        extensionIdentifier: String,
        panelID: String,
        context: ExtensionCommandContext,
        initialViewport: ExtensionRemoteSurfaceViewport,
        consumer: ExtensionRemoteSurfaceConsumer
    ) -> ExtensionRemoteSurfaceSubscription? {
        guard let remoteDefinition else { return nil }
        remoteContexts.append(context)
        remoteViewports.append(initialViewport)
        consumer.remoteSurfaceDidConnect(definition: remoteDefinition)
        return ExtensionRemoteSurfaceSubscription(
            presentationID: initialViewport.presentationID,
            viewport: { [weak self] viewport in
                self?.remoteViewports.append(viewport)
            },
            input: { [weak self] input in
                self?.remoteInputs.append(input)
            },
            cancellation: { [weak self] in
                self?.remoteCancellations += 1
            }
        )
    }
}

private final class TestExtensionSecretStore:
    ExtensionSecretStoring,
    @unchecked Sendable
{
    private var values: [String: [String: Data]] = [:]

    func data(extensionIdentifier: String, key: String) throws -> Data? {
        values[extensionIdentifier]?[key]
    }

    func setData(
        _ data: Data,
        extensionIdentifier: String,
        key: String
    ) throws {
        values[extensionIdentifier, default: [:]][key] = data
    }

    func remove(extensionIdentifier: String, key: String) throws {
        values[extensionIdentifier]?[key] = nil
    }

    func keys(extensionIdentifier: String) throws -> [String] {
        values[extensionIdentifier]?.keys.sorted() ?? []
    }
}
