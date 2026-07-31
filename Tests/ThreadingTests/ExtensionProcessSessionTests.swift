import Foundation
import ThreadingExtensionKit
import XCTest
@testable import Threading

final class ExtensionProcessSessionTests: XCTestCase {

    func testPersistentProcessRegistersAndReturnsACorrelatedPanelUpdate() throws {
        let registration = ExtensionRegistration(
            panels: [
                .init(
                    id: "status",
                    title: "Status",
                    root: .status("Ready", role: .positive)
                )
            ]
        )
        let response = ExtensionActionResponse(
            requestID: "request-1",
            panel: .init(
                id: "status",
                title: "Status",
                root: .status("Refreshed", role: .positive)
            ),
            message: "Status refreshed."
        )
        let directory = try makeBundle(
            registration: registration,
            scriptAfterRegistration: """
            IFS= read -r request || exit 65
            printf '%s\\n' \(shellQuoted(json(response)))
            while IFS= read -r request; do :; done
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = try ExtensionBundleInspector.inspect(at: directory)
        let started = try ExtensionProcessSession.start(bundle: bundle)
        defer { started.session.terminate() }
        XCTAssertEqual(started.registration, registration)

        let completed = expectation(description: "action response")
        started.session.invoke(
            panelID: "status",
            actionID: "refresh",
            requestID: "request-1"
        ) { result in
            XCTAssertEqual(try? result.get(), response)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    func testReturnedPanelMustMatchThePanelThatRaisedTheAction() throws {
        let registration = ExtensionRegistration(
            panels: [
                .init(
                    id: "status",
                    title: "Status",
                    root: .status("Ready", role: .positive)
                )
            ]
        )
        let response = ExtensionActionResponse(
            requestID: "request-2",
            panel: .init(
                id: "different",
                title: "Different",
                root: .status("Wrong panel", role: .negative)
            )
        )
        let directory = try makeBundle(
            registration: registration,
            scriptAfterRegistration: """
            IFS= read -r request || exit 65
            printf '%s\\n' \(shellQuoted(json(response)))
            while IFS= read -r request; do :; done
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = try ExtensionProcessSession.start(
            bundle: ExtensionBundleInspector.inspect(at: directory)
        )
        defer { started.session.terminate() }

        let completed = expectation(description: "rejected response")
        started.session.invoke(
            panelID: "status",
            actionID: "refresh",
            requestID: "request-2"
        ) { result in
            switch result {
            case .success:
                XCTFail("mismatched panel was accepted")
            case .failure(let error):
                guard case .responsePanelMismatch(let expected, let actual) =
                    error as? ExtensionProcessError else {
                    XCTFail("unexpected error: \(error)")
                    completed.fulfill()
                    return
                }
                XCTAssertEqual(expected, "status")
                XCTAssertEqual(actual, "different")
            }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    func testPersistentProcessRoutesACorrelatedWorkspaceNavigatorUpdate() throws {
        let initial = ExtensionWorkspaceNavigator(
            id: "activity",
            title: "Activity",
            root: .content(.status("Loading", role: .neutral)),
            loadActionID: "refresh"
        )
        let replacement = ExtensionWorkspaceNavigator(
            id: initial.id,
            title: initial.title,
            root: .collection(.init(
                id: "threads",
                layout: .list,
                items: [
                    .init(
                        id: "thread-1",
                        content: .text("Build fixed", role: .body),
                        activation: .action(id: "open-thread")
                    )
                ]
            )),
            loadActionID: initial.loadActionID
        )
        let response = ExtensionWorkspaceNavigatorActionResponse(
            requestID: "navigator-request-1",
            navigatorID: initial.id,
            navigator: replacement,
            message: "Activity refreshed."
        )
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingNavigatorAction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storage) }
        let directory = try makeBundle(
            registration: .init(workspaceNavigators: [initial]),
            additionalCapabilities: [.keyValueStorage],
            scriptAfterRegistration: """
            IFS= read -r request || exit 65
            printf '%s\\n' "$request" > "$THREADING_EXTENSION_KEY_VALUE_DIRECTORY/navigator-request.json"
            printf '%s\\n' \(shellQuoted(try json(response)))
            while IFS= read -r request; do :; done
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = try ExtensionProcessSession.start(
            bundle: ExtensionBundleInspector.inspect(at: directory),
            additionalEnvironment: [
                ExtensionStorageEnvironment.keyValueDirectory: storage.path
            ]
        )
        defer { started.session.terminate() }

        let context = ExtensionCommandContext(projectID: "project-1", sessionID: "session-1")
        let completed = expectation(description: "navigator response")
        started.session.invokeWorkspaceNavigatorAction(
            navigatorID: initial.id,
            actionID: "filter",
            value: .string("active"),
            context: context,
            requestID: response.requestID
        ) { result in
            XCTAssertEqual(try? result.get(), response)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)

        let request = try JSONDecoder().decode(
            ExtensionWorkspaceNavigatorActionRequest.self,
            from: Data(
                contentsOf: storage.appendingPathComponent("navigator-request.json")
            )
        )
        XCTAssertEqual(request.navigatorID, initial.id)
        XCTAssertEqual(request.actionID, "filter")
        XCTAssertEqual(request.value, .string("active"))
        XCTAssertEqual(request.context, context)
    }

    func testWorkspaceNavigatorResponseMustNameTheInvokedNavigator() throws {
        let navigator = ExtensionWorkspaceNavigator(
            id: "activity",
            title: "Activity",
            root: .content(.status("Ready", role: .positive))
        )
        let response = ExtensionWorkspaceNavigatorActionResponse(
            requestID: "navigator-request-mismatch",
            navigatorID: "different-navigator"
        )
        let directory = try makeBundle(
            registration: .init(workspaceNavigators: [navigator]),
            scriptAfterRegistration: """
            IFS= read -r request || exit 65
            printf '%s\\n' \(shellQuoted(try json(response)))
            while IFS= read -r request; do :; done
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = try ExtensionProcessSession.start(
            bundle: ExtensionBundleInspector.inspect(at: directory)
        )
        defer { started.session.terminate() }

        let completed = expectation(description: "navigator mismatch")
        started.session.invokeWorkspaceNavigatorAction(
            navigatorID: navigator.id,
            actionID: "refresh",
            requestID: response.requestID
        ) { result in
            guard case .failure(let error) = result,
                  case .responseNavigatorMismatch(let expected, let actual) =
                    error as? ExtensionProcessError else {
                XCTFail("mismatched navigator was accepted")
                completed.fulfill()
                return
            }
            XCTAssertEqual(expected, navigator.id)
            XCTAssertEqual(actual, response.navigatorID)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    func testIndividualActionTimesOutWithoutBlockingTheCaller() throws {
        let registration = ExtensionRegistration(
            panels: [
                .init(
                    id: "status",
                    title: "Status",
                    root: .status("Ready", role: .positive)
                )
            ]
        )
        let directory = try makeBundle(
            registration: registration,
            scriptAfterRegistration: """
            IFS= read -r request || exit 65
            while IFS= read -r ignored; do :; done
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = try ExtensionProcessSession.start(
            bundle: ExtensionBundleInspector.inspect(at: directory)
        )
        defer { started.session.terminate() }

        let completed = expectation(description: "action timeout")
        started.session.invoke(
            panelID: "status",
            actionID: "refresh",
            timeout: 0.05
        ) { result in
            switch result {
            case .success:
                XCTFail("timed-out action succeeded")
            case .failure(let error):
                guard case .actionTimedOut(let action) = error as? ExtensionProcessError else {
                    XCTFail("unexpected error: \(error)")
                    completed.fulfill()
                    return
                }
                XCTAssertEqual(action, "refresh")
            }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    func testPersistentRegistrationHasABoundedStartup() throws {
        let directory = try makeBundle(
            registration: .init(),
            writesRegistration: false,
            scriptAfterRegistration: "while IFS= read -r ignored; do :; done"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(
            try ExtensionProcessSession.start(
                bundle: ExtensionBundleInspector.inspect(at: directory),
                timeout: 0.05
            )
        ) { error in
            guard case .registrationTimedOut = error as? ExtensionProcessError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testPersistentProcessRoutesACorrelatedCommandResponse() throws {
        let command = ExtensionCommand(
            id: "open-build",
            title: "Open Build",
            scope: .project
        )
        let registration = ExtensionRegistration(commands: [command])
        let response = ExtensionCommandResponse(
            requestID: "command-request-1",
            commandID: command.id,
            message: "Opened build."
        )
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingExtensionCommand-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storage) }
        let directory = try makeBundle(
            registration: registration,
            additionalCapabilities: [.keyValueStorage],
            scriptAfterRegistration: """
            IFS= read -r request || exit 65
            printf '%s\\n' "$request" > "$THREADING_EXTENSION_KEY_VALUE_DIRECTORY/received-command.json"
            printf '%s\\n' \(shellQuoted(json(response)))
            while IFS= read -r request; do :; done
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = try ExtensionProcessSession.start(
            bundle: ExtensionBundleInspector.inspect(at: directory),
            additionalEnvironment: [
                ExtensionStorageEnvironment.keyValueDirectory: storage.path
            ]
        )
        defer { started.session.terminate() }

        let context = ExtensionCommandContext(
            projectID: "project-1",
            sessionID: "session-1"
        )
        let completed = expectation(description: "command response")
        started.session.invokeCommand(
            commandID: command.id,
            context: context,
            requestID: response.requestID
        ) { result in
            XCTAssertEqual(try? result.get(), response)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)

        let received = try JSONDecoder().decode(
            ExtensionCommandRequest.self,
            from: Data(
                contentsOf: storage.appendingPathComponent("received-command.json")
            )
        )
        XCTAssertEqual(received.commandID, command.id)
        XCTAssertEqual(received.context, context)
    }

    func testCommandResponseMustNameTheCommandThatWasInvoked() throws {
        let command = ExtensionCommand(id: "open-build", title: "Open Build")
        let response = ExtensionCommandResponse(
            requestID: "command-request-mismatch",
            commandID: "different-command",
            message: "Wrong command."
        )
        let directory = try makeBundle(
            registration: .init(commands: [command]),
            scriptAfterRegistration: """
            IFS= read -r request || exit 65
            printf '%s\\n' \(shellQuoted(json(response)))
            while IFS= read -r request; do :; done
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = try ExtensionProcessSession.start(
            bundle: ExtensionBundleInspector.inspect(at: directory)
        )
        defer { started.session.terminate() }

        let completed = expectation(description: "command mismatch")
        started.session.invokeCommand(
            commandID: command.id,
            context: .init(),
            requestID: response.requestID
        ) { result in
            guard case .failure(let error) = result,
                  case .responseCommandMismatch(let expected, let actual) =
                    error as? ExtensionProcessError else {
                XCTFail("mismatched command was accepted")
                completed.fulfill()
                return
            }
            XCTAssertEqual(expected, command.id)
            XCTAssertEqual(actual, response.commandID)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    func testPersistentProcessRoutesACorrelatedMCPToolResponse() throws {
        let tool = ExtensionMCPTool(
            id: "lookup",
            title: "Lookup",
            description: "Look up one value."
        )
        let registration = ExtensionRegistration(mcpTools: [tool])
        let response = ExtensionMCPToolResponse(
            requestID: "tool-request-1",
            text: "cached value"
        )
        let directory = try makeBundle(
            registration: registration,
            scriptAfterRegistration: """
            IFS= read -r request || exit 65
            printf '%s\\n' \(shellQuoted(json(response)))
            while IFS= read -r request; do :; done
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = try ExtensionProcessSession.start(
            bundle: ExtensionBundleInspector.inspect(at: directory)
        )
        defer { started.session.terminate() }

        let completed = expectation(description: "MCP tool response")
        started.session.invokeMCPTool(
            sessionID: UUID().uuidString,
            toolID: tool.id,
            arguments: .object(["key": .string("answer")]),
            requestID: response.requestID
        ) { result in
            XCTAssertEqual(try? result.get(), response)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    func testPersistentProcessRoutesAndValidatesASettingsUpdate() throws {
        let settings = ExtensionSettingsContribution(
            pages: [
                .init(
                    id: "status",
                    title: "Status",
                    sections: [
                        .init(
                            id: "display",
                            fields: [
                                .init(
                                    id: "show-light",
                                    title: "Show light",
                                    control: .toggle(defaultValue: true)
                                )
                            ]
                        )
                    ]
                )
            ]
        )
        let response = ExtensionSettingsUpdateResponse(
            requestID: "settings-request-1",
            settingIDs: ["show-light"]
        )
        let directory = try makeBundle(
            registration: .init(),
            settings: settings,
            scriptAfterRegistration: """
            IFS= read -r request || exit 65
            printf '%s\\n' \(shellQuoted(json(response)))
            while IFS= read -r request; do :; done
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = try ExtensionProcessSession.start(
            bundle: ExtensionBundleInspector.inspect(at: directory)
        )
        defer { started.session.terminate() }

        let completed = expectation(description: "settings response")
        started.session.updateSettings(
            values: ["show-light": .bool(false)],
            requestID: response.requestID
        ) { result in
            XCTAssertEqual(try? result.get(), response)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    func testPersistentProcessRoutesAComponentActionWithoutAppKit() throws {
        let response = ExtensionActionResponse(
            requestID: "component-request-1",
            message: "Opened build."
        )
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingExtensionAction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storage) }
        let directory = try makeBundle(
            registration: .init(),
            additionalCapabilities: [.keyValueStorage],
            scriptAfterRegistration: """
            IFS= read -r request || exit 65
            printf '%s\\n' "$request" > "$THREADING_EXTENSION_KEY_VALUE_DIRECTORY/received-component-action.json"
            printf '%s\\n' \(shellQuoted(json(response)))
            while IFS= read -r request; do :; done
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = try ExtensionProcessSession.start(
            bundle: ExtensionBundleInspector.inspect(at: directory),
            additionalEnvironment: [
                ExtensionStorageEnvironment.keyValueDirectory: storage.path
            ]
        )
        defer { started.session.terminate() }

        let target = ExtensionComponentTarget(
            component: "sidebar.session-row",
            contractVersion: 1,
            entityID: "session-42"
        )
        let completed = expectation(description: "component action response")
        started.session.invokeComponentAction(
            target: target,
            actionID: "open-build",
            value: .string("build-42"),
            requestID: response.requestID
        ) { result in
            XCTAssertEqual(try? result.get(), response)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)

        let received = try JSONDecoder().decode(
            ExtensionComponentActionRequest.self,
            from: Data(
                contentsOf: storage.appendingPathComponent(
                    "received-component-action.json"
                )
            )
        )
        XCTAssertEqual(received.requestID, response.requestID)
        XCTAssertEqual(received.target, target)
        XCTAssertEqual(received.actionID, "open-build")
        XCTAssertEqual(received.value, .string("build-42"))
    }

    func testSandboxKeepsThePackageReadOnlyAndDeclaredStorageWritable() throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingExtensionSandbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storage) }
        let directory = try makeBundle(
            registration: .init(),
            additionalCapabilities: [.keyValueStorage],
            preRegistrationScript: """
            printf 'blocked' > ./package-write 2>/dev/null || :
            printf 'allowed' > "$THREADING_EXTENSION_KEY_VALUE_DIRECTORY/storage-write" || exit 68
            """,
            scriptAfterRegistration: "while IFS= read -r request; do :; done"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = try ExtensionProcessSession.start(
            bundle: ExtensionBundleInspector.inspect(at: directory),
            additionalEnvironment: [
                ExtensionStorageEnvironment.keyValueDirectory: storage.path
            ]
        )
        defer { started.session.terminate() }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("package-write").path
        ))
        XCTAssertEqual(
            try String(
                contentsOf: storage.appendingPathComponent("storage-write"),
                encoding: .utf8
            ),
            "allowed"
        )
    }

    func testPersistentProcessHandlesACorrelatedBrokeredServiceCall() throws {
        let service = ExtensionServiceDefinition(
            id: "status",
            version: 2,
            title: "Status",
            description: "Returns current status."
        )
        let registration = ExtensionRegistration(services: [service])
        let response = ExtensionServiceResponse(
            requestID: "service-request",
            serviceID: service.id,
            serviceVersion: service.version,
            value: .object(["state": .string("passed")])
        )
        let directory = try makeBundle(
            registration: registration,
            scriptAfterRegistration: """
            IFS= read -r request || exit 65
            printf '%s\\n' \(shellQuoted(try json(response)))
            while IFS= read -r request; do :; done
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = try ExtensionProcessSession.start(
            bundle: ExtensionBundleInspector.inspect(at: directory)
        )
        defer { started.session.terminate() }
        let completed = expectation(description: "service response")
        started.session.invokeService(
            callerExtensionIdentifier: "com.example.consumer",
            serviceID: service.id,
            serviceVersion: service.version,
            arguments: .object(["projectID": .string("project-1")]),
            requestID: response.requestID
        ) { result in
            XCTAssertEqual(try? result.get(), response)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    func testBrokeredServiceCallTimesOutWithoutStoppingTheProvider() throws {
        let service = ExtensionServiceDefinition(
            id: "status",
            title: "Status",
            description: "Returns current status."
        )
        let directory = try makeBundle(
            registration: .init(services: [service]),
            scriptAfterRegistration: """
            while IFS= read -r request; do :; done
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = try ExtensionProcessSession.start(
            bundle: ExtensionBundleInspector.inspect(at: directory)
        )
        defer { started.session.terminate() }

        let completed = expectation(description: "service timeout")
        started.session.invokeService(
            callerExtensionIdentifier: "com.example.consumer",
            serviceID: service.id,
            serviceVersion: service.version,
            arguments: .emptyObject,
            timeout: 0.05
        ) { result in
            guard case .failure(let error) = result,
                  case .serviceTimedOut(let serviceID) =
                    error as? ExtensionProcessError else {
                XCTFail("timed-out service call succeeded")
                completed.fulfill()
                return
            }
            XCTAssertEqual(serviceID, service.id)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    private func makeBundle(
        registration: ExtensionRegistration,
        writesRegistration: Bool = true,
        additionalCapabilities: Set<ExtensionCapability> = [],
        settings: ExtensionSettingsContribution = .init(),
        preRegistrationScript: String = "",
        scriptAfterRegistration: String
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingExtensionProcessTests-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bin,
            withIntermediateDirectories: true
        )

        var capabilities: Set<ExtensionCapability> = [.panels]
        if !registration.commands.isEmpty {
            capabilities.insert(.commands)
        }
        if !registration.mcpTools.isEmpty {
            capabilities.insert(.mcpTools)
        }
        if !registration.services.isEmpty {
            capabilities.insert(.servicesProvide)
        }
        if !registration.workspaceNavigators.isEmpty {
            capabilities.insert(.workspaceNavigation)
        }
        capabilities.formUnion(additionalCapabilities)
        if !settings.isEmpty {
            capabilities.insert(.settings)
        }
        let manifest = ExtensionManifest(
            identifier: "com.example.process-test",
            name: "Process Test",
            version: "0.1.0",
            runtime: .native,
            executable: "bin/extension",
            capabilities: capabilities,
            mcpTools: registration.mcpTools,
            settings: settings,
            services: registration.services
        )
        try JSONEncoder().encode(manifest).write(
            to: root.appendingPathComponent(ExtensionBundleInspector.manifestName)
        )

        let registrationLine = writesRegistration
            ? "printf '%s\\n' \(shellQuoted(try json(registration)))"
            : ""
        let script = """
        #!/bin/sh
        [ "$1" = "--threading-serve" ] || exit 64
        \(preRegistrationScript)
        \(registrationLine)
        \(scriptAfterRegistration)
        """
        let executable = bin.appendingPathComponent("extension")
        try Data((script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return root
    }

    private func json<Value: Encodable>(_ value: Value) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
