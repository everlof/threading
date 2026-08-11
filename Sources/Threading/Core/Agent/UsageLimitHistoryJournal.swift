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
        do {
            try prepareDirectory()
        } catch {
            ThreadingLogger.usage.error(
                "Usage history directory is unavailable: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return UsageLimitHistorySnapshot(samples: [], resets: [], loadedAt: now)
        }
        pruneFiles(now: now)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let cutoff = now.addingTimeInterval(
            -TimeInterval(UsageLimitHistoryDefaults.retentionDays) * 86_400
        )
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
        } catch {
            ThreadingLogger.usage.error(
                "Usage history enumeration failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return UsageLimitHistorySnapshot(samples: [], resets: [], loadedAt: now)
        }
        let urls = contents.filter(Self.isJournalFile)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var samples: [UsageSample] = []
        var resets: [UsageLimitResetEvent] = []
        var resetIDs = Set<String>()
        var count = 0
        var rejectedFiles = 0
        var rejectedRecords = 0

        for url in urls where count < UsageLimitHistoryDefaults.maximumLoadedRecords {
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ]), values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= UsageLimitHistoryDefaults.maximumDailyFileBytes,
                  let data = try? BoundedFileReader.read(
                    url,
                    maximumBytes: UsageLimitHistoryDefaults.maximumDailyFileBytes
                  ) else {
                rejectedFiles += 1
                continue
            }

            for line in data.split(separator: 0x0A)
                where count < UsageLimitHistoryDefaults.maximumLoadedRecords {
                guard let record = try? decoder.decode(Record.self, from: Data(line)),
                      record.schemaVersion == 1 else {
                    rejectedRecords += 1
                    continue
                }
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
        if rejectedFiles > 0 || rejectedRecords > 0 {
            ThreadingLogger.usage.warning(
                "Usage history load skipped files=\(rejectedFiles, privacy: .public) records=\(rejectedRecords, privacy: .public)"
            )
        }
        ThreadingLogger.usage.info(
            "Usage history loaded records=\(count, privacy: .public) samples=\(samples.count, privacy: .public) resets=\(resets.count, privacy: .public)"
        )
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

    @discardableResult
    func deleteHistory() -> Bool {
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch where !fileManager.fileExists(atPath: directory.path) {
            loadedSnapshot = .empty
            return true
        } catch {
            ThreadingLogger.usage.error(
                "Usage history deletion could not enumerate storage: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return false
        }
        var deletionFailures = 0
        for url in urls where Self.isJournalFile(url) {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                deletionFailures += 1
                ThreadingLogger.usage.error(
                    "Usage history file deletion failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        guard deletionFailures == 0 else {
            // A later load must reflect the surviving records; caching an empty snapshot would
            // make a failed privacy reset appear successful for the rest of the process.
            loadedSnapshot = nil
            return false
        }
        loadedSnapshot = .empty
        ThreadingLogger.usage.info("Usage history deleted")
        return true
    }

    private func append(_ data: Data, to url: URL) throws {
        try prepareDirectory()
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

    private func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func pruneFiles(now: Date) {
        let cutoff = now.addingTimeInterval(
            -TimeInterval(UsageLimitHistoryDefaults.retentionDays) * 86_400
        )
        let cutoffDay = Self.dayKey(cutoff)
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey]
            )
        } catch {
            ThreadingLogger.usage.warning(
                "Usage history retention scan failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return
        }
        for url in urls where Self.isJournalFile(url) {
            let name = url.deletingPathExtension().lastPathComponent
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true,
                  name.hasPrefix("limits-"),
                  String(name.dropFirst("limits-".count)) < cutoffDay else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                ThreadingLogger.usage.warning(
                    "Usage history retention deletion failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
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
