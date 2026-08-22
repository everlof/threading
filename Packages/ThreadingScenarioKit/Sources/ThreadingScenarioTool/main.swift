import Foundation
import ThreadingScenarioKit

enum ScenarioToolError: LocalizedError {
    case usage
    case privacyFindings(URL, [AgentScenarioPrivacyFinding])

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: threading-scenario validate <scenario.json> [...] | replay <scenario.json> --scenario-root <directory> | terminal-fixture <codex|claude> [--history-lines <count>]"
        case .privacyFindings(let url, let findings):
            let summary = findings
                .map { "step \($0.step): \($0.kind.rawValue)" }
                .joined(separator: ", ")
            return "\(url.path): privacy audit failed (\(summary))"
        }
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "validate" where arguments.count > 1:
        for path in arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            let tape = try AgentScenarioTape.load(from: url)
            let findings = AgentScenarioPrivacyAudit.findings(in: tape)
            guard findings.isEmpty else {
                throw ScenarioToolError.privacyFindings(url, findings)
            }
            print("scenario valid: \(tape.id) (\(tape.steps.count) steps)")
        }

    case "replay" where arguments.count == 4 && arguments[2] == "--scenario-root":
        let tape = try AgentScenarioTape.load(from: URL(fileURLWithPath: arguments[1]))
        let findings = AgentScenarioPrivacyAudit.findings(in: tape)
        guard findings.isEmpty else {
            throw ScenarioToolError.privacyFindings(URL(fileURLWithPath: arguments[1]), findings)
        }
        let status = try AgentScenarioReplayer().run(
            tape: tape,
            scenarioRoot: URL(fileURLWithPath: arguments[3], isDirectory: true)
        )
        exit(status)

    case "terminal-fixture" where arguments.count == 2 || arguments.count == 4:
        guard let provider = TerminalWireFixtureProvider(rawValue: arguments[1]) else {
            throw ScenarioToolError.usage
        }
        let historyLines: Int
        if arguments.count == 4 {
            guard arguments[2] == "--history-lines",
                  let value = Int(arguments[3]),
                  value > 0,
                  value <= TerminalWireFixture.maximumHistoryLines else {
                throw ScenarioToolError.usage
            }
            historyLines = value
        } else {
            historyLines = TerminalWireFixture.defaultHistoryLines
        }
        exit(try TerminalWireFixtureRunner.run(
            provider: provider,
            historyLines: historyLines
        ))

    default:
        throw ScenarioToolError.usage
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(2)
}
