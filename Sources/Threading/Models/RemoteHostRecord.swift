import Foundation

/// A remote execution host's identifier.
///
/// Its own type, deliberately incompatible with the session and project identifiers it sits beside:
/// a project names the host it runs on, and confusing the two would route a launch at a machine
/// nobody chose.
struct RemoteHostID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue.uuidString }
}

/// One machine a person has told Threading about, configured once and used by any number of
/// projects.
///
/// **A host is a record, not a string on a project.** The first version stored the destination on
/// each project, which meant configuring the same machine again for every checkout on it and having
/// nowhere to say whether it was reachable. A project now names a host by id and adds only the
/// folder its sessions run in; everything about *the machine* lives here.
///
/// What is **not** here is state: whether the host is prepared, downloading or refusing is a fact
/// about this run of the app and belongs to `RemoteExecutionHosts`. A record that remembered it
/// would go stale the moment the machine was switched off.
struct RemoteHostRecord: Equatable, Codable, Sendable, Identifiable {
    let id: RemoteHostID
    /// What the person calls it. Blank means the destination is its own name.
    var label: String
    /// What `ssh` connects to: an alias from their ssh config, or `user@host`.
    var destination: String
    /// An ssh config file other than `~/.ssh/config`, such as a Lima VM's. Nil for the default.
    var sshConfigFile: String?
    let addedAt: Date

    init(
        id: RemoteHostID = RemoteHostID(),
        label: String = "",
        destination: String,
        sshConfigFile: String? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.destination = destination
        self.sshConfigFile = sshConfigFile
        self.addedAt = addedAt
    }

    /// Decoded leniently for the reason `ProjectExecutionHost` is: a record that half-decodes is
    /// kept and refused where it is used, rather than disappearing and taking a project's host with
    /// it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(RemoteHostID.self, forKey: .id)) ?? RemoteHostID()
        label = (try? container.decodeIfPresent(String.self, forKey: .label)) ?? ""
        destination = (try? container.decodeIfPresent(String.self, forKey: .destination)) ?? ""
        sshConfigFile = (try? container.decodeIfPresent(String.self, forKey: .sshConfigFile)) ?? nil
        addedAt = (try? container.decodeIfPresent(Date.self, forKey: .addedAt)) ?? Date()
    }

    /// The name to show: what they called it, else the destination itself.
    var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? destination : trimmed
    }

    /// Whether this record and another name the same machine, which is what keeps a second copy of
    /// one host out of the list.
    func names(_ other: RemoteHostRecord) -> Bool {
        destination == other.destination && sshConfigFile == other.sshConfigFile
    }

    var sshDestination: RemoteHostDestination {
        RemoteHostDestination(alias: destination, configFile: sshConfigFile)
    }

    /// Why this host cannot be used, in the words its editor shows. Nil when it can.
    var problem: ProjectExecutionHost.Problem? {
        // The machine's half of the same validation: a destination `ssh` would read as an option,
        // and a config file that is not a full path. The folder belongs to the project, not here.
        ProjectExecutionHost(destination: destination, sshConfigFile: sshConfigFile, remoteDirectory: "/")
            .problem
    }

    var isValid: Bool { problem == nil }

    /// Builds a record from what a person typed.
    static func typed(label: String, destination: String, sshConfigFile: String) -> RemoteHostRecord {
        let config = sshConfigFile.trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteHostRecord(
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            destination: destination.trimmingCharacters(in: .whitespacesAndNewlines),
            sshConfigFile: config.isEmpty ? nil : config
        )
    }
}
