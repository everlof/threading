import Foundation
import ThreadingController

// MARK: - Remote Controller RPC

/// One remote host's controller, reached over the owner's SSH: `owner-rpc` for owner operations
/// and `mail-rpc` for a peer exchange. Shared by mail sync, remote session mailboxes and the
/// mail access editor, so every caller quotes, bounds and decodes the same way.
struct RemoteControllerEndpoint: Equatable, Sendable {
    let hostID: RemoteHostID
    let name: String
    let destination: RemoteHostDestination
    let executable: String
    let database: String

    /// The saved controller of a host record, or nil when its paths are not set up.
    init?(_ host: RemoteHostRecord) {
        guard let executable = host.controllerExecutable, let database = host.controllerDatabase,
              RemoteAutomationEndpoint(hostID: host.id, executable: executable, database: database).isValid,
              host.isValid else { return nil }
        self.init(hostID: host.id, name: host.displayName, destination: host.sshDestination,
                  executable: executable, database: database)
    }

    init(hostID: RemoteHostID, name: String, destination: RemoteHostDestination, executable: String, database: String) {
        self.hostID = hostID
        self.name = name
        self.destination = destination
        self.executable = executable
        self.database = database
    }
}

struct RemoteControllerRPC: Sendable {

    enum Failure: Error, Equatable {
        case transport(String)
        case invalidResponse
        case wrongHost
    }

    struct OwnerArgument: Encodable, Sendable {
        var value: String? = nil
        var text: String? = nil
    }

    private struct OwnerRequest: Encodable {
        let command: String
        let arguments: [OwnerArgument]
    }

    let endpoint: RemoteControllerEndpoint
    let runner: any RemoteHostCommandRunning
    var timeout: TimeInterval = RemoteControllerRPCDefaults.timeout

    /// One owner command, decoded from the controller's one JSON line.
    func owner<T: Decodable>(_ command: String, _ arguments: [OwnerArgument] = [], as type: T.Type = T.self) async throws -> T {
        let input = try JSONEncoder().encode(OwnerRequest(command: command, arguments: arguments))
        return try Self.decodeLastLine(T.self, from: try await run("owner-rpc", input: input))
    }

    /// One peer exchange, refused when another host answers.
    func mail(_ request: MailRPCRequest, local: HostID, expecting host: HostID) async throws -> MailRPCResponse {
        let input = try JSONEncoder().encode(request)
        guard input.count <= MailTransportLimits.requestBytes else { throw Failure.transport("request_too_large") }
        let response = try Self.decodeLastLine(
            MailRPCResponse.self, from: try await run("mail-rpc --peer \(local.description)", input: input)
        )
        guard response.host == host else { throw Failure.wrongHost }
        return response
    }

    /// Blocking SSH, so it runs on a detached task rather than on the caller's executor.
    private func run(_ subcommand: String, input: Data) async throws -> String {
        let command = Self.quoted(endpoint.executable) + " --database " + Self.quoted(endpoint.database) + " " + subcommand
        let runner = runner
        let destination = endpoint.destination
        let timeout = timeout
        let result = try await Task.detached(priority: .utility) {
            try runner.run(on: destination, command: command, input: .data(input), extraOptions: [], timeout: timeout)
        }.value
        guard result.succeeded else { throw Failure.transport(String(result.output.suffix(256))) }
        return result.output
    }

    /// The controller prints one JSON line; anything before it (an SSH banner on the merged
    /// stream) is ignored rather than failing the decode.
    static func decodeLastLine<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        guard let line = output.split(whereSeparator: \.isNewline)
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let value = try? JSONDecoder().decode(T.self, from: Data(line.utf8)) else {
            throw Failure.invalidResponse
        }
        return value
    }

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as Failure:
            switch error {
            case .transport(let detail): return "transport: \(detail)"
            case .invalidResponse: return "invalid_response"
            case .wrongHost: return "mail_peer_identity"
            }
        case let error as ControllerError: return error.description
        default: return MacMailbox.describe(error)
        }
    }
}

extension RemoteAutomationEndpoint {
    var isValid: Bool { (try? validate()) != nil }
}

enum RemoteControllerRPCDefaults {
    static let timeout: TimeInterval = 30
    /// Launch-time owner calls: short, because a launch waits on them and falls back to the
    /// Mac's mailbox rather than hanging.
    static let launchTimeout: TimeInterval = 10
}
