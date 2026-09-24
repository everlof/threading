import Foundation

/// The small, filesystem-only part of Codex session discovery. A rollout is authoritative only
/// when its first record identifies the launch directory and exactly one recent file matches.
enum CodexRolloutIdentity {
    private struct Header: Decodable {
        let type: String
        let payload: Payload

        struct Payload: Decodable {
            let id: TranscriptID
            let cwd: String
        }
    }

    /// Scan only launch-adjacent day directories and a bounded number of entries. The caller
    /// performs polling off the UI thread; an ambiguous result must remain awaitingIdentifier.
    static func find(projectPath: String, sessionsDirectory: URL, launchedAt: Date) -> TranscriptID? {
        let cutoff = launchedAt.addingTimeInterval(-CodexDiscoveryDefaults.clockSlack)
        let project = normalized(projectPath)
        var match: TranscriptID?
        var visited = 0
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = utc.dateComponents([.year, .month, .day], from: launchedAt)
        guard let day = utc.date(from: components) else { return nil }

        for offset in -1...1 {
            guard let date = utc.date(byAdding: .day, value: offset, to: day) else { continue }
            let parts = utc.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            let directory = sessionsDirectory
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
            guard let files = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { continue }
            while let file = files.nextObject() as? URL {
                visited += 1
                guard visited <= CodexDiscoveryDefaults.maximumDailyFiles else { return nil }
                guard file.pathExtension == CodexDiscoveryDefaults.rolloutExtension,
                      file.lastPathComponent.hasPrefix(CodexDiscoveryDefaults.rolloutPrefix),
                      let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
                      created >= cutoff,
                      let header = header(at: file),
                      header.type == CodexDiscoveryDefaults.sessionMetaType,
                      normalized(header.payload.cwd) == project,
                      header.payload.id.isSafePathComponent else { continue }
                if match != nil { return nil }
                match = header.payload.id
            }
        }
        return match
    }

    private static func header(at file: URL) -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: CodexDiscoveryDefaults.headerReadLimit),
              let newline = data.firstIndex(of: 10) else { return nil }
        return try? JSONDecoder().decode(Header.self, from: data.prefix(upTo: newline))
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
