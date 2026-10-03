import Foundation
import ThreadingController

/// One bounded request on stdin, one JSON result on stdout. Transport authentication belongs
/// to SSH/the OS account, exactly as for the owner CLI. Never expose this as a public listener.
enum ControllerOwnerRPC {
    struct Argument: Decodable { let value: String?; let text: String? }
    struct Request: Decodable { let command: String; let arguments: [Argument] }
    static let allowed: Set<String> = [
        "automations", "automation", "automation-configure", "automation-enable", "automation-pause",
        "automation-delete", "automation-run", "automation-runs",
        "worker-sources", "worker-set-sources", "enqueue-request", "worker-reconcile", "work-message", "work-messages", "work-history", "work-cancel", "worker-archive",
        "workers", "worker-add", "worker-configure", "worker-policy", "worker-enable", "worker-pause", "enqueue", "work", "works",
        "question", "questions", "open-questions", "answer", "delivery", "deliveries", "pending-deliveries",
        "delivery-begin", "delivery-ack", "delivery-uncertain",
        "work-deliveries", "launches", "active-launches", "launch-record", "launch-status", "launch-stop", "retry", "events",
        "memory-get", "memory-history", "knowledge-get", "knowledge-history",
        // Mail administration and mailbox reads. Not mail-rpc (a peer's own forced command) and
        // not mail-sync (the resident supervisor's job, which runs the peers' transports).
        "host", "host-set-name", "mail-address", "mail-peer-set", "mail-peers", "mail-grant-set", "mail-grants",
        "mail-register", "mail-contact-set", "mail-contacts", "mailbox", "mail-history", "mail-get",
        "mail-send", "mail-ack", "mail-notice", "mail-outbound"
    ]
    static func run(store: ControllerStore, database: String) async throws {
        let maximumBytes = 262_144
        guard let input = try FileHandle.standardInput.read(upToCount: maximumBytes + 1), input.count <= maximumBytes else {
            throw ControllerError.invalidInput("rpc_size")
        }
        let request = try JSONDecoder().decode(Request.self, from: input)
        guard allowed.contains(request.command), request.arguments.count <= 16 else { throw ControllerError.invalidInput("rpc_command") }
        let directory = URL(fileURLWithPath: database).deletingLastPathComponent().appendingPathComponent("rpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var args: [String] = []
        for (index, argument) in request.arguments.enumerated() {
            // Each command still reads its file through its own bound; this is only the
            // largest any command accepts (an automation spec).
            if let text = argument.text, argument.value == nil, text.utf8.count <= ControllerMain.automationSpecFileBytes {
                let file = directory.appendingPathComponent("\(index).txt")
                try Data(text.utf8).write(to: file, options: .withoutOverwriting)
                args.append(file.path)
            } else if let value = argument.value, argument.text == nil, value.utf8.count <= 4096, !value.contains("\0") {
                args.append(value)
            } else { throw ControllerError.invalidInput("rpc_argument") }
        }
        try await ControllerMain.execute(request.command, args, store, database: database)
    }
}
