import Foundation
import SkalmanExtensionPolicy

private let arguments = Array(CommandLine.arguments.dropFirst())

guard let stampPath = arguments.first else {
    FileHandle.standardError.write(
        Data("error: policy checker needs an output stamp path\n".utf8)
    )
    exit(EXIT_FAILURE)
}

var violations: [String] = []

for sourcePath in arguments.dropFirst() {
    guard let source = try? String(contentsOfFile: sourcePath, encoding: .utf8) else {
        violations.append("\(sourcePath): error: could not read extension source")
        continue
    }

    violations.append(
        contentsOf: ExtensionSourcePolicy
            .violations(in: source, path: sourcePath)
            .map(\.diagnostic)
    )
}

if !violations.isEmpty {
    FileHandle.standardError.write(Data((violations.joined(separator: "\n") + "\n").utf8))
    exit(EXIT_FAILURE)
}

do {
    try Data("ok\n".utf8).write(to: URL(fileURLWithPath: stampPath), options: .atomic)
} catch {
    FileHandle.standardError.write(
        Data("\(stampPath): error: could not write policy stamp: \(error)\n".utf8)
    )
    exit(EXIT_FAILURE)
}
