import Foundation
import ThreadingScenarioKit

enum ScenarioToolError: LocalizedError {
    case usage
    case privacyFindings(URL, [AgentScenarioPrivacyFinding])

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: threading-scenario validate <scenario.json> [...]"
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
    guard arguments.first == "validate", arguments.count > 1 else {
        throw ScenarioToolError.usage
    }
    for path in arguments.dropFirst() {
        let url = URL(fileURLWithPath: path)
        let tape = try AgentScenarioTape.load(from: url)
        let findings = AgentScenarioPrivacyAudit.findings(in: tape)
        guard findings.isEmpty else {
            throw ScenarioToolError.privacyFindings(url, findings)
        }
        print("scenario valid: \(tape.id) (\(tape.steps.count) steps)")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(2)
}
