import Foundation

actor TriggerStore {
    enum StoreError: LocalizedError {
        case invalidRecord(String)
        case duplicate
        case missing

        var errorDescription: String? {
            switch self {
            case .invalidRecord(let reason): "Invalid trigger record: \(reason)"
            case .duplicate: "That trigger event or run already exists."
            case .missing: "The trigger record no longer exists."
            }
        }
    }

    static let shared = TriggerStore()

    private static let schemaVersion = 3
    private let database: SQLiteDatabase?
    private let openingError: Error?
    private let publishesDaemonConfiguration: Bool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(url: URL? = nil) {
        publishesDaemonConfiguration = url == nil && !StateManager.isHostedTest
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        do {
            let storeURL: URL
            if let url {
                storeURL = url
            } else {
                storeURL = try Self.defaultURL()
            }
            let opened = try SQLiteDatabase(
                path: storeURL.path,
                maximumSchemaVersion: Self.schemaVersion
            )
            try opened.migrate(to: Self.schemaVersion) { version in
                switch version {
                case 1:
                    try opened.execute(Self.version1)
                case 2:
                    try opened.execute(Self.version2)
                case 3:
                    try opened.execute("CREATE TABLE automation_due (id TEXT PRIMARY KEY, due REAL NOT NULL); CREATE INDEX automation_due_time ON automation_due(due,id); CREATE INDEX trigger_run_trigger ON trigger_run(trigger_id); CREATE INDEX trigger_run_trigger_state ON trigger_run(trigger_id,state);")
                default:
                    throw SQLiteDatabase.Failure.syntheticStep(
                        "No trigger migration to schema version \(version)"
                    )
                }
            }
            database = opened
            openingError = nil
        } catch {
            database = nil
            openingError = error
        }
    }

    func healthError() -> String? { openingError?.localizedDescription }

    /// Ends this store's SQLite lifetime before an owning temporary directory or app-data
    /// container is moved. Production's shared store remains open for the process lifetime.
    func close() { database?.close() }

    // MARK: Sources

    func saveSource(_ source: TriggerSourceInstallation) throws {
        let database = try readyDatabase()
        try validate(source)
        let payload = try encoder.encode(source)
        let statement = try database.prepare(Self.upsertSource)
        try statement
            .bind(1, source.id.uuidString)
            .bind(2, source.sourceType)
            .bind(3, source.enabled ? 1 : 0)
            .bind(4, source.health.rawValue)
            .bind(5, source.updatedAt.timeIntervalSince1970)
            .bind(6, payload)
            .run()
        if publishesDaemonConfiguration {
            let shouldRun = try publishDaemonConfiguration()
            Task { @MainActor in
                TriggerDaemonRegistrationCoordinator.shared.reconcile(shouldRun: shouldRun)
            }
        }
        changed()
    }

    func sources() throws -> [TriggerSourceInstallation] {
        let statement = try readyDatabase().prepare(Self.selectSources)
        defer { statement.finalize() }
        var result: [TriggerSourceInstallation] = []
        while try statement.step() {
            guard let data = statement.data(0) else { throw StoreError.invalidRecord("source data") }
            result.append(try decoder.decode(TriggerSourceInstallation.self, from: data))
        }
        return result
    }

    func source(id: TriggerSourceInstallationID) throws -> TriggerSourceInstallation? {
        let statement = try readyDatabase().prepare(Self.selectSource)
        defer { statement.finalize() }
        _ = statement.bind(1, id.uuidString)
        guard try statement.step(), let data = statement.data(0) else { return nil }
        return try decoder.decode(TriggerSourceInstallation.self, from: data)
    }

    // MARK: Definitions and revisions

    func saveDraft(_ definition: TriggerDefinition, revision: TriggerRevision) throws {
        let database = try readyDatabase()
        try validate(definition, revision: revision)
        try database.transaction { try writeDraft(definition, revision: revision) }
        changed()
    }

    private func writeDraft(_ definition: TriggerDefinition, revision: TriggerRevision) throws {
        let database = try readyDatabase()
        if try trigger(id: definition.id) == nil {
            let existing = try database.prepare("SELECT id FROM trigger_definition WHERE id=?")
            defer { existing.finalize() }
            _ = existing.bind(1, definition.id.uuidString)
            guard try !existing.step() else { throw StoreError.invalidRecord("deleted automation ID cannot be reused") }
            let count = try database.prepare("SELECT COUNT(*) FROM trigger_definition WHERE active_revision_id IS NOT NULL OR draft_revision_id IS NOT NULL")
            defer { count.finalize() }
            guard try count.step(), count.int(0) < 500 else { throw StoreError.invalidRecord("maximum 500 automations") }
        }
        // The definition owns its revisions. Insert it first so the revision's
        // foreign key remains valid for a brand-new draft.
        let definitionWrite = try database.prepare(Self.upsertDefinition)
        try definitionWrite
            .bind(1, definition.id.uuidString)
            .bind(2, definition.name)
            .bind(3, definition.enabled ? 1 : 0)
            .bind(4, definition.activeRevisionID?.uuidString)
            .bind(5, revision.id.uuidString)
            .bind(6, definition.updatedAt.timeIntervalSince1970)
            .bind(7, encoder.encode(definition))
            .run()

        // Revisions are approval records. Their payload is immutable once written; editing a
        // draft creates a new revision instead of changing what an earlier approval named.
        let revisionWrite = try database.prepare(Self.insertRevision)
        try revisionWrite
            .bind(1, revision.id.uuidString)
            .bind(2, revision.triggerID.uuidString)
            .bind(3, revision.sequence)
            .bind(4, revision.sourceInstallationID.uuidString)
            .bind(5, revision.projectID.uuidString)
            .bind(6, revision.eventKind)
            .bind(7, revision.createdAt.timeIntervalSince1970)
            .bind(8, encoder.encode(revision))
            .run()
    }

    func activate(triggerID: TriggerID, revisionID: TriggerRevisionID, at date: Date = Date()) throws {
        let database = try readyDatabase()
        guard var pair = try trigger(id: triggerID), pair.revision.id == revisionID else {
            throw StoreError.missing
        }
        if pair.definition.enabled, pair.definition.activeRevisionID == revisionID, pair.definition.draftRevisionID == nil { return }
        pair.definition.enabled = true
        pair.definition.activeRevisionID = revisionID
        pair.definition.draftRevisionID = nil
        pair.definition.updatedAt = date
        try database.transaction {
        let statement = try database.prepare(Self.updateActivation)
        try statement
            .bind(1, revisionID.uuidString)
            .bind(2, date.timeIntervalSince1970)
            .bind(3, encoder.encode(pair.definition))
            .bind(4, triggerID.uuidString)
            .run()
        try resetSchedule(triggerID, at: date)
        }
        republishDaemonConfiguration()
        changed()
    }

    func setEnabled(_ enabled: Bool, triggerID: TriggerID, expectedRevision: TriggerRevisionID? = nil, at date: Date = Date()) throws {
        guard var pair = try trigger(id: triggerID), expectedRevision == nil || expectedRevision == pair.revision.id else { throw StoreError.missing }
        if pair.definition.enabled == enabled { return }
        pair.definition.enabled = enabled
        pair.definition.updatedAt = date
        try readyDatabase().transaction {
        let statement = try readyDatabase().prepare(Self.updateDefinitionEnabled)
        try statement
            .bind(1, enabled ? 1 : 0)
            .bind(2, date.timeIntervalSince1970)
            .bind(3, encoder.encode(pair.definition))
            .bind(4, triggerID.uuidString)
            .run()
        try resetSchedule(triggerID, at: date)
        }
        republishDaemonConfiguration()
        changed()
    }

    func triggers() throws -> [(definition: TriggerDefinition, revision: TriggerRevision)] {
        try selectTriggerPairs(sql: Self.selectDefinitions)
    }

    /// Runtime definitions deliberately ignore pending drafts. Drafts are visible to the
    /// editor and MCP inspection tools, but cannot affect source events until host activation.
    func activeTriggers() throws -> [(definition: TriggerDefinition, revision: TriggerRevision)] {
        try selectTriggerPairs(sql: Self.selectActiveDefinitions)
    }

    private func selectTriggerPairs(
        sql: String
    ) throws -> [(definition: TriggerDefinition, revision: TriggerRevision)] {
        let statement = try readyDatabase().prepare(sql)
        defer { statement.finalize() }
        var result: [(TriggerDefinition, TriggerRevision)] = []
        while try statement.step() {
            guard let definitionData = statement.data(0), let revisionData = statement.data(1) else {
                throw StoreError.invalidRecord("trigger data")
            }
            result.append((
                try decoder.decode(TriggerDefinition.self, from: definitionData),
                try decoder.decode(TriggerRevision.self, from: revisionData)
            ))
        }
        return result
    }

    func trigger(id: TriggerID) throws -> (definition: TriggerDefinition, revision: TriggerRevision)? {
        let statement = try readyDatabase().prepare(Self.selectDefinition)
        defer { statement.finalize() }
        _ = statement.bind(1, id.uuidString)
        guard try statement.step(),
              let definitionData = statement.data(0),
              let revisionData = statement.data(1) else { return nil }
        return (
            try decoder.decode(TriggerDefinition.self, from: definitionData),
            try decoder.decode(TriggerRevision.self, from: revisionData)
        )
    }

    func revision(id: TriggerRevisionID) throws -> TriggerRevision? {
        let statement = try readyDatabase().prepare(Self.selectRevision)
        defer { statement.finalize() }
        _ = statement.bind(1, id.uuidString)
        guard try statement.step(), let data = statement.data(0) else { return nil }
        return try decoder.decode(TriggerRevision.self, from: data)
    }

    // MARK: Events and runs

    @discardableResult
    func accept(_ event: TriggerEvent) throws -> Bool {
        let database = try readyDatabase()
        try validate(event)
        let statement = try database.prepare(Self.insertEvent)
        do {
            try statement
                .bind(1, event.storageKey)
                .bind(2, event.sourceInstallationID.uuidString)
                .bind(3, event.kind)
                .bind(4, event.receivedAt.timeIntervalSince1970)
                .bind(5, encoder.encode(event))
                .run()
            changed()
            return true
        } catch let failure as SQLiteDatabase.Failure where failure.isConstraintViolation {
            return false
        }
    }

    /// Commits the source event and every run derived from the active revision in one
    /// transaction. If the helper redelivers an event after a crash, the event key prevents a
    /// second set of runs; if the process dies before commit, neither half becomes durable.
    @discardableResult
    func accept(_ event: TriggerEvent, creating runs: [TriggerRun]) throws -> Bool {
        let database = try readyDatabase()
        try validate(event)
        guard runs.allSatisfy({ $0.eventKey == event.storageKey }) else {
            throw StoreError.invalidRecord("run event key")
        }
        try runs.forEach(validate)
        do {
            try database.transaction {
                let eventWrite = try database.prepare(Self.insertEvent)
                try eventWrite
                    .bind(1, event.storageKey)
                    .bind(2, event.sourceInstallationID.uuidString)
                    .bind(3, event.kind)
                    .bind(4, event.receivedAt.timeIntervalSince1970)
                    .bind(5, encoder.encode(event))
                    .run()

                for run in runs {
                    let runWrite = try database.prepare(Self.insertRun)
                    try runWrite
                        .bind(1, run.id.uuidString)
                        .bind(2, run.triggerID.uuidString)
                        .bind(3, run.triggerRevisionID.uuidString)
                        .bind(4, run.eventKey)
                        .bind(5, run.state.rawValue)
                        .bind(6, run.sessionID?.uuidString)
                        .bind(7, run.queuedAt.timeIntervalSince1970)
                        .bind(8, run.settledAt?.timeIntervalSince1970)
                        .bind(9, encoder.encode(run))
                        .run()
                }
            }
            changed()
            return true
        } catch let failure as SQLiteDatabase.Failure where failure.isConstraintViolation {
            return false
        }
    }

    @discardableResult
    func createRun(_ run: TriggerRun) throws -> Bool {
        try validate(run)
        let statement = try readyDatabase().prepare(Self.insertRun)
        do {
            try statement
                .bind(1, run.id.uuidString)
                .bind(2, run.triggerID.uuidString)
                .bind(3, run.triggerRevisionID.uuidString)
                .bind(4, run.eventKey)
                .bind(5, run.state.rawValue)
                .bind(6, run.sessionID?.uuidString)
                .bind(7, run.queuedAt.timeIntervalSince1970)
                .bind(8, run.settledAt?.timeIntervalSince1970)
                .bind(9, encoder.encode(run))
                .run()
            changed()
            return true
        } catch let failure as SQLiteDatabase.Failure where failure.isConstraintViolation {
            return false
        }
    }

    func updateRun(_ run: TriggerRun) throws {
        try validate(run)
        let statement = try readyDatabase().prepare(Self.updateRun)
        try statement
            .bind(1, run.state.rawValue)
            .bind(2, run.sessionID?.uuidString)
            .bind(3, run.settledAt?.timeIntervalSince1970)
            .bind(4, encoder.encode(run))
            .bind(5, run.id.uuidString)
            .run()
        changed()
    }

    func runs(triggerID: TriggerID? = nil, limit: Int = 1_000) throws -> [TriggerRun] {
        let boundedLimit = max(1, min(limit, 1_000))
        let sql = triggerID == nil ? Self.selectRuns : Self.selectRunsForTrigger
        let statement = try readyDatabase().prepare(sql)
        defer { statement.finalize() }
        if let triggerID {
            _ = statement.bind(1, triggerID.uuidString).bind(2, boundedLimit)
        } else {
            _ = statement.bind(1, boundedLimit)
        }
        var result: [TriggerRun] = []
        while try statement.step() {
            guard let data = statement.data(0) else { throw StoreError.invalidRecord("run data") }
            result.append(try decoder.decode(TriggerRun.self, from: data))
        }
        return result
    }

    struct RunPage: Encodable, Sendable { let items: [TriggerRun]; let next: Int64? }
    func runPage(triggerID: TriggerID? = nil, before: Int64? = nil) throws -> RunPage {
        let sql = "SELECT rowid,data FROM trigger_run WHERE rowid<?"
            + (triggerID == nil ? "" : " AND trigger_id=?") + " ORDER BY rowid DESC LIMIT 26"
        let statement = try readyDatabase().prepare(sql)
        defer { statement.finalize() }
        _ = statement.bind(1, before ?? Int64.max)
        if let triggerID { _ = statement.bind(2, triggerID.uuidString) }
        var items: [TriggerRun] = []
        var last: Int64?
        while try statement.step() {
            if items.count == 25 { return RunPage(items: items, next: last) }
            guard let data = statement.data(1) else { throw StoreError.invalidRecord("run data") }
            items.append(try decoder.decode(TriggerRun.self, from: data))
            last = Int64(statement.int(0))
        }
        return RunPage(items: items, next: nil)
    }

    func activeRunCount(triggerID: TriggerID) throws -> Int {
        let statement = try readyDatabase().prepare(Self.selectActiveRunCount)
        defer { statement.finalize() }
        _ = statement.bind(1, triggerID.uuidString)
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    func run(id: TriggerRunID) throws -> TriggerRun? {
        let statement = try readyDatabase().prepare(Self.selectRun)
        defer { statement.finalize() }
        _ = statement.bind(1, id.uuidString)
        guard try statement.step(), let data = statement.data(0) else { return nil }
        return try decoder.decode(TriggerRun.self, from: data)
    }

    func run(sessionID: SessionID) throws -> TriggerRun? {
        let statement = try readyDatabase().prepare(Self.selectRunForSession)
        defer { statement.finalize() }
        _ = statement.bind(1, sessionID.uuidString)
        guard try statement.step(), let data = statement.data(0) else { return nil }
        return try decoder.decode(TriggerRun.self, from: data)
    }

    func event(key: String) throws -> TriggerEvent? {
        let statement = try readyDatabase().prepare(Self.selectEvent)
        defer { statement.finalize() }
        _ = statement.bind(1, key)
        guard try statement.step(), let data = statement.data(0) else { return nil }
        return try decoder.decode(TriggerEvent.self, from: data)
    }

    /// Runs committed before a crash but not yet handed to a session. Bounded at the storage
    /// edge so a large offline backlog is drained over several turns rather than decoded on the
    /// main actor in one launch-sized burst.
    func receivedDispatches(limit: Int = 100) throws -> [TriggerDispatch] {
        let statement = try readyDatabase().prepare(Self.selectReceivedDispatches)
        defer { statement.finalize() }
        _ = statement.bind(1, max(1, min(limit, 100)))
        var result: [TriggerDispatch] = []
        while try statement.step() {
            guard let runData = statement.data(0),
                  let revisionData = statement.data(1),
                  let eventData = statement.data(2) else {
                throw StoreError.invalidRecord("dispatch data")
            }
            result.append(TriggerDispatch(
                run: try decoder.decode(TriggerRun.self, from: runData),
                revision: try decoder.decode(TriggerRevision.self, from: revisionData),
                event: try decoder.decode(TriggerEvent.self, from: eventData)
            ))
        }
        return result
    }

    /// Runs held before their first launch. A run that already owns a session belongs to the
    /// assessment/fix lifecycle and must never be recycled through the opening dispatch.
    func queuedDispatches(limit: Int = 100) throws -> [TriggerDispatch] {
        let statement = try readyDatabase().prepare(Self.selectQueuedDispatches)
        defer { statement.finalize() }
        _ = statement.bind(1, max(1, min(limit, 100)))
        var result: [TriggerDispatch] = []
        while try statement.step() {
            guard let runData = statement.data(0),
                  let revisionData = statement.data(1),
                  let eventData = statement.data(2) else {
                throw StoreError.invalidRecord("queued dispatch data")
            }
            let run = try decoder.decode(TriggerRun.self, from: runData)
            guard run.startedAt == nil, run.sessionID == nil else { continue }
            result.append(TriggerDispatch(
                run: run,
                revision: try decoder.decode(TriggerRevision.self, from: revisionData),
                event: try decoder.decode(TriggerEvent.self, from: eventData)
            ))
        }
        return result
    }

    /// Authorized second stages which were durably recorded before the assessment runtime
    /// finished. Unlike an opening queue entry, these already own a session and must resume at
    /// the fix boundary rather than being sent through assessment again after a relaunch.
    func fixStageDispatches(limit: Int = 100) throws -> [TriggerDispatch] {
        let statement = try readyDatabase().prepare(Self.selectFixStageDispatches)
        defer { statement.finalize() }
        _ = statement.bind(1, max(1, min(limit, 100)))
        var result: [TriggerDispatch] = []
        while try statement.step() {
            guard let runData = statement.data(0),
                  let revisionData = statement.data(1),
                  let eventData = statement.data(2) else {
                throw StoreError.invalidRecord("fix-stage dispatch data")
            }
            result.append(TriggerDispatch(
                run: try decoder.decode(TriggerRun.self, from: runData),
                revision: try decoder.decode(TriggerRevision.self, from: revisionData),
                event: try decoder.decode(TriggerEvent.self, from: eventData)
            ))
        }
        return result
    }

    /// Native agent processes do not survive an app crash. Keep their durable session and
    /// receipt, but settle the in-flight stage explicitly so it cannot consume concurrency
    /// forever or be replayed with a prompt whose delivery boundary is no longer knowable.
    func interruptedRuns(limit: Int = 100) throws -> [TriggerRun] {
        let statement = try readyDatabase().prepare(Self.selectInterruptedRuns)
        defer { statement.finalize() }
        _ = statement.bind(1, max(1, min(limit, 100)))
        var result: [TriggerRun] = []
        while try statement.step() {
            guard let data = statement.data(0) else {
                throw StoreError.invalidRecord("interrupted run data")
            }
            result.append(try decoder.decode(TriggerRun.self, from: data))
        }
        return result
    }

    // MARK: Validation and storage

    private func validate(_ source: TriggerSourceInstallation) throws {
        guard !source.sourceType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !source.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.displayName.utf8.count <= 160,
              source.configuration.count <= 32,
              source.configuration.allSatisfy({ key, value in
                  !key.isEmpty && key.utf8.count <= 256 && Self.isBounded(value)
              }),
              (source.credentialReference?.utf8.count ?? 0) <= 256,
              (source.boundedDiagnostic?.utf8.count ?? 0) <= 1_024 else {
            throw StoreError.invalidRecord("source fields exceed their bounds")
        }
    }

    private func validate(_ definition: TriggerDefinition, revision: TriggerRevision) throws {
        try revision.automation?.schedule?.validate()
        guard definition.id == revision.triggerID,
              definition.draftRevisionID == revision.id,
              revision.sequence > 0,
              !definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              definition.name.utf8.count <= 160,
              !revision.eventKind.isEmpty,
              revision.eventKind.utf8.count <= 256,
              revision.instructions.utf8.count <= 32_768,
              (revision.accountHandleName?.utf8.count ?? 0) <= 256,
              (revision.model?.utf8.count ?? 0) <= 256,
              (revision.reasoningEffort?.utf8.count ?? 0) <= 256,
              (1 ... 8).contains(revision.limits.maximumConcurrentRuns),
              (1 ... 1_440).contains(revision.limits.maximumRuntimeMinutes),
              revision.conditions.count <= 32,
              revision.conditions.allSatisfy({ condition in
                  !condition.attribute.isEmpty
                      && condition.attribute.utf8.count <= 256
                      && (condition.comparison == .exists
                          ? condition.value == nil
                          : condition.value.map(Self.isBounded) == true)
              }) else {
            throw StoreError.invalidRecord("definition or revision fields exceed their bounds")
        }
    }

    private func validate(_ event: TriggerEvent) throws {
        guard !event.externalID.isEmpty,
              event.externalID.utf8.count <= 1_024,
              !event.revision.isEmpty,
              event.revision.utf8.count <= 256,
              !event.kind.isEmpty,
              event.kind.utf8.count <= 256,
              event.title.utf8.count <= 1_024,
              event.attributes.count <= 128,
              event.resources.count <= 32,
              event.attributes.allSatisfy({ key, value in
                  !key.isEmpty && key.utf8.count <= 256 && Self.isBounded(value)
              }),
              event.resources.allSatisfy({ resource in
                  !resource.kind.isEmpty
                      && resource.kind.utf8.count <= 256
                      && !resource.identifier.isEmpty
                      && resource.identifier.utf8.count <= 1_024
                      && resource.displayName.utf8.count <= 1_024
                      && (resource.byteCount ?? 0) >= 0
              }),
              (event.deepLink?.absoluteString.utf8.count ?? 0) <= 4_096,
              event.deepLink?.user == nil,
              event.deepLink?.password == nil else {
            throw StoreError.invalidRecord("event fields exceed their bounds")
        }
    }

    private func validate(_ run: TriggerRun) throws {
        guard (run.boundedDiagnostic?.utf8.count ?? 0) <= 1_024,
              (run.result?.summary.utf8.count ?? 0) <= 4_096,
              (run.result?.changedPaths.count ?? 0) <= 256,
              (run.result?.tests.count ?? 0) <= 128,
              run.result?.changedPaths.allSatisfy({ $0.utf8.count <= 1_024 }) != false,
              run.result?.tests.allSatisfy({ $0.utf8.count <= 1_024 }) != false else {
            throw StoreError.invalidRecord("run result fields exceed their bounds")
        }
    }

    private static func isBounded(_ value: TriggerAttributeValue) -> Bool {
        switch value {
        case .string(let text): text.utf8.count <= 4_096
        case .integer, .decimal, .boolean, .timestamp: true
        }
    }

    private func readyDatabase() throws -> SQLiteDatabase {
        if let openingError { throw openingError }
        guard let database else { throw StoreError.missing }
        return database
    }

    private func changed() {
        NotificationCenter.default.post(name: .triggersDidChange, object: nil)
    }

    private static func defaultURL() throws -> URL {
        let fileManager = FileManager.default
        let directory: URL
        if StateManager.isHostedTest {
            directory = StateManager.hostedTestDirectory(fileManager: fileManager)
        } else {
            let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            directory = root.appendingPathComponent("Threading", isDirectory: true)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("triggers.db")
    }

    private static let version1 = """
        CREATE TABLE trigger_source (
            id TEXT PRIMARY KEY,
            source_type TEXT NOT NULL,
            enabled INTEGER NOT NULL,
            health TEXT NOT NULL,
            updated_at REAL NOT NULL,
            data BLOB NOT NULL
        );
        CREATE INDEX trigger_source_enabled ON trigger_source(enabled, source_type);

        CREATE TABLE trigger_definition (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            enabled INTEGER NOT NULL,
            active_revision_id TEXT,
            draft_revision_id TEXT,
            updated_at REAL NOT NULL,
            data BLOB NOT NULL
        );
        CREATE INDEX trigger_definition_enabled ON trigger_definition(enabled, updated_at DESC);

        CREATE TABLE trigger_revision (
            id TEXT PRIMARY KEY,
            trigger_id TEXT NOT NULL REFERENCES trigger_definition(id) ON DELETE CASCADE,
            sequence INTEGER NOT NULL,
            source_installation_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            event_kind TEXT NOT NULL,
            created_at REAL NOT NULL,
            data BLOB NOT NULL,
            UNIQUE(trigger_id, sequence)
        );
        CREATE INDEX trigger_revision_source_kind
          ON trigger_revision(source_installation_id, event_kind);

        CREATE TABLE trigger_event (
            event_key TEXT PRIMARY KEY,
            source_installation_id TEXT NOT NULL,
            event_kind TEXT NOT NULL,
            received_at REAL NOT NULL,
            data BLOB NOT NULL
        );
        CREATE INDEX trigger_event_received ON trigger_event(received_at DESC);

        CREATE TABLE trigger_run (
            id TEXT PRIMARY KEY,
            trigger_id TEXT NOT NULL,
            trigger_revision_id TEXT NOT NULL,
            event_key TEXT NOT NULL,
            state TEXT NOT NULL,
            queued_at REAL NOT NULL,
            settled_at REAL,
            data BLOB NOT NULL,
            UNIQUE(trigger_id, trigger_revision_id, event_key)
        );
        CREATE INDEX trigger_run_state ON trigger_run(state, queued_at);
        CREATE INDEX trigger_run_recent ON trigger_run(queued_at DESC);
        """

    private static let version2 = """
        ALTER TABLE trigger_run ADD COLUMN session_id TEXT;
        CREATE UNIQUE INDEX trigger_run_session
          ON trigger_run(session_id) WHERE session_id IS NOT NULL;
        """

    private static let upsertSource = """
        INSERT INTO trigger_source(id, source_type, enabled, health, updated_at, data)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          source_type = excluded.source_type,
          enabled = excluded.enabled,
          health = excluded.health,
          updated_at = excluded.updated_at,
          data = excluded.data
        """
    private static let selectSources = "SELECT data FROM trigger_source ORDER BY updated_at DESC"
    private static let selectSource = "SELECT data FROM trigger_source WHERE id = ?"
    private static let upsertDefinition = """
        INSERT INTO trigger_definition(
          id, name, enabled, active_revision_id, draft_revision_id, updated_at, data
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          name = excluded.name,
          enabled = excluded.enabled,
          active_revision_id = excluded.active_revision_id,
          draft_revision_id = excluded.draft_revision_id,
          updated_at = excluded.updated_at,
          data = excluded.data
        """
    private static let insertRevision = """
        INSERT INTO trigger_revision(
          id, trigger_id, sequence, source_installation_id, project_id, event_kind, created_at, data
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
    private static let selectDefinitions = """
        SELECT definitions.data, revisions.data
        FROM trigger_definition definitions
        JOIN trigger_revision revisions
          ON revisions.id = COALESCE(definitions.draft_revision_id, definitions.active_revision_id)
        ORDER BY definitions.updated_at DESC
        """
    private static let selectActiveDefinitions = """
        SELECT definitions.data, revisions.data
        FROM trigger_definition definitions
        JOIN trigger_revision revisions ON revisions.id = definitions.active_revision_id
        WHERE definitions.enabled = 1
        ORDER BY definitions.updated_at DESC
        """
    private static let selectDefinition = selectDefinitions.replacingOccurrences(
        of: "ORDER BY definitions.updated_at DESC",
        with: "WHERE definitions.id = ?"
    )
    private static let selectRevision = "SELECT data FROM trigger_revision WHERE id = ?"
    private static let updateActivation = """
        UPDATE trigger_definition
        SET enabled = 1, active_revision_id = ?, draft_revision_id = NULL, updated_at = ?, data = ?
        WHERE id = ?
        """
    private static let updateDefinitionEnabled = """
        UPDATE trigger_definition SET enabled = ?, updated_at = ?, data = ? WHERE id = ?
        """
    private static let insertEvent = """
        INSERT INTO trigger_event(event_key, source_installation_id, event_kind, received_at, data)
        VALUES (?, ?, ?, ?, ?)
        """
    private static let insertRun = """
        INSERT INTO trigger_run(
          id, trigger_id, trigger_revision_id, event_key, state, session_id, queued_at, settled_at, data
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
    private static let updateRun = """
        UPDATE trigger_run SET state = ?, session_id = ?, settled_at = ?, data = ? WHERE id = ?
        """
    private static let selectRuns = "SELECT data FROM trigger_run ORDER BY queued_at DESC LIMIT ?"
    private static let selectRunsForTrigger = """
        SELECT data FROM trigger_run WHERE trigger_id = ? ORDER BY queued_at DESC LIMIT ?
        """
    private static let selectRun = "SELECT data FROM trigger_run WHERE id = ?"
    private static let selectRunForSession = "SELECT data FROM trigger_run WHERE session_id = ?"
    private static let selectEvent = "SELECT data FROM trigger_event WHERE event_key = ?"
    private static let selectReceivedDispatches = """
        SELECT runs.data, revisions.data, events.data
        FROM trigger_run runs
        JOIN trigger_revision revisions ON revisions.id = runs.trigger_revision_id
        JOIN trigger_event events ON events.event_key = runs.event_key
        WHERE runs.state = 'received'
        ORDER BY runs.queued_at ASC
        LIMIT ?
        """
    private static let selectQueuedDispatches = """
        SELECT runs.data, revisions.data, events.data
        FROM trigger_run runs
        JOIN trigger_revision revisions ON revisions.id = runs.trigger_revision_id
        JOIN trigger_event events ON events.event_key = runs.event_key
        WHERE runs.state = 'queued'
        ORDER BY runs.queued_at ASC
        LIMIT ?
        """
    private static let selectFixStageDispatches = """
        SELECT runs.data, revisions.data, events.data
        FROM trigger_run runs
        JOIN trigger_revision revisions ON revisions.id = runs.trigger_revision_id
        JOIN trigger_event events ON events.event_key = runs.event_key
        WHERE runs.state = 'fixQueued'
           OR (runs.state = 'queued' AND runs.session_id IS NOT NULL)
        ORDER BY runs.queued_at ASC
        LIMIT ?
        """
    private static let selectDueAutomations =
        "SELECT id,due FROM automation_due WHERE due<=? ORDER BY due,id LIMIT 32"
    private static let deleteDefinitionPointers = """
        UPDATE trigger_definition
        SET enabled = 0, active_revision_id = NULL, draft_revision_id = NULL, updated_at = ?, data = ?
        WHERE id = ?
        """
    /// A moment more than this late is missed rather than on time.
    static let missedScheduleGrace: TimeInterval = 90
    /// A rule that could not be admitted is retried after this, not on every sweep.
    static let failedAdmissionRetry: TimeInterval = 300
    private static let selectInterruptedRuns = """
        SELECT data FROM trigger_run
        WHERE state IN ('assessing', 'fixing', 'running', 'finishing') OR (state='received' AND session_id IS NOT NULL)
        ORDER BY queued_at ASC
        LIMIT ?
        """
    private static let selectActiveRunCount = """
        SELECT COUNT(*) FROM trigger_run
        WHERE trigger_id = ?
          AND (
            state IN ('received', 'assessing', 'fixQueued', 'fixing', 'running', 'finishing')
            OR (state = 'queued' AND session_id IS NOT NULL)
          )
        """
}

// MARK: Shared human / agent automation operations
extension TriggerStore {
    func configureAutomation(_ config: AutomationConfiguration, id: TriggerID,
                             expectedRevision: TriggerRevisionID?, proposedBy: SessionID?,
                             now: Date = Date()) throws -> TriggerRevision {
        let existing = try trigger(id: id)
        guard existing?.revision.id == expectedRevision,
              !config.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              config.agent.supportsNativeUI, config.agent.supportsPermissionModes else {
            throw StoreError.invalidRecord("stale revision or unsupported configuration")
        }
        if config.options.schedule == nil {
            guard let sourceID = config.sourceID, try source(id: sourceID) != nil,
                  let kind = config.eventKind, !kind.isEmpty else {
                throw StoreError.invalidRecord("event source and kind are required")
            }
        } else if config.sourceID != nil || !config.conditions.isEmpty {
            throw StoreError.invalidRecord("choose either a schedule or an event source")
        }
        let revisionID = TriggerRevisionID()
        let definition = TriggerDefinition(id: id, name: config.name, enabled: false,
            activeRevisionID: existing?.definition.activeRevisionID, draftRevisionID: revisionID,
            createdAt: existing?.definition.createdAt ?? now, updatedAt: now)
        var revision = TriggerRevision(id: revisionID, triggerID: id,
            sequence: (existing?.revision.sequence ?? 0) + 1,
            sourceInstallationID: config.sourceID ?? TriggerSourceInstallationID(id.rawValue),
            eventKind: config.options.schedule == nil ? config.eventKind! : "schedule.due",
            conditions: config.conditions, projectID: config.projectID, instructions: config.instructions,
            agentKind: config.agent, accountHandleName: config.account, model: config.model,
            reasoningEffort: config.reasoningEffort, executionMode: config.executionMode,
            checkoutPolicy: config.checkoutPolicy, limits: .init(maximumConcurrentRuns:
                config.options.schedule == nil ? (existing?.revision.limits.maximumConcurrentRuns ?? 1) : 1,
                maximumRuntimeMinutes: config.maximumRuntimeMinutes),
            quietHours: config.options.schedule == nil ? existing?.revision.quietHours : nil,
            notifications: existing?.revision.notifications ?? .standard,
            allowSourceResources: existing?.revision.allowSourceResources ?? false,
            proposedBySessionID: proposedBy, createdAt: now)
        revision.automation = config.options
        try validate(definition, revision: revision)
        let database = try readyDatabase()
        // The draft and the schedule it replaces commit together: a caller never sees a saved
        // revision reported as a failure, which an agent would answer by saving it again.
        try database.transaction {
            try writeDraft(definition, revision: revision)
            try resetSchedule(id, at: now)
        }
        changed()
        republishDaemonConfiguration()
        return revision
    }

    func removeAutomation(_ id: TriggerID, expectedRevision: TriggerRevisionID, at date: Date = Date()) throws {
        let database = try readyDatabase()
        try database.transaction {
            guard let pair = try trigger(id: id), pair.revision.id == expectedRevision,
                  try activeRunCount(triggerID: id) == 0 else {
                throw StoreError.invalidRecord("stale revision or a run is still active")
            }
            // Retain revisions and run history. A deleted automation is a paused definition whose
            // editable pointers are removed; history continues to resolve its frozen revision.
            var deleted = pair.definition
            deleted.enabled = false; deleted.activeRevisionID = nil; deleted.draftRevisionID = nil
            deleted.updatedAt = date
            let statement = try database.prepare(Self.deleteDefinitionPointers)
            try statement
                .bind(1, date.timeIntervalSince1970)
                .bind(2, encoder.encode(deleted))
                .bind(3, id.uuidString)
                .run()
            try resetSchedule(id, at: date)
        }
        republishDaemonConfiguration()
        changed()
    }

    /// The daemon's file is a projection of this database, rewritten after every committed
    /// change and at launch. Failing to write it is logged, never thrown: a thrown error would
    /// report a committed change as failed — and drop the dispatches a sweep just reserved.
    private func republishDaemonConfiguration() {
        guard publishesDaemonConfiguration else { return }
        do {
            let shouldRun = try publishDaemonConfiguration()
            Task { @MainActor in TriggerDaemonRegistrationCoordinator.shared.reconcile(shouldRun: shouldRun) }
        } catch {
            ThreadingLogger.app.error(
                "Trigger daemon configuration was not published: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    func publishDaemonConfiguration() throws -> Bool {
        guard publishesDaemonConfiguration else { return false }
        let statement = try readyDatabase().prepare("SELECT due FROM automation_due ORDER BY due LIMIT 1")
        defer { statement.finalize() }
        let next = try statement.step() ? Date(timeIntervalSince1970: statement.double(0)) : nil
        return try TriggerDaemonConfigurationStore.publish(sources(), nextScheduleAt: next)
    }

    func nextAutomationDate(_ id: TriggerID) throws -> Date? {
        let statement = try readyDatabase().prepare("SELECT due FROM automation_due WHERE id=?")
        defer { statement.finalize() }
        _ = statement.bind(1, id.uuidString)
        guard try statement.step() else { return nil }
        return Date(timeIntervalSince1970: statement.double(0))
    }

    func resetSchedule(_ id: TriggerID, at now: Date) throws {
        let database = try readyDatabase()
        let deletion = try database.prepare("DELETE FROM automation_due WHERE id=?")
        try deletion.bind(1, id.uuidString).run()
        if let pair = try trigger(id: id), pair.definition.enabled,
           pair.definition.activeRevisionID == pair.revision.id,
           let schedule = pair.revision.automation?.schedule {
            let insertion = try database.prepare("INSERT INTO automation_due(id,due) VALUES(?,?)")
            try insertion.bind(1, id.uuidString).bind(2, schedule.next(after: now).timeIntervalSince1970).run()
        }
    }

    /// At most 32 due rules per sweep. Each commits its reservation, occurrence identity and
    /// next deadline in its own transaction, so one rule that cannot be admitted is retried
    /// later rather than failing the sweep that carries every other schedule.
    func scheduledDispatches(now: Date = Date()) throws -> [TriggerDispatch] {
        let database = try readyDatabase()
        let statement = try database.prepare(Self.selectDueAutomations)
        var due: [(String, Date)] = []
        do {
            defer { statement.finalize() }
            _ = statement.bind(1, now.timeIntervalSince1970)
            while try statement.step() {
                guard let raw = statement.text(0) else { continue }
                due.append((raw, Date(timeIntervalSince1970: statement.double(1))))
            }
        }
        guard !due.isEmpty else { return [] }
        var dispatches: [TriggerDispatch] = []
        for (raw, moment) in due {
            do {
                let dispatch = try database.transaction { try admitScheduled(raw, moment: moment, now: now) }
                if let dispatch, dispatch.run.state == .received { dispatches.append(dispatch) }
            } catch {
                ThreadingLogger.app.error(
                    "Scheduled automation could not be admitted: \(error.localizedDescription, privacy: .private)"
                )
                let retry = now.addingTimeInterval(Self.failedAdmissionRetry).timeIntervalSince1970
                _ = try? database.transaction {
                    try database.prepare("UPDATE automation_due SET due=? WHERE id=?")
                        .bind(1, retry).bind(2, raw).run()
                }
            }
        }
        republishDaemonConfiguration()
        return dispatches
    }

    private func admitScheduled(_ raw: String, moment: Date, now: Date) throws -> TriggerDispatch? {
        guard let id = TriggerID(uuidString: raw) else {
            try readyDatabase().prepare("DELETE FROM automation_due WHERE id=?").bind(1, raw).run()
            return nil
        }
        guard let pair = try trigger(id: id), pair.definition.enabled,
              pair.definition.activeRevisionID == pair.revision.id,
              let options = pair.revision.automation, let schedule = options.schedule else {
            try resetSchedule(id, at: now)
            return nil
        }
        let late = now.timeIntervalSince(moment) > Self.missedScheduleGrace
        let missed = late && options.missedRunPolicy != .latest
        // A catch-up stands for the most recent occurrence it replaces, not the oldest it missed.
        let occurrence = late && !missed ? (try schedule.latest(onOrBefore: now) ?? moment) : moment
        let key = "scheduled:\(pair.revision.id.uuidString):\(Int64(moment.timeIntervalSince1970))"
        let dispatch = try reserveAutomation(pair, key: key, due: occurrence, now: now, missed: missed)
        try resetSchedule(id, at: now)
        return dispatch
    }

    func runAutomationNow(_ id: TriggerID, expectedRevision: TriggerRevisionID, requestKey: String,
                          now: Date = Date()) throws -> TriggerDispatch {
        guard !requestKey.isEmpty, requestKey.utf8.count <= 160,
              let pair = try trigger(id: id), pair.revision.id == expectedRevision else {
            throw StoreError.invalidRecord("current revision and a bounded request key are required")
        }
        return try readyDatabase().transaction {
            try reserveAutomation(pair, key: "manual:" + requestKey, due: now, now: now, missed: false, manual: true)
        }
    }

    private func reserveAutomation(_ pair: (definition: TriggerDefinition, revision: TriggerRevision),
                                   key: String, due: Date, now: Date, missed: Bool, manual: Bool = false) throws -> TriggerDispatch {
        let database = try readyDatabase()
        let event = TriggerEvent(sourceInstallationID: pair.revision.sourceInstallationID,
            externalID: pair.definition.id.uuidString + ":" + key, revision: pair.revision.id.uuidString,
            kind: pair.revision.eventKind, occurredAt: due, receivedAt: now,
            title: pair.definition.name, attributes: [:], deepLink: nil, resources: [])
        let existing = try database.prepare("SELECT data FROM trigger_run WHERE trigger_id=? AND trigger_revision_id=? AND event_key=?")
        defer { existing.finalize() }
        _ = existing.bind(1, pair.definition.id.uuidString).bind(2, pair.revision.id.uuidString).bind(3, event.storageKey)
        if try existing.step(), let data = existing.data(0) {
            return TriggerDispatch(run: try decoder.decode(TriggerRun.self, from: data), revision: pair.revision, event: event)
        }
        let busy = try activeRunCount(triggerID: pair.definition.id) > 0
        let suppressed = missed || busy
        var run = TriggerRun(id: TriggerRunID(), triggerID: pair.definition.id,
            triggerRevisionID: pair.revision.id, eventKey: event.storageKey,
            state: suppressed ? .suppressed : .received, queuedAt: now, startedAt: nil,
            settledAt: suppressed ? now : nil, sessionID: nil, managedWorkspaceID: nil,
            holdReason: busy ? .concurrencyLimit : nil, result: nil,
            boundedDiagnostic: missed ? "Missed schedule; skipped." : (busy ? "Previous run is still active; skipped." : nil))
        run.initiatedManually = manual
        let eventWrite = try database.prepare(Self.insertEvent)
        try eventWrite.bind(1, event.storageKey).bind(2, event.sourceInstallationID.uuidString)
            .bind(3, event.kind).bind(4, now.timeIntervalSince1970).bind(5, encoder.encode(event)).run()
        _ = try createRun(run)
        return TriggerDispatch(run: run, revision: pair.revision, event: event)
    }

    /// Reserves the session once, and checks pause/edit again at dispatch. Repeated timer,
    /// notification and run-now delivery cannot create duplicate sessions.
    func claimDispatch(_ runID: TriggerRunID) throws -> TriggerRun? {
        try readyDatabase().transaction {
        guard var run = try run(id: runID), run.state == .received, run.sessionID == nil else { return nil }
        let manual = run.initiatedManually == true
        let pair = try trigger(id: run.triggerID)
        let authorized = manual
            ? pair?.revision.id == run.triggerRevisionID
            : pair?.definition.enabled == true && pair?.definition.activeRevisionID == run.triggerRevisionID && pair?.definition.draftRevisionID == nil
        guard authorized else {
            run.state = .suppressed; run.settledAt = Date()
            run.boundedDiagnostic = "Automation was paused, edited or removed before dispatch."
            try updateRun(run)
            return nil
        }
        run.sessionID = SessionID()
        try updateRun(run)
        return run
        }
    }
}
