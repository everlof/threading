import Foundation

/// Serial append-only persistence for long-term limit history. Daily JSONL files contain only
/// normalized percentages, reset times, labels and credit count/expiry—not credentials or chat.
actor UsageLimitHistoryJournal {
    private struct Record: Codable {
        let schemaVersion: Int
        let sample: UsageSample?
        let reset: UsageLimitResetEvent?
    }

    private let directory: URL
    private let fileManager = FileManager.default
    private var loadedSnapshot: UsageLimitHistorySnapshot?

    init(directory: URL) {
        self.directory = directory
    }

    func load(now: Date) -> UsageLimitHistorySnapshot {
        if let loadedSnapshot { return loadedSnapshot }
        prepareDirectory()
        pruneFiles(now: now)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let cutoff = now.addingTimeInterval(
            -TimeInterval(UsageLimitHistoryDefaults.retentionDays) * 86_400
        )
        let urls = ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )) ?? []).filter(Self.isJournalFile).sorted { $0.lastPathComponent < $1.lastPathComponent }

        var samples: [UsageSample] = []
        var resets: [UsageLimitResetEvent] = []
        var resetIDs = Set<String>()
        var count = 0

        for url in urls where count < UsageLimitHistoryDefaults.maximumLoadedRecords {
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ]), values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= UsageLimitHistoryDefaults.maximumDailyFileBytes,
                  let data = try? BoundedFileReader.read(
                    url,
                    maximumBytes: UsageLimitHistoryDefaults.maximumDailyFileBytes
                  ) else { continue }

            for line in data.split(separator: 0x0A)
                where count < UsageLimitHistoryDefaults.maximumLoadedRecords {
                guard let record = try? decoder.decode(Record.self, from: Data(line)),
                      record.schemaVersion == 1 else { continue }
                count += 1
                if let sample = record.sample,
                   sample.at >= cutoff, sample.at <= now.addingTimeInterval(5 * 60),
                   sample.fraction.isFinite {
                    samples.append(sample)
                }
                if let reset = record.reset,
                   reset.detectedAt >= cutoff, reset.detectedAt <= now.addingTimeInterval(5 * 60),
                   resetIDs.insert(reset.id).inserted {
                    resets.append(reset)
                }
            }
        }

        let snapshot = UsageLimitHistorySnapshot(
            samples: samples.sorted { $0.at < $1.at },
            resets: resets.sorted { $0.detectedAt < $1.detectedAt },
            loadedAt: now
        )
        loadedSnapshot = snapshot
        return snapshot
    }

    func append(
        samples: [UsageSample],
        resets: [UsageLimitResetEvent],
        now: Date
    ) throws {
        var snapshot = load(now: now)
        let records = samples.map { Record(schemaVersion: 1, sample: $0, reset: nil) }
            + resets.map { Record(schemaVersion: 1, sample: nil, reset: $0) }
        let grouped = Dictionary(grouping: records) { record in
            Self.dayKey(record.sample?.at ?? record.reset?.detectedAt ?? now)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        for (day, dayRecords) in grouped {
            let url = directory.appendingPathComponent("limits-\(day).jsonl")
            var data = Data()
            for record in dayRecords {
                data.append(try encoder.encode(record))
                data.append(0x0A)
            }
            try append(data, to: url)
        }

        snapshot = UsageLimitHistorySnapshot(
            samples: (snapshot.samples + samples).sorted { $0.at < $1.at },
            resets: deduplicated(snapshot.resets + resets),
            loadedAt: now
        )
        loadedSnapshot = trimmed(snapshot, now: now)
        pruneFiles(now: now)
    }

    func deleteHistory() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            loadedSnapshot = .empty
            return
        }
        for url in urls where Self.isJournalFile(url) {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try? fileManager.removeItem(at: url)
        }
        loadedSnapshot = .empty
    }

    private func append(_ data: Data, to url: URL) throws {
        prepareDirectory()
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else { throw CocoaError(.fileWriteUnknown) }
        }

        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let current = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard data.count <= UsageLimitHistoryDefaults.maximumDailyFileBytes,
              current >= 0,
              current <= UsageLimitHistoryDefaults.maximumDailyFileBytes - data.count else {
            throw CocoaError(.fileWriteOutOfSpace)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func prepareDirectory() {
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func pruneFiles(now: Date) {
        let cutoff = now.addingTimeInterval(
            -TimeInterval(UsageLimitHistoryDefaults.retentionDays) * 86_400
        )
        let cutoffDay = Self.dayKey(cutoff)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) else { return }
        for url in urls where Self.isJournalFile(url) {
            let name = url.deletingPathExtension().lastPathComponent
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true,
                  name.hasPrefix("limits-"),
                  String(name.dropFirst("limits-".count)) < cutoffDay else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private func trimmed(
        _ snapshot: UsageLimitHistorySnapshot,
        now: Date
    ) -> UsageLimitHistorySnapshot {
        let cutoff = now.addingTimeInterval(
            -TimeInterval(UsageLimitHistoryDefaults.retentionDays) * 86_400
        )
        return UsageLimitHistorySnapshot(
            samples: Array(snapshot.samples.filter { $0.at >= cutoff }
                .suffix(UsageLimitHistoryDefaults.maximumLoadedRecords)),
            resets: snapshot.resets.filter { $0.detectedAt >= cutoff },
            loadedAt: now
        )
    }

    private func deduplicated(_ resets: [UsageLimitResetEvent]) -> [UsageLimitResetEvent] {
        var seen = Set<String>()
        return resets.filter { seen.insert($0.id).inserted }.sorted { $0.detectedAt < $1.detectedAt }
    }

    private static func isJournalFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("limits-") && url.pathExtension == "jsonl"
    }

    private static func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04lld-%02lld-%02lld",
            Int64(values.year ?? 0),
            Int64(values.month ?? 0),
            Int64(values.day ?? 0)
        )
    }
}
