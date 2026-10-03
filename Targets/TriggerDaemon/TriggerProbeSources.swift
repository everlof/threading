import Foundation
#if !THREADING_TRIGGER_DAEMON
import ThreadingController
import ThreadingDomain
#endif

// Probe sources on the Mac: the portable probe contract (`TriggerProbe`, shared with the
// controller) run by `threading-triggerd`, with the cursor, inbox and health this host keeps.
//
// This file is compiled into both the daemon, which runs probes, and the app, which publishes
// their configuration — so the configuration the app writes and the envelope the daemon writes
// are one declaration, and the app's tests reach the poll pipeline the daemon executes.
//
// The daemon does not link the packages. Two helper tools linking a package product that the
// test bundle also links make Xcode build it as a dynamic framework both tools copy to the same
// place, which fails the build; so, like the other helpers' shared files, the daemon compiles
// `TriggerProbe.swift` and `AutomationSchedule.swift` directly (both Foundation-only) and this
// file under `THREADING_TRIGGER_DAEMON`. See docs/architecture/triggers.md.

/// What the daemon needs of a probe's spec: the controller's `ControllerSourceSpec` fields that
/// decide how it runs, in the same JSON shape. The app projects it from the full spec.
struct TriggerProbeRunSpec: Codable, Equatable, Sendable {
    let executable: String
    let script: String?
    let arguments: [String]
    let environment: [String: String]
    /// Environment variable → secret name.
    let secrets: [String: String]
    let intervalSeconds: Int?
    let schedule: AutomationSchedule?
    let timeoutSeconds: Int
    let limit: Int

    /// The files whose content the approval names, in the controller's order.
    var hashedPaths: [String] { [executable] + (script.map { [$0] } ?? []) }
}

/// One approved probe as the daemon receives it. Only an approved revision is ever published:
/// a probe with no approval is not in the daemon's configuration at all.
struct TriggerProbeDaemonSource: Codable, Equatable, Sendable {
    let id: UUID
    let revision: Int
    let spec: TriggerProbeRunSpec
    /// What the executable and script must still hash to before every run.
    let approvedHash: String
    /// A paused source is still published so a person's "Run now" can poll it; only an enabled
    /// one is polled on its schedule.
    let enabled: Bool
}

/// Resolves a configured secret name to its value at poll time. The Mac's resolver reads
/// Keychain; tests substitute a fake. A value exists only in the probe's environment.
protocol TriggerProbeSecretResolving: Sendable {
    func value(forSecret name: String) throws -> String
}

enum TriggerProbeSecretFailure: LocalizedError, Equatable {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let name): return "Secret “\(name)” is not set."
        }
    }
}

enum TriggerProbeDefaults {
    /// `TriggerSourceInstallation.sourceType` for a probe.
    static let sourceType = "probe"
    /// Every probe event's `TriggerEvent.kind`: matching is by the event's typed fields.
    static let eventKind = "probe.event"
    /// The Keychain service holding probe secrets, one generic password per secret name.
    static let secretService = "codes.threading.trigger-probe-secret"
    /// Bounded diagnostics on the source's health, never shown to an agent.
    static let diagnosticBytes = 1_024
    /// Scheduled polls the daemon starts per tick, and polls in flight at once.
    static let duePerTick = 8
    static let concurrentPolls = 2
    /// Failure backoff ceiling, as the controller's.
    static let maximumBackoff: TimeInterval = 3_600
}

/// The daemon's health spellings, which are the app's `TriggerSourceHealth` raw values.
enum TriggerProbeHealth: String, Codable, Sendable {
    case healthy
    case backingOff
    case authenticationRequired
    case failed
    /// The executable or script no longer hashes to its approval; nothing ran.
    case changed
}

struct TriggerProbePollOutcome: Equatable, Sendable {
    let health: TriggerProbeHealth
    let writtenEvents: Int
    let committedCursor: String?
    let lastEventAt: Date?
    let diagnostic: String?
}

/// The normalized inbox envelope: exactly the JSON the app decodes as `TriggerEvent`, so a
/// probe event meets `TriggerEngine`'s typed matching, revisions and authority unchanged.
struct TriggerProbeInboxEvent: Encodable, Equatable, Sendable {
    enum Attribute: Encodable, Equatable, Sendable {
        case string(String)
        case integer(Int64)
        case decimal(Double)
        case boolean(Bool)

        private enum CodingKeys: String, CodingKey { case type, string, integer, decimal, boolean }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .string(let value):
                try container.encode("string", forKey: .type)
                try container.encode(value, forKey: .string)
            case .integer(let value):
                try container.encode("integer", forKey: .type)
                try container.encode(value, forKey: .integer)
            case .decimal(let value):
                try container.encode("decimal", forKey: .type)
                try container.encode(value, forKey: .decimal)
            case .boolean(let value):
                try container.encode("boolean", forKey: .type)
                try container.encode(value, forKey: .boolean)
            }
        }
    }

    let sourceInstallationID: UUID
    let externalID: String
    let revision: String
    let kind: String
    let occurredAt: Date
    let receivedAt: Date
    let title: String
    let attributes: [String: Attribute]
    let resources: [String]
    /// Text shown to the agent as untrusted evidence; never an attribute, so never matched.
    let evidence: String?
}

enum TriggerProbeSourceRunner {
    // MARK: - Envelope

    static func inboxEvent(_ event: ProbeEvent, sourceID: UUID, receivedAt: Date) -> TriggerProbeInboxEvent {
        var attributes: [String: TriggerProbeInboxEvent.Attribute] = [:]
        for (name, value) in event.fields {
            switch value {
            case .string(let text): attributes[name] = .string(text)
            case .bool(let flag): attributes[name] = .boolean(flag)
            case .number(let number):
                if number.rounded() == number, abs(number) < 1e15 {
                    attributes[name] = .integer(Int64(number))
                } else {
                    attributes[name] = .decimal(number)
                }
            }
        }
        let occurredAt = event.occurredAt.flatMap(parseDate) ?? receivedAt
        return TriggerProbeInboxEvent(
            sourceInstallationID: sourceID,
            externalID: event.id,
            revision: event.revision,
            kind: TriggerProbeDefaults.eventKind,
            occurredAt: occurredAt,
            receivedAt: receivedAt,
            title: title(of: event),
            attributes: attributes,
            resources: [],
            evidence: event.evidence
        )
    }

    /// A readable line for Activity: a `title` or `subject` field when the probe gave one.
    private static func title(of event: ProbeEvent) -> String {
        for key in ["title", "subject"] {
            if case .string(let text)? = event.fields[key], !text.isEmpty { return text }
        }
        return event.id
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: - Invocation

    /// Exactly the configured environment, the secrets resolved by name, and the two reserved
    /// identities. Nothing is inherited from the daemon.
    static func environment(
        for source: TriggerProbeDaemonSource,
        secrets: any TriggerProbeSecretResolving
    ) throws -> (environment: [String: String], secretValues: [String]) {
        var environment = source.spec.environment
        var values: [String] = []
        for (variable, name) in source.spec.secrets.sorted(by: { $0.key < $1.key }) {
            let value = try secrets.value(forSecret: name)
            environment[variable] = value
            values.append(value)
        }
        environment["THREADING_SOURCE_ID"] = source.id.uuidString.lowercased()
        environment["THREADING_SOURCE_REVISION"] = String(source.revision)
        return (environment, values)
    }

    // MARK: - Poll

    /// One poll. The hash is checked before anything runs, so an edited probe never runs under
    /// an old approval. Every event is written before the cursor is committed, so a failure in
    /// between redelivers and the app's idempotent acceptance absorbs the repeat.
    static func poll(
        _ source: TriggerProbeDaemonSource,
        cursor: String?,
        directory: String,
        secrets: any TriggerProbeSecretResolving,
        observedHash: String?,
        receivedAt: Date = Date(),
        run: (ProbeInvocation) async -> ProbeRun = { await TriggerProbe.run($0) },
        write: (TriggerProbeInboxEvent, Int) throws -> Void,
        commit: (String) throws -> Void
    ) async -> TriggerProbePollOutcome {
        guard observedHash == source.approvedHash else {
            return TriggerProbePollOutcome(
                health: .changed, writtenEvents: 0, committedCursor: nil, lastEventAt: nil,
                diagnostic: "The probe changed since it was approved. Review it on the Sources page."
            )
        }
        let resolved: (environment: [String: String], secretValues: [String])
        do {
            resolved = try environment(for: source, secrets: secrets)
        } catch {
            return TriggerProbePollOutcome(
                health: .authenticationRequired, writtenEvents: 0, committedCursor: nil, lastEventAt: nil,
                diagnostic: bounded(error.localizedDescription)
            )
        }
        let result = await run(ProbeInvocation(
            executable: source.spec.executable,
            arguments: source.spec.arguments,
            environment: resolved.environment,
            directory: directory,
            cursor: cursor,
            limit: source.spec.limit,
            timeout: TimeInterval(source.spec.timeoutSeconds)
        ))
        let diagnostic = redact(result.diagnostics, secrets: resolved.secretValues)
        switch result.outcome {
        case .healthy:
            guard let next = result.cursor else {
                return TriggerProbePollOutcome(health: .failed, writtenEvents: 0, committedCursor: nil,
                                               lastEventAt: nil, diagnostic: "invalid_output: missing_cursor")
            }
            var written = 0
            var lastEventAt: Date?
            do {
                for (index, event) in result.events.prefix(source.spec.limit).enumerated() {
                    let envelope = inboxEvent(event, sourceID: source.id, receivedAt: receivedAt)
                    try write(envelope, index)
                    written += 1
                    lastEventAt = max(lastEventAt ?? envelope.occurredAt, envelope.occurredAt)
                }
                try commit(next)
            } catch {
                return TriggerProbePollOutcome(
                    health: .failed, writtenEvents: written, committedCursor: nil, lastEventAt: lastEventAt,
                    diagnostic: bounded("inbox: " + error.localizedDescription)
                )
            }
            return TriggerProbePollOutcome(health: .healthy, writtenEvents: written, committedCursor: next,
                                           lastEventAt: lastEventAt, diagnostic: diagnostic.isEmpty ? nil : diagnostic)
        case .backoff:
            return TriggerProbePollOutcome(health: .backingOff, writtenEvents: 0, committedCursor: nil,
                                           lastEventAt: nil, diagnostic: diagnostic.isEmpty ? nil : diagnostic)
        case .authenticationNeeded:
            return TriggerProbePollOutcome(health: .authenticationRequired, writtenEvents: 0, committedCursor: nil,
                                           lastEventAt: nil, diagnostic: diagnostic.isEmpty ? nil : diagnostic)
        case .failed:
            return TriggerProbePollOutcome(health: .failed, writtenEvents: 0, committedCursor: nil,
                                           lastEventAt: nil, diagnostic: diagnostic.isEmpty ? nil : diagnostic)
        }
    }

    /// When the next scheduled poll is due: the calendar or the interval, and after a failure an
    /// exponential backoff from the interval to an hour, as the controller does.
    static func nextPoll(_ spec: TriggerProbeRunSpec, after date: Date, failures: Int) -> Date {
        if let schedule = spec.schedule, failures == 0, let next = try? schedule.next(after: date) {
            return next
        }
        let base = TimeInterval(spec.intervalSeconds ?? 600)
        guard failures > 0 else { return date.addingTimeInterval(base) }
        return date.addingTimeInterval(min(base * pow(2, Double(min(failures, 10))), TriggerProbeDefaults.maximumBackoff))
    }

    /// A probe's stderr may echo a secret it was given; the receipt never repeats one.
    static func redact(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[secret]")
        }
        return bounded(result.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func bounded(_ text: String) -> String {
        guard text.utf8.count > TriggerProbeDefaults.diagnosticBytes else { return text }
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= TriggerProbeDefaults.diagnosticBytes else { break }
            result.append(character)
        }
        return result
    }
}
