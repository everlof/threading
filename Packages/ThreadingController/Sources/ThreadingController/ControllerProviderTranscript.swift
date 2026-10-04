import Foundation

/// Bound by the provider's host hook, never inferred from nearby filesystem timestamps.
public struct ProviderTranscript: Codable, Equatable, Sendable {
    public let sessionID: String
    public let path: String
    public init(sessionID: String, path: String) { self.sessionID = sessionID; self.path = path }
}

/// One attempt's binding: the declared account whose home holds the transcript the hook named.
public struct ProviderTranscriptBinding: Codable, Equatable, Sendable {
    public let account: String
    public let sessionID: String
    public let path: String
    public init(account: String, sessionID: String, path: String) { self.account = account; self.sessionID = sessionID; self.path = path }
}

extension ControllerLaunch {
    /// Every attempt's binding in the order the hooks reported them. A launch stored before
    /// per-attempt bindings carries only `providerTranscript`, which belonged to its one home.
    public var transcriptBindings: [ProviderTranscriptBinding] {
        if let providerTranscripts { return providerTranscripts }
        guard let transcript = providerTranscript, let first = spec.usage?.attempts.first else { return [] }
        return [ProviderTranscriptBinding(account: first.account, sessionID: transcript.sessionID, path: transcript.path)]
    }
}

extension ControllerStore {
    /// Records the transcript a provider hook reports for this execution.
    ///
    /// A recipe that declares several account homes may fail over between them, and the
    /// runner's resume copies the conversation into the next home: a report inside another
    /// declared home is a new attempt and is bound beside the first, at most one per home. A
    /// report outside every declared home, or a different session/path within an already bound
    /// home, is refused and marks the launch's coverage partial — that transcript alone cannot
    /// claim complete usage, even if the hook ignores the refusal.
    public func bindProviderTranscript(_ executionID: ExecutionID, credential: String, transcript: ProviderTranscript) throws {
        var refusal: ControllerError?
        try db.transaction {
            var value = try launch(executionID)
            guard try credentialMatches(ControllerCredential.executionKind, executionID.description, presented: credential),
                  value.state == .dispatching || value.state == .running,
                  let source = value.spec.usage else { throw ControllerError.forbidden }
            try Limits.text(transcript.sessionID, field: "provider_session", maximum: 256)
            try Limits.text(transcript.path, field: "provider_transcript", maximum: 4096)
            var bindings = value.transcriptBindings
            let attempt = transcript.path.hasPrefix("/") ? source.attempt(containing: transcript.path) : nil
            let existing = attempt.flatMap { attempt in bindings.first { $0.account == attempt.account } }
            if let existing, existing.sessionID == transcript.sessionID, existing.path == transcript.path { return }
            guard let attempt, existing == nil else {
                value.providerTranscriptChanged = true
                try update("launch", executionID.description, state: value.state.rawValue, value: value)
                refusal = attempt == nil ? .forbidden : .conflict
                return
            }
            bindings.append(ProviderTranscriptBinding(account: attempt.account, sessionID: transcript.sessionID, path: transcript.path))
            value.providerTranscripts = bindings
            if value.providerTranscript == nil { value.providerTranscript = transcript }
            try update("launch", executionID.description, state: value.state.rawValue, value: value)
            try event("launch.transcript_bound", executionID.description)
        }
        if let refusal { throw refusal }
    }
}
