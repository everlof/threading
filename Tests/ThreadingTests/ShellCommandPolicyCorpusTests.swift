import XCTest
@testable import Threading

/// Runs `ShellCommandPolicy` over the shell commands Codex actually ran on this machine.
///
/// The unit tests next door pin the *rules*; this pins the thing the rules exist for. The
/// classifier was written against a measurement — 42% of Codex's shell calls are `sed -n` file
/// reads, and refusing them left it admitting a fifth of real traffic — so a change that
/// quietly undoes that measurement should fail here rather than be discovered as a wall of
/// permission cards.
///
/// Skipped when the corpus is absent, since it reads the developer's own rollouts.
final class ShellCommandPolicyCorpusTests: XCTestCase {

    /// Below this, the feature is not worth having: a session prompting for four calls in five
    /// is one the user turns off.
    private static let minimumCoverage = 0.50

    /// Enough to be representative without reading a thousand files in a unit test.
    private static let rolloutsSampled = 60
    private static let commandCeiling = 1_500

    func testRealCodexCommandsAreMostlyRecognised() throws {
        let commands = try Self.realShellCommands()
        try XCTSkipIf(commands.count < 100, "No Codex rollout corpus on this machine")

        let allowed = commands.filter(ShellCommandPolicy.isReadOnly)
        let coverage = Double(allowed.count) / Double(commands.count)

        XCTAssertGreaterThan(
            coverage, Self.minimumCoverage,
            """
            Only \(allowed.count) of \(commands.count) real commands \
            (\(Int(coverage * 100))%) skip the prompt. \
            A rule change has undone the measurement this policy was built on.
            """
        )
    }

    /// Nothing in the corpus that writes may be admitted. A blunt check on the obvious
    /// destroyers, because the corpus is real and unreviewed — it is a net, not a proof.
    func testNothingDestructiveInTheCorpusIsAdmitted() throws {
        let commands = try Self.realShellCommands()
        try XCTSkipIf(commands.count < 100, "No Codex rollout corpus on this machine")

        let destructive = ["rm ", "rm -", "mv ", "chmod", "chown", "npm i", "cargo build",
                           "curl", "git commit", "git push", "git checkout", "> ", ">>"]

        for command in commands where ShellCommandPolicy.isReadOnly(command) {
            for marker in destructive {
                XCTAssertFalse(
                    command.contains(marker),
                    "admitted a command containing '\(marker)': \(command)"
                )
            }
        }
    }

    // MARK: - Corpus

    /// Shell commands pulled from the most recent Codex rollouts.
    private static func realShellCommands() throws -> [String] {
        let sessions = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")

        guard FileManager.default.fileExists(atPath: sessions.path) else { return [] }

        let rollouts = FileManager.default
            .enumerator(at: sessions, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.hasPrefix("rollout-") } ?? []

        var commands: [String] = []

        for rollout in rollouts.suffix(rolloutsSampled) {
            guard let text = try? String(contentsOf: rollout, encoding: .utf8) else { continue }

            for line in text.split(separator: "\n") {
                guard commands.count < commandCeiling else { return commands }
                guard line.contains("\"function_call\""),
                      let command = shellCommand(inRecord: String(line)) else { continue }
                commands.append(command)
            }
        }

        return commands
    }

    /// The command a `function_call` record ran, when it is one of the shell tools.
    ///
    /// Codex nests its arguments as a JSON *string*, which is one of the traps the fixture
    /// scrubber had to learn too.
    private static func shellCommand(inRecord line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let payload = (record["payload"] as? [String: Any]) ?? record

        guard payload["type"] as? String == "function_call",
              let name = payload["name"] as? String,
              ToolIdentity(name) == .bash,
              let argumentText = payload["arguments"] as? String,
              let argumentData = argumentText.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: argumentData) as? [String: Any]
        else { return nil }

        if let command = (arguments["cmd"] ?? arguments["command"]) as? String { return command }
        if let words = (arguments["cmd"] ?? arguments["command"]) as? [String] {
            return words.joined(separator: " ")
        }
        return nil
    }
}
