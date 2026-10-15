import Foundation

/// Exercises the launch contract, not just the binary's presence. Older bridges required the
/// token in argv and exited 64 when given the environment-only configuration the app now writes.
enum RemoteHostBridgeProbe {
    static let timeout: TimeInterval = 15

    static func script(executable: String) -> String {
        """
        set -eu
        umask 077
        scratch=$(mktemp -d)
        trap 'rm -rf "$scratch"' EXIT HUP INT TERM
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | \
          env THREADING_SESSION_TOKEN=threading-bridge-probe \
          \(ShellCommand(word: executable).source) --socket "$scratch/mcp.sock" --cache "$scratch/cache.json"
        """
    }

    static func accepts(_ response: RemoteHostCommandResult) -> Bool {
        guard response.succeeded, response.output.utf8.count <= 64 * 1024 else { return false }
        return response.output.split(separator: "\n").contains { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["id"] as? Int == 1,
                  let result = object["result"] as? [String: Any],
                  result["serverInfo"] is [String: Any], result["protocolVersion"] is String
            else { return false }
            return true
        }
    }
}
