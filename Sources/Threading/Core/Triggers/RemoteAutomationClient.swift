import Foundation
import ThreadingController

struct RemoteAutomationEndpoint: Codable, Equatable, Sendable {
    var hostID: RemoteHostID
    var executable: String
    var database: String

    init(hostID: RemoteHostID, executable: String, database: String) {
        self.hostID = hostID; self.executable = executable; self.database = database
    }

    /// An agent names only the host. The paths come from that host's saved connection, so
    /// missing ones decode as empty rather than failing the whole tool call.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decode(RemoteHostID.self, forKey: .hostID)
        executable = try container.decodeIfPresent(String.self, forKey: .executable) ?? ""
        database = try container.decodeIfPresent(String.self, forKey: .database) ?? ""
    }

    func validate() throws {
        guard executable.hasPrefix("/"), database.hasPrefix("/"),
              executable.utf8.count <= 4096, database.utf8.count <= 4096,
              !executable.contains("\0"), !database.contains("\0") else {
            throw TriggerStore.StoreError.invalidRecord("absolute controller executable and database paths required")
        }
    }
}

/// SSH carries one owner RPC to the selected host. Work stays in its database; the Mac never
/// downloads or edits that database, and a timeout is never automatically retried.
actor RemoteAutomationClient {
    static let shared = RemoteAutomationClient()
    /// The controller's owner RPC reads at most this much from stdin.
    static let maximumRequestBytes = 262_144
    private var inFlight = false
    struct Argument: Encodable, Sendable {
        var value: String? = nil
        var text: String? = nil
    }
    struct Request: Encodable { let command: String; let arguments: [Argument] }

    func request(endpoint: RemoteAutomationEndpoint, destination: RemoteHostDestination,
                 command: String, arguments: [Argument],
                 runner: any RemoteHostCommandRunning = SystemSSHCommandRunner(maximumOutputBytes: 2_097_152)) async throws -> String {
        try endpoint.validate()
        guard destination.isValid, !inFlight else { throw TriggerStore.StoreError.invalidRecord("remote automation request already in progress or invalid host") }
        let allowed: Set<String> = ["automations", "automation", "automation-configure", "automation-enable",
            "automation-pause", "automation-delete", "automation-run", "automation-runs", "worker-policy", "workers"]
        guard allowed.contains(command) else { throw TriggerStore.StoreError.invalidRecord("automation operation") }
        let data = try JSONEncoder().encode(Request(command: command, arguments: arguments))
        guard data.count <= Self.maximumRequestBytes else { throw TriggerStore.StoreError.invalidRecord("automation request too large") }
        inFlight = true
        defer { inFlight = false }
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let shellCommand = quote(endpoint.executable) + " --database " + quote(endpoint.database) + " owner-rpc"
        let result = try await Task.detached(priority: .utility) {
            try runner.run(on: destination, command: shellCommand, input: .data(data),
                extraOptions: [], timeout: RemoteHostDefaults.commandTimeout)
        }.value
        guard result.succeeded else {
            throw TriggerStore.StoreError.invalidRecord("Remote controller did not confirm the request. Inspect it before retrying: " + String(result.output.suffix(1024)))
        }
        guard let bytes = result.output.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed)) != nil else {
            throw TriggerStore.StoreError.invalidRecord("Invalid or truncated remote controller response")
        }
        return result.output
    }
}
