import XCTest
@testable import Threading

/// Reads every `ACPWireAdapter` entry point against one fixed corpus of payloads.
///
/// The payloads are built from JSON text through `JSONSerialization`, the way the live transport
/// builds them, rather than from Swift dictionary literals. That is deliberate: a Swift `1` in an
/// `Any` is an `Int` and a JSON `1` is an `NSNumber`, and several of the casts under test behave
/// differently for the two. A corpus written as literals cannot see the difference the wire does.
///
/// The rendered corpus is written to `acp-wire-corpus.txt` under `THREADING_RENDER_OUT`, the same
/// evidence root the rendered-state tests use, so two builds can be diffed line by line.
final class ACPWireAdapterTests: XCTestCase {

    // MARK: - Corpus

    func testRendersTheWireCorpus() throws {
        let text = ACPWireCorpus.render()
        XCTAssertFalse(text.isEmpty)
        guard let root = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
              !root.isEmpty else { return }
        let url = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("acp-wire-corpus.txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Session

    func testCurrentModelReadsTheStandardLocationAndNothingElse() {
        XCTAssertNil(ACPWireAdapter.currentModel(in: nil))
        XCTAssertNil(ACPWireAdapter.currentModel(in: json("{}")))
        XCTAssertNil(ACPWireAdapter.currentModel(in: json(#"{"models":{}}"#)))
        XCTAssertNil(ACPWireAdapter.currentModel(in: json(#"{"models":"sonnet"}"#)))
        XCTAssertNil(ACPWireAdapter.currentModel(in: json(#"{"models":{"currentModelId":7}}"#)))
        XCTAssertNil(ACPWireAdapter.currentModel(in: json(#"{"currentModelId":"sonnet"}"#)))
        XCTAssertEqual(
            ACPWireAdapter.currentModel(in: json(#"{"models":{"currentModelId":"sonnet-4"}}"#)),
            "sonnet-4"
        )
    }

    func testSessionTitleTrimsAndRefusesAnEmptyTitle() {
        XCTAssertNil(ACPWireAdapter.sessionTitle(in: json("{}")))
        XCTAssertNil(ACPWireAdapter.sessionTitle(in: json(#"{"title":""}"#)))
        XCTAssertNil(ACPWireAdapter.sessionTitle(in: json(#"{"title":"   \n "}"#)))
        XCTAssertNil(ACPWireAdapter.sessionTitle(in: json(#"{"title":12}"#)))
        XCTAssertNil(ACPWireAdapter.sessionTitle(in: json(#"{"title":null}"#)))
        XCTAssertEqual(ACPWireAdapter.sessionTitle(in: json(#"{"title":"  Fix it  "}"#)), "Fix it")
    }

    func testTextContentReadsOnlyATextBlock() {
        XCTAssertNil(ACPWireAdapter.textContent(in: json("{}")))
        XCTAssertNil(ACPWireAdapter.textContent(in: json(#"{"content":"hello"}"#)))
        XCTAssertNil(ACPWireAdapter.textContent(in: json(#"{"content":{"type":"image"}}"#)))
        XCTAssertNil(ACPWireAdapter.textContent(in: json(#"{"content":{"type":"text"}}"#)))
        XCTAssertNil(ACPWireAdapter.textContent(in: json(#"{"content":{"type":"text","text":3}}"#)))
        XCTAssertEqual(
            ACPWireAdapter.textContent(in: json(#"{"content":{"type":"text","text":"hi"}}"#)),
            "hi"
        )
        XCTAssertEqual(
            ACPWireAdapter.textContent(in: json(#"{"content":{"type":"text","text":""}}"#)),
            ""
        )
    }

    func testContextUsageRefusesABooleanAndTruncatesTowardZero() {
        func used(_ text: String) -> Int? {
            ACPWireAdapter.contextUsage(in: json(text)).used
        }
        XCTAssertNil(used("{}"))
        XCTAssertNil(used(#"{"used":null}"#))
        XCTAssertNil(used(#"{"used":true}"#))
        XCTAssertNil(used(#"{"used":false}"#))
        XCTAssertNil(used(#"{"used":"12"}"#))
        XCTAssertEqual(used(#"{"used":0}"#), 0)
        XCTAssertEqual(used(#"{"used":1}"#), 1)
        XCTAssertEqual(used(#"{"used":1.9}"#), 1)
        XCTAssertEqual(used(#"{"used":-1.9}"#), -1)
        XCTAssertEqual(used(#"{"used":10000000000}"#), 10_000_000_000)

        let both = ACPWireAdapter.contextUsage(in: json(#"{"used":120,"size":200000}"#))
        XCTAssertEqual(both.used, 120)
        XCTAssertEqual(both.size, 200_000)
    }

    func testPlanStepsKeepsRecognisedStatusesAndDropsTheRest() {
        XCTAssertEqual(ACPWireAdapter.planSteps(in: json("{}")).count, 0)
        XCTAssertEqual(ACPWireAdapter.planSteps(in: json(#"{"entries":[]}"#)).count, 0)
        XCTAssertEqual(ACPWireAdapter.planSteps(in: json(#"{"entries":"nope"}"#)).count, 0)

        let steps = ACPWireAdapter.planSteps(in: json("""
        {"entries":[
          {"content":"Read the file","status":"pending","priority":"high"},
          {"content":"Edit it","status":"in_progress"},
          {"content":"Done","status":"completed"},
          {"content":"Blocked","status":"blocked"},
          {"content":"No status"},
          {"status":"pending"},
          {"content":7,"status":"pending"}
        ]}
        """))
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[0].title, "Read the file")
        XCTAssertEqual(steps[0].status, .pending)
        XCTAssertNil(steps[0].id)
        XCTAssertEqual(steps[1].title, "Edit it")
        XCTAssertEqual(steps[1].status, .inProgress)
        XCTAssertEqual(steps[2].title, "Done")
        XCTAssertEqual(steps[2].status, .completed)
    }

    // MARK: - Command Catalog

    func testComposerCapabilitiesAppliesThePolicyAndRefusesAnIncompleteCommand() {
        let commands = jsonArray("""
        [
          {"name":"plan","description":"Make a plan","input":{"hint":"<goal>"}},
          {"name":"compact","description":"Compact the session"},
          {"name":"login","description":"Log in"},
          {"name":"","description":"Nameless"},
          {"name":"nodesc"},
          {"name":"badhint","description":"Odd input","input":"hint"},
          {"name":"numdesc","description":4}
        ]
        """)
        let capabilities = ACPWireAdapter.composerCapabilities(from: commands, policy: policy)
        XCTAssertEqual(capabilities.map(\.name), ["plan", "compact", "login", "badhint"])
        XCTAssertEqual(capabilities[0].id, "acp:plan")
        XCTAssertEqual(capabilities[0].description, "Make a plan")
        XCTAssertEqual(capabilities[0].argumentHint, "<goal>")
        XCTAssertEqual(capabilities[0].presentation, .turn)
        XCTAssertEqual(capabilities[0].availability, .available)
        XCTAssertEqual(capabilities[1].presentation, .command)
        XCTAssertEqual(capabilities[2].availability, .unavailable(reason: "Agent terminal only."))
        XCTAssertEqual(capabilities[3].argumentHint, "")
    }

    // MARK: - Tool Calls

    func testToolIdentityMapsEveryKind() {
        func identity(_ kind: ACPToolCallKind?) -> String {
            ACPWireAdapter.toolIdentity(kind: kind, title: "Grep the tree").rawName
        }
        XCTAssertEqual(identity(.read), "Read")
        XCTAssertEqual(identity(.edit), "Edit")
        XCTAssertEqual(identity(.delete), "Edit")
        XCTAssertEqual(identity(.move), "Edit")
        XCTAssertEqual(identity(.search), "Grep")
        XCTAssertEqual(identity(.execute), "Bash")
        XCTAssertEqual(identity(.think), "Plan")
        XCTAssertEqual(identity(.fetch), "WebFetch")
        XCTAssertEqual(identity(.unknown("teleport")), "Grep the tree")
        XCTAssertEqual(identity(nil), "Grep the tree")
    }

    func testToolInputPrefersRawInputAndFillsTheEditFieldsFromADiff() {
        let input = ACPWireAdapter.toolInput(from: json("""
        {"toolCallId":"c1","title":"Edit main.swift","kind":"edit","status":"completed",
         "rawInput":{"instruction":"tidy","retries":1,"dry_run":false},
         "locations":[{"path":"/repo/main.swift","line":10},{"path":"/repo/other.swift"}],
         "content":[
           {"type":"content","content":{"type":"text","text":"ignored here"}},
           {"type":"diff","path":"/repo/main.swift","oldText":"a","newText":"b"}
         ]}
        """))
        XCTAssertEqual(input["instruction"], .string("tidy"))
        XCTAssertEqual(input["retries"], .integer(1))
        XCTAssertEqual(input["dry_run"], .bool(false))
        XCTAssertEqual(input["title"], .string("Edit main.swift"))
        XCTAssertEqual(input["kind"], .string("edit"))
        XCTAssertEqual(input["file_path"], .string("/repo/main.swift"))
        XCTAssertEqual(input["old_string"], .string("a"))
        XCTAssertEqual(input["new_string"], .string("b"))
        XCTAssertEqual(input.count, 8)
    }

    func testToolInputWrapsANonObjectRawInputAndKeepsWhatRawInputAlreadySaid() {
        let wrapped = ACPWireAdapter.toolInput(from: json(#"{"rawInput":"just text"}"#))
        XCTAssertEqual(wrapped, ["input": .string("just text")])

        let list = ACPWireAdapter.toolInput(from: json(#"{"rawInput":[1,2]}"#))
        XCTAssertEqual(list, ["input": .array([.integer(1), .integer(2)])])

        XCTAssertEqual(ACPWireAdapter.toolInput(from: json(#"{"rawInput":null}"#)), [:])
        XCTAssertEqual(ACPWireAdapter.toolInput(from: json("{}")), [:])

        let kept = ACPWireAdapter.toolInput(from: json("""
        {"title":"Wire title","kind":"read",
         "rawInput":{"title":"Own title","kind":"own","file_path":"/own.swift"},
         "locations":[{"path":"/wire.swift"}],
         "content":[{"type":"diff","path":"/diff.swift","oldText":"x","newText":"y"}]}
        """))
        XCTAssertEqual(kept["title"], .string("Own title"))
        XCTAssertEqual(kept["kind"], .string("own"))
        XCTAssertEqual(kept["file_path"], .string("/own.swift"))
        XCTAssertEqual(kept["old_string"], .string("x"))
        XCTAssertEqual(kept["new_string"], .string("y"))
    }

    func testToolInputLeavesTheEditFieldsAloneWhenNoContentEntryIsADiff() {
        let input = ACPWireAdapter.toolInput(from: json("""
        {"title":"Run tests","kind":"execute",
         "content":[{"type":"content","content":{"type":"text","text":"ok"}},
                    {"type":"terminal","terminalId":"t1"}]}
        """))
        XCTAssertEqual(input, ["title": .string("Run tests"), "kind": .string("execute")])
    }

    func testToolInputTakesTheFirstLocationPathOnly() {
        let input = ACPWireAdapter.toolInput(from: json("""
        {"locations":[{"line":3},{"path":"/second.swift"}]}
        """))
        XCTAssertEqual(input, [:])
    }

    func testToolResultTextPrefersRawOutput() {
        XCTAssertEqual(
            ACPWireAdapter.toolResultText(from: json(#"{"rawOutput":"plain"}"#)),
            "plain"
        )
        XCTAssertEqual(
            ACPWireAdapter.toolResultText(from: json(#"{"rawOutput":{"b":2,"a":1}}"#)),
            "{\n  \"a\" : 1,\n  \"b\" : 2\n}"
        )
        XCTAssertEqual(ACPWireAdapter.toolResultText(from: json(#"{"rawOutput":42}"#)), "42")
        XCTAssertEqual(ACPWireAdapter.toolResultText(from: json(#"{"rawOutput":1.5}"#)), "1.5")
    }

    /// A bare scalar `rawOutput` is rendered as the JSON it is.
    ///
    /// This is the one place the typed reading deliberately differs from the dictionary one it
    /// replaced: a boolean used to reach `String(describing:)` still wrapped in an `NSNumber`,
    /// whose description is `1`, so an agent answering `true` produced a tool row reading `1`.
    func testToolResultTextRendersABareScalarRawOutputAsJSON() {
        XCTAssertEqual(ACPWireAdapter.toolResultText(from: json(#"{"rawOutput":true}"#)), "true")
        XCTAssertEqual(
            ACPWireAdapter.toolResultText(from: json(#"{"rawOutput":[1,2]}"#)),
            "[\n  1,\n  2\n]"
        )
    }

    /// The wire's `1` is one, not `true`.
    ///
    /// `NSNumber as? Bool` succeeds for exactly `0` and `1`, so a conversion that asks whether a
    /// parsed number *can* be read as a boolean answers yes for two of them. Every ACP tool input
    /// and every audited ACP payload went through that question. The corpus is built from JSON
    /// text for this reason: written as Swift literals, `1` is an `Int` and the cast never fires,
    /// so a test can pass while the shipping path is wrong.
    func testJSONValueClassifiesParsedNumbersAsNumbersAndBooleansAsBooleans() {
        let parsed = ACPWireCorpus.object(
            #"{"one":1,"zero":0,"two":2,"whole":1.0,"fraction":0.5,"yes":true,"no":false}"#
        )
        let converted = JSONValue.object(from: parsed)
        XCTAssertEqual(converted?["one"], .integer(1))
        XCTAssertEqual(converted?["zero"], .integer(0))
        XCTAssertEqual(converted?["two"], .integer(2))
        XCTAssertEqual(converted?["whole"], .integer(1))
        XCTAssertEqual(converted?["fraction"], .number(0.5))
        XCTAssertEqual(converted?["yes"], .bool(true))
        XCTAssertEqual(converted?["no"], .bool(false))

        XCTAssertEqual(JSONValue(foundationValue: true), .bool(true))
        XCTAssertEqual(JSONValue(foundationValue: false), .bool(false))
        XCTAssertEqual(JSONValue(foundationValue: 1), .integer(1))
        XCTAssertEqual(JSONValue(foundationValue: 0), .integer(0))
    }

    func testToolResultTextFallsBackToTheContentBlocks() {
        XCTAssertEqual(ACPWireAdapter.toolResultText(from: json("{}")), "")
        XCTAssertEqual(ACPWireAdapter.toolResultText(from: json(#"{"rawOutput":null}"#)), "")
        XCTAssertEqual(
            ACPWireAdapter.toolResultText(from: json(#"{"rawOutput":null,"content":[]}"#)),
            ""
        )
        XCTAssertEqual(
            ACPWireAdapter.toolResultText(from: json("""
            {"content":[
              {"type":"content","content":{"type":"text","text":"first"}},
              {"type":"content","content":{"type":"image","data":"…"}},
              {"type":"content","content":"bare"},
              {"type":"diff","path":"/repo/main.swift"},
              {"type":"terminal","terminalId":"term-9"},
              {"type":"teleport","payload":"?"},
              {"content":{"type":"text","text":"typeless"}}
            ]}
            """)),
            "first\n/repo/main.swift\nterm-9"
        )
    }

    // MARK: - Tool Call State

    func testToolCallStateDefaultsItsTitleAndMergesLaterUpdates() {
        var state = ACPToolCallState(update: json(#"{"toolCallId":"c1"}"#))
        XCTAssertEqual(state.title, "tool")
        XCTAssertNil(state.kind)
        XCTAssertNil(state.status)
        XCTAssertFalse(state.didEmitCall)
        XCTAssertFalse(state.didEmitResult)

        state.merge(json(#"{"title":"Read it","kind":"read","status":"in_progress"}"#))
        XCTAssertEqual(state.title, "Read it")
        XCTAssertEqual(state.kind, .read)
        XCTAssertEqual(state.status, .inProgress)
        XCTAssertEqual(state.status?.isTerminal, false)

        state.merge(json(#"{"status":"completed","rawOutput":"done"}"#))
        XCTAssertEqual(state.title, "Read it")
        XCTAssertEqual(state.status, .completed)
        XCTAssertEqual(state.status?.isTerminal, true)
        XCTAssertEqual(ACPWireAdapter.toolResultText(from: state.payload), "done")

        state.merge(json(#"{"title":9,"kind":7,"status":false}"#))
        XCTAssertEqual(state.title, "Read it")
        XCTAssertEqual(state.kind, .read)
        XCTAssertEqual(state.status, .completed)
    }

    func testToolCallStateKeepsAnUnrecognisedKindAndStatusVerbatim() {
        var state = ACPToolCallState(update: json(#"{"kind":"teleport","status":"paused"}"#))
        XCTAssertEqual(state.kind, .unknown("teleport"))
        XCTAssertEqual(state.status, .unknown("paused"))
        XCTAssertEqual(state.status?.isTerminal, false)
        XCTAssertEqual(state.kind?.providerValue, "teleport")

        state.merge(json(#"{"status":"failed"}"#))
        XCTAssertEqual(state.status, .failed)
        XCTAssertEqual(state.status?.isTerminal, true)
    }

    // MARK: - Turn Outcome

    func testStopReasonNamesOnlyTheTwoTheProtocolDistinguishes() {
        XCTAssertEqual(TurnOutcome(acpStopReason: "cancelled"), .stopped)
        XCTAssertEqual(TurnOutcome(acpStopReason: "refusal"), .failed)
        XCTAssertEqual(TurnOutcome(acpStopReason: "end_turn"), .completed)
        XCTAssertEqual(TurnOutcome(acpStopReason: "max_tokens"), .completed)
        XCTAssertEqual(TurnOutcome(acpStopReason: "max_turn_requests"), .completed)
        XCTAssertEqual(TurnOutcome(acpStopReason: "teleported"), .completed)
        XCTAssertEqual(TurnOutcome(acpStopReason: nil), .completed)
    }

    // MARK: - Helpers

    private var policy: ACPCommandCatalogPolicy {
        ACPCommandCatalogPolicy(
            identifierPrefix: "acp:",
            hostOnlyNames: ["login"],
            hostOnlyReason: "Agent terminal only.",
            sessionCommandNames: ["compact"]
        )
    }

    private func json(_ text: String) -> [String: Any] {
        ACPWireCorpus.object(text)
    }

    private func jsonArray(_ text: String) -> [[String: Any]] {
        ACPWireCorpus.objects(text)
    }
}

// MARK: - Corpus

/// One fixed set of payloads read through every adapter entry point, rendered as text.
///
/// The rendering is deliberately independent of the adapter: it classifies a Foundation value the
/// way JSON does (a `__NSCFBoolean` is a boolean, an integral number is an integer), so the same
/// corpus can be rendered before and after a change of representation and compared line by line.
enum ACPWireCorpus {

    static func render() -> String {
        var lines: [String] = []
        lines.append("# ACP wire corpus")

        lines.append("\n## currentModel")
        for (name, text) in modelResults {
            lines.append("\(name) -> \(optional(ACPWireAdapter.currentModel(in: object(text))))")
        }
        lines.append("nil -> \(optional(ACPWireAdapter.currentModel(in: nil)))")

        lines.append("\n## sessionTitle")
        for (name, text) in titleUpdates {
            lines.append("\(name) -> \(optional(ACPWireAdapter.sessionTitle(in: object(text))))")
        }

        lines.append("\n## textContent")
        for (name, text) in contentUpdates {
            lines.append("\(name) -> \(optional(ACPWireAdapter.textContent(in: object(text))))")
        }

        lines.append("\n## integer")
        for (name, text) in usageUpdates {
            let value = ACPWireAdapter.contextUsage(in: object(text)).used
            lines.append("\(name) -> \(value.map(String.init) ?? "nil")")
        }

        lines.append("\n## planSteps")
        for (name, text) in planUpdates {
            let steps = ACPWireAdapter.planSteps(in: object(text))
                .map { "(\(optional($0.id)), \($0.title), \($0.status))" }
            lines.append("\(name) -> [\(steps.joined(separator: ", "))]")
        }

        lines.append("\n## composerCapabilities")
        for (name, text) in commandCatalogs {
            let capabilities = ACPWireAdapter.composerCapabilities(
                from: objects(text),
                policy: corpusPolicy
            ).map(describe)
            lines.append("\(name) -> [\(capabilities.joined(separator: ", "))]")
        }

        lines.append("\n## toolIdentity")
        for kind in corpusKinds {
            let identity = ACPWireAdapter.toolIdentity(kind: kind.1, title: "A wire title")
            lines.append("\(kind.0) -> \(identity.rawName)")
        }

        lines.append("\n## toolInput")
        for (name, text) in toolPayloads {
            lines.append("\(name) -> \(canon(payload: ACPWireAdapter.toolInput(from: object(text))))")
        }

        lines.append("\n## toolResultText")
        for (name, text) in toolResults {
            let value = ACPWireAdapter.toolResultText(from: object(text))
            lines.append("\(name) -> \(quoted(value))")
        }

        lines.append("\n## toolCallState")
        for (name, texts) in toolCallSequences {
            var state = ACPToolCallState(update: object(texts[0]))
            for text in texts.dropFirst() { state.merge(object(text)) }
            lines.append(
                "\(name) -> title=\(state.title) kind=\(optional(state.kind?.providerValue)) "
                + "status=\(optional(state.status.map(String.init(describing:)))) "
                + "terminal=\(state.status?.isTerminal == true) "
                + "payload=\(canon(payload: state.payload)) "
                + "result=\(quoted(ACPWireAdapter.toolResultText(from: state.payload)))"
            )
        }

        lines.append("\n## stopReason")
        for reason in stopReasons {
            lines.append("\(reason ?? "nil") -> \(TurnOutcome(acpStopReason: reason))")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Payloads

    private static let modelResults: [(String, String)] = [
        ("empty", "{}"),
        ("models-missing", #"{"sessionId":"s1"}"#),
        ("models-empty", #"{"models":{}}"#),
        ("models-string", #"{"models":"sonnet"}"#),
        ("models-null", #"{"models":null}"#),
        ("id-number", #"{"models":{"currentModelId":7}}"#),
        ("id-null", #"{"models":{"currentModelId":null}}"#),
        ("top-level-id", #"{"currentModelId":"sonnet"}"#),
        ("standard", #"{"models":{"currentModelId":"sonnet-4","availableModels":[]}}"#)
    ]

    private static let titleUpdates: [(String, String)] = [
        ("empty", "{}"),
        ("blank", #"{"title":""}"#),
        ("whitespace", #"{"title":"  \n\t "}"#),
        ("padded", #"{"title":"  Fix the parser  "}"#),
        ("number", #"{"title":12}"#),
        ("null", #"{"title":null}"#),
        ("plain", #"{"title":"Fix the parser"}"#)
    ]

    private static let contentUpdates: [(String, String)] = [
        ("empty", "{}"),
        ("content-string", #"{"content":"hello"}"#),
        ("content-array", #"{"content":[{"type":"text","text":"hi"}]}"#),
        ("content-null", #"{"content":null}"#),
        ("no-type", #"{"content":{"text":"hi"}}"#),
        ("image", #"{"content":{"type":"image","data":"…"}}"#),
        ("resource-link", #"{"content":{"type":"resource_link","uri":"file:///a"}}"#),
        ("text-missing", #"{"content":{"type":"text"}}"#),
        ("text-number", #"{"content":{"type":"text","text":3}}"#),
        ("text-empty", #"{"content":{"type":"text","text":""}}"#),
        ("text", #"{"content":{"type":"text","text":"hello there"},"messageId":"m1"}"#)
    ]

    private static let usageUpdates: [(String, String)] = [
        ("empty", "{}"),
        ("null", #"{"used":null}"#),
        ("true", #"{"used":true}"#),
        ("false", #"{"used":false}"#),
        ("string", #"{"used":"12"}"#),
        ("zero", #"{"used":0}"#),
        ("one", #"{"used":1}"#),
        ("fraction", #"{"used":1.9}"#),
        ("negative-fraction", #"{"used":-1.9}"#),
        ("large", #"{"used":10000000000}"#),
        ("object", #"{"used":{"tokens":5}}"#)
    ]

    private static let planUpdates: [(String, String)] = [
        ("empty", "{}"),
        ("entries-empty", #"{"entries":[]}"#),
        ("entries-string", #"{"entries":"nope"}"#),
        ("entries-null", #"{"entries":null}"#),
        ("entries-scalars", #"{"entries":["a","b"]}"#),
        ("standard", """
        {"entries":[{"content":"Read","status":"pending","priority":"high"},
                    {"content":"Edit","status":"in_progress","priority":"medium"},
                    {"content":"Ship","status":"completed","priority":"low"}]}
        """),
        ("camel-status", #"{"entries":[{"content":"Edit","status":"inProgress"}]}"#),
        ("unknown-status", #"{"entries":[{"content":"Blocked","status":"blocked"}]}"#),
        ("missing-status", #"{"entries":[{"content":"No status"}]}"#),
        ("missing-content", #"{"entries":[{"status":"pending"}]}"#),
        ("number-content", #"{"entries":[{"content":7,"status":"pending"}]}"#),
        ("mixed", """
        {"entries":[{"content":"Keep","status":"pending"},
                    {"content":"Drop","status":"blocked"},
                    {"content":"Keep too","status":"completed"}]}
        """)
    ]

    private static let commandCatalogs: [(String, String)] = [
        ("empty", "[]"),
        ("standard", """
        [{"name":"plan","description":"Make a plan","input":{"hint":"<goal>"}},
         {"name":"compact","description":"Compact the session"},
         {"name":"login","description":"Log in"}]
        """),
        ("degenerate", """
        [{"name":"","description":"Nameless"},
         {"name":"nodesc"},
         {"name":"nulldesc","description":null},
         {"name":"numdesc","description":4},
         {"name":"badhint","description":"Odd input","input":"hint"},
         {"name":"nullhint","description":"Null hint","input":{"hint":null}},
         {"name":"numname","description":"Fine"},
         {"name":"ok","description":"Fine","input":{"hint":"<x>"}}]
        """)
    ]

    private static let corpusKinds: [(String, ACPToolCallKind?)] = [
        ("read", .read), ("edit", .edit), ("delete", .delete), ("move", .move),
        ("search", .search), ("execute", .execute), ("think", .think), ("fetch", .fetch),
        ("unknown", .unknown("teleport")), ("nil", nil)
    ]

    private static let toolPayloads: [(String, String)] = [
        ("empty", "{}"),
        ("raw-null", #"{"rawInput":null}"#),
        ("raw-string", #"{"rawInput":"just text"}"#),
        ("raw-number", #"{"rawInput":7}"#),
        ("raw-bool", #"{"rawInput":true}"#),
        ("raw-array", #"{"rawInput":[1,2]}"#),
        ("raw-object", #"{"rawInput":{"path":"/a.swift","limit":200,"offset":0,"all":true}}"#),
        ("title-and-kind", #"{"title":"Read a file","kind":"read"}"#),
        ("title-number", #"{"title":9,"kind":7}"#),
        ("locations", #"{"locations":[{"path":"/a.swift","line":3},{"path":"/b.swift"}]}"#),
        ("locations-empty", #"{"locations":[]}"#),
        ("locations-no-path", #"{"locations":[{"line":3},{"path":"/b.swift"}]}"#),
        ("locations-string", #"{"locations":"/a.swift"}"#),
        ("content-no-diff", """
        {"content":[{"type":"content","content":{"type":"text","text":"ok"}},
                    {"type":"terminal","terminalId":"t1"}]}
        """),
        ("content-diff", """
        {"content":[{"type":"diff","path":"/a.swift","oldText":"a","newText":"b"}]}
        """),
        ("content-diff-partial", #"{"content":[{"type":"diff","path":"/a.swift"}]}"#),
        ("content-diff-null", """
        {"content":[{"type":"diff","path":null,"oldText":null,"newText":null}]}
        """),
        ("content-string", #"{"content":"text"}"#),
        ("raw-object-owns-fields", """
        {"title":"Wire","kind":"read",
         "rawInput":{"title":"Own","kind":"own","file_path":"/own.swift","old_string":"o"},
         "locations":[{"path":"/wire.swift"}],
         "content":[{"type":"diff","path":"/diff.swift","oldText":"x","newText":"y"}]}
        """),
        ("full", """
        {"toolCallId":"c1","title":"Edit main.swift","kind":"edit","status":"completed",
         "rawInput":{"instruction":"tidy","retries":1,"dry_run":false,"nested":{"n":0}},
         "locations":[{"path":"/repo/main.swift","line":10}],
         "content":[{"type":"content","content":{"type":"text","text":"ignored"}},
                    {"type":"diff","path":"/repo/main.swift","oldText":"a","newText":"b"}]}
        """)
    ]

    private static let toolResults: [(String, String)] = [
        ("empty", "{}"),
        ("raw-null", #"{"rawOutput":null}"#),
        ("raw-string", #"{"rawOutput":"plain"}"#),
        ("raw-empty-string", #"{"rawOutput":""}"#),
        ("raw-number", #"{"rawOutput":42}"#),
        ("raw-fraction", #"{"rawOutput":1.5}"#),
        ("raw-bool", #"{"rawOutput":true}"#),
        ("raw-object", #"{"rawOutput":{"b":2,"a":1}}"#),
        ("raw-object-path", #"{"rawOutput":{"path":"/a/b"}}"#),
        ("raw-array", #"{"rawOutput":[1,2]}"#),
        ("content-empty", #"{"content":[]}"#),
        ("content-string", #"{"content":"text"}"#),
        ("content-text", """
        {"content":[{"type":"content","content":{"type":"text","text":"first"}}]}
        """),
        ("content-nontext", """
        {"content":[{"type":"content","content":{"type":"image","data":"…"}}]}
        """),
        ("content-bare", #"{"content":[{"type":"content","content":"bare"}]}"#),
        ("content-text-number", """
        {"content":[{"type":"content","content":{"type":"text","text":5}}]}
        """),
        ("content-diff", #"{"content":[{"type":"diff","path":"/repo/main.swift"}]}"#),
        ("content-diff-no-path", #"{"content":[{"type":"diff","oldText":"a"}]}"#),
        ("content-terminal", #"{"content":[{"type":"terminal","terminalId":"term-9"}]}"#),
        ("content-unknown-type", #"{"content":[{"type":"teleport","payload":"?"}]}"#),
        ("content-typeless", #"{"content":[{"content":{"type":"text","text":"typeless"}}]}"#),
        ("content-mixed", """
        {"content":[{"type":"content","content":{"type":"text","text":"first"}},
                    {"type":"content","content":{"type":"image","data":"…"}},
                    {"type":"diff","path":"/repo/main.swift"},
                    {"type":"terminal","terminalId":"term-9"},
                    {"type":"teleport","payload":"?"}]}
        """),
        ("raw-output-beats-content", """
        {"rawOutput":"chosen","content":[{"type":"diff","path":"/ignored.swift"}]}
        """)
    ]

    private static let toolCallSequences: [(String, [String])] = [
        ("bare", [#"{"toolCallId":"c1"}"#]),
        ("opening", [#"{"toolCallId":"c1","title":"Read it","kind":"read","status":"pending"}"#]),
        ("unknown-vocabulary", [#"{"kind":"teleport","status":"paused"}"#]),
        ("progress", [
            #"{"toolCallId":"c1","title":"Read it","kind":"read","status":"pending"}"#,
            #"{"status":"in_progress"}"#,
            #"{"status":"completed","rawOutput":"done"}"#
        ]),
        ("wrong-types-do-not-clear", [
            #"{"toolCallId":"c1","title":"Read it","kind":"read","status":"completed"}"#,
            #"{"title":9,"kind":7,"status":false}"#
        ]),
        ("content-replaced", [
            #"{"toolCallId":"c1","content":[{"type":"diff","path":"/first.swift"}]}"#,
            #"{"content":[{"type":"diff","path":"/second.swift"}]}"#
        ]),
        ("numbers-survive", [
            #"{"toolCallId":"c1","rawInput":{"limit":1,"offset":0,"ratio":0.5,"flag":true}}"#
        ])
    ]

    private static let stopReasons: [String?] = [
        nil, "cancelled", "refusal", "end_turn", "max_tokens", "max_turn_requests", "teleported", ""
    ]

    private static let corpusPolicy = ACPCommandCatalogPolicy(
        identifierPrefix: "acp:",
        hostOnlyNames: ["login"],
        hostOnlyReason: "Agent terminal only.",
        sessionCommandNames: ["compact"]
    )

    // MARK: - Parsing

    static func object(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return value
    }

    static func objects(_ text: String) -> [[String: Any]] {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return value
    }

    // MARK: - Rendering

    /// Renders a Foundation-JSON value with the classification JSON itself uses.
    static func canon(any value: Any?) -> String {
        guard let value else { return "absent" }
        switch value {
        case is NSNull:
            return "null"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return "bool(\(number.boolValue))" }
            if number.doubleValue.rounded(.towardZero) == number.doubleValue {
                return "int(\(number.int64Value))"
            }
            return "num(\(number.doubleValue))"
        case let text as String:
            return "str(\(text))"
        case let list as [Any]:
            return "[" + list.map { canon(any: $0) }.joined(separator: ", ") + "]"
        case let object as [String: Any]:
            return canon(payload: object)
        default:
            return "foreign(\(String(describing: value)))"
        }
    }

    static func canon(payload: [String: Any]) -> String {
        let body = payload.keys.sorted()
            .map { "\($0): \(canon(any: payload[$0]))" }
            .joined(separator: ", ")
        return "{\(body)}"
    }

    static func canon(json value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return "bool(\(flag))"
        case .integer(let number): return "int(\(number))"
        case .number(let number): return "num(\(number))"
        case .string(let text): return "str(\(text))"
        case .array(let list): return "[" + list.map { canon(json: $0) }.joined(separator: ", ") + "]"
        case .object(let object): return canon(payload: object)
        }
    }

    static func canon(payload: [String: JSONValue]) -> String {
        let body = payload.keys.sorted()
            .map { "\($0): \(canon(json: payload[$0]!))" }
            .joined(separator: ", ")
        return "{\(body)}"
    }

    private static func describe(_ capability: ComposerCapability) -> String {
        "(\(capability.id), \(capability.name), \(capability.description), "
        + "\(capability.argumentHint), \(capability.presentation.rawValue), "
        + "\(capability.availability.reason ?? "available"))"
    }

    private static func optional(_ value: String?) -> String {
        value.map { "\"\($0)\"" } ?? "nil"
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
