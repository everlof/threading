import Foundation
import XCTest
@testable import Threading

/// A deterministic dump of what every Foundation→`JSONValue` boundary answers for a fixed corpus.
///
/// The corpus is built by parsing **JSON text** through `JSONSerialization`, because that is what
/// the wire actually hands these adapters: a Swift dictionary literal produces `Bool` and `Int`
/// rather than `__NSCFBoolean` and `__NSCFNumber`, and so cannot reproduce the class of defect
/// this boundary has already shipped once. Members that JSON cannot express are spliced into the
/// parsed value afterwards, which is the only way a non-JSON member can reach these call sites at
/// all.
///
/// The dump exists to be diffed across a change to the boundary. It deliberately describes values
/// with `if case` chains rather than an exhaustive `switch`, so the harness itself stays
/// byte-identical when a case is added to `JSONValue` and every difference in the output belongs
/// to the code under test.
///
/// The dump lands in a stable file rather than the test log, so an ordinary run stays quiet and
/// the previous run is always overwritten: `$TMPDIR/threading-json-conversion-corpus.txt`, or
/// `THREADING_JSON_CORPUS_OUT` when that names a path. The test prints where it wrote.
final class JSONConversionCorpusDumpTests: XCTestCase {
    func testDumpsEveryFoundationConversionBoundary() throws {
        var lines: [String] = []

        for sample in Self.corpus() {
            lines.append(contentsOf: Self.dump(sample: sample))
        }

        XCTAssertEqual(lines.count, Self.corpus().count * Self.sitesPerSample)
        let path = ProcessInfo.processInfo.environment["THREADING_JSON_CORPUS_OUT"]
            ?? NSTemporaryDirectory() + "threading-json-conversion-corpus.txt"
        try (lines.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        print("json conversion corpus: \(lines.count) records at \(path)")
    }

    /// Every entry point `dump(sample:)` records, so a site silently dropped from the harness
    /// fails rather than shrinking the evidence.
    static let sitesPerSample = 13

    // MARK: - Corpus

    struct Sample {
        let name: String
        /// The parsed document, with any non-JSON members spliced in.
        let object: [String: Any]
        /// The document as it arrived on the wire, before splicing.
        ///
        /// An adapter that parses its own line can only ever be handed this, which is itself a
        /// finding: a non-JSON member cannot reach that adapter's conversion at all.
        let jsonText: String
        let spliced: Bool
    }

    /// Parses `text` and splices any non-JSON members in afterwards.
    ///
    /// `splice` is keyed by a dotted path, where a numeric segment indexes an array.
    private static func sample(
        _ name: String,
        _ text: String,
        splice: [String: Any] = [:]
    ) -> Sample {
        guard let data = text.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Sample(
                name: name,
                object: ["corpus_parse_failed": text],
                jsonText: "{}",
                spliced: false
            )
        }
        for (path, value) in splice.sorted(by: { $0.key < $1.key }) {
            object = insert(value, at: path.components(separatedBy: "."), into: object)
        }
        return Sample(name: name, object: object, jsonText: text, spliced: !splice.isEmpty)
    }

    private static func insert(
        _ value: Any,
        at path: [String],
        into object: [String: Any]
    ) -> [String: Any] {
        guard let head = path.first else { return object }
        var result = object
        if path.count == 1 {
            result[head] = value
            return result
        }
        let rest = Array(path.dropFirst())
        if let child = result[head] as? [String: Any] {
            result[head] = insert(value, at: rest, into: child)
        } else if var list = result[head] as? [Any],
                  let index = Int(rest[0]), index < list.count {
            if rest.count == 1 {
                list[index] = value
            } else if let child = list[index] as? [String: Any] {
                list[index] = insert(value, at: Array(rest.dropFirst()), into: child)
            }
            result[head] = list
        }
        return result
    }

    /// A value `JSONSerialization` never produces, standing in for whatever an in-process caller
    /// puts in one of these dictionaries. Fixed, so the dump does not change between runs.
    private static let notJSON = Date(timeIntervalSince1970: 0)
    private static let alsoNotJSON = URL(fileURLWithPath: "/tmp/corpus")

    static func corpus() -> [Sample] {
        [
            sample("empty", "{}"),
            sample(
                "scalars",
                """
                {"zero":0,"one":1,"true":true,"false":false,"null":null,\
                "text":"hello","float":1.5,"negative":-3,"exponent":1e3}
                """
            ),
            sample(
                "nested",
                """
                {"outer":{"inner":[1,2,{"leaf":null}],"empty_object":{},"empty_array":[]},\
                "list":[{"a":"b"},[true,false],"tail"]}
                """
            ),
            sample(
                "large_numbers",
                """
                {"big":9007199254740993,"huge":12345678901234567890,"tiny":-0.000001}
                """
            ),
            sample(
                "escapes",
                """
                {"text":"line\\nbreak \\"quoted\\" \\u00e9 \\\\ / ok"}
                """
            ),
            sample(
                "one_unconvertible_member",
                """
                {"command":"git status","cwd":"/repo","timeout":120}
                """,
                splice: ["when": notJSON]
            ),
            sample(
                "unconvertible_nested_in_object",
                """
                {"outer":{"kept":"yes","dropped":null},"sibling":"intact"}
                """,
                splice: ["outer.dropped": notJSON]
            ),
            sample(
                "unconvertible_nested_in_array",
                """
                {"items":["first","second","third"],"count":3}
                """,
                splice: ["items.1": alsoNotJSON]
            ),
            sample(
                "entirely_unconvertible",
                """
                {"only":null}
                """,
                splice: ["only": notJSON]
            ),
            sample(
                "two_unconvertible_members",
                """
                {"a":null,"b":null,"c":"kept"}
                """,
                splice: ["a": notJSON, "b": alsoNotJSON]
            )
        ]
    }

    // MARK: - Sites

    private static func dump(sample: Sample) -> [String] {
        var lines: [String] = []
        func emit(_ site: String, _ value: String) {
            lines.append("CORPUS|\(sample.name)|\(site)|\(value)")
        }

        // The shared helpers every one of the call sites goes through.
        emit(
            "JSONValue.object(from:)",
            JSONValue.object(from: sample.object).map(described) ?? "nil"
        )
        emit(
            "JSONValue.init(foundationValue:)",
            JSONValue(foundationValue: sample.object).map(described) ?? "nil"
        )

        // ProviderExecutionAdapters — the execution-audit ledger.
        //
        // Claude's adapter parses its own line, so its dictionary can only ever be
        // `JSONSerialization` output; the corpus reaches it as the tool `input`.
        emit("ClaudeProviderExecutionAdapter.events(line:)", describedEvents(
            ClaudeProviderExecutionAdapter.events(
                line: Self.claudeAssistantLine(inputJSON: sample.jsonText)
            )
        ))
        emit("ClaudeProviderExecutionAdapter.result(line:)", describedEvents(
            ClaudeProviderExecutionAdapter.events(
                line: Self.claudeResultLine(contentJSON: sample.jsonText)
            )
        ))
        emit("splice_reaches_claude_adapter", sample.spliced ? "no (line is parsed here)" : "n/a")
        emit("CodexProviderExecutionAdapter.events(started)", describedEvents(
            CodexProviderExecutionAdapter.events(
                method: "item/started",
                parameters: [
                    "item": Self.merged(
                        ["id": "call-1", "type": "commandExecution"],
                        sample.object
                    )
                ]
            )
        ))
        emit("ACPProviderExecutionAdapter.event", describedEvent(
            ACPProviderExecutionAdapter.event(
                update: Self.merged(["toolCallId": "acp-1"], sample.object),
                operation: "Read file",
                kind: .read,
                phase: .requested,
                asInput: true
            )
        ))

        // CodexAppServerEvent — the native conversation timeline.
        emit("CodexAppServerEvent.fileChange", describedStreamEvents(
            CodexAppServerEvent.streamEvents(
                method: "item/started",
                parameters: [
                    "item": Self.merged(["id": "fc-1", "type": "fileChange"], sample.object)
                ]
            )
        ))
        emit("CodexAppServerEvent.plan", describedStreamEvents(
            CodexAppServerEvent.streamEvents(
                method: "item/started",
                parameters: ["item": Self.merged(["id": "pl-1", "type": "plan"], sample.object)]
            )
        ))
        emit("CodexAppServerEvent.mcpToolCall", describedStreamEvents(
            CodexAppServerEvent.streamEvents(
                method: "item/started",
                parameters: [
                    "item": [
                        "id": "mcp-1",
                        "type": "mcpToolCall",
                        "server": "threading",
                        "tool": "display_image",
                        "arguments": sample.object
                    ]
                ]
            )
        ))
        emit("CodexAppServerEvent.dynamicToolCall", describedStreamEvents(
            CodexAppServerEvent.streamEvents(
                method: "item/started",
                parameters: [
                    "item": [
                        "id": "dyn-1",
                        "type": "dynamicToolCall",
                        "tool": "shell",
                        "arguments": sample.object
                    ]
                ]
            )
        ))

        // TranscriptReplay — a replayed Codex rollout.
        emit("TranscriptReplay.codexEvent", describedStreamEvent(
            TranscriptReplay.codexEvent(from: [
                "type": "response_item",
                "payload": [
                    "type": "custom_tool_call",
                    "call_id": "rep-1",
                    "name": "shell",
                    "input": sample.object
                ]
            ])
        ))

        // StreamEvent.contentBlock — a replayed Claude transcript tool row.
        emit("StreamEvent.contentBlock", describedBlock(
            StreamEvent.contentBlock([
                "type": "tool_use",
                "id": "blk-1",
                "name": "Bash",
                "input": sample.object
            ])
        ))

        return lines
    }

    private static func merged(_ base: [String: Any], _ extra: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in extra where result[key] == nil {
            result[key] = value
        }
        return result
    }

    private static func claudeAssistantLine(inputJSON: String) -> String {
        """
        {"type":"assistant","message":{"content":[\
        {"type":"tool_use","id":"tu-1","name":"Bash","input":\(inputJSON)}]}}
        """
    }

    private static func claudeResultLine(contentJSON: String) -> String {
        """
        {"type":"user","message":{"content":[\
        {"type":"tool_result","tool_use_id":"tu-1","content":\(contentJSON)}]}}
        """
    }

    // MARK: - Describers
    //
    // `if case` rather than `switch` on purpose: a new `JSONValue` case must not change this
    // file, or the diff stops being evidence about the code under test.

    static func described(_ value: JSONValue) -> String {
        if case .null = value { return "null" }
        if case .bool(let value) = value { return "bool(\(value))" }
        if case .integer(let value) = value { return "integer(\(value))" }
        if case .number(let value) = value { return "number(\(value))" }
        if case .string(let value) = value { return "string(\(escaped(value)))" }
        if case .array(let values) = value {
            return "array[" + values.map(described).joined(separator: ",") + "]"
        }
        if case .object(let values) = value { return described(values) }
        return "other(\(escaped(value.encodedText())))"
    }

    /// One record per line, so the dump can be diffed. A tool argument really does contain
    /// newlines, tabs and pipes.
    private static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "|", with: "\\pipe")
    }

    static func described(_ object: [String: JSONValue]) -> String {
        "object{" + object.keys.sorted().map { key in
            "\(key):\(described(object[key]!))"
        }.joined(separator: ",") + "}"
    }

    private static func describedEvents(_ events: [ProviderExecutionEvent]) -> String {
        "[" + events.map { describedEvent($0) }.joined(separator: ",") + "]"
    }

    private static func describedEvent(_ event: ProviderExecutionEvent?) -> String {
        guard let event else { return "nil" }
        return [
            "category=\(event.category.rawValue)",
            "phase=\(event.phase.rawValue)",
            "operation=\(event.operation ?? "nil")",
            "callID=\(event.callID)",
            "input=\(event.input.map(described) ?? "nil")",
            "output=\(event.output.map(described) ?? "nil")",
            "fidelity=\(event.fidelity.rawValue)"
        ].joined(separator: " ")
    }

    private static func describedStreamEvents(_ events: [StreamEvent]) -> String {
        "[" + events.map(describedStreamEvent).joined(separator: ",") + "]"
    }

    private static func describedStreamEvent(_ event: StreamEvent?) -> String {
        guard let event else { return "nil" }
        if case .assistantMessage(let blocks) = event {
            return "assistantMessage[" + blocks.map(describedBlock).joined(separator: ",") + "]"
        }
        if case .toolResults(let results) = event {
            return "toolResults[" + results.map {
                "\($0.toolUseID):isError=\($0.isError):\(escaped($0.text))"
            }.joined(separator: ",") + "]"
        }
        return "otherStreamEvent"
    }

    private static func describedBlock(_ block: ContentBlock?) -> String {
        guard let block else { return "nil" }
        if case .text(let text) = block { return "text(\(escaped(text)))" }
        if case .thinking(let text) = block { return "thinking(\(escaped(text)))" }
        if case .toolUse(let id, let tool, let input) = block {
            return "toolUse(id=\(id),tool=\(tool.rawName),input=\(described(input)))"
        }
        return "otherBlock"
    }
}
