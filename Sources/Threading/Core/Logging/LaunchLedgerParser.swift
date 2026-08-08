import Foundation

// MARK: - Launch Ledger Parse

/// What reading the bytes concluded, before anything is done about it.
///
/// Separated from `LaunchLedger` so the whole read is a pure function of a `Data`: every fixture
/// in the matrix — a torn last line, a newer format, an interior lie — is a literal in a test
/// rather than a file someone had to damage convincingly.
enum LaunchLedgerParse: Equatable {
    case valid(LaunchLedgerHistory)
    case unsupportedVersion(newestFormatSeen: Int)
    case corrupt
}

// MARK: - Launch Ledger Parser

enum LaunchLedgerParser {

    /// Reads the file's lines into launches.
    ///
    /// Three rules carry it:
    ///
    /// - **A torn *final* line is expected, not damage.** A process that died between two writes
    ///   leaves exactly that, and it is the signature this file exists to record rather than a
    ///   reason to distrust everything above it. A line that fails anywhere else did not come
    ///   from a death mid-write, so it is damage.
    /// - **A newer format wins over damage.** A file holding records from a later Threading is
    ///   left alone even if this build also dislikes something else in it: quarantining would
    ///   mean a downgrade confiscated history it merely cannot read.
    /// - **A record naming a launch with no `begin` is dropped and counted.** Reset Everything
    ///   moves the directory aside under a running app, whose next write recreates the file
    ///   holding nothing but an ending.
    static func parse(_ data: Data) -> LaunchLedgerParse {
        let endsWithNewline = data.last == LaunchLedgerParserDefaults.newline
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }

        var history = LaunchLedgerHistory()
        var indexByLaunch: [String: Int] = [:]
        var newestFormatSeen = 0
        var foundDamage = false
        let decoder = JSONDecoder()

        for (offset, line) in lines.enumerated() {
            let isFinal = offset == lines.count - 1 && !endsWithNewline
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            guard let bytes = trimmed.data(using: .utf8) else {
                foundDamage = true
                continue
            }

            // The version first and on its own, because a record this build cannot read must be
            // skippable without its unknown fields being decoded at all.
            guard let probe = try? decoder.decode(LaunchLedgerVersionProbe.self, from: bytes) else {
                if isFinal { history.droppedTrailingPartial = true } else { foundDamage = true }
                continue
            }

            guard probe.version <= LaunchLedgerDefaults.formatVersion else {
                newestFormatSeen = max(newestFormatSeen, probe.version)
                continue
            }

            guard let record = try? decoder.decode(LaunchLedgerRecord.self, from: bytes) else {
                if isFinal { history.droppedTrailingPartial = true } else { foundDamage = true }
                continue
            }

            history.records.append(record)
            absorb(record, into: &history, indexByLaunch: &indexByLaunch)
        }

        if newestFormatSeen > LaunchLedgerDefaults.formatVersion {
            return .unsupportedVersion(newestFormatSeen: newestFormatSeen)
        }
        if foundDamage { return .corrupt }
        return .valid(history)
    }

    // MARK: - Private Methods

    private static func absorb(
        _ record: LaunchLedgerRecord,
        into history: inout LaunchLedgerHistory,
        indexByLaunch: inout [String: Int]
    ) {
        switch record.kind {
        case .begin:
            // A second `begin` for one id cannot be a second launch — ids are minted per launch —
            // so the first one stands and this is counted rather than allowed to overwrite it.
            guard indexByLaunch[record.launch] == nil else {
                history.unattachedRecordCount += 1
                return
            }
            indexByLaunch[record.launch] = history.launches.count
            history.launches.append(LaunchLedgerLaunch(
                id: record.launch,
                startedAt: LaunchLedger.timestampFormatter.date(from: record.at),
                uptime: record.uptime,
                bootID: record.boot,
                fingerprint: record.fingerprint ?? "",
                mode: record.mode.flatMap(LaunchMode.init(rawValue:)) ?? .normal
            ))

        case .checkpoint:
            guard let index = indexByLaunch[record.launch] else {
                history.unattachedRecordCount += 1
                return
            }
            // An unrecognised checkpoint name is a record from a build that knows one more than
            // this one does. It is not damage, and it is not a checkpoint this build can reason
            // about, so it is dropped from the trail and the launch keeps everything else.
            guard let checkpoint = record.checkpoint.flatMap(StartupCheckpoint.init(rawValue:))
            else { return }
            history.launches[index].checkpoints.append(checkpoint)

        case .end, .outcome:
            guard let index = indexByLaunch[record.launch] else {
                history.unattachedRecordCount += 1
                return
            }
            // The first ending stands. An `end` written on the way out and an `outcome` written
            // by a successor can both exist when the ending reached disk and the marker did not,
            // and the one the dying process wrote about itself is the better witness.
            guard history.launches[index].ending == nil else { return }
            history.launches[index].ending = LaunchEnding(
                disposition: LaunchDisposition(token: record.disposition ?? ""),
                systemInitiated: record.systemInitiated ?? false
            )
        }
    }
}

// MARK: - Version Probe

/// Just enough of a record to decide whether the rest of it may be read.
private struct LaunchLedgerVersionProbe: Decodable {
    let version: Int
}

// MARK: - Launch Ledger Parser Defaults

enum LaunchLedgerParserDefaults {
    static let newline: UInt8 = 0x0A
}
