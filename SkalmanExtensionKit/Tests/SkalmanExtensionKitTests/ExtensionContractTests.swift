import Foundation
import XCTest
@testable import SkalmanExtensionKit
@testable import SkalmanExtensionPolicy

final class ExtensionContractTests: XCTestCase {
    func testSafeAPIV1VersionDomainsAndCapabilitiesArePinned() throws {
        XCTAssertEqual(SkalmanExtensionAPI.majorVersion, 1)
        XCTAssertEqual(SkalmanExtensionAPI.sdkVersion, 1)
        XCTAssertEqual(
            SkalmanExtensionAPI.manifestFormatVersion,
            ExtensionManifest.currentFormatVersion
        )
        XCTAssertEqual(SkalmanExtensionAPI.processProtocolVersion, 1)
        XCTAssertEqual(
            SkalmanExtensionAPI.hostProtocolVersion,
            ExtensionComponentPatchPublication.currentProtocolVersion
        )
        XCTAssertEqual(SkalmanExtensionAPI.companionProtocolVersion, 1)
        XCTAssertEqual(SkalmanExtensionAPI.remoteSurfaceProtocolVersion, 1)
        XCTAssertEqual(
            SkalmanExtensionAPI.componentContractVersions,
            [
                .applicationMainWindow: 1,
                .composerConversationReply: 1,
                .composerSessionStart: 1,
                .conversationAssistantMessage: 1,
                .conversationPermissionCard: 1,
                .conversationToolCall: 1,
                .conversationUserMessage: 1,
                .displayPaneHeader: 1,
                .displayTabHeader: 1,
                .sidebarProjectHoverCard: 1,
                .sidebarProjectRow: 1,
                .sidebarSessionIdentity: 1,
                .sidebarSessionHoverCard: 1,
                .sidebarSessionRow: 1,
                .toolbarAccountUsagePopover: 1
            ]
        )
        XCTAssertFalse(
            SkalmanExtensionAPI.safeCapabilities.contains(.networkClient),
            "WebAssembly has no socket or safe network-broker import in API v1"
        )
        XCTAssertTrue(
            SkalmanExtensionAPI.safeCapabilities.contains(.hostSessionRuntimeRead)
        )
        XCTAssertTrue(
            SkalmanExtensionAPI.safeCapabilities.contains(.companionOperations)
        )

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sdkVersion = try String(
            contentsOf: packageRoot.appendingPathComponent("SDK_VERSION"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(sdkVersion, String(SkalmanExtensionAPI.sdkVersion))
    }

    func testHostSnapshotAndCursorEventContractsRoundTrip() throws {
        let repository = ExtensionRepositorySnapshot(
            remoteHost: "github.com",
            repositoryPath: "mjukis/skalman",
            branch: "main",
            headRevision: String(repeating: "a", count: 40)
        )
        let project = ExtensionProjectSnapshot(
            id: "project-1",
            displayName: "Skalman",
            repository: repository
        )
        let session = ExtensionSessionSnapshot(
            id: "session-1",
            projectID: project.id,
            providerID: "codex",
            accountID: "codex:default",
            displayTitle: "Add extension events",
            activity: .working,
            branch: "main",
            isSideChat: false,
            isArchived: false,
            usesNativeUI: true
        )
        let page = ExtensionHostEventPage(
            events: [
                .init(
                    cursor: 42,
                    kind: .sessionChanged,
                    entityID: session.id,
                    projectID: project.id
                )
            ],
            nextCursor: 42,
            hasMore: false
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(
                ExtensionProjectSnapshotPage.self,
                from: encoder.encode(
                    ExtensionProjectSnapshotPage(cursor: 41, projects: [project])
                )
            ).projects,
            [project]
        )
        XCTAssertEqual(
            try decoder.decode(
                ExtensionSessionSnapshotPage.self,
                from: encoder.encode(
                    ExtensionSessionSnapshotPage(cursor: 41, sessions: [session])
                )
            ).sessions,
            [session]
        )
        let runtime = ExtensionSessionRuntimeSnapshot(
            sessionID: session.id,
            processGroups: [
                .init(
                    origin: .agent,
                    processes: [
                        .init(
                            processIdentifier: 42,
                            command: "node",
                            memoryBytes: 8_388_608,
                            cpuPercent: nil
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
                            address: "::",
                            isIPv6: true,
                            interface: .allInterfaces,
                            isReachableViaLocalhost: true
                        )
                    ]
                )
            ]
        )
        XCTAssertEqual(
            try decoder.decode(
                ExtensionSessionRuntimeSnapshot.self,
                from: encoder.encode(runtime)
            ),
            runtime
        )
        XCTAssertEqual(
            try decoder.decode(ExtensionHostEventPage.self, from: encoder.encode(page)),
            page
        )
    }

    func testManifestRoundTripsUnknownCapabilities() throws {
        let manifest = ExtensionManifest(
            identifier: "se.mjukis.example",
            name: "Example",
            version: "1.0.0",
            executable: "bin/example",
            capabilities: [.commands, .init(rawValue: "future.capability")]
        )

        try manifest.validate()
        let decoded = try JSONDecoder().decode(
            ExtensionManifest.self,
            from: JSONEncoder().encode(manifest)
        )

        XCTAssertEqual(decoded, manifest)
    }

    func testManifestRejectsPathsThatEscapeTheExtensionDirectory() {
        let manifest = ExtensionManifest(
            identifier: "se.mjukis.example",
            name: "Example",
            version: "1.0.0",
            executable: "../example"
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            let validation = error as? ExtensionValidationError
            XCTAssertEqual(validation?.issues.map(\.path), ["executable"])
        }
    }

    func testManifestRuntimeDefaultsToNativeAndWebAssemblyRequiresAWasmArtifact() throws {
        let legacyJSON = Data("""
        {
          "formatVersion": 1,
          "identifier": "se.mjukis.legacy",
          "name": "Legacy",
          "version": "1.0.0",
          "executable": "bin/legacy",
          "capabilities": []
        }
        """.utf8)
        let legacy = try JSONDecoder().decode(ExtensionManifest.self, from: legacyJSON)
        XCTAssertEqual(legacy.runtime, .native)
        XCTAssertEqual(legacy.dataVersion, 1)

        let invalid = ExtensionManifest(
            identifier: "se.mjukis.wasm",
            name: "Wasm",
            version: "1.0.0",
            runtime: .webAssembly,
            executable: "bin/not-a-module"
        )
        XCTAssertThrowsError(try invalid.validate()) { error in
            XCTAssertEqual(
                (error as? ExtensionValidationError)?.issues.map(\.path),
                ["executable"]
            )
        }
    }

    func testAdvancedCompanionsRoundTripWithoutChangingTheCoreCapabilityBoundary() throws {
        let companion = ExtensionCompanion(
            id: "simulator",
            bundlePath: "Companions/Simulator.app",
            activation: .onDemand,
            capabilities: [.processSpawn, .screenCapture, .inputControl, .remoteSurfaces]
        )
        let manifest = ExtensionManifest(
            identifier: "se.mjukis.simulator",
            name: "Simulator",
            version: "1.0.0",
            runtime: .webAssembly,
            executable: "bin/simulator.wasm",
            capabilities: [.panels, .hostSessionsRead],
            companions: [companion]
        )

        try manifest.validate()
        let decoded = try JSONDecoder().decode(
            ExtensionManifest.self,
            from: JSONEncoder().encode(manifest)
        )

        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(
            companion.expectedBundleIdentifier(extensionIdentifier: manifest.identifier),
            "se.mjukis.simulator.companion.simulator"
        )
        XCTAssertFalse(
            manifest.capabilities.contains(.networkClient),
            "a companion authority must not leak into the WebAssembly core's host grants"
        )
    }

    func testCompanionOperationsRequireAnExplicitCoreCapabilityAndRoundTrip() throws {
        let operation = ExtensionCompanionOperation(
            id: "simulator-status",
            title: "Simulator Status",
            description: "Returns the state of the companion-owned simulator.",
            outputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "state": .object(["type": .string("string")])
                ])
            ])
        )
        let companion = ExtensionCompanion(
            id: "simulator",
            bundlePath: "Companions/Simulator.app",
            operations: [operation]
        )
        let missingCapability = ExtensionManifest(
            identifier: "se.mjukis.simulator",
            name: "Simulator",
            version: "1.0.0",
            runtime: .webAssembly,
            executable: "bin/simulator.wasm",
            companions: [companion]
        )

        XCTAssertThrowsError(try missingCapability.validate()) { error in
            let issues = (error as? ExtensionValidationError)?.issues ?? []
            XCTAssertTrue(issues.contains {
                $0.path == "capabilities" && $0.message.contains("companions.invoke")
            })
        }

        let manifest = ExtensionManifest(
            identifier: "se.mjukis.simulator",
            name: "Simulator",
            version: "1.0.0",
            runtime: .webAssembly,
            executable: "bin/simulator.wasm",
            capabilities: [.companionOperations],
            companions: [companion]
        )
        try manifest.validate()
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionManifest.self,
                from: JSONEncoder().encode(manifest)
            ),
            manifest
        )
    }

    func testRemoteSurfacesRequireExplicitAuthorityAndResolveFromPanels() throws {
        let surface = ExtensionRemoteSurface(
            id: "device",
            title: "Device",
            accessibilityLabel: "Live device display",
            maximumWidth: 1_280,
            maximumHeight: 800,
            acceptsPointer: true,
            acceptsKeyboard: true
        )
        let unauthorizedCompanion = ExtensionCompanion(
            id: "worker",
            bundlePath: "Companions/Worker.app",
            surfaces: [surface]
        )
        let unauthorized = ExtensionManifest(
            identifier: "se.mjukis.surface",
            name: "Surface",
            version: "1.0.0",
            runtime: .webAssembly,
            executable: "bin/surface.wasm",
            capabilities: [.panels],
            companions: [unauthorizedCompanion]
        )
        XCTAssertThrowsError(try unauthorized.validate()) { error in
            XCTAssertTrue(
                (error as? ExtensionValidationError)?.issues.contains {
                    $0.path == "companions[0].capabilities"
                        && $0.message.contains("ui.remote-surfaces")
                } == true
            )
        }

        let companion = ExtensionCompanion(
            id: "worker",
            bundlePath: "Companions/Worker.app",
            capabilities: [.remoteSurfaces],
            surfaces: [surface]
        )
        let manifest = ExtensionManifest(
            identifier: "se.mjukis.surface",
            name: "Surface",
            version: "1.0.0",
            runtime: .webAssembly,
            executable: "bin/surface.wasm",
            capabilities: [.panels],
            companions: [companion]
        )
        let registration = ExtensionRegistration(panels: [
            .init(
                id: "device",
                title: "Device",
                root: .status("Device display unavailable", role: .neutral),
                remoteSurface: .init(companionID: "worker", surfaceID: "device")
            )
        ])

        try manifest.validate()
        try registration.validate(for: manifest)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionManifest.self,
                from: JSONEncoder().encode(manifest)
            ),
            manifest
        )

        let missing = ExtensionRegistration(panels: [
            .init(
                id: "missing",
                title: "Missing",
                root: .status("Unavailable", role: .neutral),
                remoteSurface: .init(companionID: "worker", surfaceID: "other")
            )
        ])
        XCTAssertThrowsError(try missing.validate(for: manifest)) { error in
            XCTAssertTrue(
                (error as? ExtensionValidationError)?.issues.contains {
                    $0.path == "panels[0].remoteSurface.surfaceID"
                } == true
            )
        }
    }

    func testRemoteSurfaceWirePreservesPixelsAndValidatesBounds() throws {
        let pixels = Data((0..<16).map(UInt8.init))
        let frame = ExtensionRemoteSurfaceFrame(
            presentationID: "presentation-1",
            sequence: 1,
            width: 2,
            height: 2,
            bytesPerRow: 8,
            payloadLength: pixels.count
        )
        let packet = ExtensionRemoteSurfacePacket(
            message: .frame(frame),
            payload: pixels
        )
        let pipe = Pipe()
        try ExtensionRemoteSurfaceWire.write(packet, to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()

        XCTAssertEqual(
            try ExtensionRemoteSurfaceWire.read(from: pipe.fileHandleForReading),
            packet
        )
        XCTAssertNil(
            try ExtensionRemoteSurfaceWire.read(from: pipe.fileHandleForReading)
        )

        XCTAssertThrowsError(try ExtensionRemoteSurfaceWire.encoded(.init(
            message: .frame(.init(
                presentationID: "presentation-1",
                sequence: 2,
                width: 2,
                height: 2,
                bytesPerRow: 8,
                payloadLength: 16
            )),
            payload: Data(count: 15)
        )))

        let tooLarge = ExtensionCompanion(
            id: "worker",
            bundlePath: "Companions/Worker.app",
            capabilities: [.remoteSurfaces],
            surfaces: [
                .init(
                    id: "square",
                    title: "Square",
                    accessibilityLabel: "Oversized square",
                    maximumWidth: 4_096,
                    maximumHeight: 4_096
                )
            ]
        )
        XCTAssertFalse(tooLarge.validationIssues(
            path: "companions[0]",
            extensionIdentifier: "se.mjukis.surface"
        ).isEmpty)
    }

    func testCompanionOperationWireMessagesAreCorrelatedAndGenerationBound() throws {
        let request = ExtensionCompanionOperationRequest(
            requestID: "request-1",
            generation: "generation-1",
            operationID: "simulator-status",
            arguments: .object(["device": .string("iPhone 18")])
        )
        let response = ExtensionCompanionOperationResponse(
            requestID: request.requestID,
            generation: request.generation,
            operationID: request.operationID,
            value: .object(["state": .string("booted")])
        )

        try request.validate()
        try response.validate()
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionCompanionOperationRequest.self,
                from: JSONEncoder().encode(request)
            ),
            request
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionCompanionOperationResponse.self,
                from: JSONEncoder().encode(response)
            ),
            response
        )

        XCTAssertThrowsError(try ExtensionCompanionOperationResponse(
            requestID: request.requestID,
            generation: request.generation,
            operationID: request.operationID
        ).validate())
        XCTAssertThrowsError(try ExtensionCompanionOperationResponse(
            requestID: request.requestID,
            generation: request.generation,
            operationID: request.operationID,
            value: .emptyObject,
            error: "cannot return both"
        ).validate())
    }

    func testAdvancedCompanionsRequireAWasmCoreAndSafeUniqueAppPaths() {
        let duplicate = ExtensionCompanion(
            id: "worker",
            bundlePath: "Companions/Worker.app",
            capabilities: [.networkListen]
        )
        let manifest = ExtensionManifest(
            identifier: "se.mjukis.advanced",
            name: "Advanced",
            version: "1.0.0",
            executable: "bin/native",
            companions: [
                duplicate,
                duplicate,
                .init(id: "escape", bundlePath: "../Escape.app")
            ]
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            let paths = (error as? ExtensionValidationError)?.issues.map(\.path) ?? []
            XCTAssertTrue(paths.contains("companions"))
            XCTAssertTrue(paths.contains("companions[1].id"))
            XCTAssertTrue(paths.contains("companions[1].bundlePath"))
            XCTAssertTrue(paths.contains("companions[2].bundlePath"))
        }
    }

    func testCompanionHandshakeAndShutdownAreGenerationBound() throws {
        let hello = ExtensionCompanionHello(
            companionID: "worker",
            generation: "generation-1"
        )
        let shutdown = ExtensionCompanionHostMessage(
            type: .shutdown,
            generation: hello.generation
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        XCTAssertEqual(
            try decoder.decode(
                ExtensionCompanionHello.self,
                from: encoder.encode(hello)
            ),
            hello
        )
        XCTAssertEqual(
            try decoder.decode(
                ExtensionCompanionHostMessage.self,
                from: encoder.encode(shutdown)
            ),
            shutdown
        )
        XCTAssertEqual(hello.protocolVersion, SkalmanCompanionAPI.protocolVersion)
        XCTAssertEqual(
            Set([
                ExtensionCompanionEnvironment.extensionIdentifier,
                ExtensionCompanionEnvironment.companionIdentifier,
                ExtensionCompanionEnvironment.generation,
                ExtensionCompanionEnvironment.capabilitiesJSON
            ]),
            Set([
                "SKALMAN_EXTENSION_ID",
                "SKALMAN_COMPANION_ID",
                "SKALMAN_COMPANION_GENERATION",
                "SKALMAN_COMPANION_CAPABILITIES_JSON"
            ])
        )
    }

    func testDataMigrationContextIsMonotonicAndEnvironmentDriven() throws {
        let context = ExtensionDataMigrationContext(environment: [
            ExtensionDataMigrationEnvironment.previousVersion: "2",
            ExtensionDataMigrationEnvironment.targetVersion: "4"
        ])
        XCTAssertEqual(context.previousVersion, 2)
        XCTAssertEqual(context.targetVersion, 4)
        XCTAssertTrue(context.isRequired)

        let invalid = ExtensionManifest(
            identifier: "se.mjukis.data-version",
            name: "Data Version",
            version: "1.0.0",
            dataVersion: 0,
            executable: "bin/extension"
        )
        XCTAssertThrowsError(try invalid.validate()) { error in
            XCTAssertEqual(
                (error as? ExtensionValidationError)?.issues.map(\.path),
                ["dataVersion"]
            )
        }
    }

    func testEveryNodeHasAStableTaggedJSONShapeAndRoundTrips() throws {
        let nodes: [ExtensionNode] = [
            .text("Heading", role: .heading),
            .text("Compact", role: .compactBody),
            .image(
                .hostAsset("provider.codex"),
                role: .identity,
                accessibilityLabel: "Codex"
            ),
            .button(id: "run", title: "Run", role: .primary, isEnabled: false),
            .status("Waiting", role: .warning),
            .proceed,
            .overlay(
                base: .proceed,
                overlay: .status("Overlay", role: .neutral)
            ),
            .customSurface(
                .metal(ExtensionMetalSurface(
                    shaderResource: "Resources/effect.metal",
                    inputs: [.init(name: "amount", value: .constant(0.5))]
                )),
                accessibilityLabel: nil
            ),
            .divider,
            .spacer(.large),
            .flexibleSpacer,
            .stack(
                axis: .horizontal,
                spacing: .small,
                children: [.text("Child", role: .body)]
            )
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for node in nodes {
            let data = try encoder.encode(node)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertNotNil(object["type"], "\(node) has no wire discriminator")
            XCTAssertEqual(try decoder.decode(ExtensionNode.self, from: data), node)
        }
    }

    func testComposableWindowHookRequiresExactlyOneProceedAndRoundTrips() throws {
        let contract = SkalmanComponentCatalog.applicationMainWindow
        let hook = ExtensionComponentPatch(
            id: "around-window",
            target: .init(component: .applicationMainWindow, contractVersion: 1),
            hook: .overlay(
                base: .proceed,
                overlay: .customSurface(
                    .metal(ExtensionMetalSurface(
                        shaderResource: "Resources/rain.metal",
                        inputs: [
                            .init(
                                name: "density",
                                value: .signal(
                                    .activeAccountUsageRemaining,
                                    mapping: .init(
                                        outputMinimum: 1,
                                        outputMaximum: 0
                                    )
                                )
                            )
                        ]
                    )),
                    accessibilityLabel: nil
                )
            )
        )

        try contract.validate(hook)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionComponentPatch.self,
                from: JSONEncoder().encode(hook)
            ),
            hook
        )

        let missingProceed = ExtensionComponentPatch(
            id: "missing-next",
            target: hook.target,
            hook: .customSurface(
                .metal(ExtensionMetalSurface(shaderResource: "Resources/rain.metal")),
                accessibilityLabel: nil
            )
        )
        XCTAssertThrowsError(try contract.validate(missingProceed))

        let duplicateProceed = ExtensionComponentPatch(
            id: "duplicate-next",
            target: hook.target,
            hook: .overlay(base: .proceed, overlay: .proceed)
        )
        XCTAssertThrowsError(try contract.validate(duplicateProceed))
    }

    func testComponentContractAndHStackPatchRoundTrip() throws {
        let compact = ExtensionComponentNodeConstraints(
            maximumDepth: 1,
            maximumNodes: 8,
            maximumTextLength: 80,
            requiredRootAxis: .horizontal,
            allowedStackAxes: [.horizontal],
            allowedTextRoles: [.compactBody, .compactDetail],
            allowedImageRoles: [.identity, .icon],
            allowedButtonRoles: [.standard],
            allowedStatusRoles: [.neutral, .positive, .warning, .negative],
            allowsFixedSpacer: true,
            allowsFlexibleSpacer: true
        )
        let contract = ExtensionComponentContract(
            id: "sidebar.session-row",
            version: 1,
            context: .sessionPresentation,
            properties: [.title, .identityImage, .toolTip],
            slots: [
                .init(id: "after-title", maximumInlineItems: 2)
            ],
            replacement: .contentOnly,
            replacementConstraints: compact,
            hostOwnedBehavior: [
                .selection,
                .dragAndDrop,
                .rowActions,
                .activityState,
                .accessibilityContainer
            ]
        )
        let patch = ExtensionComponentPatch(
            id: "ci-session-row",
            target: .init(
                component: contract.id,
                contractVersion: contract.version,
                entityID: "session-42"
            ),
            properties: [
                .init(property: .toolTip, value: .text("CI passed"))
            ],
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
        )

        try contract.validate()
        let contractObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(contract)
            ) as? [String: Any]
        )
        XCTAssertEqual(contractObject["id"] as? String, "sidebar.session-row")
        XCTAssertEqual(
            contractObject["properties"] as? [String],
            ["title", "identity-image", "tool-tip"]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionComponentContract.self,
                from: JSONEncoder().encode(contract)
            ),
            contract
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionComponentPatch.self,
                from: JSONEncoder().encode(patch)
            ),
            patch
        )
    }

    func testComponentPublicationAndActionProtocolRoundTrip() throws {
        let target = ExtensionComponentTarget(
            component: "sidebar.session-row",
            contractVersion: 1,
            entityID: "session-42"
        )
        let patch = ExtensionComponentPatch(
            id: "ci",
            target: target,
            slots: [
                .init(
                    slot: "after-title",
                    children: [.status("Passed", role: .positive)]
                )
            ]
        )
        let publication = ExtensionComponentPatchPublication(patches: [patch])
        let action = ExtensionComponentActionRequest(
            requestID: "component-action-1",
            target: target,
            actionID: "open-build"
        )

        try publication.validate()
        try action.validate()
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionComponentPatchPublication.self,
                from: JSONEncoder().encode(publication)
            ),
            publication
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionComponentActionRequest.self,
                from: JSONEncoder().encode(action)
            ),
            action
        )
    }

    func testComponentPublicationRejectsDuplicatePatchIDsBeforeTransport() {
        let target = ExtensionComponentTarget(
            component: "sidebar.session-row",
            contractVersion: 1
        )
        let publication = ExtensionComponentPatchPublication(patches: [
            .init(
                id: "same",
                target: target,
                properties: [.init(property: .title, value: .text("One"))]
            ),
            .init(
                id: "same",
                target: target,
                properties: [.init(property: .title, value: .text("Two"))]
            )
        ])

        XCTAssertThrowsError(try publication.validate()) { error in
            XCTAssertEqual(
                (error as? ExtensionValidationError)?.issues.map(\.path),
                ["patches[1].id"]
            )
        }
    }

    func testCompactComponentConstraintsAcceptHStackAndRejectExpandedUI() throws {
        let compact = ExtensionComponentNodeConstraints(
            maximumDepth: 1,
            maximumNodes: 6,
            maximumTextLength: 32,
            requiredRootAxis: .horizontal,
            allowedStackAxes: [.horizontal],
            allowedTextRoles: [.compactBody],
            allowedImageRoles: [.identity],
            allowedButtonRoles: [.standard],
            allowedStatusRoles: [.positive],
            allowsFlexibleSpacer: true
        )
        let valid = ExtensionNode.stack(
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
                    id: "details",
                    title: "Details",
                    role: .standard,
                    isEnabled: true
                )
            ]
        )
        XCTAssertNoThrow(try compact.validate(valid))

        let invalid = ExtensionNode.stack(
            axis: .vertical,
            spacing: .large,
            children: [
                .text("A multiline body is not a compact row", role: .body),
                .button(
                    id: "delete",
                    title: "Delete",
                    role: .destructive,
                    isEnabled: true
                )
            ]
        )
        XCTAssertThrowsError(try compact.validate(invalid)) { error in
            let issues = (error as? ExtensionValidationError)?.issues ?? []
            XCTAssertTrue(issues.contains { $0.message.contains("root must be") })
            XCTAssertTrue(issues.contains { $0.message.contains("body") })
            XCTAssertTrue(issues.contains { $0.message.contains("destructive") })
        }
    }

    func testComponentContractRejectsDuplicateAndUnboundedSlots() {
        let contract = ExtensionComponentContract(
            id: "sidebar.session-row",
            version: 0,
            context: .sessionPresentation,
            properties: [.title, .title],
            slots: [
                .init(id: "after-title", maximumInlineItems: 0),
                .init(id: "after-title", maximumInlineItems: 1)
            ]
        )

        XCTAssertThrowsError(try contract.validate()) { error in
            XCTAssertEqual(
                (error as? ExtensionValidationError)?.issues.map(\.path),
                [
                    "version",
                    "properties[1]",
                    "slots[1]",
                    "slots[0].maximumInlineItems"
                ]
            )
        }
    }

    func testRegistrationRequiresCapabilitiesAndUniqueValidIDs() throws {
        let manifest = ExtensionManifest(
            identifier: "se.mjukis.example",
            name: "Example",
            version: "1.0.0",
            executable: "bin/example"
        )
        let registration = ExtensionRegistration(
            commands: [
                .init(id: "Refresh", title: "First"),
                .init(id: "Refresh", title: "Second")
            ],
            panels: [
                .init(id: "status", title: "Status", root: .status("Ready", role: .positive))
            ]
        )

        XCTAssertThrowsError(try registration.validate(for: manifest)) { error in
            let paths = (error as? ExtensionValidationError)?.issues.map(\.path)
            XCTAssertEqual(
                paths,
                [
                    "commands[0].id",
                    "commands[1].id",
                    "commands[1].id",
                    "capabilities",
                    "capabilities"
                ]
            )
        }
    }

    func testPanelRegistrationRejectsInvalidProductUIBeforeRendering() {
        var tooDeep = ExtensionNode.status("Ready", role: .positive)
        for _ in 0...ExtensionPanel.nodeConstraints.maximumDepth {
            tooDeep = .stack(axis: .vertical, spacing: .small, children: [tooDeep])
        }
        let registration = ExtensionRegistration(panels: [
            .init(
                id: "status",
                title: " ",
                root: .button(
                    id: "Not Valid",
                    title: "Refresh",
                    role: .standard,
                    isEnabled: true
                )
            ),
            .init(id: "deep", title: "Deep", root: tooDeep)
        ])
        let manifest = ExtensionManifest(
            identifier: "se.mjukis.example",
            name: "Example",
            version: "1.0.0",
            executable: "bin/example",
            capabilities: [.panels]
        )

        XCTAssertThrowsError(try registration.validate(for: manifest)) { error in
            let paths = Set(
                (error as? ExtensionValidationError)?.issues.map(\.path) ?? []
            )
            XCTAssertTrue(paths.contains("panels[0].title"))
            XCTAssertTrue(paths.contains("panels[0].root.id"))
            XCTAssertTrue(paths.contains {
                $0.hasPrefix("panels[1].root") && $0.hasSuffix(".children[0]")
            })
        }
    }

    func testPanelLoadActionRoundTripsAndRemainsBackwardCompatible() throws {
        let panel = ExtensionPanel(
            id: "session-info",
            title: "Session Info",
            root: .status("Loading", role: .neutral),
            loadActionID: "load-session"
        )

        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionPanel.self,
                from: JSONEncoder().encode(panel)
            ),
            panel
        )

        let legacy = Data(
            #"{"id":"status","title":"Status","root":{"type":"status","text":"Ready","role":"positive"}}"#
                .utf8
        )
        XCTAssertNil(
            try JSONDecoder().decode(ExtensionPanel.self, from: legacy).loadActionID
        )
    }

    func testPanelRejectsInvalidLoadActionIdentifier() {
        let panel = ExtensionPanel(
            id: "session-info",
            title: "Session Info",
            root: .status("Loading", role: .neutral),
            loadActionID: "Load Session"
        )

        XCTAssertEqual(
            panel.validationIssues(path: "panels[0]").map(\.path),
            ["panels[0].loadActionID"]
        )
    }

    func testCommandMetadataAndInvocationRoundTrip() throws {
        let command = ExtensionCommand(
            id: "open-build",
            title: "Open Build",
            description: "Open the current CI build.",
            scope: .project,
            risk: .destructive,
            defaultShortcut: .init(
                key: "b",
                modifiers: [.option, .command]
            ),
            menuPlacements: [.project, .view]
        )
        let request = ExtensionCommandRequest(
            requestID: "command-request-1",
            commandID: command.id,
            context: .init(projectID: "project-1", sessionID: "session-1")
        )
        let response = ExtensionCommandResponse(
            requestID: request.requestID,
            commandID: request.commandID,
            message: "Opened build."
        )

        XCTAssertTrue(command.validationIssues(path: "commands[0]").isEmpty)
        try request.validate()
        try response.validate()
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionCommand.self,
                from: JSONEncoder().encode(command)
            ),
            command
        )
        XCTAssertEqual(command.menuPlacements, [.project, .view])
        XCTAssertEqual(command.risk, .destructive)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionCommandRequest.self,
                from: JSONEncoder().encode(request)
            ),
            request
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionCommandResponse.self,
                from: JSONEncoder().encode(response)
            ),
            response
        )
    }

    func testSettingsContributionAndRuntimeUpdateRoundTrip() throws {
        let settings = ExtensionSettingsContribution(
            pages: [
                .init(
                    id: "ci",
                    title: "CI",
                    sections: [
                        .init(
                            id: "display",
                            title: "Display",
                            fields: [
                                .init(
                                    id: "show-light",
                                    title: "Show CI light",
                                    control: .toggle(defaultValue: true)
                                ),
                                .init(
                                    id: "label",
                                    title: "Label",
                                    control: .text(
                                        defaultValue: "Build",
                                        placeholder: nil,
                                        maximumLength: 40
                                    )
                                ),
                                .init(
                                    id: "tone",
                                    title: "Tone",
                                    control: .choice(
                                        defaultValue: "positive",
                                        options: [
                                            .init(id: "positive", title: "Positive"),
                                            .init(id: "warning", title: "Warning")
                                        ]
                                    )
                                ),
                                .init(
                                    id: "limit",
                                    title: "Limit",
                                    control: .integer(
                                        defaultValue: 5,
                                        minimum: 1,
                                        maximum: 9,
                                        step: 2
                                    )
                                )
                            ]
                        )
                    ]
                )
            ],
            sections: [
                .init(
                    id: "general-ci",
                    page: .general,
                    fields: [
                        .init(
                            id: "refresh",
                            title: "Refresh automatically",
                            control: .toggle(defaultValue: false)
                        )
                    ]
                )
            ]
        )
        let manifest = ExtensionManifest(
            identifier: "com.example.settings",
            name: "Settings",
            version: "1.0.0",
            executable: "bin/settings",
            capabilities: [.settings],
            settings: settings
        )
        let request = ExtensionSettingsUpdateRequest(
            requestID: "settings-1",
            values: [
                "show-light": .bool(false),
                "tone": .string("warning"),
                "limit": .integer(7)
            ]
        )
        let response = ExtensionSettingsUpdateResponse(
            requestID: request.requestID,
            settingIDs: request.values.keys.sorted()
        )

        try manifest.validate()
        try request.validate(against: settings)
        try response.validate()
        XCTAssertEqual(manifest.profile, .settings)
        XCTAssertEqual(
            settings.effectiveValues(overriding: [
                "label": .string("Pipeline"),
                "limit": .integer(8)
            ]),
            [
                "show-light": .bool(true),
                "label": .string("Pipeline"),
                "tone": .string("positive"),
                "limit": .integer(5),
                "refresh": .bool(false)
            ]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(
                ExtensionSettingsContribution.self,
                from: encoder.encode(settings)
            ),
            settings
        )
        XCTAssertEqual(
            try decoder.decode(
                ExtensionSettingsUpdateRequest.self,
                from: encoder.encode(request)
            ),
            request
        )
        XCTAssertEqual(
            try decoder.decode(
                ExtensionSettingsUpdateResponse.self,
                from: encoder.encode(response)
            ),
            response
        )

        let json = String(decoding: try encoder.encode([
            "label": ExtensionJSONValue.string("From environment")
        ]), as: UTF8.self)
        XCTAssertEqual(
            try ExtensionSettingsEnvironment.values(environment: [
                ExtensionSettingsEnvironment.valuesJSON: json
            ]),
            ["label": .string("From environment")]
        )
    }

    func testSettingsRejectDuplicateFieldsInvalidDefaultsAndMissingCapability() {
        let repeated = ExtensionSettingField(
            id: "tone",
            title: "Tone",
            control: .choice(
                defaultValue: "missing",
                options: [
                    .init(id: "positive", title: "Positive")
                ]
            )
        )
        let settings = ExtensionSettingsContribution(
            pages: [
                .init(
                    id: "status",
                    title: "Status",
                    sections: [
                        .init(id: "first", fields: [repeated]),
                        .init(id: "second", fields: [repeated])
                    ]
                )
            ]
        )
        let manifest = ExtensionManifest(
            identifier: "com.example.invalid-settings",
            name: "Invalid",
            version: "1.0.0",
            executable: "bin/invalid",
            settings: settings
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            let issues = (error as? ExtensionValidationError)?.issues ?? []
            XCTAssertTrue(issues.contains { $0.path == "settings.fields[1].id" })
            XCTAssertTrue(issues.contains {
                $0.path.hasSuffix("control.defaultValue")
            })
            XCTAssertTrue(issues.contains { $0.path == "capabilities" })
        }
    }

    func testLegacyCommandMetadataGetsSafeDefaults() throws {
        let data = Data(#"{"id":"refresh","title":"Refresh"}"#.utf8)
        let command = try JSONDecoder().decode(ExtensionCommand.self, from: data)

        XCTAssertEqual(command.scope, .application)
        XCTAssertEqual(command.risk, .ordinary)
        XCTAssertNil(command.defaultShortcut)
        XCTAssertEqual(command.menuPlacements, [.extensions])
    }

    func testCommandRejectsAnUnsafeShortcut() {
        let command = ExtensionCommand(
            id: "refresh",
            title: "Refresh",
            defaultShortcut: .init(key: "rr", modifiers: [.shift, .shift])
        )

        XCTAssertEqual(
            command.validationIssues(path: "commands[0]").map(\.path),
            [
                "commands[0].defaultShortcut.key",
                "commands[0].defaultShortcut.modifiers",
                "commands[0].defaultShortcut.modifiers"
            ]
        )
    }

    func testCommandRejectsDuplicateMenuPlacements() {
        let command = ExtensionCommand(
            id: "refresh",
            title: "Refresh",
            menuPlacements: [.project, .project]
        )

        XCTAssertEqual(
            command.validationIssues(path: "commands[0]"),
            [
                .init(
                    path: "commands[0].menuPlacements",
                    message: "must not contain duplicates"
                )
            ]
        )
    }

    func testActionProtocolRoundTripsCorrelatedPanelUpdates() throws {
        let request = ExtensionActionRequest(
            requestID: "request-42",
            panelID: "status",
            actionID: "refresh",
            context: .init(projectID: "project-1", sessionID: "session-1")
        )
        let response = ExtensionActionResponse(
            requestID: request.requestID,
            panel: .init(
                id: request.panelID,
                title: "Status",
                root: .status("Refreshed", role: .positive)
            ),
            message: "Status refreshed."
        )

        try request.validate()
        try response.validate()
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionActionRequest.self,
                from: JSONEncoder().encode(request)
            ),
            request
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionActionResponse.self,
                from: JSONEncoder().encode(response)
            ),
            response
        )

        let legacy = Data(
            #"{"protocolVersion":1,"requestID":"legacy","panelID":"status","actionID":"refresh"}"#
                .utf8
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ExtensionActionRequest.self, from: legacy).context,
            .init()
        )
    }

    func testActionProtocolRejectsMixedSuccessAndErrorResponses() {
        let response = ExtensionActionResponse(
            requestID: "request-42",
            message: "This cannot be both.",
            error: "Failed"
        )

        XCTAssertThrowsError(try response.validate()) { error in
            XCTAssertEqual(
                (error as? ExtensionValidationError)?.issues.map(\.path),
                ["error"]
            )
        }
    }

    func testMCPToolDeclarationAndRuntimeRegistrationMatch() throws {
        let tool = ExtensionMCPTool(
            id: "lookup",
            title: "Lookup",
            description: "Look up a cached value.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "key": .object([
                        "type": .string("string"),
                        "description": .string("The key to look up.")
                    ])
                ]),
                "required": .array([.string("key")])
            ])
        )
        let manifest = ExtensionManifest(
            identifier: "se.mjukis.example",
            name: "Example",
            version: "1.0.0",
            executable: "bin/example",
            capabilities: [.mcpTools],
            mcpTools: [tool]
        )
        let registration = ExtensionRegistration(mcpTools: [tool])

        try manifest.validate()
        try registration.validate(for: manifest)
        XCTAssertEqual(
            tool.qualifiedName(extensionIdentifier: manifest.identifier),
            "ext__se__mjukis__example__lookup"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionManifest.self,
                from: JSONEncoder().encode(manifest)
            ),
            manifest
        )
    }

    func testRuntimeCannotBroadenDeclaredMCPToolSchema() {
        let declared = ExtensionMCPTool(
            id: "lookup",
            title: "Lookup",
            description: "Read one value."
        )
        let changed = ExtensionMCPTool(
            id: "lookup",
            title: "Lookup",
            description: "Read or delete a value."
        )
        let manifest = ExtensionManifest(
            identifier: "se.mjukis.example",
            name: "Example",
            version: "1.0.0",
            executable: "bin/example",
            capabilities: [.mcpTools],
            mcpTools: [declared]
        )

        XCTAssertThrowsError(
            try ExtensionRegistration(mcpTools: [changed]).validate(for: manifest)
        ) { error in
            XCTAssertTrue(
                (error as? ExtensionValidationError)?.issues.contains {
                    $0.path == "mcpTools[0]"
                } == true
            )
        }
    }

    func testMCPRequestAndResponseRoundTripArbitraryJSONArguments() throws {
        let request = ExtensionMCPToolRequest(
            requestID: "request-7",
            sessionID: "session-9",
            toolID: "lookup",
            arguments: .object([
                "key": .string("answer"),
                "options": .object([
                    "fresh": .bool(true),
                    "limit": .integer(3)
                ])
            ])
        )
        let response = ExtensionMCPToolResponse(
            requestID: request.requestID,
            text: "42"
        )

        try request.validate()
        try response.validate()
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionMCPToolRequest.self,
                from: JSONEncoder().encode(request)
            ),
            request
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionMCPToolResponse.self,
                from: JSONEncoder().encode(response)
            ),
            response
        )
    }

    func testProfilesAreDerivedFromComposableContributionCapabilities() {
        func manifest(
            _ capabilities: Set<ExtensionCapability>
        ) -> ExtensionManifest {
            ExtensionManifest(
                identifier: "com.example.profile",
                name: "Profile",
                version: "1.0.0",
                executable: "bin/profile",
                capabilities: capabilities
            )
        }

        XCTAssertEqual(manifest([]).profile, .runtime)
        XCTAssertEqual(manifest([.commands]).profile, .command)
        XCTAssertEqual(manifest([.panels]).profile, .panel)
        XCTAssertEqual(manifest([.mcpTools]).profile, .agentTool)
        XCTAssertEqual(manifest([.settings]).profile, .settings)
        XCTAssertEqual(manifest([.servicesProvide]).profile, .service)
        XCTAssertEqual(manifest([.componentCustomization]).profile, .component)
        XCTAssertEqual(manifest([.sessionIdentityRenderer]).profile, .component)

        let hybrid = manifest([
            .commands,
            .panels,
            .mcpTools,
            .componentCustomization
        ])
        XCTAssertEqual(hybrid.profile, .hybrid)
        XCTAssertEqual(hybrid.contributionKinds, [
            .commands,
            .panels,
            .agentTools,
            .componentCustomization
        ])
    }

    func testBrokeredServiceManifestAndWireContractsRoundTrip() throws {
        let definition = ExtensionServiceDefinition(
            id: "ci-status",
            version: 2,
            title: "CI status",
            description: "Returns the latest CI status for a project.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "projectID": .object(["type": .string("string")])
                ])
            ]),
            outputSchema: .object(["type": .string("object")])
        )
        let dependency = ExtensionServiceDependency(
            providerIdentifier: "com.example.ci",
            serviceID: definition.id,
            version: definition.version,
            required: true
        )
        let provider = ExtensionManifest(
            identifier: "com.example.ci",
            name: "CI",
            version: "1.0.0",
            executable: "bin/ci",
            capabilities: [.servicesProvide],
            services: [definition]
        )
        let consumer = ExtensionManifest(
            identifier: "com.example.dashboard",
            name: "Dashboard",
            version: "1.0.0",
            executable: "bin/dashboard",
            capabilities: [.servicesConsume],
            serviceDependencies: [dependency]
        )
        let registration = ExtensionRegistration(services: [definition])
        try provider.validate()
        try consumer.validate()
        try registration.validate(for: provider)

        let request = ExtensionServiceRequest(
            requestID: "service-request",
            callerExtensionIdentifier: consumer.identifier,
            serviceID: definition.id,
            serviceVersion: definition.version,
            arguments: .object(["projectID": .string("project-1")])
        )
        let response = ExtensionServiceResponse(
            requestID: request.requestID,
            serviceID: definition.id,
            serviceVersion: definition.version,
            value: .object(["state": .string("passed")])
        )
        try request.validate()
        try response.validate()
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionServiceRequest.self,
                from: JSONEncoder().encode(request)
            ),
            request
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionServiceResponse.self,
                from: JSONEncoder().encode(response)
            ),
            response
        )

        let nullResponse = ExtensionServiceResponse(
            requestID: "null-result",
            serviceID: definition.id,
            serviceVersion: definition.version,
            value: .null
        )
        let decodedNull = try JSONDecoder().decode(
            ExtensionServiceResponse.self,
            from: JSONEncoder().encode(nullResponse)
        )
        XCTAssertEqual(decodedNull.value, .null)
        try decodedNull.validate()
    }

    func testBrokeredServicesRejectImplicitAuthorityAndRuntimeBroadening() {
        let definition = ExtensionServiceDefinition(
            id: "status",
            title: "Status",
            description: "Returns status."
        )
        let providerWithoutCapability = ExtensionManifest(
            identifier: "com.example.provider",
            name: "Provider",
            version: "1.0.0",
            executable: "bin/provider",
            services: [definition]
        )
        XCTAssertThrowsError(try providerWithoutCapability.validate())

        let selfConsumer = ExtensionManifest(
            identifier: "com.example.consumer",
            name: "Consumer",
            version: "1.0.0",
            executable: "bin/consumer",
            capabilities: [.servicesConsume],
            serviceDependencies: [
                .init(
                    providerIdentifier: "com.example.consumer",
                    serviceID: "status"
                )
            ]
        )
        XCTAssertThrowsError(try selfConsumer.validate())

        let duplicateDependencies = ExtensionManifest(
            identifier: "com.example.consumer",
            name: "Consumer",
            version: "1.0.0",
            executable: "bin/consumer",
            capabilities: [.servicesConsume],
            serviceDependencies: [
                .init(
                    providerIdentifier: "com.example.provider",
                    serviceID: "status",
                    required: false
                ),
                .init(
                    providerIdentifier: "com.example.provider",
                    serviceID: "status",
                    required: true
                )
            ]
        )
        XCTAssertThrowsError(try duplicateDependencies.validate())

        let provider = ExtensionManifest(
            identifier: "com.example.provider",
            name: "Provider",
            version: "1.0.0",
            executable: "bin/provider",
            capabilities: [.servicesProvide],
            services: [definition]
        )
        let broadened = ExtensionRegistration(services: [
            .init(
                id: "other",
                title: "Other",
                description: "Was not declared."
            )
        ])
        XCTAssertThrowsError(try broadened.validate(for: provider))
    }

    func testKeyValueStoragePersistsCodableAndJSONValuesAcrossInstances() throws {
        struct Preferences: Codable, Equatable {
            let branch: String
            let refreshes: Int
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SkalmanExtensionStorageTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try ExtensionKeyValueStore(directoryURL: directory)
        try first.set(
            Preferences(branch: "main", refreshes: 3),
            forKey: "project.preferences"
        )
        try first.setJSONValue(.null, forKey: "nullable")

        let reopened = try ExtensionKeyValueStore(directoryURL: directory)
        XCTAssertEqual(
            try reopened.value(forKey: "project.preferences", as: Preferences.self),
            Preferences(branch: "main", refreshes: 3)
        )
        XCTAssertEqual(try reopened.jsonValue(forKey: "nullable"), .null)
        XCTAssertEqual(reopened.keys(), ["nullable", "project.preferences"])
        XCTAssertEqual(reopened.keys(withPrefix: "project."), ["project.preferences"])

        try reopened.removeValue(forKey: "nullable")
        XCTAssertNil(try reopened.jsonValue(forKey: "nullable"))
    }

    func testKeyValueStorageRejectsAnOversizedAtomicMutationWithoutLosingState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SkalmanExtensionStorageQuotaTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try ExtensionKeyValueStore(directoryURL: directory)
        try store.set("kept", forKey: "small")

        XCTAssertThrowsError(
            try store.set(
                String(repeating: "x", count: ExtensionKeyValueStore.maximumStoreBytes),
                forKey: "too-large"
            )
        ) { error in
            XCTAssertEqual(
                error as? ExtensionStorageError,
                .quotaExceeded(maximumBytes: ExtensionKeyValueStore.maximumStoreBytes)
            )
        }
        XCTAssertEqual(try store.value(forKey: "small", as: String.self), "kept")
        XCTAssertNil(try store.jsonValue(forKey: "too-large"))
    }

    func testBrokeredKeyValueStorageSpeaksTheHostWireContract() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let hostEnd = descriptors[0]
        let childEnd = descriptors[1]
        defer {
            ExtensionHostDescriptorTransport.forget(descriptor: childEnd)
            close(hostEnd)
            close(childEnd)
        }

        // A stub host: it records what the client sent and answers with the canned bytes the
        // real service would. This pins the client's half of the contract without a Skalman.
        let recorded = RequestLog()
        let responder = Thread {
            var replies: [String?] = ["{\"protocolVersion\":1,\"values\":{}}", nil, nil]
            Self.serveStubHost(hostEnd, replies: &replies, into: recorded)
        }
        responder.start()

        // A granted directory is present too, and must lose: a process holding a broker was
        // launched by the runner, which grants no writable path.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SkalmanBrokerPrecedence-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try ExtensionKeyValueStore(environment: [
            ExtensionHostConnection.descriptorEnvironmentKey: String(childEnd),
            ExtensionHostConnection.tokenEnvironmentKey: "token-value",
            ExtensionStorageEnvironment.keyValueDirectory: directory.path
        ])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    ExtensionKeyValueStore.stateFileName
                ).path
            ),
            "a brokered store must not also write the granted directory"
        )

        try store.setJSONValue(.string("passing"), forKey: "status/one")
        try store.removeValue(forKey: "status/one")

        let requests = recorded.entries
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests[0].head.hasPrefix("GET /v1/storage/kv HTTP/1.1\r\n"))
        XCTAssertTrue(requests[0].head.contains("Authorization: Bearer token-value\r\n"))

        // The key is percent-encoded, so a key containing a slash addresses one resource rather
        // than inventing a path segment.
        XCTAssertTrue(requests[1].head.hasPrefix("PUT /v1/storage/kv/status%2Fone HTTP/1.1\r\n"))
        XCTAssertTrue(requests[1].head.contains("Content-Type: application/json\r\n"))
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionKeyValueWrite.self,
                from: Data(requests[1].body.utf8)
            ),
            ExtensionKeyValueWrite(value: .string("passing"))
        )
        XCTAssertTrue(
            requests[2].head.hasPrefix("DELETE /v1/storage/kv/status%2Fone HTTP/1.1\r\n")
        )
    }

    func testBrokeredKeyValueStorageMapsHostRefusalsOntoStorageErrors() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let hostEnd = descriptors[0]
        let childEnd = descriptors[1]
        defer {
            ExtensionHostDescriptorTransport.forget(descriptor: childEnd)
            close(hostEnd)
            close(childEnd)
        }

        let responder = Thread {
            var buffer = [UInt8](repeating: 0, count: 8192)
            guard Darwin.read(hostEnd, &buffer, buffer.count) > 0 else { return }
            let refusal = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"
            _ = Data(refusal.utf8).withUnsafeBytes {
                Darwin.write(hostEnd, $0.baseAddress, $0.count)
            }
        }
        responder.start()

        XCTAssertThrowsError(try ExtensionKeyValueStore(environment: [
            ExtensionHostConnection.descriptorEnvironmentKey: String(childEnd),
            ExtensionHostConnection.tokenEnvironmentKey: "token-value"
        ])) { error in
            XCTAssertEqual(
                error as? ExtensionStorageError,
                .unavailable("persistent key-value storage")
            )
        }
    }

    private final class RequestLog: @unchecked Sendable {
        struct Entry {
            let head: String
            let body: String
        }

        private let lock = NSLock()
        private var recorded: [Entry] = []

        func append(head: String, body: String) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(Entry(head: head, body: body))
        }

        var entries: [Entry] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    func testCacheStoreRoundTripsThroughADirectoryAndRefusesUnsafeNames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SkalmanCacheStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = try ExtensionCacheStore(directoryURL: directory)
        XCTAssertNil(try cache.data(forName: "absent.bin"))
        XCTAssertEqual(try cache.names(), [])

        try cache.setData(Data("index".utf8), forName: "index.bin")
        try cache.setData(Data("assets".utf8), forName: "assets.json")
        XCTAssertEqual(try cache.names(), ["assets.json", "index.bin"])
        XCTAssertEqual(try cache.data(forName: "index.bin"), Data("index".utf8))

        try cache.removeData(forName: "index.bin")
        XCTAssertEqual(try cache.names(), ["assets.json"])
        // Removing an absent entry is not an error: the host may have reclaimed it already.
        XCTAssertNoThrow(try cache.removeData(forName: "index.bin"))

        for unsafe in ["..", ".", "", "nested/name", "with\u{0}nul", "line\nbreak",
                       String(repeating: "x", count: ExtensionCacheStore.maximumNameBytes + 1)] {
            XCTAssertThrowsError(try cache.data(forName: unsafe), unsafe) { error in
                XCTAssertEqual(error as? ExtensionStorageError, .invalidName, unsafe)
            }
        }

        XCTAssertThrowsError(
            try cache.setData(
                Data(count: ExtensionCacheStore.maximumEntryBytes + 1),
                forName: "huge.bin"
            )
        ) { error in
            XCTAssertEqual(
                error as? ExtensionStorageError,
                .quotaExceeded(maximumBytes: ExtensionCacheStore.maximumEntryBytes)
            )
        }
    }

    func testBrokeredCacheStorageSpeaksTheHostWireContract() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let hostEnd = descriptors[0]
        let childEnd = descriptors[1]
        defer {
            ExtensionHostDescriptorTransport.forget(descriptor: childEnd)
            close(hostEnd)
            close(childEnd)
        }

        let recorded = RequestLog()
        let entry = try JSONEncoder().encode(
            ExtensionCacheEntry(value: Data("cached".utf8))
        )
        let responder = Thread {
            var replies: [String?] = [String(decoding: entry, as: UTF8.self), nil]
            Self.serveStubHost(hostEnd, replies: &replies, into: recorded)
        }
        responder.start()

        // A granted directory is present too, and must lose to the broker.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SkalmanCacheBrokerPrecedence-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = try ExtensionCacheStore(environment: [
            ExtensionHostConnection.descriptorEnvironmentKey: String(childEnd),
            ExtensionHostConnection.tokenEnvironmentKey: "token-value",
            ExtensionStorageEnvironment.cacheDirectory: directory.path
        ])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.path),
            "a brokered cache must not also create the granted directory"
        )

        XCTAssertEqual(try cache.data(forName: "index.bin"), Data("cached".utf8))
        try cache.setData(Data("written".utf8), forName: "index.bin")

        let requests = recorded.entries
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(
            requests[0].head.hasPrefix("GET /v1/storage/cache/index.bin HTTP/1.1\r\n")
        )
        XCTAssertTrue(requests[0].head.contains("Authorization: Bearer token-value\r\n"))
        XCTAssertTrue(
            requests[1].head.hasPrefix("PUT /v1/storage/cache/index.bin HTTP/1.1\r\n")
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionCacheWrite.self,
                from: Data(requests[1].body.utf8)
            ),
            ExtensionCacheWrite(value: Data("written".utf8))
        )
    }

    /// Answers one canned reply per request on a socket, recording what arrived.
    ///
    /// A `nil` reply is `204 No Content`. It stops once every reply is spent, so a test that
    /// sends more requests than it queued replies for hangs on the extra one rather than
    /// silently reading a stale response.
    private static func serveStubHost(
        _ descriptor: Int32,
        replies: inout [String?],
        into log: RequestLog
    ) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while !replies.isEmpty {
            let read = Darwin.read(descriptor, &buffer, buffer.count)
            guard read > 0 else { return }
            pending.append(contentsOf: buffer[0..<read])
            while let terminator = pending.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(
                    decoding: pending[pending.startIndex..<terminator.lowerBound],
                    as: UTF8.self
                )
                let length = head
                    .components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap {
                        Int($0.dropFirst("content-length:".count)
                            .trimmingCharacters(in: .whitespaces))
                    } ?? 0
                let bodyEnd = terminator.upperBound + length
                guard pending.count >= bodyEnd - pending.startIndex else { break }
                log.append(
                    head: head,
                    body: String(
                        decoding: pending[terminator.upperBound..<bodyEnd],
                        as: UTF8.self
                    )
                )
                pending = Data(pending[bodyEnd...])

                guard !replies.isEmpty else { break }
                let reply = replies.removeFirst()
                let response: String
                if let reply {
                    response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                        + "Content-Length: \(reply.utf8.count)\r\n\r\n\(reply)"
                } else {
                    response = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"
                }
                _ = Data(response.utf8).withUnsafeBytes {
                    Darwin.write(descriptor, $0.baseAddress, $0.count)
                }
            }
        }
    }

    func testStorageEnvironmentExposesOnlyHostGrantedDirectories() throws {
        XCTAssertThrowsError(try ExtensionKeyValueStore(environment: [:]))
        XCTAssertThrowsError(try ExtensionCache.directoryURL(environment: [:]))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SkalmanExtensionCacheTests-\(UUID().uuidString)",
            isDirectory: true
        )
        XCTAssertEqual(
            try ExtensionCache.directoryURL(environment: [
                ExtensionStorageEnvironment.cacheDirectory: directory.path
            ]),
            directory
        )
    }

    func testSecretWireValuesRoundTripAndEnforceBounds() throws {
        let write = ExtensionSecretWrite(value: Data("token-value".utf8))
        try write.validate()
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionSecretWrite.self,
                from: JSONEncoder().encode(write)
            ),
            write
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionSecretResult.self,
                from: JSONEncoder().encode(
                    ExtensionSecretResult(value: write.value)
                )
            ).value,
            write.value
        )
        XCTAssertThrowsError(
            try ExtensionSecretConstraints.validate(key: "line\nbreak")
        )
        XCTAssertThrowsError(try ExtensionSecretWrite(
            value: Data(
                repeating: 0,
                count: ExtensionSecretConstraints.maximumValueBytes + 1
            )
        ).validate())
    }

    func testPrimitiveIdentitySnapshotsAndPublicationRoundTrip() throws {
        let provider = ExtensionProviderSnapshot(
            id: "codex",
            displayName: "Codex",
            image: .hostAsset("identity.provider.codex")
        )
        let account = ExtensionAccountSnapshot(
            id: "codex:standard",
            providerID: "codex",
            displayName: "Default",
            isDefault: true,
            hasUserSelectedImage: false
        )
        let publication = ExtensionIdentityResolutionPublication(
            providerIcons: [
                .init(providerID: provider.id, image: .systemSymbol("terminal.fill"))
            ],
            accountIcons: [
                .init(accountID: account.id, image: .extensionResource("Images/account.png"))
            ]
        )

        try publication.validate()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(
                ExtensionProviderSnapshot.self,
                from: encoder.encode(provider)
            ),
            provider
        )
        XCTAssertEqual(
            try decoder.decode(
                ExtensionAccountSnapshot.self,
                from: encoder.encode(account)
            ),
            account
        )
        XCTAssertEqual(
            try decoder.decode(
                ExtensionIdentityResolutionPublication.self,
                from: encoder.encode(publication)
            ),
            publication
        )
    }

    func testPrimitiveIdentityPublicationRejectsDuplicateIDsAndEscapingResources() {
        let duplicate = ExtensionIdentityResolutionPublication(providerIcons: [
            .init(providerID: "codex", image: .systemSymbol("terminal")),
            .init(providerID: "codex", image: .systemSymbol("hammer"))
        ])
        XCTAssertThrowsError(try duplicate.validate())

        let escaping = ExtensionIdentityResolutionPublication(accountIcons: [
            .init(accountID: "codex:standard", image: .extensionResource("../secret.png"))
        ])
        XCTAssertThrowsError(try escaping.validate())
    }

    func testSessionIdentityRendererUsesTheComponentPatchContract() throws {
        let target = ExtensionComponentTarget.sessionIdentity(sessionID: "session-42")
        let patch = ExtensionComponentPatch(
            id: "session-identity",
            target: target,
            replacement: .stack(
                axis: .horizontal,
                spacing: .tight,
                children: [
                    .image(
                        ExtensionSessionIdentityAsset.providerImage,
                        role: .identity,
                        accessibilityLabel: "Provider"
                    ),
                    .image(
                        ExtensionSessionIdentityAsset.accountImage,
                        role: .icon,
                        accessibilityLabel: "Account"
                    )
                ]
            )
        )

        let publication = ExtensionComponentPatchPublication(patches: [patch])
        try publication.validate()
        XCTAssertEqual(target.component, .sidebarSessionIdentity)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ExtensionComponentPatchPublication.self,
                from: JSONEncoder().encode(publication)
            ),
            publication
        )
    }

    func testPublicComponentCatalogueExamplesUseTheirOwnRuntimeValidator() throws {
        XCTAssertEqual(SkalmanComponentCatalog.entries.count, 15)
        XCTAssertEqual(
            Set(SkalmanComponentCatalog.all.map(\.id.rawValue)),
            [
                "application.main-window",
                "composer.conversation-reply",
                "composer.session-start",
                "conversation.assistant-message",
                "conversation.permission-card",
                "conversation.tool-call",
                "conversation.user-message",
                "display.pane-header",
                "display.tab-header",
                "sidebar.project-hover-card",
                "sidebar.session-identity",
                "sidebar.session-hover-card",
                "sidebar.session-row",
                "sidebar.project-row",
                "toolbar.account-usage-popover"
            ]
        )

        for entry in SkalmanComponentCatalog.entries {
            try entry.contract.validate()
            try entry.contract.validate(entry.examplePatch)
            XCTAssertEqual(
                SkalmanComponentCatalog.entry(
                    id: entry.contract.id,
                    version: entry.contract.version
                ),
                entry
            )
        }
    }

    func testProjectHoverCardSupportsHooksAndExclusiveReplacement() throws {
        let contract = SkalmanComponentCatalog.sidebarProjectHoverCard
        let target = ExtensionComponentTarget.projectHoverCard(projectID: "project-1")
        let hook = ExtensionComponentPatch(
            id: "add-ci",
            target: target,
            hook: .stack(
                axis: .vertical,
                spacing: .medium,
                children: [
                    .proceed,
                    .divider,
                    .button(
                        id: "open-build",
                        title: "Open Build",
                        role: .standard,
                        isEnabled: true
                    )
                ]
            )
        )
        let replacement = ExtensionComponentPatch(
            id: "replace-card",
            target: target,
            replacement: .stack(
                axis: .vertical,
                spacing: .small,
                children: [
                    .text("Custom project card", role: .heading),
                    .status("Ready", role: .positive)
                ]
            )
        )

        try contract.validate(hook)
        try contract.validate(replacement)

        XCTAssertThrowsError(try contract.validate(.init(
            id: "missing-next",
            target: target,
            hook: .status("No original", role: .neutral)
        )))
        XCTAssertThrowsError(try contract.validate(.init(
            id: "replacement-calls-next",
            target: target,
            replacement: .proceed
        )))
    }

    func testSessionHoverCardSupportsHooksAndExclusiveReplacement() throws {
        let contract = SkalmanComponentCatalog.sidebarSessionHoverCard
        let target = ExtensionComponentTarget.sessionHoverCard(sessionID: "session-1")
        let hook = ExtensionComponentPatch(
            id: "add-preview",
            target: target,
            hook: .stack(
                axis: .vertical,
                spacing: .medium,
                children: [
                    .proceed,
                    .divider,
                    .status("Preview ready", role: .positive)
                ]
            )
        )
        let replacement = ExtensionComponentPatch(
            id: "replace-card",
            target: target,
            replacement: .text("Custom session card", role: .heading)
        )

        try contract.validate(hook)
        try contract.validate(replacement)
        XCTAssertEqual(contract.context, .sessionPresentation)
        XCTAssertThrowsError(try contract.validate(.init(
            id: "missing-next",
            target: target,
            hook: .status("No original", role: .neutral)
        )))
        XCTAssertThrowsError(try contract.validate(.init(
            id: "replacement-calls-next",
            target: target,
            replacement: .proceed
        )))
    }

    func testAccountUsagePopoverKeepsRefreshAndHoverBehaviorInTheHost() throws {
        let contract = SkalmanComponentCatalog.toolbarAccountUsagePopover
        let target = ExtensionComponentTarget.accountUsagePopover(accountID: "codex:work")
        let hook = ExtensionComponentPatch(
            id: "budget-note",
            target: target,
            hook: .stack(
                axis: .vertical,
                spacing: .medium,
                children: [
                    .proceed,
                    .divider,
                    .status("Team budget available", role: .neutral)
                ]
            )
        )

        try contract.validate(hook)
        XCTAssertEqual(contract.context, .accountPresentation)
        XCTAssertTrue(contract.hostOwnedBehavior.contains(.dataRefresh))
        XCTAssertTrue(contract.hostOwnedBehavior.contains(.accountSelection))
        XCTAssertTrue(contract.hostOwnedBehavior.contains(.hoverSurvival))
        XCTAssertThrowsError(try contract.validate(.init(
            id: "missing-next",
            target: target,
            hook: .text("Detached replacement", role: .body)
        )))
    }

    func testComposerContractsAllowOnlyProtectedHorizontalAccessories() throws {
        let start = SkalmanComponentCatalog.composerSessionStart
        let reply = SkalmanComponentCatalog.composerConversationReply
        let startTarget = ExtensionComponentTarget.sessionStartComposer(
            projectID: "project-1"
        )
        let replyTarget = ExtensionComponentTarget.conversationReplyComposer(
            sessionID: "session-1"
        )

        let leading = ExtensionComponentPatch(
            id: "template",
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
        )
        let trailing = ExtensionComponentPatch(
            id: "context",
            target: replyTarget,
            hook: .stack(
                axis: .horizontal,
                spacing: .small,
                children: [
                    .proceed,
                    .status("Context", role: .neutral)
                ]
            )
        )

        try start.validate(leading)
        try reply.validate(trailing)
        XCTAssertEqual(start.replacement, .none)
        XCTAssertEqual(reply.replacement, .none)
        XCTAssertTrue(start.hostOwnedBehavior.contains(.draftPersistence))
        XCTAssertTrue(reply.hostOwnedBehavior.contains(.streamAvailability))
        XCTAssertTrue(reply.hostOwnedBehavior.contains(.permissionState))

        XCTAssertThrowsError(try start.validate(.init(
            id: "vertical",
            target: startTarget,
            hook: .stack(
                axis: .vertical,
                spacing: .small,
                children: [.proceed, .status("No", role: .neutral)]
            )
        )))
        XCTAssertThrowsError(try reply.validate(.init(
            id: "replacement",
            target: replyTarget,
            replacement: .text("Alternate input", role: .compactBody)
        )))
        XCTAssertThrowsError(try reply.validate(.init(
            id: "missing-input",
            target: replyTarget,
            hook: .button(
                id: "send",
                title: "Send",
                role: .standard,
                isEnabled: true
            )
        )))
    }

    func testConversationRowContractsPreserveNativeRowsAndApprovalAuthority() throws {
        let sessionID = "session-1"
        let contracts: [(ExtensionComponentContract, ExtensionComponentTarget)] = [
            (
                SkalmanComponentCatalog.conversationUserMessage,
                .conversationUserMessage(sessionID: sessionID)
            ),
            (
                SkalmanComponentCatalog.conversationAssistantMessage,
                .conversationAssistantMessage(sessionID: sessionID)
            ),
            (
                SkalmanComponentCatalog.conversationToolCall,
                .conversationToolCall(sessionID: sessionID)
            ),
            (
                SkalmanComponentCatalog.conversationPermissionCard,
                .conversationPermissionCard(sessionID: sessionID)
            )
        ]

        for (contract, target) in contracts {
            try contract.validate(.init(
                id: "annotation-\(contract.id.rawValue)",
                target: target,
                hook: .stack(
                    axis: .vertical,
                    spacing: .small,
                    children: [
                        .proceed,
                        .status("Annotated", role: .neutral)
                    ]
                )
            ))
            XCTAssertEqual(contract.context, .conversationRow)
            XCTAssertEqual(contract.replacement, .none)
            XCTAssertTrue(contract.hostOwnedBehavior.contains(.transcriptOrder))

            XCTAssertThrowsError(try contract.validate(.init(
                id: "replacement-\(contract.id.rawValue)",
                target: target,
                replacement: .text("Hidden native row", role: .compactBody)
            )))
            XCTAssertThrowsError(try contract.validate(.init(
                id: "horizontal-\(contract.id.rawValue)",
                target: target,
                hook: .stack(
                    axis: .horizontal,
                    spacing: .small,
                    children: [.proceed, .status("No", role: .neutral)]
                )
            )))
        }

        let permission = SkalmanComponentCatalog.conversationPermissionCard
        XCTAssertTrue(permission.hostOwnedBehavior.contains(.permissionDecision))
        XCTAssertTrue(permission.hostOwnedBehavior.contains(.permissionQueue))
        XCTAssertTrue(permission.hostOwnedBehavior.contains(.remoteMirroring))
        XCTAssertThrowsError(try permission.validate(.init(
            id: "fake-approval",
            target: .conversationPermissionCard(sessionID: sessionID),
            hook: .stack(
                axis: .vertical,
                spacing: .small,
                children: [
                    .proceed,
                    .button(
                        id: "allow",
                        title: "Allow",
                        role: .standard,
                        isEnabled: true
                    )
                ]
            )
        )))

        XCTAssertTrue(
            SkalmanComponentCatalog.conversationUserMessage.hostOwnedBehavior
                .contains(.messageContent)
        )
        XCTAssertTrue(
            SkalmanComponentCatalog.conversationToolCall.hostOwnedBehavior
                .contains(.toolResultAttachment)
        )
    }

    func testDisplayChromeContractsExposeOnlyAdditiveSessionScopedSeams() throws {
        let sessionID = "session-1"
        let pane = SkalmanComponentCatalog.displayPaneHeader
        let paneTarget = ExtensionComponentTarget.displayPaneHeader(sessionID: sessionID)

        try pane.validate(.init(
            id: "display-status",
            target: paneTarget,
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
        ))
        XCTAssertEqual(pane.context, .sessionPresentation)
        XCTAssertEqual(pane.replacement, .none)
        for behavior in [
            ExtensionHostOwnedBehavior.tabSelection,
            .tabClosure,
            .tabOrder,
            .tabIdentity,
            .tabActiveState,
            .tabOverflow,
            .tabPersistence,
            .newTabMenu,
            .paneVisibility
        ] {
            XCTAssertTrue(pane.hostOwnedBehavior.contains(behavior))
        }
        XCTAssertThrowsError(try pane.validate(.init(
            id: "replacement",
            target: paneTarget,
            replacement: .text("Alternate tabs", role: .compactBody)
        )))
        XCTAssertThrowsError(try pane.validate(.init(
            id: "missing-proceed",
            target: paneTarget,
            hook: .status("No native anchor", role: .warning)
        )))
        XCTAssertThrowsError(try pane.validate(.init(
            id: "vertical",
            target: paneTarget,
            hook: .stack(
                axis: .vertical,
                spacing: .small,
                children: [.proceed, .status("No", role: .neutral)]
            )
        )))

        let tab = SkalmanComponentCatalog.displayTabHeader
        let tabTarget = ExtensionComponentTarget.displayTabHeader(sessionID: sessionID)
        try tab.validate(.init(
            id: "tab-status",
            target: tabTarget,
            slots: [
                .init(
                    slot: "after-title",
                    children: [.status("Live", role: .positive)]
                )
            ]
        ))
        XCTAssertEqual(tab.context, .sessionPresentation)
        XCTAssertEqual(tab.replacement, .none)
        XCTAssertNil(tab.hookConstraints)
        XCTAssertTrue(tab.hostOwnedBehavior.contains(.tabSelection))
        XCTAssertTrue(tab.hostOwnedBehavior.contains(.tabClosure))
        XCTAssertThrowsError(try tab.validate(.init(
            id: "tab-action",
            target: tabTarget,
            slots: [
                .init(
                    slot: "after-title",
                    children: [
                        .button(
                            id: "close",
                            title: "Close",
                            role: .standard,
                            isEnabled: true
                        )
                    ]
                )
            ]
        )))
        XCTAssertThrowsError(try tab.validate(.init(
            id: "tab-hook",
            target: tabTarget,
            hook: .stack(
                axis: .horizontal,
                spacing: .small,
                children: [.proceed, .status("No", role: .neutral)]
            )
        )))
    }

    func testPublicComponentValidatorReturnsPathsForGeneratedInvalidUI() throws {
        let patch = ExtensionComponentPatch(
            id: "invalid-row",
            target: .init(
                component: "sidebar.session-row",
                contractVersion: 1
            ),
            replacement: .stack(
                axis: .vertical,
                spacing: .large,
                children: [
                    .text(String(repeating: "x", count: 81), role: .heading)
                ]
            )
        )

        XCTAssertThrowsError(
            try SkalmanComponentCatalog.sidebarSessionRow.validate(patch)
        ) { error in
            let validation = error as? ExtensionValidationError
            let paths = Set(validation?.issues.map(\.path) ?? [])
            XCTAssertTrue(paths.contains("replacement"))
            XCTAssertTrue(paths.contains("replacement.children[0]"))
            XCTAssertTrue(paths.contains("replacement.children[0].text"))
        }
    }

    func testGeneratedComponentDocumentCarriesSchemaAssetsAndExamples() throws {
        let document = SkalmanComponentCatalog.document
        let identity = try XCTUnwrap(
            document.components.first {
                $0.entry.contract.id == .sidebarSessionIdentity
            }
        )

        XCTAssertEqual(
            identity.entry.hostAssets.map(\.id),
            ["session.provider-image", "session.account-image"]
        )
        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(
            ExtensionComponentCatalogDocument.self,
            from: encoded
        )
        XCTAssertEqual(decoded, document)
        XCTAssertTrue(
            String(decoding: encoded, as: UTF8.self)
                .contains(#""sidebar.session-identity""#)
        )
    }

    func testTheHostConnectionPrefersAnInheritedDescriptorOverALoopbackPort() throws {
        let both = try ExtensionHostConnection(environment: [
            ExtensionHostConnection.tokenEnvironmentKey: "token",
            ExtensionHostConnection.urlEnvironmentKey: "http://127.0.0.1:9/v1",
            ExtensionHostConnection.descriptorEnvironmentKey: "3"
        ])
        XCTAssertEqual(both.descriptor, 3)
        XCTAssertEqual(both.baseURL, ExtensionHostConnection.descriptorBaseURL)

        let loopback = try ExtensionHostConnection(environment: [
            ExtensionHostConnection.tokenEnvironmentKey: "token",
            ExtensionHostConnection.urlEnvironmentKey: "http://127.0.0.1:9/v1"
        ])
        XCTAssertNil(loopback.descriptor)

        // A descriptor that is not a descriptor must not silently disable brokering: with no
        // usable URL either, the extension is told it has no host rather than failing later.
        XCTAssertThrowsError(try ExtensionHostConnection(environment: [
            ExtensionHostConnection.tokenEnvironmentKey: "token",
            ExtensionHostConnection.descriptorEnvironmentKey: "not-a-number"
        ]))
        XCTAssertThrowsError(try ExtensionHostConnection(environment: [
            ExtensionHostConnection.urlEnvironmentKey: "http://127.0.0.1:9/v1",
            ExtensionHostConnection.descriptorEnvironmentKey: "3"
        ]))
    }

    func testDescriptorTransportFramesRequestsTheHostRouterAlreadyParses() throws {
        let request = ExtensionHostDescriptorTransport.serialize(
            method: "PUT",
            requestTarget: "/v1/component-patches",
            bearerToken: "token-value",
            contentType: "application/json",
            body: Data("{}".utf8)
        )
        let text = String(decoding: request, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("PUT /v1/component-patches HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Authorization: Bearer token-value\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{}"))

        // A GET states a zero length rather than omitting it, because the host's reader
        // delimits every message by Content-Length and never by connection close.
        let get = String(
            decoding: ExtensionHostDescriptorTransport.serialize(
                method: "GET",
                requestTarget: "/v1/sessions",
                bearerToken: "token-value",
                contentType: nil,
                body: nil
            ),
            as: UTF8.self
        )
        XCTAssertTrue(get.contains("Content-Length: 0\r\n"))
        XCTAssertFalse(get.contains("Content-Type"))
    }

    func testDescriptorTransportReadsOneResponseAndKeepsTheRest() throws {
        var buffer = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8)
        buffer.append(Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n".utf8))

        let first = try XCTUnwrap(
            ExtensionHostDescriptorTransport.parseResponse(from: &buffer)
        )
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(String(decoding: first.body, as: UTF8.self), "hello")

        let second = try XCTUnwrap(
            ExtensionHostDescriptorTransport.parseResponse(from: &buffer)
        )
        XCTAssertEqual(second.status, 204)
        XCTAssertTrue(second.body.isEmpty)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDescriptorTransportWaitsForAPartialResponseAndRejectsAnUnframedOne() throws {
        var partial = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel".utf8)
        XCTAssertNil(try ExtensionHostDescriptorTransport.parseResponse(from: &partial))

        var headless = Data("HTTP/1.1 200 OK\r\n\r\nhello".utf8)
        XCTAssertThrowsError(
            try ExtensionHostDescriptorTransport.parseResponse(from: &headless)
        ) { error in
            XCTAssertEqual(error as? ExtensionHostClientError, .invalidResponse)
        }

        var garbage = Data("NOT-HTTP\r\n\r\n".utf8)
        XCTAssertThrowsError(
            try ExtensionHostDescriptorTransport.parseResponse(from: &garbage)
        )
    }

    func testTheSafeSDKDoesNotImportUIFrameworks() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot
            .appendingPathComponent("Sources/SkalmanExtensionKit", isDirectory: true)

        let files = try FileManager.default.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        )

        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("import AppKit"), file.lastPathComponent)
            XCTAssertFalse(source.contains("import SwiftUI"), file.lastPathComponent)
        }
    }

    func testPolicyRejectsEverySwiftImportFormForUIFrameworks() {
        let source = """
            import Foundation
            import AppKit
            @_implementationOnly import SwiftUI
            import class AppKit.NSButton
            """

        let violations = ExtensionSourcePolicy.violations(
            in: source,
            path: "Sources/Example/main.swift"
        )

        XCTAssertEqual(
            violations.map(\.module),
            ["AppKit", "SwiftUI", "AppKit"]
        )
        XCTAssertEqual(violations.map(\.line), [2, 3, 4])
    }

    /// Every example manifest, found by enumeration rather than by name.
    ///
    /// This listed its two manifests explicitly until a third example was added with
    /// `schemaVersion` where the format requires `formatVersion` — an invalid manifest that
    /// would have been refused on import, sitting in the directory authors are told to copy
    /// from, passing tests. A named list only ever checks the examples someone remembered to
    /// add to it.
    func testEveryExampleManifestDecodesAndValidates() throws {
        let examples = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples", isDirectory: true)

        let directories = try FileManager.default.contentsOfDirectory(
            at: examples,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        XCTAssertGreaterThanOrEqual(directories.count, 3, "examples went missing")

        var manifests: [String: ExtensionManifest] = [:]
        for directory in directories {
            let url = directory.appendingPathComponent("skalman-extension.json")
            let name = directory.lastPathComponent
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "\(name) has no manifest, so nothing installs it"
            )
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
                try manifest.validate()
                manifests[name] = manifest
            } catch {
                XCTFail("\(name): \(error)")
            }
        }

        XCTAssertEqual(
            manifests["HelloStatusExtension"]?.identifier,
            "se.mjukis.hello-status"
        )
        XCTAssertEqual(
            manifests["HelloStatusConsumerExtension"]?
                .serviceDependencies.first?.providerIdentifier,
            manifests["HelloStatusExtension"]?.identifier
        )
    }
}
