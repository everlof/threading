import Foundation

/// Posted when the list of hosts changes, so the Settings page and every project picker reading it
/// redraw from one source.
struct RemoteHostsDidChange: AppEvent {
    static let name = Notification.Name("remoteHostsDidChange")
}

/// The machines a person has told Threading about.
///
/// A handful of records, read whole at launch and written whole on every change — a JSON file
/// rather than a table, by the rule `ScheduledMessageStore` states: columns exist to be ordered by,
/// filtered on or joined, and nothing here is any of those. `criticality: .userAuthored`, so a file
/// this build cannot read is moved aside rather than deleted: a person's hosts are theirs, and an
/// unreadable one is a thing to recover, not to discard.
///
/// Disk is authoritative. A change that the file refuses is not announced in memory, because a
/// project pointing at a host the next launch will not find is a project whose sessions silently
/// run somewhere else.
@MainActor
final class RemoteHostStore {

    static let shared = RemoteHostStore()

    private let persistence: RecoverableFileStore<RemoteHostsFile>
    private let center: NotificationCenter
    private(set) var hosts: [RemoteHostRecord] = []

    /// The directory is injectable for `ScheduledMessageStore`'s reason: the test bundle is hosted
    /// in the app, so a store that always resolved Application Support would have every test
    /// rewriting the developer's own hosts.
    init(directory: URL? = nil, fileManager: FileManager = .default, center: NotificationCenter = .default) {
        let root = directory ?? PTYHostLocation.supportRoot
        self.center = center
        self.persistence = RecoverableFileStore(
            url: root.appendingPathComponent(RemoteHostStoreDefaults.fileName),
            fileManager: fileManager,
            criticality: .userAuthored,
            sizePolicy: .userDocument,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        )
        load()
    }

    // MARK: - Reading

    /// Every host, the way the list shows them: by name, so the order does not move when one is
    /// edited.
    var ordered: [RemoteHostRecord] {
        hosts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func host(withID id: RemoteHostID) -> RemoteHostRecord? {
        hosts.first { $0.id == id }
    }

    /// The host naming this machine, if one already does.
    func host(naming destination: String, sshConfigFile: String?) -> RemoteHostRecord? {
        hosts.first { $0.destination == destination && $0.sshConfigFile == sshConfigFile }
    }

    // MARK: - Writing

    enum Outcome: Equatable {
        case applied
        /// The record names no usable machine; the editor says which part.
        case refused(ProjectExecutionHost.Problem)
        /// Another record already names this machine.
        case duplicate(RemoteHostID)
        /// Disk refused the write, so memory does not pretend otherwise.
        case notPersisted
    }

    @discardableResult
    func add(_ host: RemoteHostRecord) -> Outcome {
        if let problem = host.problem { return .refused(problem) }
        if let existing = hosts.first(where: { $0.names(host) }) { return .duplicate(existing.id) }
        return commit(hosts + [host])
    }

    @discardableResult
    func update(_ host: RemoteHostRecord) -> Outcome {
        if let problem = host.problem { return .refused(problem) }
        if let clash = hosts.first(where: { $0.id != host.id && $0.names(host) }) {
            return .duplicate(clash.id)
        }
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return add(host) }
        var updated = hosts
        updated[index] = host
        return commit(updated)
    }

    @discardableResult
    func remove(_ id: RemoteHostID) -> Outcome {
        commit(hosts.filter { $0.id != id })
    }

    /// The record for a machine, made if this is the first time it is named.
    ///
    /// How a project set up before hosts were records keeps working: its destination is adopted
    /// into the list the first time it is read, rather than becoming a second place a machine is
    /// configured.
    @discardableResult
    func adopt(destination: String, sshConfigFile: String?, label: String = "") -> RemoteHostRecord? {
        if let existing = host(naming: destination, sshConfigFile: sshConfigFile) { return existing }
        let record = RemoteHostRecord(label: label, destination: destination, sshConfigFile: sshConfigFile)
        guard record.isValid, commit(hosts + [record]) == .applied else { return nil }
        return record
    }

    // MARK: - Private Methods

    private func load() {
        let outcome = persistence.load(defaultValue: RemoteHostsFile(hosts: []))
        hosts = outcome.value.hosts
        if case .unreadable = outcome {
            EventLog.shared.record(.session, "Remote hosts could not be read and were set aside", [:])
        }
    }

    @discardableResult
    private func commit(_ updated: [RemoteHostRecord]) -> Outcome {
        guard persistence.save(RemoteHostsFile(hosts: updated)) else { return .notPersisted }
        hosts = updated
        center.post(RemoteHostsDidChange())
        return .applied
    }
}

// MARK: - Stored Shape

/// The file's own shape, so a later version can add a key without the list becoming unreadable.
private struct RemoteHostsFile: Codable {
    var hosts: [RemoteHostRecord]
}

enum RemoteHostStoreDefaults {
    static let fileName = "remote-hosts.json"
}
