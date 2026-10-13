import ThreadingRemoteKit
import XCTest
@testable import Threading

@MainActor
final class RemoteConversationConfigurationTests: HostedStoreTestCase {
    private static let provider = """
    import json, sys
    for line in sys.stdin:
        message = json.loads(line)
        if message.get("type") != "control_request": continue
        request = message.get("request", {})
        refused = request.get("subtype") == "set_permission_mode" and request.get("mode") == "plan"
        response = {"subtype": "error" if refused else "success", "request_id": message.get("request_id")}
        if refused: response["error"] = "Fixture refused the permission change"
        else: response["response"] = {}
        print(json.dumps({"type": "control_response", "response": response}), flush=True)
    """

    func testRemoteSettingsUseLiveProviderAcknowledgementAndPersistOnlySuccessfulChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: directory))
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude, usesNativeUI: true))
        let initialModel = try XCTUnwrap(AgentModels.options(for: .claude, account: nil).first {
            AgentModels.supportsFastMode(kind: .claude, model: $0.identifier, account: nil)
        }).identifier
        XCTAssertTrue(store.update(sessionID: session.id) {
            $0.backgroundHost = false
            $0.model = initialModel
        }.succeeded)
        let controller = try XCTUnwrap(ConversationViewController(
            agentSession: session, project: project,
            currentSessionProjection: CurrentSessionProjection { id in store.session(withID: id) },
            launchPlanProvider: { _, _, _ in
                .init(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.provider], resumeState: .unavailable)
            }, customizationLookup: { _ in .empty }
        ))
        _ = controller.view
        controller.launch()
        defer { controller.terminate(preservingViewport: false) }
        XCTAssertTrue(waitUntil { controller.isRunning })
        let settings = try XCTUnwrap(controller.remoteSnapshot.configuration)
        XCTAssertFalse(settings.controls.contains { $0.setting == .effort }, "Claude has no live effort control")
        let speed = try XCTUnwrap(settings.controls.first { $0.setting == .speed })
        XCTAssertEqual(Set(speed.choices.compactMap(\.value)), ["true", "false"])
        let model = try XCTUnwrap(settings.controls.first { $0.setting == .model })
        let choice = try XCTUnwrap(model.choices.first { $0.value != nil && $0.value != initialModel })
        var changed: Result<Void, Error>?
        controller.configureRemoteConversation(setting: .model, value: choice.value) { changed = $0 }
        XCTAssertTrue(waitUntil { changed != nil })
        try XCTUnwrap(changed).get()
        XCTAssertEqual(store.session(withID: session.id)?.model, choice.value)

        let permissions = try XCTUnwrap(controller.remoteSnapshot.configuration?.controls.first { $0.setting == .permissions })
        XCTAssertTrue(permissions.choices.contains { $0.value == AgentPermissionMode.plan.rawValue })
        let original = store.session(withID: session.id)?.permissionMode
        var refused: Result<Void, Error>?
        controller.configureRemoteConversation(setting: .permissions, value: AgentPermissionMode.plan.rawValue) { refused = $0 }
        XCTAssertTrue(waitUntil { refused != nil })
        XCTAssertThrowsError(try XCTUnwrap(refused).get())
        XCTAssertEqual(store.session(withID: session.id)?.permissionMode, original)

        var invalid: Result<Void, Error>?
        controller.configureRemoteConversation(setting: .model, value: "not-in-the-catalogue") { invalid = $0 }
        XCTAssertThrowsError(try XCTUnwrap(invalid).get())
        XCTAssertEqual(store.session(withID: session.id)?.model, choice.value)

    }

    func testSharedParticipantsCannotChangeSessionSettings() throws {
        let guest = RemoteAuthorization(shareID: "guest", capability: .interact, scope: .allSessions, principal: .guest)
        var result: Result<Void, Error>?
        RemoteSessionMirrorRegistry.shared.configureConversation(
            sessionID: SessionID(), setting: .permissions, value: AgentPermissionMode.bypassPermissions.rawValue,
            authorization: guest
        ) { result = $0 }
        XCTAssertThrowsError(try XCTUnwrap(result).get())
    }

    func testSettingsAreProjectedOnlyToOwnerDevices() {
        let configuration = RemoteConversationConfigurationDTO(controls: [
            .init(setting: .permissions, title: "Ask", isEnabled: true, choices: [.init(title: "Ask", value: "default")])
        ])
        let snapshot = RemoteConversationSnapshotDTO(rows: [], canSend: true, configuration: configuration)
        let owner = RemoteAuthorization(shareID: "owner", capability: .interact, scope: .allSessions, principal: .ownerDevice)
        let guest = RemoteAuthorization(shareID: "guest", capability: .interact, scope: .allSessions, principal: .guest)
        XCTAssertEqual(RemoteConversationWirePolicy.authorized(snapshot, for: owner).configuration, configuration)
        XCTAssertNil(RemoteConversationWirePolicy.authorized(snapshot, for: guest).configuration)
        let delta = RemoteConversationWirePolicy.deltaWithUnchangedRows(
            from: .init(rows: [], canSend: true), to: snapshot, baseRevision: 1, revision: 2
        )
        XCTAssertEqual(delta?.configuration, configuration)
        XCTAssertNil(delta.flatMap { RemoteConversationWirePolicy.authorized($0, for: guest).configuration })
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(12)
        while !predicate(), Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        return predicate()
    }
}
