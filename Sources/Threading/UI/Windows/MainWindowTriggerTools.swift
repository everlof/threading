import AppKit

private struct TriggerListPayload: Encodable {
    struct Item: Encodable {
        let id: String
        let name: String
        let enabled: Bool
        let revisionID: String
        let sourceID: String
        let eventKind: String
        let projectID: String
        let executionMode: String
        let checkoutPolicy: String

        private enum CodingKeys: String, CodingKey {
            case id, name, enabled
            case revisionID = "revision_id"
            case sourceID = "source_id"
            case eventKind = "event_kind"
            case projectID = "project_id"
            case executionMode = "execution_mode"
            case checkoutPolicy = "checkout_policy"
        }
    }

    let triggers: [Item]
}

private struct TriggerSourceListPayload: Encodable {
    struct Item: Encodable {
        let id: String
        let type: String
        let name: String
        let enabled: Bool
        let health: String
    }
    let sources: [Item]
    let backgroundListener: String

    private enum CodingKeys: String, CodingKey {
        case sources
        case backgroundListener = "background_listener"
    }
}

private struct TriggerRunListPayload: Encodable {
    struct Item: Encodable {
        let id: String
        let triggerID: String
        let state: String
        let queuedAt: Date
        let sessionID: String?
        let summary: String?

        private enum CodingKeys: String, CodingKey {
            case id, state, summary
            case triggerID = "trigger_id"
            case queuedAt = "queued_at"
            case sessionID = "session_id"
        }
    }
    let runs: [Item]
}

@MainActor
enum TriggerToolActions {
    static func listTriggerSources(
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        Task { @MainActor in
            do {
                let sources = try await TriggerStore.shared.sources()
                let daemonStatusTask = Task.detached(priority: .utility) {
                    try TriggerDaemonStatusStore.statuses()
                }
                let registrationTask = Task.detached(priority: .utility) {
                    TriggerDaemonRegistrationCoordinator.currentStatus()
                }
                let daemonStatuses = (try? await daemonStatusTask.value) ?? [:]
                let payload = TriggerSourceListPayload(
                    sources: sources.map { source in
                        .init(
                            id: source.id.uuidString,
                            type: source.sourceType,
                            name: source.displayName,
                            enabled: source.enabled,
                            health: (daemonStatuses[source.id].flatMap { status in
                                status.lastCheckedAt >= source.updatedAt ? status.health : nil
                            } ?? source.health).rawValue
                        )
                    },
                    backgroundListener: await registrationTask.value.rawValue
                )
                completion(Self.triggerJSON(payload))
            } catch {
                completion(.failure(error.localizedDescription))
            }
        }
    }

    static func listTriggers(
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        Task { @MainActor in
            do {
                let pairs = try await TriggerStore.shared.triggers()
                let payload = TriggerListPayload(triggers: pairs.map { pair in
                    .init(
                        id: pair.definition.id.uuidString,
                        name: pair.definition.name,
                        enabled: pair.definition.enabled,
                        revisionID: pair.revision.id.uuidString,
                        sourceID: pair.revision.sourceInstallationID.uuidString,
                        eventKind: pair.revision.eventKind,
                        projectID: pair.revision.projectID.uuidString,
                        executionMode: pair.revision.executionMode.rawValue,
                        checkoutPolicy: pair.revision.checkoutPolicy.rawValue
                    )
                })
                completion(Self.triggerJSON(payload))
            } catch {
                completion(.failure(error.localizedDescription))
            }
        }
    }

    static func listTriggerRuns(
        _ arguments: TriggerReferenceArguments,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let triggerID: TriggerID?
        if let raw = arguments.triggerID {
            guard let parsed = TriggerID(uuidString: raw) else {
                completion(.failure("trigger_id is not a Threading trigger id."))
                return
            }
            triggerID = parsed
        } else {
            triggerID = nil
        }
        Task { @MainActor in
            do {
                let runs = try await TriggerStore.shared.runs(triggerID: triggerID, limit: 100)
                let payload = TriggerRunListPayload(runs: runs.map {
                    .init(
                        id: $0.id.uuidString,
                        triggerID: $0.triggerID.uuidString,
                        state: $0.state.rawValue,
                        queuedAt: $0.queuedAt,
                        sessionID: $0.sessionID?.uuidString,
                        summary: $0.result?.summary
                    )
                })
                completion(Self.triggerJSON(payload))
            } catch {
                completion(.failure(error.localizedDescription))
            }
        }
    }

    static func createTriggerDraft(
        _ arguments: CreateTriggerDraftArguments,
        for sessionID: SessionID,
        projects: ProjectStore,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let name = arguments.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let eventKind = arguments.eventKind?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let instructions = arguments.instructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, !eventKind.isEmpty, !instructions.isEmpty,
              let sourceID = arguments.sourceID.flatMap(TriggerSourceInstallationID.init(uuidString:)),
              let projectID = arguments.projectID.flatMap(ProjectID.init(uuidString:)) else {
            completion(.failure(
                "name, source_id, event_kind, project_id, and instructions are required."
            ))
            return
        }
        guard projects.project(withID: projectID) != nil else {
            completion(.failure("project_id is not a current Threading project."))
            return
        }
        guard let agent = AgentKind(rawValue: arguments.agent ?? "codex"),
              agent.supportsNativeUI,
              agent.supportsPermissionModes,
              let executionMode = TriggerExecutionMode(
                rawValue: arguments.executionMode ?? TriggerExecutionMode.assessThenFix.rawValue
              ),
              let checkoutPolicy = TriggerCheckoutPolicy(
                rawValue: arguments.checkoutPolicy ?? TriggerCheckoutPolicy.projectCheckout.rawValue
              ) else {
            completion(.failure(
                "agent, execution_mode, or checkout_policy contains an unsupported value."
            ))
            return
        }

        do {
            let conditions = try (arguments.conditions ?? []).map { try $0.condition() }
            let now = Date()
            let triggerID = TriggerID()
            let revisionID = TriggerRevisionID()
            let definition = TriggerDefinition(
                id: triggerID,
                name: name,
                enabled: false,
                activeRevisionID: nil,
                draftRevisionID: revisionID,
                createdAt: now,
                updatedAt: now
            )
            let revision = TriggerRevision(
                id: revisionID,
                triggerID: triggerID,
                sequence: 1,
                sourceInstallationID: sourceID,
                eventKind: eventKind,
                conditions: conditions,
                projectID: projectID,
                instructions: instructions,
                agentKind: agent,
                accountHandleName: arguments.account,
                model: arguments.model,
                reasoningEffort: arguments.reasoningEffort,
                executionMode: executionMode,
                checkoutPolicy: checkoutPolicy,
                limits: .conservative,
                quietHours: nil,
                notifications: .standard,
                allowSourceResources: false,
                proposedBySessionID: sessionID,
                createdAt: now
            )
            Task { @MainActor in
                do {
                    guard try await TriggerStore.shared.source(id: sourceID) != nil else {
                        completion(.failure("source_id is not a configured trigger source."))
                        return
                    }
                    try await TriggerStore.shared.saveDraft(definition, revision: revision)
                    completion(.success(
                        "Created disabled trigger draft \(triggerID.uuidString), revision "
                            + "\(revisionID.uuidString). It will not listen until the user activates it."
                    ))
                } catch {
                    completion(.failure(error.localizedDescription))
                }
            }
        } catch {
            completion(.failure(error.localizedDescription))
        }
    }

    static func proposeTriggerActivation(
        _ arguments: TriggerReferenceArguments,
        window: NSWindow?,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let triggerID = arguments.triggerID.flatMap(TriggerID.init(uuidString:)),
              let revisionID = arguments.revisionID.flatMap(TriggerRevisionID.init(uuidString:)) else {
            completion(.failure("trigger_id and revision_id are required."))
            return
        }
        Task { @MainActor in
            do {
                guard let pair = try await TriggerStore.shared.trigger(id: triggerID),
                      pair.revision.id == revisionID,
                      pair.definition.draftRevisionID == revisionID else {
                    completion(.failure("That exact draft revision is no longer current."))
                    return
                }
                guard let window else {
                    completion(.failure("No Threading window is available for approval."))
                    return
                }
                let request = ConfirmationRequest(
                    prompt: .approveTriggerActivation,
                    title: L10n.format("Activate “%@”?", pair.definition.name),
                    message: L10n.string(
                        "Threading will listen for matching source events and may start agents in the configured project. Review the trigger in Triggers before approving if anything is unexpected."
                    ),
                    confirmTitle: L10n.string("Activate")
                )
                ConfirmationAlert.ask(request, in: window) { approved in
                    guard approved else {
                        completion(.failure("The user did not activate the trigger."))
                        return
                    }
                    Task { @MainActor in
                        do {
                            try await TriggerStore.shared.activate(
                                triggerID: triggerID,
                                revisionID: revisionID
                            )
                            completion(.success("The user activated the trigger."))
                        } catch {
                            completion(.failure(error.localizedDescription))
                        }
                    }
                }
            } catch {
                completion(.failure(error.localizedDescription))
            }
        }
    }

    static func reportTriggerAssessment(
        _ arguments: ReportTriggerAssessmentArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let runID = arguments.runID.flatMap(TriggerRunID.init(uuidString:)),
              let disposition = arguments.disposition.flatMap(
                TriggerAssessmentDisposition.init(rawValue:)
              ),
              disposition != .fixed,
              let summary = Self.boundedTriggerText(arguments.summary, maximum: 4_096) else {
            completion(.failure("run_id, disposition, and a bounded summary are required."))
            return
        }
        Task { @MainActor in
            do {
                guard var run = try await TriggerStore.shared.run(id: runID),
                      run.sessionID == sessionID,
                      run.state == .assessing,
                      let revision = try await TriggerStore.shared.revision(
                        id: run.triggerRevisionID
                      ) else {
                    completion(.failure(
                        "This trigger run does not belong to the calling assessment session."
                    ))
                    return
                }
                run.result = TriggerRunResult(
                    disposition: disposition,
                    summary: summary,
                    changedPaths: [],
                    tests: []
                )
                run.state = disposition == .straightforwardFix
                    && revision.executionMode == .assessThenFix
                    ? .fixQueued
                    : Self.settledState(disposition)
                if run.state != .fixQueued { run.settledAt = Date() }
                try await TriggerStore.shared.updateRun(run)
                NotificationCenter.default.post(TriggerAssessmentDidFinish(
                    run: run,
                    revision: revision
                ))
                completion(.success(
                    run.state == .fixQueued
                        ? "Assessment recorded. End this turn; Threading will start the authorized fix stage."
                        : "Assessment recorded. No fix stage will start."
                ))
                if run.state != .fixQueued { try? await TriggerRuntime.shared.releaseQueue() }
            } catch {
                completion(.failure(error.localizedDescription))
            }
        }
    }

    static func reportTriggerResult(
        _ arguments: ReportTriggerResultArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let runID = arguments.runID.flatMap(TriggerRunID.init(uuidString:)),
              let disposition = arguments.disposition.flatMap(
                TriggerAssessmentDisposition.init(rawValue:)
              ),
              disposition != .straightforwardFix,
              let summary = Self.boundedTriggerText(arguments.summary, maximum: 4_096),
              (arguments.changedPaths?.count ?? 0) <= 256,
              (arguments.tests?.count ?? 0) <= 128 else {
            completion(.failure(
                "run_id, a final disposition, and bounded result fields are required."
            ))
            return
        }
        Task { @MainActor in
            do {
                guard var run = try await TriggerStore.shared.run(id: runID),
                      run.sessionID == sessionID,
                      run.state == .fixing else {
                    completion(.failure(
                        "This trigger run does not belong to the calling fix session."
                    ))
                    return
                }
                let paths = (arguments.changedPaths ?? []).map { String($0.prefix(1_024)) }
                let tests = (arguments.tests ?? []).map { String($0.prefix(1_024)) }
                run.result = TriggerRunResult(
                    disposition: disposition,
                    summary: summary,
                    changedPaths: paths,
                    tests: tests
                )
                run.state = Self.settledState(disposition)
                run.settledAt = Date()
                try await TriggerStore.shared.updateRun(run)
                NotificationCenter.default.post(TriggerFixDidFinish(run: run))
                completion(.success("Trigger result recorded. The user will be notified."))
                try? await TriggerRuntime.shared.releaseQueue()
            } catch {
                completion(.failure(error.localizedDescription))
            }
        }
    }

    private static func triggerJSON<T: Encodable>(_ payload: T) -> MCPToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else {
            return .failure("Threading could not encode the trigger result.")
        }
        return .success(text)
    }

    private static func boundedTriggerText(_ value: String?, maximum: Int) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.utf8.count <= maximum else { return nil }
        return text
    }

    private static func settledState(
        _ disposition: TriggerAssessmentDisposition
    ) -> TriggerRunState {
        switch disposition {
        case .noChangeNeeded, .fixed: return .completed
        case .straightforwardFix: return .needsAttention
        case .needsHuman: return .needsAttention
        case .failed: return .failed
        }
    }
}
