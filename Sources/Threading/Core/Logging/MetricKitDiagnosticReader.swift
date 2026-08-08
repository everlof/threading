import Foundation

// MARK: - Storage Layout

/// Where `MetricKitDiagnostics` writes, named once so the reader is not guessing at the writer.
///
/// The two sides are deliberately separate types — the writer runs on a serial queue during a real
/// app launch, the reader runs once when someone asks for a support report — but they must agree
/// on exactly one directory, and a string typed twice is how that agreement quietly ends.
enum MetricKitStorage {
    static let performanceDirectoryName = "Performance"
    static let rootDirectoryName = "MetricKit"
    static let metricsDirectoryName = "metrics"
    static let diagnosticsDirectoryName = "diagnostics"
    static let payloadExtension = "json"
}

/// What one read of the persisted payloads is allowed to cost.
///
/// The writer already prunes to `reportLimit` files, so in the ordinary case none of these bind.
/// They are here because a budget enforced only by the *other* side of a boundary is not a budget:
/// a corrupted cap, a directory someone copied files into, or a payload Apple grows by an order of
/// magnitude would otherwise make a menu command read whatever it found.
enum MetricKitReadBudget {
    /// A little above the writer's 20 so a payload delivered between a write and its prune is
    /// still counted, and a hard stop past that. Newest files win.
    static let maximumPayloadFiles = 24

    /// One payload is normally tens of kilobytes; call-stack trees are what make the tail long.
    /// A file past this is reported as unreadable rather than parsed, because refusing to answer
    /// is cheaper than an unbounded parse and more honest than pretending the file was not there.
    static let maximumPayloadBytes = 4 * 1024 * 1024

    /// Each identifying fact is one token in a support field. Apple writes these, not the user,
    /// but a bound plus a sanitizer is what keeps that true whatever a later macOS emits.
    static let maximumTokenCharacters = 48
}

// MARK: - Typed Reading

/// What a read of the persisted MetricKit diagnostics found.
///
/// Four answers rather than two, for the reason `docs/architecture/reliability-and-type-safety.md`
/// states: "MetricKit has never delivered here", "it delivered nothing worth recording" and "there
/// are payloads on disk this build could not parse" are different facts about the machine, and
/// collapsing the last one into an empty result is how a support report says *no crash was seen*
/// about a Mac that crashed.
enum MetricKitDiagnosticReading: Equatable, Sendable {

    /// The directory does not exist: MetricKit has never delivered a diagnostic payload here.
    case noDirectory

    /// The directory exists and holds no payload files.
    case empty

    /// At least one payload parsed. `summary.unreadablePayloadCount` carries the ones beside it
    /// that did not, so a partially damaged directory still reports what it knows.
    case read(MetricKitDiagnosticSummary)

    /// Payload files exist and none of them could be read. `payloadFiles == 0` is the narrower
    /// case where the directory itself could not be listed, which is not an empty directory.
    case unreadable(payloadFiles: Int)
}

/// The share-safe shape of what MetricKit saw: counts, a covered window, and the few identifying
/// facts of the most recent crash. Never a call tree, a stack frame or an address.
struct MetricKitDiagnosticSummary: Equatable, Sendable {
    /// Payload files that parsed. The counts below are over exactly these.
    let payloadCount: Int

    /// Payload files that did not parse — truncated, or written in a shape this build does not
    /// recognise. Kept apart from `skippedPayloadCount` because one is damage and the other is a
    /// budget, and a support report that conflated them would report damage that is not there.
    let unreadablePayloadCount: Int

    /// Payload files past `MetricKitReadBudget.maximumPayloadFiles`, oldest first. Normally zero:
    /// the writer prunes below this. A non-zero value says the window below is not the whole
    /// directory.
    let skippedPayloadCount: Int

    let crashCount: Int
    let hangCount: Int
    let cpuExceptionCount: Int
    let diskWriteExceptionCount: Int

    /// The span the readable payloads cover, which is not the span the app ran for: MetricKit
    /// aggregates a prior period and makes no delivery guarantee.
    let coveredFrom: Date?
    let coveredTo: Date?

    let mostRecentCrash: MetricKitCrashFacts?

    init(
        payloadCount: Int,
        unreadablePayloadCount: Int,
        skippedPayloadCount: Int,
        crashCount: Int,
        hangCount: Int,
        cpuExceptionCount: Int,
        diskWriteExceptionCount: Int,
        coveredFrom: Date?,
        coveredTo: Date?,
        mostRecentCrash: MetricKitCrashFacts?
    ) {
        self.payloadCount = payloadCount
        self.unreadablePayloadCount = unreadablePayloadCount
        self.skippedPayloadCount = skippedPayloadCount
        self.crashCount = crashCount
        self.hangCount = hangCount
        self.cpuExceptionCount = cpuExceptionCount
        self.diskWriteExceptionCount = diskWriteExceptionCount
        self.coveredFrom = coveredFrom
        self.coveredTo = coveredTo
        self.mostRecentCrash = mostRecentCrash
    }
}

/// Enough to tell a support conversation *whether MetricKit saw the crash*, and nothing that would
/// need reading before the report is sent. Every string here has already been reduced to one
/// bounded token by the reader, so no consumer can pass an OS-authored sentence through untouched.
struct MetricKitCrashFacts: Equatable, Sendable {
    let appVersion: String?
    let appBuildVersion: String?
    let exceptionType: Int?
    let exceptionCode: Int?
    let signal: Int?
    let terminationReason: String?

    init(
        appVersion: String?,
        appBuildVersion: String?,
        exceptionType: Int?,
        exceptionCode: Int?,
        signal: Int?,
        terminationReason: String?
    ) {
        self.appVersion = appVersion
        self.appBuildVersion = appBuildVersion
        self.exceptionType = exceptionType
        self.exceptionCode = exceptionCode
        self.signal = signal
        self.terminationReason = terminationReason
    }

    var isEmpty: Bool {
        appVersion == nil && appBuildVersion == nil && exceptionType == nil
            && exceptionCode == nil && signal == nil && terminationReason == nil
    }
}

// MARK: - Reader

/// Reads back what `MetricKitDiagnostics` persisted.
///
/// The payloads were written by whatever macOS version happened to be running, and Apple's
/// `jsonRepresentation` has changed shape between releases — scalars that were numbers have
/// appeared as strings, keys have been added. So this parses defensively: a value whose type moved
/// is read leniently, an unrecognised key is ignored, and a blob that is not a diagnostic payload
/// at all is *counted* rather than skipped.
struct MetricKitDiagnosticReader {

    // MARK: - Properties

    let directory: URL

    // MARK: - Initialization

    /// Defaults to the diagnostics half of the writer's directory. Injectable for the same reason
    /// the writer's is: a test must read a stated fixture, never this Mac's own crash history.
    init(directory: URL? = nil) {
        self.directory = directory ?? MetricKitDiagnostics.defaultDirectory
            .appendingPathComponent(MetricKitStorage.diagnosticsDirectoryName, isDirectory: true)
    }

    // MARK: - Public Methods

    func read() -> MetricKitDiagnosticReading {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .noDirectory
        }

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            // A directory-level read failure is an error, not an empty inventory.
            ThreadingLogger.performance.error(
                "MetricKit diagnostics unreadable: \(error.localizedDescription, privacy: .public)"
            )
            return .unreadable(payloadFiles: 0)
        }

        // The writer names files `<beginEpoch>-<endEpoch>.json`, so the newest sort last. Ordering
        // by name rather than by modification date keeps the budget deterministic even after a
        // copy or a restore has rewritten every timestamp on disk.
        let payloads = contents
            .filter { $0.pathExtension == MetricKitStorage.payloadExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !payloads.isEmpty else { return .empty }

        let considered = Array(payloads.suffix(MetricKitReadBudget.maximumPayloadFiles))
        let skipped = payloads.count - considered.count

        var parsed: [ParsedPayload] = []
        var unreadable = 0
        for url in considered {
            if let payload = parse(url) {
                parsed.append(payload)
            } else {
                unreadable += 1
            }
        }

        if unreadable > 0 {
            ThreadingLogger.performance.error(
                "MetricKit diagnostics: \(unreadable, privacy: .public) payload(s) unreadable"
            )
        }

        guard !parsed.isEmpty else { return .unreadable(payloadFiles: payloads.count) }

        return .read(summary(
            of: parsed,
            unreadablePayloadCount: unreadable,
            skippedPayloadCount: skipped
        ))
    }

    // MARK: - Private Methods

    private func summary(
        of parsed: [ParsedPayload],
        unreadablePayloadCount: Int,
        skippedPayloadCount: Int
    ) -> MetricKitDiagnosticSummary {
        let ordered = parsed.sorted { $0.sortDate < $1.sortDate }

        // Apple documents no order within a payload's own diagnostics array, so "most recent"
        // means the newest payload that carries a crash; the last entry inside it is the closest
        // this format gets to an answer. A crash whose metadata says nothing identifying is
        // stepped over rather than reported as a fact-free field — it is still in `crashCount`.
        let latestCrash = ordered.reversed()
            .compactMap { $0.crashes.last { !$0.isEmpty } }
            .first

        return MetricKitDiagnosticSummary(
            payloadCount: ordered.count,
            unreadablePayloadCount: unreadablePayloadCount,
            skippedPayloadCount: skippedPayloadCount,
            crashCount: ordered.reduce(0) { $0 + $1.crashes.count },
            hangCount: ordered.reduce(0) { $0 + $1.hangCount },
            cpuExceptionCount: ordered.reduce(0) { $0 + $1.cpuExceptionCount },
            diskWriteExceptionCount: ordered.reduce(0) { $0 + $1.diskWriteExceptionCount },
            coveredFrom: ordered.compactMap { $0.began ?? $0.ended }.min(),
            coveredTo: ordered.compactMap { $0.ended ?? $0.began }.max(),
            mostRecentCrash: latestCrash
        )
    }

    private func parse(_ url: URL) -> ParsedPayload? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= MetricKitReadBudget.maximumPayloadBytes else { return nil }

        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(PersistedDiagnosticPayload.self, from: data)
        else {
            return nil
        }

        let fallback = Self.dates(fromFileName: url.deletingPathExtension().lastPathComponent)
        return ParsedPayload(
            began: payload.timeStampBegin?.date ?? fallback?.began,
            ended: payload.timeStampEnd?.date ?? fallback?.ended,
            crashes: (payload.crashDiagnostics ?? []).map { $0.crashFacts },
            hangCount: payload.hangDiagnostics?.count ?? 0,
            cpuExceptionCount: payload.cpuExceptionDiagnostics?.count ?? 0,
            diskWriteExceptionCount: payload.diskWriteExceptionDiagnostics?.count ?? 0
        )
    }

    /// `<beginEpoch>-<endEpoch>` — the writer's own naming, and the one timestamp source that does
    /// not depend on which macOS release formatted the payload.
    private static func dates(fromFileName name: String) -> (began: Date, ended: Date)? {
        let parts = name.split(separator: "-")
        guard parts.count == 2,
              let began = TimeInterval(parts[0]),
              let ended = TimeInterval(parts[1]) else {
            return nil
        }
        return (Date(timeIntervalSince1970: began), Date(timeIntervalSince1970: ended))
    }

    // MARK: - Parsed Shape

    private struct ParsedPayload {
        let began: Date?
        let ended: Date?
        let crashes: [MetricKitCrashFacts]
        let hangCount: Int
        let cpuExceptionCount: Int
        let diskWriteExceptionCount: Int

        var sortDate: Date { ended ?? began ?? .distantPast }
    }
}

// MARK: - Persisted Payload Shape

/// The subset of `MXDiagnosticPayload.jsonRepresentation()` this reads.
///
/// Decoding fails — deliberately — when the blob is not a JSON object or carries none of these
/// keys. That is what separates "a payload whose contents this build does not recognise" from
/// "a truncated or corrupt file", and only the second may be reported as unreadable.
private struct PersistedDiagnosticPayload: Decodable {
    let timeStampBegin: LooseScalar?
    let timeStampEnd: LooseScalar?
    let crashDiagnostics: [PersistedDiagnostic]?
    let hangDiagnostics: [PersistedDiagnostic]?
    let cpuExceptionDiagnostics: [PersistedDiagnostic]?
    let diskWriteExceptionDiagnostics: [PersistedDiagnostic]?

    enum CodingKeys: String, CodingKey {
        case timeStampBegin
        case timeStampEnd
        case crashDiagnostics
        case hangDiagnostics
        case cpuExceptionDiagnostics
        case diskWriteExceptionDiagnostics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard !container.allKeys.isEmpty else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Not a MetricKit diagnostic payload"
            ))
        }
        timeStampBegin = try? container.decodeIfPresent(LooseScalar.self, forKey: .timeStampBegin)
        timeStampEnd = try? container.decodeIfPresent(LooseScalar.self, forKey: .timeStampEnd)
        crashDiagnostics = try? container.decodeIfPresent(
            [PersistedDiagnostic].self, forKey: .crashDiagnostics
        )
        hangDiagnostics = try? container.decodeIfPresent(
            [PersistedDiagnostic].self, forKey: .hangDiagnostics
        )
        cpuExceptionDiagnostics = try? container.decodeIfPresent(
            [PersistedDiagnostic].self, forKey: .cpuExceptionDiagnostics
        )
        diskWriteExceptionDiagnostics = try? container.decodeIfPresent(
            [PersistedDiagnostic].self, forKey: .diskWriteExceptionDiagnostics
        )
    }
}

private struct PersistedDiagnostic: Decodable {
    let diagnosticMetaData: PersistedDiagnosticMetadata?

    var crashFacts: MetricKitCrashFacts {
        MetricKitCrashFacts(
            appVersion: diagnosticMetaData?.appVersion?.token,
            appBuildVersion: diagnosticMetaData?.appBuildVersion?.token,
            exceptionType: diagnosticMetaData?.exceptionType?.integer,
            exceptionCode: diagnosticMetaData?.exceptionCode?.integer,
            signal: diagnosticMetaData?.signal?.integer,
            terminationReason: diagnosticMetaData?.terminationReason?.token
        )
    }
}

/// Only the identifying half of `diagnosticMetaData`. `callStackTree`,
/// `virtualMemoryRegionInfo` and the rest are not decoded at all — the cheapest redaction is the
/// field that was never read.
private struct PersistedDiagnosticMetadata: Decodable {
    let appVersion: LooseScalar?
    let appBuildVersion: LooseScalar?
    let exceptionType: LooseScalar?
    let exceptionCode: LooseScalar?
    let signal: LooseScalar?
    let terminationReason: LooseScalar?

    enum CodingKeys: String, CodingKey {
        case appVersion
        case appBuildVersion
        case exceptionType
        case exceptionCode
        case signal
        case terminationReason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appVersion = try? container.decodeIfPresent(LooseScalar.self, forKey: .appVersion)
        appBuildVersion = try? container.decodeIfPresent(
            LooseScalar.self, forKey: .appBuildVersion
        )
        exceptionType = try? container.decodeIfPresent(LooseScalar.self, forKey: .exceptionType)
        exceptionCode = try? container.decodeIfPresent(LooseScalar.self, forKey: .exceptionCode)
        signal = try? container.decodeIfPresent(LooseScalar.self, forKey: .signal)
        terminationReason = try? container.decodeIfPresent(
            LooseScalar.self, forKey: .terminationReason
        )
    }
}

/// One JSON scalar whose *type* has moved between macOS releases.
///
/// `exceptionType` has been seen as a number and as a string; a timestamp is a string until it is
/// not. A strict `Int` here would throw, and because the throw happens inside the payload's own
/// decode it would discard a perfectly readable crash record over a field nobody needed.
private struct LooseScalar: Decodable {
    let text: String?
    let integer: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            integer = value
            text = String(value)
        } else if let value = try? container.decode(Double.self) {
            integer = value.rounded() == value ? Int(exactly: value.rounded()) : nil
            text = String(value)
        } else if let value = try? container.decode(String.self) {
            integer = Int(value)
            text = value
        } else if let value = try? container.decode(Bool.self) {
            integer = value ? 1 : 0
            text = String(value)
        } else {
            integer = nil
            text = nil
        }
    }

    /// One bounded, path-free token. Apple authors these strings, not the user, but a support
    /// report is only safe by *shape*, so the shape is enforced here rather than assumed.
    var token: String? {
        guard let text else { return nil }
        var reduced = ""
        var lastWasSeparator = true
        for character in text {
            if character.isLetter || character.isNumber || character == "." || character == "_" {
                reduced.append(character)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                reduced.append("-")
                lastWasSeparator = true
            }
            if reduced.count >= MetricKitReadBudget.maximumTokenCharacters { break }
        }
        while reduced.hasSuffix("-") { reduced.removeLast() }
        return reduced.isEmpty ? nil : reduced
    }

    /// MetricKit's own timestamps, in the formats it has used: a space-separated UTC stamp in the
    /// original representation, ISO-8601 with and without fractional seconds since.
    var date: Date? {
        guard let text else { return nil }
        return MetricKitTimestamp.date(from: text)
    }
}

// MARK: - Timestamps

private enum MetricKitTimestamp {

    static func date(from text: String) -> Date? {
        if let date = fractional.date(from: text) { return date }
        if let date = internetDateTime.date(from: text) { return date }
        return spaceSeparated.date(from: text)
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let internetDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let spaceSeparated: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
