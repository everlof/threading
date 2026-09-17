import Foundation

/// Where a project's agent sessions run when it is not this Mac: a Linux machine reached with the
/// system `ssh`, and the checkout on it.
///
/// **Stored on the project, and visible wherever the project is.** It replaced a hidden `defaults`
/// key, because a setting that decides which machine an agent runs on must not be something a
/// person can forget is set: the project row and its sessions carry a mark, the session hover card
/// names the host, and every launch it routes is journalled. See
/// `docs/feature-drafts/remote-execution-hosts.md`.
///
/// Decoded leniently: a record whose fields are missing or blank still decodes, keeps the project,
/// and is refused at launch as invalid — it must never read as "no host" and quietly run locally.
struct ProjectExecutionHost: Equatable, Codable, Sendable {

    /// What `ssh` connects to: an alias from the person's ssh config, or `user@host`.
    var destination: String
    /// An ssh config file other than `~/.ssh/config`, such as a Lima VM's. Nil for the default.
    var sshConfigFile: String?
    /// The checkout on the host that sessions run in. Absolute.
    var remoteDirectory: String

    init(destination: String, sshConfigFile: String? = nil, remoteDirectory: String) {
        self.destination = destination
        self.sshConfigFile = sshConfigFile
        self.remoteDirectory = remoteDirectory
    }

    private enum CodingKeys: String, CodingKey {
        case destination
        case sshConfigFile
        case remoteDirectory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        destination = (try? container.decodeIfPresent(String.self, forKey: .destination)) ?? ""
        sshConfigFile = (try? container.decodeIfPresent(String.self, forKey: .sshConfigFile)) ?? nil
        remoteDirectory = (try? container.decodeIfPresent(String.self, forKey: .remoteDirectory)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(destination, forKey: .destination)
        try container.encodeIfPresent(sshConfigFile, forKey: .sshConfigFile)
        try container.encode(remoteDirectory, forKey: .remoteDirectory)
    }

    // MARK: - Validation

    /// Why a host cannot be used, in words for the person who typed it. Nil when it can.
    enum Problem: Equatable, Sendable {
        case missingDestination
        /// `ssh` would read it as an option, or it holds whitespace.
        case unsafeDestination
        case relativeConfigFile
        case relativeRemoteDirectory

        var message: String {
            switch self {
            case .missingDestination:
                return L10n.string("Enter the ssh host, as you would type it after ssh.")
            case .unsafeDestination:
                return L10n.string("The ssh host can’t start with a dash or contain spaces.")
            case .relativeConfigFile:
                return L10n.string("The ssh config file must be a full path, starting with /.")
            case .relativeRemoteDirectory:
                return L10n.string("The folder on the host must be a full path, starting with /.")
            }
        }

        var token: String {
            switch self {
            case .missingDestination: return "missingDestination"
            case .unsafeDestination: return "unsafeDestination"
            case .relativeConfigFile: return "relativeConfigFile"
            case .relativeRemoteDirectory: return "relativeRemoteDirectory"
            }
        }
    }

    var problem: Problem? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .missingDestination }
        guard !destination.hasPrefix("-"),
              destination.unicodeScalars.allSatisfy({
                  !CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
              })
        else { return .unsafeDestination }
        if let sshConfigFile, !sshConfigFile.hasPrefix("/") || sshConfigFile.contains("\0") {
            return .relativeConfigFile
        }
        guard remoteDirectory.hasPrefix("/"), !remoteDirectory.contains("\0") else {
            return .relativeRemoteDirectory
        }
        return nil
    }

    var isValid: Bool { problem == nil }

    /// Builds a host from what a person typed: trimmed, and a blank config file means the default.
    static func typed(
        destination: String,
        sshConfigFile: String,
        remoteDirectory: String
    ) -> ProjectExecutionHost {
        let config = sshConfigFile.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProjectExecutionHost(
            destination: destination.trimmingCharacters(in: .whitespacesAndNewlines),
            sshConfigFile: config.isEmpty ? nil : config,
            remoteDirectory: remoteDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
