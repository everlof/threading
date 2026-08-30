import Foundation
import ThreadingExtensionKit
import XCTest

@testable import Threading

final class WorkspaceNavigatorOptionValueStoreTests: XCTestCase {
    private final class ResultBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value?

        func set(_ value: Value) {
            lock.lock()
            storage = value
            lock.unlock()
        }

        func value() -> Value? {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class FirstSaveGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var hasPaused = false

        func pauseIfNeeded() {
            lock.lock()
            let shouldPause = !hasPaused
            hasPaused = true
            lock.unlock()
            guard shouldPause else { return }
            entered.signal()
            _ = resume.wait(timeout: .now() + 2)
        }
    }

    private var cleanupURLs: [URL] = []

    override func tearDown() {
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupURLs.removeAll()
        super.tearDown()
    }

    func testHydrationFiltersInvalidValuesAndTheNextWritePreservesUnknownState() throws {
        let root = temporaryDirectory("preservation")
        let file = optionFile(in: root)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original: [String: Any] = [
            "formatVersion": 1,
            "value": [
                "formatVersion": 1,
                "values": [
                    "activity": [
                        "group": true,
                        "sort": 42,
                        "future-option": "keep-me",
                    ],
                    "future-navigator": ["future-option": ["nested", "value"]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: file)

        let store = WorkspaceNavigatorOptionValueStore(rootURL: root)
        let snapshot = try store.activate(
            extensionIdentifier: extensionIdentifier,
            processGeneration: "generation-1",
            navigators: [navigator]
        )

        XCTAssertEqual(snapshot.persistenceOutcome, .loaded)
        XCTAssertEqual(snapshot.revision, 0)
        XCTAssertEqual(snapshot.valuesByNavigatorID[navigator.id], [
            "group": .bool(true),
            "sort": .string("recent"),
        ])

        let updated = try set(
            .string("name"),
            store: store,
            generation: "generation-1",
            optionID: "sort"
        ).get()
        XCTAssertEqual(updated.revision, 1)
        XCTAssertEqual(updated.valuesByNavigatorID[navigator.id]?["sort"], .string("name"))

        let document = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        let value = try XCTUnwrap(document["value"] as? [String: Any])
        let values = try XCTUnwrap(value["values"] as? [String: Any])
        let activity = try XCTUnwrap(values["activity"] as? [String: Any])
        XCTAssertEqual(activity["future-option"] as? String, "keep-me")
        XCTAssertEqual(activity["sort"] as? String, "name")
        XCTAssertNotNil(values["future-navigator"])
    }

    func testMissingStateSerializesRapidWritesAndReopensAtTheDurableWinner() throws {
        let root = temporaryDirectory("rapid-writes")
        let store = WorkspaceNavigatorOptionValueStore(rootURL: root)
        let initial = try store.activate(
            extensionIdentifier: extensionIdentifier,
            processGeneration: "generation-1",
            navigators: [navigator]
        )
        XCTAssertEqual(initial.persistenceOutcome, .missing)
        XCTAssertEqual(initial.valuesByNavigatorID[navigator.id]?["group"], .bool(false))

        let values: [ExtensionJSONValue] = [.bool(true), .bool(false), .bool(true)]
        let boxes = values.map { _ in
            ResultBox<Result<WorkspaceNavigatorOptionSnapshot, Error>>()
        }
        let finished = DispatchSemaphore(value: 0)
        for (index, value) in values.enumerated() {
            store.set(
                value,
                extensionIdentifier: extensionIdentifier,
                processGeneration: "generation-1",
                navigatorID: navigator.id,
                optionID: "group"
            ) {
                boxes[index].set($0)
                finished.signal()
            }
        }
        for _ in values {
            XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        }
        let first = try XCTUnwrap(boxes[0].value())
        let second = try XCTUnwrap(boxes[1].value())
        let third = try XCTUnwrap(boxes[2].value())

        XCTAssertEqual(try first.get().revision, 1)
        XCTAssertEqual(try second.get().revision, 2)
        XCTAssertEqual(try third.get().revision, 3)
        XCTAssertEqual(
            try third.get().valuesByNavigatorID[navigator.id]?["group"],
            .bool(true)
        )

        let reopened = WorkspaceNavigatorOptionValueStore(rootURL: root)
        let durable = try reopened.activate(
            extensionIdentifier: extensionIdentifier,
            processGeneration: "generation-2",
            navigators: [navigator]
        )
        XCTAssertEqual(durable.persistenceOutcome, .loaded)
        XCTAssertEqual(durable.valuesByNavigatorID[navigator.id]?["group"], .bool(true))
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: optionFile(in: root).deletingLastPathComponent().path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: optionFile(in: root).path
        )
        XCTAssertEqual(
            (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
        XCTAssertEqual(
            (fileAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
    }

    func testCorruptStateIsQuarantinedBeforeDefaultsCanBeReplaced() throws {
        let root = temporaryDirectory("corrupt")
        let file = optionFile(in: root)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corrupt = Data("{".utf8)
        try corrupt.write(to: file)

        let store = WorkspaceNavigatorOptionValueStore(rootURL: root)
        let snapshot = try store.activate(
            extensionIdentifier: extensionIdentifier,
            processGeneration: "generation-1",
            navigators: [navigator]
        )
        guard case .quarantinedCorrupt(let recoveryURL) = snapshot.persistenceOutcome else {
            return XCTFail("corrupt state was not quarantined")
        }
        let recovery = try XCTUnwrap(recoveryURL)
        XCTAssertEqual(try Data(contentsOf: recovery), corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        _ = try set(
            .bool(true),
            store: store,
            generation: "generation-1",
            optionID: "group"
        ).get()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: recovery), corrupt)
    }

    func testNewerStateIsPreservedByteForByteAndDisablesWrites() throws {
        let root = temporaryDirectory("future")
        let file = optionFile(in: root)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let future = Data(
            #"{"formatVersion":1,"value":{"formatVersion":2,"values":{"future":{"option":true}}}}"#.utf8
        )
        try future.write(to: file)

        let store = WorkspaceNavigatorOptionValueStore(rootURL: root)
        let snapshot = try store.activate(
            extensionIdentifier: extensionIdentifier,
            processGeneration: "generation-1",
            navigators: [navigator]
        )
        XCTAssertEqual(snapshot.persistenceOutcome, .unsupportedNewer(found: 2))
        XCTAssertEqual(snapshot.valuesByNavigatorID[navigator.id]?["group"], .bool(false))

        XCTAssertThrowsError(try set(
            .bool(true),
            store: store,
            generation: "generation-1",
            optionID: "group"
        ).get()) { error in
            XCTAssertEqual(
                error as? WorkspaceNavigatorOptionValueStoreError,
                .unsupportedNewerFormat(2)
            )
        }
        XCTAssertEqual(try Data(contentsOf: file), future)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: file.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent),
            [file.lastPathComponent]
        )
    }

    func testNewerRecoverableEnvelopeIsPreservedWithoutAQuarantineCopy() throws {
        let root = temporaryDirectory("future-envelope")
        let file = optionFile(in: root)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let future = Data(
            #"{"formatVersion":2,"value":{"futureShape":true}}"#.utf8
        )
        try future.write(to: file)

        let store = WorkspaceNavigatorOptionValueStore(rootURL: root)
        let snapshot = try store.activate(
            extensionIdentifier: extensionIdentifier,
            processGeneration: "generation-1",
            navigators: [navigator]
        )

        XCTAssertEqual(snapshot.persistenceOutcome, .unsupportedNewer(found: 2))
        XCTAssertEqual(snapshot.valuesByNavigatorID[navigator.id]?["group"], .bool(false))
        XCTAssertEqual(try Data(contentsOf: file), future)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: file.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent),
            [file.lastPathComponent]
        )
    }

    func testReloadDrainsAcceptedWritesThenFencesTheRetiredGeneration() throws {
        let root = temporaryDirectory("reload-fence")
        let gate = FirstSaveGate()
        let store = WorkspaceNavigatorOptionValueStore(rootURL: root) {
            gate.pauseIfNeeded()
        }
        _ = try store.activate(
            extensionIdentifier: extensionIdentifier,
            processGeneration: "generation-1",
            navigators: [navigator]
        )

        let first = ResultBox<Result<WorkspaceNavigatorOptionSnapshot, Error>>()
        let second = ResultBox<Result<WorkspaceNavigatorOptionSnapshot, Error>>()
        let writesFinished = DispatchSemaphore(value: 0)
        store.set(
            .bool(true),
            extensionIdentifier: extensionIdentifier,
            processGeneration: "generation-1",
            navigatorID: navigator.id,
            optionID: "group"
        ) {
            first.set($0)
            writesFinished.signal()
        }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 2), .success)
        store.set(
            .bool(false),
            extensionIdentifier: extensionIdentifier,
            processGeneration: "generation-1",
            navigatorID: navigator.id,
            optionID: "group"
        ) {
            second.set($0)
            writesFinished.signal()
        }

        store.deactivate(
            extensionIdentifier: extensionIdentifier,
            processGeneration: "generation-1"
        )
        let replacement = ResultBox<Result<WorkspaceNavigatorOptionSnapshot, Error>>()
        let activationFinished = DispatchSemaphore(value: 0)
        let identifier = extensionIdentifier
        let declaration = navigator
        DispatchQueue.global(qos: .userInitiated).async {
            replacement.set(Result {
                try store.activate(
                    extensionIdentifier: identifier,
                    processGeneration: "generation-2",
                    navigators: [declaration]
                )
            })
            activationFinished.signal()
        }
        gate.resume.signal()

        XCTAssertEqual(writesFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(writesFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(activationFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(try XCTUnwrap(first.value()).get().revision, 1)
        XCTAssertEqual(try XCTUnwrap(second.value()).get().revision, 2)
        let activated = try XCTUnwrap(replacement.value()).get()
        XCTAssertEqual(
            activated.valuesByNavigatorID[navigator.id]?["group"],
            .bool(false)
        )

        store.deactivate(
            extensionIdentifier: extensionIdentifier,
            processGeneration: "generation-2"
        )
        XCTAssertThrowsError(try set(
            .bool(true),
            store: store,
            generation: "generation-2",
            optionID: "group"
        ).get()) { error in
            XCTAssertEqual(
                error as? WorkspaceNavigatorOptionValueStoreError,
                .inactiveGeneration
            )
        }

        let reopened = WorkspaceNavigatorOptionValueStore(rootURL: root)
        let durable = try reopened.activate(
            extensionIdentifier: extensionIdentifier,
            processGeneration: "generation-3",
            navigators: [navigator]
        )
        XCTAssertEqual(
            durable.valuesByNavigatorID[navigator.id]?["group"],
            .bool(false)
        )
    }

    func testADeclarationFreeGenerationDoesNotTouchTheFilesystem() throws {
        let root = temporaryDirectory("no-options")
        let store = WorkspaceNavigatorOptionValueStore(rootURL: root)
        let snapshot = try store.activate(
            extensionIdentifier: extensionIdentifier,
            processGeneration: "generation-1",
            navigators: [ExtensionWorkspaceNavigator(
                id: "plain",
                title: "Plain",
                root: .content(.status("Ready", role: .neutral))
            )]
        )

        XCTAssertEqual(snapshot.persistenceOutcome, .skippedNoDeclarations)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRegisteredFactSelectionRoundTripsAndNoneElidesItsStoredValue() throws {
        let root = temporaryDirectory("registered-fact")
        let store = WorkspaceNavigatorOptionValueStore(rootURL: root)
        let declaration = registeredFactNavigator
        let initial = try store.activate(
            extensionIdentifier: extensionIdentifier,
            processGeneration: "generation-1",
            navigators: [declaration]
        )
        XCTAssertEqual(initial.persistenceOutcome, .missing)
        XCTAssertEqual(initial.valuesByNavigatorID[declaration.id], [:])
        XCTAssertEqual(initial.registeredFactSelectionsByNavigatorID[declaration.id], [:])

        let key = ExtensionFactKey(id: "gitlab.merge-request.state", version: 1)
        let selected = try setRegisteredFact(
            key,
            store: store,
            generation: "generation-1",
            navigator: declaration
        ).get()
        XCTAssertEqual(selected.revision, 1)
        XCTAssertEqual(
            selected.registeredFactSelectionsByNavigatorID[declaration.id]?["group-by"],
            key
        )
        XCTAssertEqual(selected.valuesByNavigatorID[declaration.id], [:])

        let document = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: optionFile(in: root))
            ) as? [String: Any]
        )
        let value = try XCTUnwrap(document["value"] as? [String: Any])
        let values = try XCTUnwrap(value["values"] as? [String: Any])
        let navigatorValues = try XCTUnwrap(values[declaration.id] as? [String: Any])
        let encodedKey = try XCTUnwrap(navigatorValues["group-by"] as? [String: Any])
        XCTAssertEqual(encodedKey["id"] as? String, key.id)
        XCTAssertEqual(encodedKey["version"] as? Int, key.version)

        XCTAssertThrowsError(try set(
            .string("not-a-static-option"),
            store: store,
            generation: "generation-1",
            optionID: "group-by"
        ).get()) { error in
            XCTAssertEqual(
                error as? WorkspaceNavigatorOptionValueStoreError,
                .invalidValue("group-by")
            )
        }

        let cleared = try setRegisteredFact(
            nil,
            store: store,
            generation: "generation-1",
            navigator: declaration
        ).get()
        XCTAssertEqual(cleared.revision, 2)
        XCTAssertEqual(cleared.registeredFactSelectionsByNavigatorID[declaration.id], [:])

        let reopened = WorkspaceNavigatorOptionValueStore(rootURL: root)
        let durable = try reopened.activate(
            extensionIdentifier: extensionIdentifier,
            processGeneration: "generation-2",
            navigators: [declaration]
        )
        XCTAssertEqual(durable.registeredFactSelectionsByNavigatorID[declaration.id], [:])
    }

    func testTemporarilyRemovedRegisteredFactDeclarationRetainsItsSelection() throws {
        let root = temporaryDirectory("registered-fact-retention")
        let declaration = registeredFactNavigator
        let key = ExtensionFactKey(id: "gitlab.merge-request.author", version: 1)
        let store = WorkspaceNavigatorOptionValueStore(rootURL: root)
        _ = try store.activate(
            extensionIdentifier: extensionIdentifier,
            processGeneration: "generation-1",
            navigators: [declaration]
        )
        _ = try setRegisteredFact(
            key,
            store: store,
            generation: "generation-1",
            navigator: declaration
        ).get()

        _ = try store.activate(
            extensionIdentifier: extensionIdentifier,
            processGeneration: "generation-2",
            navigators: [ExtensionWorkspaceNavigator(
                id: declaration.id,
                title: "Activity",
                root: .content(.status("Ready", role: .neutral))
            )]
        )
        let restored = try store.activate(
            extensionIdentifier: extensionIdentifier,
            processGeneration: "generation-3",
            navigators: [declaration]
        )
        XCTAssertEqual(
            restored.registeredFactSelectionsByNavigatorID[declaration.id]?["group-by"],
            key
        )
    }

    private var extensionIdentifier: String { "com.example.navigator" }

    private var navigator: ExtensionWorkspaceNavigator {
        ExtensionWorkspaceNavigator(
            id: "activity",
            title: "Activity",
            root: .content(.status("Ready", role: .neutral)),
            options: [
                .init(
                    id: "group",
                    title: "Group",
                    control: .toggle(defaultValue: false)
                ),
                .init(
                    id: "sort",
                    title: "Sort",
                    control: .choice(
                        defaultValue: "recent",
                        options: [
                            .init(id: "recent", title: "Recent"),
                            .init(id: "name", title: "Name"),
                        ]
                    )
                ),
            ]
        )
    }

    private var registeredFactNavigator: ExtensionWorkspaceNavigator {
        ExtensionWorkspaceNavigator(
            id: "activity",
            title: "Activity",
            root: .content(.status("Ready", role: .neutral)),
            pipeline: .init(
                consumes: [],
                registeredFactOptions: [
                    .init(
                        id: "group-by",
                        title: "Group by",
                        application: .bucket(
                            direction: .ascending,
                            unknownTitle: "Unknown"
                        )
                    ),
                ],
                output: .init(
                    collectionID: "sessions",
                    rowTemplate: .text(.literal("Session"), role: .body)
                )
            )
        )
    }

    private func set(
        _ value: ExtensionJSONValue,
        store: WorkspaceNavigatorOptionValueStore,
        generation: String,
        optionID: String
    ) -> Result<WorkspaceNavigatorOptionSnapshot, Error> {
        let result = ResultBox<Result<WorkspaceNavigatorOptionSnapshot, Error>>()
        let finished = DispatchSemaphore(value: 0)
        store.set(
            value,
            extensionIdentifier: extensionIdentifier,
            processGeneration: generation,
            navigatorID: navigator.id,
            optionID: optionID
        ) {
            result.set($0)
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        return result.value() ?? .failure(
            WorkspaceNavigatorOptionValueStoreError.couldNotBeSaved
        )
    }

    private func setRegisteredFact(
        _ key: ExtensionFactKey?,
        store: WorkspaceNavigatorOptionValueStore,
        generation: String,
        navigator: ExtensionWorkspaceNavigator
    ) -> Result<WorkspaceNavigatorOptionSnapshot, Error> {
        let result = ResultBox<Result<WorkspaceNavigatorOptionSnapshot, Error>>()
        let finished = DispatchSemaphore(value: 0)
        store.setRegisteredFactSelection(
            key,
            extensionIdentifier: extensionIdentifier,
            processGeneration: generation,
            navigatorID: navigator.id,
            optionID: "group-by"
        ) {
            result.set($0)
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        return result.value() ?? .failure(
            WorkspaceNavigatorOptionValueStoreError.couldNotBeSaved
        )
    }

    private func temporaryDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WorkspaceNavigatorOptionValueStoreTests-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        cleanupURLs.append(url)
        return url
    }

    private func optionFile(in root: URL) -> URL {
        root
            .appendingPathComponent(extensionIdentifier, isDirectory: true)
            .appendingPathComponent("navigator-options.json", isDirectory: false)
    }
}
