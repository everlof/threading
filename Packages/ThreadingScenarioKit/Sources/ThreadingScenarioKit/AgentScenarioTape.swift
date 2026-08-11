import Foundation

/// A recorded provider exchange that a deterministic child process can replay.
///
/// This is intentionally below `StreamEvent`. Replaying normalized presentation events would
/// bypass the provider parser, pipe framing, process lifecycle, and exactly-once completion paths
/// that an application-level scenario is meant to prove.
public struct AgentScenarioTape: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let id: String
    public let title: String
    public let provider: Provider
    public let transport: Transport
    public let provenance: RecordingProvenance
    public let steps: [AgentScenarioStep]

    public init(
        version: Int = AgentScenarioTape.currentVersion,
        id: String,
        title: String,
        provider: Provider,
        transport: Transport,
        provenance: RecordingProvenance,
        steps: [AgentScenarioStep]
    ) {
        self.version = version
        self.id = id
        self.title = title
        self.provider = provider
        self.transport = transport
        self.provenance = provenance
        self.steps = steps
    }

    public enum Provider: String, Codable, CaseIterable, Sendable {
        case claude
        case codex
        case grok
        case openCode = "open-code"
    }

    /// The real boundary the fixture process impersonates.
    public enum Transport: String, Codable, CaseIterable, Sendable {
        case terminalPTY = "terminal-pty"
        case claudeStreamJSON = "claude-stream-json"
        case codexAppServer = "codex-app-server"
        case grokACP = "grok-acp"
    }
}

public struct RecordingProvenance: Codable, Equatable, Sendable {
    public let providerVersion: String
    public let protocolVersion: String
    public let recordedAt: Date

    public init(providerVersion: String, protocolVersion: String, recordedAt: Date) {
        self.providerVersion = providerVersion
        self.protocolVersion = protocolVersion
        self.recordedAt = recordedAt
    }
}

/// One ordered action performed by the deterministic agent boundary.
///
/// Associated values make illegal combinations unrepresentable: an exit cannot accidentally
/// carry stdout, an expected host write cannot acquire a replay delay, and a checkpoint cannot be
/// mistaken for bytes that should be sent to the application.
public enum AgentScenarioStep: Equatable, Sendable {
    case expectHost(channel: HostChannel, payload: String)
    case emitAgent(channel: AgentChannel, payload: String, afterMilliseconds: Int)
    case writeFixtureFile(path: String, contents: String)
    case checkpoint(name: String)
    case exit(status: Int32, afterMilliseconds: Int)

    public enum HostChannel: String, Codable, CaseIterable, Sendable {
        case standardInput = "stdin"
    }

    public enum AgentChannel: String, Codable, CaseIterable, Sendable {
        case standardOutput = "stdout"
        case standardError = "stderr"
        case terminal = "pty"
    }
}

extension AgentScenarioStep: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case channel
        case payload
        case afterMilliseconds
        case name
        case status
        case path
        case contents
    }

    private enum Kind: String, Codable {
        case expectHost
        case emitAgent
        case writeFixtureFile
        case checkpoint
        case exit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .expectHost:
            self = .expectHost(
                channel: try container.decode(HostChannel.self, forKey: .channel),
                payload: try container.decode(String.self, forKey: .payload)
            )
        case .emitAgent:
            self = .emitAgent(
                channel: try container.decode(AgentChannel.self, forKey: .channel),
                payload: try container.decode(String.self, forKey: .payload),
                afterMilliseconds: try container.decodeIfPresent(
                    Int.self,
                    forKey: .afterMilliseconds
                ) ?? 0
            )
        case .writeFixtureFile:
            self = .writeFixtureFile(
                path: try container.decode(String.self, forKey: .path),
                contents: try container.decode(String.self, forKey: .contents)
            )
        case .checkpoint:
            self = .checkpoint(name: try container.decode(String.self, forKey: .name))
        case .exit:
            self = .exit(
                status: try container.decode(Int32.self, forKey: .status),
                afterMilliseconds: try container.decodeIfPresent(
                    Int.self,
                    forKey: .afterMilliseconds
                ) ?? 0
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .expectHost(let channel, let payload):
            try container.encode(Kind.expectHost, forKey: .kind)
            try container.encode(channel, forKey: .channel)
            try container.encode(payload, forKey: .payload)
        case .emitAgent(let channel, let payload, let delay):
            try container.encode(Kind.emitAgent, forKey: .kind)
            try container.encode(channel, forKey: .channel)
            try container.encode(payload, forKey: .payload)
            if delay != 0 {
                try container.encode(delay, forKey: .afterMilliseconds)
            }
        case .writeFixtureFile(let path, let contents):
            try container.encode(Kind.writeFixtureFile, forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(contents, forKey: .contents)
        case .checkpoint(let name):
            try container.encode(Kind.checkpoint, forKey: .kind)
            try container.encode(name, forKey: .name)
        case .exit(let status, let delay):
            try container.encode(Kind.exit, forKey: .kind)
            try container.encode(status, forKey: .status)
            if delay != 0 {
                try container.encode(delay, forKey: .afterMilliseconds)
            }
        }
    }
}

public enum AgentScenarioLimits {
    public static let maximumEncodedBytes = 4 * 1_024 * 1_024
    public static let maximumSteps = 4_096
    public static let maximumPayloadBytes = 256 * 1_024
    public static let maximumAggregatePayloadBytes = 3 * 1_024 * 1_024
    public static let maximumIdentifierBytes = 128
    public static let maximumTitleBytes = 256
    public static let maximumVersionBytes = 128
    public static let maximumCheckpointBytes = 128
    public static let maximumFixturePathBytes = 1_024
    public static let maximumStepDelayMilliseconds = 30_000
    public static let maximumAggregateDelayMilliseconds = 120_000
}

public enum AgentScenarioValidationError: Error, Equatable, LocalizedError, Sendable {
    case fileTooLarge(actual: Int, maximum: Int)
    case unsupportedVersion(found: Int, current: Int)
    case invalidIdentifier
    case emptyField(field: String)
    case fieldTooLarge(field: String, actual: Int, maximum: Int)
    case incompatibleProviderTransport(provider: String, transport: String)
    case incompatibleAgentChannel(step: Int, channel: String, transport: String)
    case emptySteps
    case tooManySteps(actual: Int, maximum: Int)
    case payloadTooLarge(step: Int, actual: Int, maximum: Int)
    case aggregatePayloadTooLarge(actual: Int, maximum: Int)
    case invalidDelay(step: Int, milliseconds: Int)
    case aggregateDelayTooLarge(actual: Int, maximum: Int)
    case exitNotLast(step: Int)
    case missingExit
    case unknownPlaceholder(step: Int, name: String)
    case invalidFixturePath(step: Int, path: String)

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge(let actual, let maximum):
            return "scenario file is \(actual) bytes; maximum is \(maximum)"
        case .unsupportedVersion(let found, let current):
            return "scenario version \(found) is unsupported; current version is \(current)"
        case .invalidIdentifier:
            return "scenario id must be a lowercase ASCII slug"
        case .emptyField(let field):
            return "scenario \(field) must not be empty"
        case .fieldTooLarge(let field, let actual, let maximum):
            return "\(field) is \(actual) bytes; maximum is \(maximum)"
        case .incompatibleProviderTransport(let provider, let transport):
            return "provider \(provider) cannot use transport \(transport)"
        case .incompatibleAgentChannel(let step, let channel, let transport):
            return "scenario step \(step) cannot emit \(channel) for transport \(transport)"
        case .emptySteps:
            return "scenario contains no steps"
        case .tooManySteps(let actual, let maximum):
            return "scenario contains \(actual) steps; maximum is \(maximum)"
        case .payloadTooLarge(let step, let actual, let maximum):
            return "scenario step \(step) contains \(actual) payload bytes; maximum is \(maximum)"
        case .aggregatePayloadTooLarge(let actual, let maximum):
            return "scenario contains \(actual) payload bytes; maximum is \(maximum)"
        case .invalidDelay(let step, let milliseconds):
            return "scenario step \(step) has invalid delay \(milliseconds) ms"
        case .aggregateDelayTooLarge(let actual, let maximum):
            return "scenario delays total \(actual) ms; maximum is \(maximum)"
        case .exitNotLast(let step):
            return "scenario exit at step \(step) is not the final step"
        case .missingExit:
            return "scenario has no final process exit"
        case .unknownPlaceholder(let step, let name):
            return "scenario step \(step) uses unknown placeholder ${\(name)}"
        case .invalidFixturePath(let step, let path):
            return "scenario step \(step) has unsafe fixture path \(path)"
        }
    }
}

public extension AgentScenarioTape {
    /// Reads at most one byte beyond the actual opened-file limit, then validates the decoded
    /// value. Metadata is never trusted as the size authority because the path can be replaced
    /// between inspection and open.
    static func load(from url: URL) throws -> AgentScenarioTape {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let maximum = AgentScenarioLimits.maximumEncodedBytes
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else {
            throw AgentScenarioValidationError.fileTooLarge(actual: data.count, maximum: maximum)
        }
        let tape = try decoder.decode(AgentScenarioTape.self, from: data)
        try tape.validate()
        return tape
    }

    func validate() throws {
        guard version == Self.currentVersion else {
            throw AgentScenarioValidationError.unsupportedVersion(
                found: version,
                current: Self.currentVersion
            )
        }
        guard Self.validIdentifier(id) else {
            throw AgentScenarioValidationError.invalidIdentifier
        }
        try Self.checkSize(
            id,
            field: "id",
            maximum: AgentScenarioLimits.maximumIdentifierBytes
        )
        try Self.checkSize(
            title,
            field: "title",
            maximum: AgentScenarioLimits.maximumTitleBytes
        )
        try Self.checkSize(
            provenance.providerVersion,
            field: "providerVersion",
            maximum: AgentScenarioLimits.maximumVersionBytes
        )
        try Self.checkSize(
            provenance.protocolVersion,
            field: "protocolVersion",
            maximum: AgentScenarioLimits.maximumVersionBytes
        )
        try Self.requireNonempty(title, field: "title")
        try Self.requireNonempty(provenance.providerVersion, field: "providerVersion")
        try Self.requireNonempty(provenance.protocolVersion, field: "protocolVersion")
        guard Self.provider(provider, supports: transport) else {
            throw AgentScenarioValidationError.incompatibleProviderTransport(
                provider: provider.rawValue,
                transport: transport.rawValue
            )
        }
        guard !steps.isEmpty else { throw AgentScenarioValidationError.emptySteps }
        guard steps.count <= AgentScenarioLimits.maximumSteps else {
            throw AgentScenarioValidationError.tooManySteps(
                actual: steps.count,
                maximum: AgentScenarioLimits.maximumSteps
            )
        }

        var aggregatePayloadBytes = 0
        var aggregateDelayMilliseconds = 0
        var sawExit = false

        for (index, step) in steps.enumerated() {
            switch step {
            case .expectHost(_, let payload):
                try Self.validatePayload(
                    payload,
                    step: index,
                    aggregate: &aggregatePayloadBytes
                )
                try Self.validatePlaceholders(in: payload, step: index)
            case .emitAgent(let channel, let payload, let delay):
                guard Self.transport(transport, supports: channel) else {
                    throw AgentScenarioValidationError.incompatibleAgentChannel(
                        step: index,
                        channel: channel.rawValue,
                        transport: transport.rawValue
                    )
                }
                try Self.validatePayload(
                    payload,
                    step: index,
                    aggregate: &aggregatePayloadBytes
                )
                try Self.validatePlaceholders(in: payload, step: index)
                try Self.validateDelay(
                    delay,
                    step: index,
                    aggregate: &aggregateDelayMilliseconds
                )
            case .writeFixtureFile(let path, let contents):
                guard Self.validFixturePath(path) else {
                    throw AgentScenarioValidationError.invalidFixturePath(
                        step: index,
                        path: path
                    )
                }
                try Self.checkSize(
                    path,
                    field: "fixture path",
                    maximum: AgentScenarioLimits.maximumFixturePathBytes
                )
                try Self.validatePayload(
                    contents,
                    step: index,
                    aggregate: &aggregatePayloadBytes
                )
                try Self.validatePlaceholders(in: contents, step: index)
            case .checkpoint(let name):
                try Self.checkSize(
                    name,
                    field: "checkpoint",
                    maximum: AgentScenarioLimits.maximumCheckpointBytes
                )
                try Self.requireNonempty(name, field: "checkpoint")
            case .exit(_, let delay):
                guard index == steps.index(before: steps.endIndex) else {
                    throw AgentScenarioValidationError.exitNotLast(step: index)
                }
                try Self.validateDelay(
                    delay,
                    step: index,
                    aggregate: &aggregateDelayMilliseconds
                )
                sawExit = true
            }
        }

        guard sawExit else { throw AgentScenarioValidationError.missingExit }
    }

    func canonicalData() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= AgentScenarioLimits.maximumEncodedBytes else {
            throw AgentScenarioValidationError.fileTooLarge(
                actual: data.count,
                maximum: AgentScenarioLimits.maximumEncodedBytes
            )
        }
        return data
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let allowedPlaceholders: Set<String> = [
        "PROJECT_ID",
        "SCENARIO_ROOT",
        "SESSION_ID",
        "TURN_ID",
        "PORT",
    ]

    private static func validIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= AgentScenarioLimits.maximumIdentifierBytes else {
            return false
        }
        return value.utf8.allSatisfy {
            ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45
        }
    }

    private static func validFixturePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/") else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func checkSize(_ value: String, field: String, maximum: Int) throws {
        let count = value.utf8.count
        guard count <= maximum else {
            throw AgentScenarioValidationError.fieldTooLarge(
                field: field,
                actual: count,
                maximum: maximum
            )
        }
    }

    private static func requireNonempty(_ value: String, field: String) throws {
        guard !value.isEmpty else {
            throw AgentScenarioValidationError.emptyField(field: field)
        }
    }

    private static func provider(_ provider: Provider, supports transport: Transport) -> Bool {
        switch transport {
        case .terminalPTY:
            return true
        case .claudeStreamJSON:
            return provider == .claude
        case .codexAppServer:
            return provider == .codex
        case .grokACP:
            return provider == .grok
        }
    }

    private static func transport(
        _ transport: Transport,
        supports channel: AgentScenarioStep.AgentChannel
    ) -> Bool {
        switch (transport, channel) {
        case (.terminalPTY, .terminal):
            return true
        case (.terminalPTY, _), (_, .terminal):
            return false
        default:
            return true
        }
    }

    private static func validatePayload(
        _ payload: String,
        step: Int,
        aggregate: inout Int
    ) throws {
        let count = payload.utf8.count
        guard count <= AgentScenarioLimits.maximumPayloadBytes else {
            throw AgentScenarioValidationError.payloadTooLarge(
                step: step,
                actual: count,
                maximum: AgentScenarioLimits.maximumPayloadBytes
            )
        }
        let (sum, overflow) = aggregate.addingReportingOverflow(count)
        guard !overflow, sum <= AgentScenarioLimits.maximumAggregatePayloadBytes else {
            throw AgentScenarioValidationError.aggregatePayloadTooLarge(
                actual: overflow ? .max : sum,
                maximum: AgentScenarioLimits.maximumAggregatePayloadBytes
            )
        }
        aggregate = sum
    }

    private static func validateDelay(
        _ delay: Int,
        step: Int,
        aggregate: inout Int
    ) throws {
        guard delay >= 0, delay <= AgentScenarioLimits.maximumStepDelayMilliseconds else {
            throw AgentScenarioValidationError.invalidDelay(step: step, milliseconds: delay)
        }
        let (sum, overflow) = aggregate.addingReportingOverflow(delay)
        guard !overflow, sum <= AgentScenarioLimits.maximumAggregateDelayMilliseconds else {
            throw AgentScenarioValidationError.aggregateDelayTooLarge(
                actual: overflow ? .max : sum,
                maximum: AgentScenarioLimits.maximumAggregateDelayMilliseconds
            )
        }
        aggregate = sum
    }

    private static func validatePlaceholders(in payload: String, step: Int) throws {
        var searchStart = payload.startIndex
        while let opening = payload.range(of: "${", range: searchStart..<payload.endIndex) {
            guard let closing = payload[opening.upperBound...].firstIndex(of: "}") else {
                let suffix = String(payload[opening.upperBound...])
                throw AgentScenarioValidationError.unknownPlaceholder(step: step, name: suffix)
            }
            let name = String(payload[opening.upperBound..<closing])
            guard allowedPlaceholders.contains(name) else {
                throw AgentScenarioValidationError.unknownPlaceholder(step: step, name: name)
            }
            searchStart = payload.index(after: closing)
        }
    }
}
