import Foundation
import ThreadingRemoteKit

public enum UsageGlanceStoreError: Error { case unavailable, unsupportedVersion, corrupt, superseded }

/// The app is the only writer. WidgetKit and App Intent queries use read() exclusively.
/// File and codec work is isolated here, never on the phone's main actor.
public actor UsageGlanceStore {
    public static let appGroup = "group.codes.threading.mobile"
    public static let widgetKind = "ThreadingUsage"
    public static let maximumBytes = 128 * 1024
    public static let shared = UsageGlanceStore()
    private let directory: URL?
    private var lastSequence: UInt64 = 0

    public init(directory: URL? = nil) { self.directory = directory }

    private func location() throws -> URL {
        if let directory { return directory.appendingPathComponent("usage-v1.json") }
#if os(iOS)
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroup
        ) else { throw UsageGlanceStoreError.unavailable }
        return group.appendingPathComponent("usage-v1.json")
#else
        throw UsageGlanceStoreError.unavailable
#endif
    }

    public func read() throws -> UsageGlanceSnapshot? {
        try read(at: location())
    }

    private func read(at url: URL) throws -> UsageGlanceSnapshot? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) { return nil }
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard bytes.count <= Self.maximumBytes else { throw UsageGlanceStoreError.corrupt }
        struct Header: Decodable { let version: Int }
        do {
            let header = try JSONDecoder().decode(Header.self, from: bytes)
            guard header.version == 1 else { throw UsageGlanceStoreError.unsupportedVersion }
            let snapshot = try JSONDecoder().decode(UsageGlanceSnapshot.self, from: bytes)
            try snapshot.validate()
            return snapshot
        } catch UsageGlanceStoreError.unsupportedVersion {
            throw UsageGlanceStoreError.unsupportedVersion
        } catch { throw UsageGlanceStoreError.corrupt }
    }

    /// Sequence is assigned synchronously by the single app publisher before it starts work.
    /// An older request cannot restore a snapshot after a host change, opt-out or revocation.
    @discardableResult
    public func publish(_ snapshot: UsageGlanceSnapshot, sequence: UInt64) throws -> Bool {
        guard sequence > lastSequence else { throw UsageGlanceStoreError.superseded }
        lastSequence = sequence
        try snapshot.validate()
        let url = try location()
        let previous = try read(at: url) // Preserve newer/corrupt archives until explicit recovery.
        if let previous, previous.pairingID == snapshot.pairingID,
           previous.hostName == snapshot.hostName, previous.capacity == snapshot.capacity { return false }
        let bytes = try JSONEncoder().encode(snapshot)
        guard bytes.count <= Self.maximumBytes else { throw RemoteUsageCapacityError.oversized }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
#if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
#endif
        try bytes.write(to: url, options: options)
        return true
    }

    /// Explicit cache reset preserves corrupt bytes for inspection. A newer format remains
    /// untouched. Recovery has one slot; it never silently overwrites a previous quarantine.
    public func clear(sequence: UInt64) throws {
        guard sequence > lastSequence else { throw UsageGlanceStoreError.superseded }
        lastSequence = sequence
        let url = try location()
        do {
            guard try read(at: url) != nil else { return }
            try FileManager.default.removeItem(at: url)
        } catch UsageGlanceStoreError.corrupt {
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable"))
        }
    }
}
