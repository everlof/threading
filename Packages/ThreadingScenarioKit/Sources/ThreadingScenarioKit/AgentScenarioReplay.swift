import Foundation

public enum AgentScenarioReplayError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedTransport(String)
    case unexpectedEndOfInput(step: Int)
    case hostLineTooLarge(step: Int, maximum: Int)
    case invalidExpectedJSON(step: Int)
    case invalidActualJSON(step: Int)
    case hostMessageMismatch(step: Int, reason: String)
    case unboundPlaceholder(step: Int, name: String)
    case renderedPayloadTooLarge(step: Int, actual: Int, maximum: Int)
    case unsafeScenarioRoot(String)
    case unsafeFixturePath(step: Int, path: String)
    case outputWriteFailed(step: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedTransport(let transport):
            return "replay does not support transport \(transport)"
        case .unexpectedEndOfInput(let step):
            return "scenario step \(step) expected a host message but stdin ended"
        case .hostLineTooLarge(let step, let maximum):
            return "scenario step \(step) host message exceeded \(maximum) bytes"
        case .invalidExpectedJSON(let step):
            return "scenario step \(step) expected payload is not one JSON object"
        case .invalidActualJSON(let step):
            return "scenario step \(step) received malformed JSON"
        case .hostMessageMismatch(let step, let reason):
            return "scenario step \(step) host message mismatch: \(reason)"
        case .unboundPlaceholder(let step, let name):
            return "scenario step \(step) uses unbound placeholder ${\(name)}"
        case .renderedPayloadTooLarge(let step, let actual, let maximum):
            return "scenario step \(step) rendered to \(actual) bytes; maximum is \(maximum)"
        case .unsafeScenarioRoot(let path):
            return "scenario root is not a safe directory: \(path)"
        case .unsafeFixturePath(let step, let path):
            return "scenario step \(step) refused fixture path \(path)"
        case .outputWriteFailed(let step):
            return "scenario step \(step) could not write provider output"
        }
    }
}

/// Synchronous replay at the same line-framed process boundary as the provider.
///
/// Expected JSON objects are structural subsets: a tape states only the fields that matter to
/// the promise it records, while arrays remain exact and scalar values remain strict. This keeps
/// harmless client metadata additions from invalidating every fixture without making a changed
/// method, prompt, path, id, or ordering invisible.
public struct AgentScenarioReplayer {
    public typealias Delay = @Sendable (Int) -> Void

    private let delay: Delay

    public init(delay: @escaping Delay = { milliseconds in
        guard milliseconds > 0 else { return }
        Thread.sleep(forTimeInterval: Double(milliseconds) / 1_000)
    }) {
        self.delay = delay
    }

    public func run(
        tape: AgentScenarioTape,
        scenarioRoot: URL,
        bindings initialBindings: [String: String] = [:],
        input: FileHandle = .standardInput,
        standardOutput: FileHandle = .standardOutput,
        standardError: FileHandle = .standardError
    ) throws -> Int32 {
        try tape.validate()
        guard tape.transport == .codexAppServer
                || tape.transport == .claudeStreamJSON
                || tape.transport == .grokACP else {
            throw AgentScenarioReplayError.unsupportedTransport(tape.transport.rawValue)
        }
        let root = try validatedRoot(scenarioRoot)
        var bindings = initialBindings
        bindings["SCENARIO_ROOT"] = root.path
        var reader = BoundedLineReader(handle: input)

        for (index, step) in tape.steps.enumerated() {
            switch step {
            case .expectHost(_, let expected):
                guard let actual = try reader.readLine(
                    maximumBytes: AgentScenarioLimits.maximumPayloadBytes,
                    step: index
                ) else {
                    throw AgentScenarioReplayError.unexpectedEndOfInput(step: index)
                }
                try JSONSubsetMatcher.match(
                    expected: expected,
                    actual: actual,
                    bindings: &bindings,
                    step: index
                )

            case .emitAgent(let channel, let payload, let milliseconds):
                delay(milliseconds)
                let rendered = try render(payload, bindings: bindings, step: index)
                let handle = channel == .standardError ? standardError : standardOutput
                do {
                    try handle.write(contentsOf: Data(rendered.utf8))
                } catch {
                    throw AgentScenarioReplayError.outputWriteFailed(step: index)
                }

            case .writeFixtureFile(let path, let contents):
                let rendered = try render(contents, bindings: bindings, step: index)
                try writeFixtureFile(rendered, at: path, root: root, step: index)

            case .checkpoint:
                break

            case .exit(let status, let milliseconds):
                delay(milliseconds)
                return status
            }
        }
        preconditionFailure("validated scenario has no final exit")
    }

    private func render(
        _ value: String,
        bindings: [String: String],
        step: Int
    ) throws -> String {
        var rendered = value
        for name in Self.placeholderNames(in: value) {
            guard let replacement = bindings[name] else {
                throw AgentScenarioReplayError.unboundPlaceholder(step: step, name: name)
            }
            rendered = rendered.replacingOccurrences(of: "${\(name)}", with: replacement)
        }
        let byteCount = rendered.utf8.count
        guard byteCount <= AgentScenarioLimits.maximumPayloadBytes else {
            throw AgentScenarioReplayError.renderedPayloadTooLarge(
                step: step,
                actual: byteCount,
                maximum: AgentScenarioLimits.maximumPayloadBytes
            )
        }
        return rendered
    }

    private func validatedRoot(_ root: URL) throws -> URL {
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard resolved.isFileURL,
              FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AgentScenarioReplayError.unsafeScenarioRoot(root.path)
        }
        return resolved
    }

    private func writeFixtureFile(
        _ contents: String,
        at relativePath: String,
        root: URL,
        step: Int
    ) throws {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AgentScenarioReplayError.unsafeFixturePath(step: step, path: relativePath)
        }

        var cursor = root
        for component in components {
            cursor.appendPathComponent(String(component))
            if FileManager.default.fileExists(atPath: cursor.path),
               (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw AgentScenarioReplayError.unsafeFixturePath(step: step, path: relativePath)
            }
        }
        let destination = root.appendingPathComponent(relativePath).standardizedFileURL
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        guard parent.path == root.path || parent.path.hasPrefix(root.path + "/") else {
            throw AgentScenarioReplayError.unsafeFixturePath(step: step, path: relativePath)
        }
        do {
            try Data(contents.utf8).write(to: destination, options: .atomic)
        } catch {
            throw AgentScenarioReplayError.unsafeFixturePath(step: step, path: relativePath)
        }
    }

    fileprivate static func placeholderNames(in value: String) -> [String] {
        var result: [String] = []
        var cursor = value.startIndex
        while let opening = value.range(of: "${", range: cursor..<value.endIndex),
              let closing = value[opening.upperBound...].firstIndex(of: "}") {
            result.append(String(value[opening.upperBound..<closing]))
            cursor = value.index(after: closing)
        }
        return result
    }
}

private struct BoundedLineReader {
    let handle: FileHandle
    private var buffered = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    mutating func readLine(maximumBytes: Int, step: Int) throws -> String? {
        while true {
            if let newline = buffered.firstIndex(of: 0x0A) {
                let line = buffered[..<newline]
                guard line.count <= maximumBytes else {
                    throw AgentScenarioReplayError.hostLineTooLarge(
                        step: step,
                        maximum: maximumBytes
                    )
                }
                buffered.removeSubrange(...newline)
                return String(decoding: line, as: UTF8.self)
            }
            guard buffered.count <= maximumBytes else {
                throw AgentScenarioReplayError.hostLineTooLarge(
                    step: step,
                    maximum: maximumBytes
                )
            }
            let chunk = try handle.read(upToCount: min(4_096, maximumBytes + 1)) ?? Data()
            if chunk.isEmpty {
                guard !buffered.isEmpty else { return nil }
                let line = buffered
                buffered.removeAll()
                return String(decoding: line, as: UTF8.self)
            }
            buffered.append(chunk)
        }
    }
}

private enum JSONSubsetMatcher {
    static func match(
        expected expectedText: String,
        actual actualText: String,
        bindings: inout [String: String],
        step: Int
    ) throws {
        guard let expected = json(expectedText) else {
            throw AgentScenarioReplayError.invalidExpectedJSON(step: step)
        }
        guard let actual = json(actualText) else {
            throw AgentScenarioReplayError.invalidActualJSON(step: step)
        }
        if let reason = mismatch(expected, actual, path: "$", bindings: &bindings) {
            throw AgentScenarioReplayError.hostMessageMismatch(step: step, reason: reason)
        }
    }

    private static func json(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func mismatch(
        _ expected: Any,
        _ actual: Any,
        path: String,
        bindings: inout [String: String]
    ) -> String? {
        if let expected = expected as? [String: Any] {
            guard let actual = actual as? [String: Any] else { return "\(path) is not an object" }
            for key in expected.keys.sorted() {
                guard let expectedValue = expected[key] else { continue }
                guard let actualValue = actual[key] else { return "\(path).\(key) is missing" }
                if let mismatch = mismatch(
                    expectedValue,
                    actualValue,
                    path: "\(path).\(key)",
                    bindings: &bindings
                ) { return mismatch }
            }
            return nil
        }
        if let expected = expected as? [Any] {
            guard let actual = actual as? [Any] else { return "\(path) is not an array" }
            guard expected.count == actual.count else {
                return "\(path) expected \(expected.count) items, found \(actual.count)"
            }
            for index in expected.indices {
                if let mismatch = mismatch(
                    expected[index],
                    actual[index],
                    path: "\(path)[\(index)]",
                    bindings: &bindings
                ) { return mismatch }
            }
            return nil
        }
        if let expected = expected as? String,
           expected.hasPrefix("${"),
           expected.hasSuffix("}"),
           AgentScenarioReplayer.placeholderNames(in: expected).count == 1 {
            let name = String(expected.dropFirst(2).dropLast())
            guard let actual = actual as? String else { return "\(path) is not a string" }
            if let bound = bindings[name] {
                return bound == actual ? nil : "\(path) expected bound ${\(name)}"
            }
            bindings[name] = actual
            return nil
        }
        if let expected = expected as? String {
            var rendered = expected
            for name in AgentScenarioReplayer.placeholderNames(in: expected) {
                guard let bound = bindings[name] else {
                    return "\(path) uses unbound ${\(name)}"
                }
                rendered = rendered.replacingOccurrences(of: "${\(name)}", with: bound)
            }
            guard let actual = actual as? String, rendered == actual else {
                return "\(path) has an unexpected value"
            }
            return nil
        }
        guard NSObjectProtocolEquality.equal(expected, actual) else {
            return "\(path) has an unexpected value"
        }
        return nil
    }
}

private enum NSObjectProtocolEquality {
    static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        if lhs is NSNull, rhs is NSNull { return true }
        if let lhs = lhs as? NSNumber, let rhs = rhs as? NSNumber {
            return CFGetTypeID(lhs) == CFGetTypeID(rhs) && lhs == rhs
        }
        if let lhs = lhs as? NSString, let rhs = rhs as? NSString { return lhs == rhs }
        return false
    }
}
