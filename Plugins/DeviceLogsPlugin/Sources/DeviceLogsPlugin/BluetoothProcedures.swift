import Foundation
import ThreadingDesignKit

/// Operations that span connections — a firmware update above all — told as one story per try.
///
/// A DFU is a dozen exchanges over two or three links: the app asks the device to reboot into its
/// bootloader, the link drops, the bootloader advertises (often under another address), the phone
/// connects again, the image goes over in objects or pages, the device validates and reboots, and
/// the app reconnects to a new firmware. When it fails, the reason is one line somewhere in
/// thousands of packets, on a connection the capture names differently from the device.
///
/// Two declarations make that legible, both plain YAML with nothing product-specific:
///
/// - `identities:` says how a device comes back as something else (`address: +1`, advertising a
///   service), so the bootloader joins the device it came from and rows say `Kronaby (bootloader)`.
/// - `procedures:` names the triggers that start a try, its steps, and what success and failure
///   look like. Each try becomes an attempt with a timeline: its steps, and — automatically — every
///   link event, error, transfer progress, checksum verdict and firmware read on the device's
///   connections while it runs. Attempts are kept on this Mac (`bluetooth-procedures.json`) so a
///   failure can be read after the fact, and the end of each try is a row that says how it ended
///   and why.
extension BluetoothPacketDefinitions {
    /// Something the link itself did, for triggers that are not packets.
    enum ProcedureEvent: String, Sendable, CaseIterable {
        case connected, disconnected
        case firmwareChanged = "firmware-changed"
        case encryptionFailed = "encryption-failed"
        case serviceChanged = "service-changed"
    }

    /// A packet (an endpoint) or a link event, optionally on one role of the device and only after
    /// a named step of the same try.
    struct Trigger: Sendable {
        let endpoint: Endpoint?
        let event: ProcedureEvent?
        /// `as: bootloader` — only on the connection that joined under that role; `as: device`
        /// only on the device's own address.
        let role: String?
        /// Only once this step has been seen in the attempt.
        let after: String?
        /// How the timeline names it when the trigger has no name of its own.
        let label: String
    }

    struct Procedure: Sendable {
        let name: String
        let start: [Trigger]
        let steps: [(name: String, trigger: Trigger)]
        let success: [Trigger]
        let failure: [Trigger]
        /// An attempt with no activity for this long is abandoned.
        let idle: Double
        /// After success, how long to keep collecting (the reconnect, the firmware read) before
        /// the attempt is closed.
        let settle: Double
    }

    /// `identities:` — a device that comes back under another address or name.
    struct IdentityRule: Sendable {
        enum Address: String, Sendable {
            case same
            case plusOne = "+1"
            case any
        }
        /// The role the new connection plays (`bootloader`).
        let name: String
        let after: Trigger
        let address: Address
        /// Service UUIDs the successor advertises, any of which identifies it.
        let advertises: [String]
        /// A glob over its advertised name (`DfuTarg*`).
        let advertisedName: String?
        let within: Double
    }
}

// MARK: - History

/// What procedures recorded, kept across captures. Bounded: 64 attempts, 256 entries each (the
/// middle of a long one is elided, never its start or end).
struct BluetoothProcedureHistory: Sendable, Equatable, Codable {
    enum Limits {
        static let attempts = 64
        static let entries = 256
        static let keptAtStart = 96
        static let bytes = 8 * 1_024 * 1_024
    }

    enum Outcome: String, Sendable, Codable {
        case running
        case completed
        /// Completed, and the device came back on the same firmware.
        case unchanged
        case failed
        case abandoned
    }

    struct Entry: Sendable, Equatable, Codable {
        var time: Date
        var text: String
        var level: String
        /// A repeated step folds into one entry: how many, and when the last was.
        var count: Int = 1
        var last: Date?
    }

    struct Attempt: Sendable, Equatable, Codable {
        var procedure: String
        var number: Int
        var device: String
        var started: Date
        var ended: Date?
        var outcome: Outcome = .running
        /// One line on why it ended the way it did.
        var reason: String?
        var firmwareBefore: String?
        var firmwareAfter: String?
        var steps: [String] = []
        var entries: [Entry] = []
        var omitted = 0

        mutating func add(_ text: String, level: BluetoothSeverity, at time: Date, step: Bool = false) {
            if step, let last = entries.last, last.text == text {
                entries[entries.count - 1].count += 1
                entries[entries.count - 1].last = time
                return
            }
            entries.append(Entry(time: time, text: text, level: level.level))
            if entries.count > Limits.entries {
                entries.remove(at: Limits.keptAtStart)
                omitted += 1
            }
        }
    }

    var version = 1
    private(set) var attempts: [Attempt] = []
    /// The last attempt number per procedure, so numbers keep counting across captures.
    private(set) var counters: [String: Int] = [:]

    mutating func begin(_ attempt: Attempt) -> Int {
        var attempt = attempt
        attempt.number = (counters[attempt.procedure] ?? 0) + 1
        counters[attempt.procedure] = attempt.number
        attempts.append(attempt)
        if attempts.count > Limits.attempts { attempts.removeFirst() }
        return attempts.count - 1
    }

    mutating func update(_ index: Int, _ change: (inout Attempt) -> Void) {
        guard attempts.indices.contains(index) else { return }
        change(&attempts[index])
    }

    func attempt(_ index: Int) -> Attempt? { attempts.indices.contains(index) ? attempts[index] : nil }

    /// Where the pane, the agent tool and the next capture read it.
    static var defaultURL: URL {
        BluetoothLearnedEnums.defaultURL.deletingLastPathComponent().appendingPathComponent("bluetooth-procedures.json")
    }

    static func load(from url: URL = defaultURL) -> BluetoothProcedureHistory {
        guard let data = try? BoundedFileReader.read(url, maximumBytes: Limits.bytes) else { return .init() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var history = try? decoder.decode(BluetoothProcedureHistory.self, from: data) else { return .init() }
        history.attempts = Array(history.attempts.suffix(Limits.attempts))
        // A capture that ended mid-try never closed it; it is not still running.
        for index in history.attempts.indices where history.attempts[index].outcome == .running {
            history.attempts[index].outcome = .abandoned
            history.attempts[index].reason = history.attempts[index].reason ?? "the capture ended during this try"
        }
        return history
    }

    func save(to url: URL = defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - Reading it

enum BluetoothProcedureFormatting {
    /// `DFU #3 · Kronaby · failed after 2 min 14 s — Disconnected Kronaby (bootloader): Connection Timeout`
    static func headline(_ attempt: BluetoothProcedureHistory.Attempt, now: Date = Date()) -> String {
        let duration = BluetoothFlowState.duration((attempt.ended ?? now).timeIntervalSince(attempt.started))
        var text = "\(attempt.procedure) #\(attempt.number) · \(attempt.device) · "
        switch attempt.outcome {
        case .running: text += "running for \(duration)"
        case .completed: text += "completed in \(duration)"
        case .unchanged: text += "completed in \(duration), but the firmware did not change"
        case .failed: text += "failed after \(duration)"
        case .abandoned: text += "abandoned after \(duration)"
        }
        if let reason = attempt.reason { text += " — \(reason)" }
        return text
    }

    /// The whole attempt as text: a headline, the facts, then the timeline with offsets from the
    /// start, so it reads the same pasted into an issue as it does in the panel.
    static func timeline(_ attempt: BluetoothProcedureHistory.Attempt, now: Date = Date()) -> String {
        var lines = [headline(attempt, now: now)]
        let stamp = dateFormatter.string(from: attempt.started)
        var facts = ["started \(stamp)"]
        switch (attempt.firmwareBefore, attempt.firmwareAfter) {
        case let (before?, after?): facts.append("firmware \(before) → \(after)")
        case let (before?, nil): facts.append("firmware \(before) → not read after")
        case let (nil, after?): facts.append("firmware → \(after)")
        default: break
        }
        if !attempt.steps.isEmpty { facts.append("steps: " + attempt.steps.joined(separator: " → ")) }
        lines.append("  " + facts.joined(separator: " · "))
        for (index, entry) in attempt.entries.enumerated() {
            if index == BluetoothProcedureHistory.Limits.keptAtStart, attempt.omitted > 0 {
                lines.append("  … \(attempt.omitted) entries omitted …")
            }
            let offset = offset(entry.time.timeIntervalSince(attempt.started))
            var text = "  \(offset)  " + (entry.level == "Info" ? "" : "\(entry.level.uppercased()): ") + entry.text
            if entry.count > 1, let last = entry.last {
                text += " ×\(entry.count) (last \(Self.offset(last.timeIntervalSince(attempt.started))))"
            }
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    static func all(_ history: BluetoothProcedureHistory, last: Int = BluetoothProcedureHistory.Limits.attempts) -> String {
        guard !history.attempts.isEmpty else { return "" }
        return history.attempts.suffix(last).reversed().map { timeline($0) }.joined(separator: "\n\n")
    }

    private static func offset(_ seconds: TimeInterval) -> String {
        let text = String(format: "+%.3f s", max(0, seconds))
        return text.count < 11 ? String(repeating: " ", count: 11 - text.count) + text : text
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm:ss"
        return formatter
    }()
}

// MARK: - Runtime

/// The procedures in progress, by device family (the device and every identity it came back as).
struct BluetoothProcedureState {
    enum Limits {
        static let identityWatches = 8
    }

    /// What happened, as the procedures see it.
    struct Signal {
        enum Kind {
            /// An app value: its characteristic, operation and decode.
            case value(characteristic: String, operation: BluetoothPacketDefinitions.Operation?,
                       decoded: BluetoothPacketDefinitions.Decoded)
            case event(BluetoothPacketDefinitions.ProcedureEvent)
            /// Anything else worth the timeline: link facts, errors, transfer progress.
            case note
        }
        let kind: Kind
        let family: String
        let device: String
        let role: String?
        let text: String
        let level: BluetoothSeverity
        let time: Double
    }

    private struct Open {
        let procedure: Int
        let index: Int
        var seen: Set<String> = []
        var last: Double
        /// Success was seen; collecting until this time.
        var settleUntil: Double?
        var rediscovered = false
    }

    var history = BluetoothProcedureHistory()
    private(set) var revision = 0
    private var open: [String: Open] = [:]
    /// The firmware each family last reported, to tell a change from a first read.
    private var firmware: [String: String] = [:]

    /// Feeds one signal; returns rows for attempts that started or ended.
    mutating func observe(
        _ signal: Signal, definitions: BluetoothPacketDefinitions,
        resolve: (Int64) -> String?, names: (String, Int64) -> String?
    ) -> [BluetoothFlowState.Row] {
        guard !definitions.procedures.isEmpty else { return [] }
        var rows: [BluetoothFlowState.Row] = []
        let date = Date(timeIntervalSince1970: signal.time)

        if var current = open[signal.family] {
            let procedure = definitions.procedures[current.procedure]
            current.last = signal.time
            var recorded = false
            func record(_ text: String, _ level: BluetoothSeverity, step: Bool = false) {
                recorded = true
                history.update(current.index) { $0.add(text, level: level, at: date, step: step) }
            }
            if let step = procedure.steps.first(where: { fires($0.trigger, signal, current.seen, resolve, names) }) {
                if !current.seen.contains(step.name) {
                    current.seen.insert(step.name)
                    history.update(current.index) { $0.steps.append(step.name) }
                }
                record("\(step.name): \(signal.text)", max(signal.level, .info), step: true)
            }
            if current.settleUntil == nil, procedure.success.contains(where: { fires($0, signal, current.seen, resolve, names) }) {
                record("success: \(signal.text)", .info)
                current.settleUntil = signal.time + procedure.settle
            } else if current.settleUntil == nil,
                      let failure = procedure.failure.first(where: { fires($0, signal, current.seen, resolve, names) }) {
                record("failure: \(signal.text)", .error)
                open[signal.family] = nil
                revision += 1
                _ = failure
                return [close(current, outcome: .failed, reason: signal.text, at: signal.time)]
            }
            // Another start trigger inside a try is a detail of it (a control-point command).
            if !recorded, procedure.start.contains(where: { fires($0, signal, current.seen, resolve, names) }) {
                record(signal.text, max(signal.level, .info), step: true)
            }
            // Everything that is not a plain app value belongs in the timeline: the link's story,
            // errors and warnings, transfer progress, checksum verdicts.
            if !recorded {
                switch signal.kind {
                case .value: if signal.level >= .warning { record(signal.text, signal.level) }
                case .event, .note: record(signal.text, signal.level)
                }
            }
            open[signal.family] = current
            revision += 1
            return rows
        }

        for (index, procedure) in definitions.procedures.enumerated() {
            guard let trigger = procedure.start.first(where: { fires($0, signal, [], resolve, names) }) else { continue }
            var attempt = BluetoothProcedureHistory.Attempt(
                procedure: procedure.name, number: 0, device: signal.device, started: date,
                firmwareBefore: firmware[signal.family]
            )
            attempt.add("started: \(signal.text)", level: .info, at: date)
            _ = trigger
            let position = history.begin(attempt)
            open[signal.family] = Open(procedure: index, index: position, last: signal.time)
            revision += 1
            let number = history.attempt(position)?.number ?? 0
            rows.append(.init(text: "\(procedure.name) #\(number) started · \(signal.device)", level: .info, incoming: true, procedure: true))
            break
        }
        return rows
    }

    /// A device reported its firmware. A change ends the family's question "did the update take".
    /// Returns whether it differs from what the family reported before.
    mutating func noteFirmware(_ value: String, family: String) -> Bool {
        let known = firmware[family]
        firmware[family] = value
        if let current = open[family] {
            // Read before any step: the firmware being replaced. After a step: the result.
            history.update(current.index) { attempt in
                if attempt.steps.isEmpty { attempt.firmwareBefore = attempt.firmwareBefore ?? value }
                else { attempt.firmwareAfter = value }
            }
            revision += 1
        }
        return known.map { $0 != value } ?? false
    }

    /// The device's GATT table was discovered on a connection of this family.
    mutating func noteDiscovery(family: String) {
        guard var current = open[family], current.settleUntil != nil else { return }
        current.rediscovered = true
        open[family] = current
    }

    /// Attempts idle past their limit, or done settling, are closed by the next packet's time.
    mutating func tick(definitions: BluetoothPacketDefinitions, time: Double) -> [BluetoothFlowState.Row] {
        var rows: [BluetoothFlowState.Row] = []
        for (family, current) in open {
            guard definitions.procedures.indices.contains(current.procedure) else { open[family] = nil; continue }
            let procedure = definitions.procedures[current.procedure]
            if let until = current.settleUntil, time >= until {
                open[family] = nil
                revision += 1
                rows.append(finish(current, at: time))
            } else if current.settleUntil == nil, time - current.last > procedure.idle {
                open[family] = nil
                revision += 1
                let attempt = history.attempt(current.index)
                // Where it got to, in the step's own words ("pages: … PAGE_START page 24 …").
                var last = "never got past its start"
                if let step = attempt?.steps.last {
                    let entry = attempt?.entries.last { $0.text.hasPrefix(step + ": ") }
                    last = "stopped at " + (entry.map { String($0.text.prefix(120)) } ?? step)
                }
                let error = attempt?.entries.last(where: { $0.level == "Error" }).map { " · last error: \($0.text)" } ?? ""
                rows.append(close(current, outcome: .abandoned,
                                  reason: "\(last), nothing for \(BluetoothFlowState.duration(procedure.idle))\(error)",
                                  at: current.last))
            }
        }
        return rows
    }

    mutating func clear() {
        history = BluetoothProcedureHistory()
        open = [:]
        revision += 1
    }

    /// The family's attempt name, for rows inside a try ("DFU #3").
    func running(family: String) -> String? {
        guard let current = open[family], let attempt = history.attempt(current.index) else { return nil }
        return "\(attempt.procedure) #\(attempt.number)"
    }

    private mutating func finish(_ current: Open, at time: Double) -> BluetoothFlowState.Row {
        guard let attempt = history.attempt(current.index) else { return close(current, outcome: .completed, reason: nil, at: time) }
        if let before = attempt.firmwareBefore, let after = attempt.firmwareAfter, before == after {
            return close(current, outcome: .unchanged, reason: "the device came back on \(after)", at: time)
        }
        var reason: String?
        if let before = attempt.firmwareBefore, let after = attempt.firmwareAfter {
            reason = "firmware \(before) → \(after)"
        } else if attempt.firmwareAfter == nil {
            reason = "the new firmware revision was not read in this capture"
        }
        if attempt.firmwareAfter != nil, !current.rediscovered {
            history.update(current.index) {
                $0.add("no GATT discovery after the firmware changed: the phone may still be using its cached table",
                       level: .warning, at: Date(timeIntervalSince1970: time))
            }
        }
        return close(current, outcome: .completed, reason: reason, at: time)
    }

    private mutating func close(
        _ current: Open, outcome: BluetoothProcedureHistory.Outcome, reason: String?, at time: Double
    ) -> BluetoothFlowState.Row {
        history.update(current.index) {
            $0.outcome = outcome
            $0.reason = reason
            $0.ended = Date(timeIntervalSince1970: time)
        }
        let attempt = history.attempt(current.index)
        let level: BluetoothSeverity = switch outcome {
        case .completed, .running: .info
        case .unchanged, .abandoned: .warning
        case .failed: .error
        }
        return .init(text: attempt.map { BluetoothProcedureFormatting.headline($0) } ?? outcome.rawValue, level: level, incoming: true, procedure: true)
    }

    private func fires(
        _ trigger: BluetoothPacketDefinitions.Trigger, _ signal: Signal, _ seen: Set<String>,
        _ resolve: (Int64) -> String?, _ names: (String, Int64) -> String?
    ) -> Bool {
        trigger.fires(on: signal, seen: seen, resolve: resolve, names: names)
    }
}

extension BluetoothPacketDefinitions.Trigger {
    func fires(
        on signal: BluetoothProcedureState.Signal, seen: Set<String> = [],
        resolve: (Int64) -> String?, names: (String, Int64) -> String?
    ) -> Bool {
        if let after, !seen.contains(after) { return false }
        if let role, role != (signal.role ?? BluetoothPacketDefinitions.deviceRole) { return false }
        switch signal.kind {
        case .value(let characteristic, let operation, let decoded):
            guard let endpoint else { return false }
            return endpoint.evaluate(characteristic: characteristic, operation: operation, decoded: decoded,
                                     resolve: resolve, names: names) != nil
        case .event(let event):
            return self.event == event
        case .note:
            return false
        }
    }
}

extension BluetoothPacketDefinitions {
    /// The role of a connection on the device's own address, for `as: device`.
    static let deviceRole = "device"
}
