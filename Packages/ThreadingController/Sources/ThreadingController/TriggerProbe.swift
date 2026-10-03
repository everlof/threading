import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// A trigger source anyone can write: an executable on a fixed stdin/stdout contract, run with
// no model and no inherited environment. It reports facts as bounded events with stable ids and
// a cursor; only events a trigger matches start agent work. See
// docs/feature-drafts/portable-trigger-sources.md. Shared by the controller's supervisor and the
// Mac's threading-triggerd, so both run probes identically.

public enum ProbeValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool)
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let flag = try? value.decode(Bool.self) { self = .bool(flag) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else { self = .string(try value.decode(String.self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let text): try value.encode(text)
        case .number(let number): try value.encode(number)
        case .bool(let flag): try value.encode(flag)
        }
    }
    /// The form a match clause compares: integral numbers without a fraction, booleans as words.
    public var text: String {
        switch self {
        case .string(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number):
            if number.rounded() == number, abs(number) < 1e15 { return String(Int64(number)) }
            return String(number)
        }
    }
}

public struct ProbeEvent: Codable, Equatable, Sendable {
    public let id: String
    public let revision: String
    public let occurredAt: String?
    public let fields: [String: ProbeValue]
    public let evidence: String?

    public init(from decoder: any Decoder) throws {
        enum Keys: String, CodingKey { case id, revision, occurredAt, fields, evidence }
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(String.self, forKey: .id)
        revision = try container.decodeIfPresent(String.self, forKey: .revision) ?? "1"
        occurredAt = try container.decodeIfPresent(String.self, forKey: .occurredAt)
        fields = try container.decodeIfPresent([String: ProbeValue].self, forKey: .fields) ?? [:]
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
    }
    func validate() throws {
        try ProbeLimits.identity(id, maximum: ProbeLimits.idBytes)
        try ProbeLimits.identity(revision, maximum: 64)
        if let occurredAt { try ProbeLimits.identity(occurredAt, maximum: 64) }
        guard fields.count <= ProbeLimits.fields else { throw ProbeFailure.invalidOutput("too_many_fields") }
        for (key, value) in fields {
            guard ProbeLimits.isFieldName(key) else { throw ProbeFailure.invalidOutput("field_name") }
            guard value.text.utf8.count <= ProbeLimits.fieldBytes, !value.text.contains("\0") else { throw ProbeFailure.invalidOutput("field_value") }
        }
        if let evidence { guard evidence.utf8.count <= ProbeLimits.evidenceBytes, !evidence.contains("\0") else { throw ProbeFailure.invalidOutput("evidence") } }
    }
}

public enum ProbeOutcome: String, Codable, Sendable {
    /// Exit 0 with a valid report. Backoff is exit 75 (EX_TEMPFAIL), authentication exit 77
    /// (EX_NOPERM); anything else, including a timeout or invalid output, is a failure.
    case healthy, backoff, authenticationNeeded, failed
}
public enum ProbeFailure: Error, Equatable, Sendable { case invalidOutput(String) }

public struct ProbeInvocation: Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let directory: String
    public let cursor: String?
    public let limit: Int
    public let timeout: TimeInterval
    public init(executable: String, arguments: [String], environment: [String: String], directory: String,
                cursor: String?, limit: Int, timeout: TimeInterval) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.directory = directory; self.cursor = cursor; self.limit = limit; self.timeout = timeout
    }
}
public struct ProbeRun: Codable, Sendable {
    public let outcome: ProbeOutcome
    public let events: [ProbeEvent]
    public let cursor: String?
    /// Bounded stderr and the host's own reason; shown on the source's health, never to an agent.
    public let diagnostics: String
    public init(outcome: ProbeOutcome, events: [ProbeEvent], cursor: String?, diagnostics: String) {
        self.outcome = outcome; self.events = events; self.cursor = cursor; self.diagnostics = diagnostics
    }
}

public enum ProbeLimits {
    public static let stdoutBytes = 1_048_576
    public static let stderrBytes = 16_384
    public static let idBytes = 256
    public static let cursorBytes = 4_096
    public static let fields = 32
    public static let fieldBytes = 1_024
    public static let evidenceBytes = 16_384
    public static let maximumEvents = 500
    public static let maximumTimeout: TimeInterval = 300
    static func identity(_ value: String, maximum: Int) throws {
        guard !value.isEmpty, value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw ProbeFailure.invalidOutput("identity")
        }
    }
    static func isFieldName(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 64 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
    }
}

public enum TriggerProbe {
    /// Parses a probe's stdout: JSON lines, each `{"event": …}` or, exactly once and last,
    /// `{"cursor": "…"}`. Any deviation fails the whole poll so no cursor is committed.
    public static func parse(_ output: Data, limit: Int) throws -> (events: [ProbeEvent], cursor: String) {
        var events: [ProbeEvent] = []
        var cursor: String?
        for line in output.split(separator: 10, omittingEmptySubsequences: true) {
            guard cursor == nil else { throw ProbeFailure.invalidOutput("line_after_cursor") }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], object.count == 1 else {
                throw ProbeFailure.invalidOutput("line")
            }
            if let value = object["cursor"] {
                guard let text = value as? String, text.utf8.count <= ProbeLimits.cursorBytes, !text.contains("\0") else {
                    throw ProbeFailure.invalidOutput("cursor")
                }
                cursor = text
            } else if object["event"] != nil {
                struct Line: Decodable { let event: ProbeEvent }
                guard let event = try? JSONDecoder().decode(Line.self, from: Data(line)).event else { throw ProbeFailure.invalidOutput("event") }
                try event.validate()
                events.append(event)
                guard events.count <= limit else { throw ProbeFailure.invalidOutput("too_many_events") }
            } else { throw ProbeFailure.invalidOutput("line") }
        }
        guard let cursor else { throw ProbeFailure.invalidOutput("missing_cursor") }
        return (events, cursor)
    }

    /// Runs one poll in its own process group, with exactly the given environment. A timeout or
    /// an oversized report kills the whole group; so does the probe's exit, so nothing it started
    /// outlives the poll.
    public static func run(_ invocation: ProbeInvocation) async -> ProbeRun {
        await withCheckedContinuation { (continuation: CheckedContinuation<ProbeRun, Never>) in
            DispatchQueue.global().async { continuation.resume(returning: runBlocking(invocation)) }
        }
    }

    static func runBlocking(_ invocation: ProbeInvocation) -> ProbeRun {
        func failed(_ reason: String) -> ProbeRun { ProbeRun(outcome: .failed, events: [], cursor: nil, diagnostics: reason) }
        // A probe that exits without reading its request must fail the poll, not this process.
        signal(SIGPIPE, SIG_IGN)
        let request: Data
        do {
            var object: [String: Any] = ["limit": invocation.limit]
            object["cursor"] = invocation.cursor ?? NSNull()
            request = try JSONSerialization.data(withJSONObject: object) + Data([10])
        } catch { return failed("request") }
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&errors) == 0 else { return failed("pipe") }
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errors[1], 2)
        for descriptor in input + output + errors { posix_spawn_file_actions_addclose(&actions, descriptor) }
        posix_spawn_file_actions_addchdir_np(&actions, invocation.directory)
        posix_spawnattr_setpgroup(&attributes, 0)
        #if canImport(Darwin)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        #else
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        #endif
        let argv = ([invocation.executable] + invocation.arguments).map { strdup($0) } + [nil]
        let envp = invocation.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, invocation.executable, &actions, &attributes, argv, envp)
        for descriptor in [input[0], output[1], errors[1]] { close(descriptor) }
        guard spawned == 0 else {
            for descriptor in [input[1], output[0], errors[0]] { close(descriptor) }
            return failed("spawn_\(spawned)")
        }
        let group = DispatchGroup()
        let killer = ProbeKiller(pid: pid)
        let requestDescriptor = input[1], errorDescriptor = errors[0], outputDescriptor = output[0]
        DispatchQueue.global().async(group: group) {
            // A probe that never reads stdin must not wedge this write: it fails with EPIPE.
            request.withUnsafeBytes { buffer in _ = write(requestDescriptor, buffer.baseAddress, buffer.count) }
            close(requestDescriptor)
        }
        let stderrBox = ProbeOutputBox()
        DispatchQueue.global().async(group: group) {
            stderrBox.set(drain(errorDescriptor, limit: ProbeLimits.stderrBytes, overflow: nil))
        }
        var overflow = false
        let timer = DispatchWorkItem { killer.expire() }
        DispatchQueue.global().asyncAfter(deadline: .now() + min(invocation.timeout, ProbeLimits.maximumTimeout), execute: timer)
        let stdout = drain(outputDescriptor, limit: ProbeLimits.stdoutBytes) { overflow = true; killer.kill() }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        timer.cancel()
        killer.kill() // Nothing the probe started outlives the poll.
        group.wait()
        let stderr = stderrBox.value
        let diagnostics = String(decoding: stderr.prefix(ProbeLimits.stderrBytes), as: UTF8.self)
        if killer.expired { return failed("timed_out") }
        if overflow { return failed("output_too_large") }
        let exited = (status & 0x7f) == 0
        let code = (status >> 8) & 0xff
        guard exited else { return failed("signalled " + diagnostics) }
        switch code {
        case 0:
            do {
                let parsed = try parse(stdout, limit: invocation.limit)
                return ProbeRun(outcome: .healthy, events: parsed.events, cursor: parsed.cursor, diagnostics: diagnostics)
            } catch ProbeFailure.invalidOutput(let reason) { return failed("invalid_output: \(reason)") }
            catch { return failed("invalid_output") }
        case 75: return ProbeRun(outcome: .backoff, events: [], cursor: nil, diagnostics: diagnostics)
        case 77: return ProbeRun(outcome: .authenticationNeeded, events: [], cursor: nil, diagnostics: diagnostics)
        default: return failed("exit \(code) " + diagnostics)
        }
    }

    private static func drain(_ descriptor: Int32, limit: Int, overflow: (() -> Void)?) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var exceeded = false
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            if !exceeded {
                data.append(contentsOf: buffer.prefix(count))
                if data.count > limit { exceeded = true; overflow?() }
            }
        }
        close(descriptor)
        return data
    }

    /// SHA-256 of an executable (and a script it interprets). A changed file pauses the source
    /// until a person approves the new hash.
    public static func contentHash(of paths: [String]) throws -> String {
        var hasher = SHA256()
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path) else { throw ProbeFailure.invalidOutput("unreadable_\(path)") }
            hasher.update(Array(path.utf8) + [0])
            hasher.update(Array(data))
            hasher.update([0])
        }
        return hasher.finalize()
    }
}

private final class ProbeOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

private final class ProbeKiller: @unchecked Sendable {
    private let lock = NSLock()
    private let pid: pid_t
    private var timedOut = false
    init(pid: pid_t) { self.pid = pid }
    var expired: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    func expire() { lock.lock(); timedOut = true; lock.unlock(); kill() }
    func kill() {
        #if canImport(Darwin)
        _ = Darwin.kill(-pid, SIGKILL)
        #else
        _ = Glibc.kill(-pid, SIGKILL)
        #endif
    }
}

/// FIPS 180-4 SHA-256. Foundation has no digest on Linux and the controller takes no
/// dependencies, so the approval hash is computed here.
struct SHA256 {
    private var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var pending: [UInt8] = []
    private var length: UInt64 = 0
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

    mutating func update(_ bytes: [UInt8]) {
        length &+= UInt64(bytes.count)
        pending += bytes
        var offset = 0
        while pending.count - offset >= 64 { compress(pending[offset..<offset + 64]); offset += 64 }
        pending.removeFirst(offset)
    }
    mutating func finalize() -> String {
        let bits = length &* 8
        var tail: [UInt8] = [0x80]
        while (pending.count + tail.count) % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8((bits >> UInt64(shift)) & 0xff)) }
        pending += tail
        var offset = 0
        while offset < pending.count { compress(pending[offset..<offset + 64]); offset += 64 }
        pending = []
        return state.map { String(format: "%08x", $0) }.joined()
    }
    private mutating func compress(_ block: ArraySlice<UInt8>) {
        var w = [UInt32](repeating: 0, count: 64)
        let base = block.startIndex
        for i in 0..<16 {
            w[i] = UInt32(block[base + 4 * i]) << 24 | UInt32(block[base + 4 * i + 1]) << 16 |
                UInt32(block[base + 4 * i + 2]) << 8 | UInt32(block[base + 4 * i + 3])
        }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var (a, b, c, d, e, f, g, h) = (state[0], state[1], state[2], state[3], state[4], state[5], state[6], state[7])
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let choice = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ choice &+ Self.k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ majority
            (h, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }
}
