import Foundation

/// Bound by the provider's host hook, never inferred from nearby filesystem timestamps.
public struct ProviderTranscript: Codable, Equatable, Sendable {
    public let sessionID: String
    public let path: String
    public init(sessionID: String, path: String) { self.sessionID = sessionID; self.path = path }
}

extension ControllerStore {
    public func bindProviderTranscript(_ executionID: ExecutionID, credential: String, transcript: ProviderTranscript) throws {
        var refusal: ControllerError?
        try db.transaction {
            var value = try launch(executionID)
            let expected: String = try required("executionCredential", executionID.description)
            guard credential == expected, value.state == .dispatching || value.state == .running,
                  let source = value.spec.usage else { throw ControllerError.forbidden }
            try Limits.text(transcript.sessionID, field: "provider_session", maximum: 256)
            try Limits.text(transcript.path, field: "provider_transcript", maximum: 4096)
            let home = URL(fileURLWithPath: source.home).standardizedFileURL.path + "/"
            let path = URL(fileURLWithPath: transcript.path).standardizedFileURL.path
            let insideHome = transcript.path.hasPrefix("/") && path.hasPrefix(home)
            let changed = value.providerTranscript.map { $0 != transcript } ?? false
            if !insideHome || changed {
                // An account failover may copy the conversation to another home. The original
                // transcript alone cannot claim complete usage, even if the hook refuses rebinding.
                value.providerTranscriptChanged = true
                try update("launch", executionID.description, state: value.state.rawValue, value: value)
                refusal = insideHome ? .conflict : .forbidden
                return
            }
            if value.providerTranscript != nil { return }
            value.providerTranscript = transcript
            try update("launch", executionID.description, state: value.state.rawValue, value: value)
            try event("launch.transcript_bound", executionID.description)
        }
        if let refusal { throw refusal }
    }
}
