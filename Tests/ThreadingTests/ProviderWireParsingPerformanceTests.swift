import XCTest
@testable import Threading

/// What one streamed provider chunk costs to read, measured through the shipped code.
///
/// This is the hottest per-token path in the app: every ACP agent message chunk, every Codex
/// delta, every tool call and every tool result arrives as one newline-delimited JSON line and is
/// read on the main actor before anything is drawn. It had no stress target, and a recommendation
/// to "convert at the transport rather than at the leaf" rested on numbers taken from a
/// standalone replica of the code shapes that no longer exists.
///
/// Everything measured here is production code. `JSONRPCLineEnvelope.parse` is the shipped entry
/// point, `ACPWireAdapter` and `CodexAppServerEvent` are the shipped readers, and
/// `LegacyACPWireReader` below is the pre-`2536faf9` adapter copied verbatim out of git history —
/// so the before/after arm compares two things that both really shipped rather than two sketches
/// of them. What is *not* included is `ACPStreamSession` itself: driving it means a real child
/// process on a real pipe, and run-loop latency would swamp a microsecond-scale reading. Its
/// contribution over these numbers is the `sessionUpdate` string switch, which is a handful of
/// comparisons.
///
/// **Payloads are generated as JSON text and parsed.** A corpus written as Swift literals never
/// runs `JSONSerialization` at all and cannot see an `NSNumber`/`Bool` confusion — the class of
/// bug `3277a3a0` fixed — so `rawInput` here deliberately carries `0`, `1` and `false`.
///
/// Default cardinalities run in the `fast` plan. `THREADING_WIRE_STRESS=1` raises them and adds
/// the full sweep whose table is recorded in `docs/architecture/performance.md`. The ceilings
/// asserted here are deliberately generous: they exist to fail on a *change in shape* — a reader
/// that became quadratic in payload size, a conversion that started copying the whole line per
/// field — not to pin a number to one machine.
final class ProviderWireParsingPerformanceTests: XCTestCase {

    /// Keeps the optimiser from discarding a measured call. Every arm returns a value derived
    /// from its own result and it is accumulated here.
    private var sink = 0

    private var isStressRun: Bool {
        ProcessInfo.processInfo.environment["THREADING_WIRE_STRESS"] == "1"
    }

    private func stressValue(key: String, normal: Int, stressed: Int) -> Int {
        if let value = ProcessInfo.processInfo.environment[key].flatMap(Int.init), value > 0 {
            return value
        }
        return isStressRun ? stressed : normal
    }

    private var smallIterations: Int {
        stressValue(key: "THREADING_WIRE_STRESS_ITERATIONS", normal: 300, stressed: 20_000)
    }

    private var largeIterations: Int {
        stressValue(key: "THREADING_WIRE_STRESS_LARGE_ITERATIONS", normal: 60, stressed: 2_000)
    }

    // MARK: - Correctness

    /// Every arm has to answer the same question about the same bytes, or the timings compare
    /// nothing. The expected values are spelled out rather than derived from the fixture.
    func testEveryArmReadsTheSameChunkTheSameWay() throws {
        let chunk = ProviderWirePayloads.acpTextChunk()
        let update = try XCTUnwrap(acpUpdate(in: chunk.line))

        XCTAssertEqual(
            ACPWireAdapter.textContent(in: update),
            "The adapter converts once at the door, then reads typed values."
        )
        XCTAssertEqual(
            LegacyACPWireReader.textContent(in: update),
            "The adapter converts once at the door, then reads typed values."
        )
        let decoded = try JSONDecoder().decode(ACPCodableLine.self, from: chunk.data)
        guard case .agentMessageChunk(let typed) = try XCTUnwrap(decoded.params?.update) else {
            return XCTFail("the text chunk did not decode as an agent message chunk")
        }
        XCTAssertEqual(typed.content?.type, "text")
        XCTAssertEqual(
            typed.content?.text,
            "The adapter converts once at the door, then reads typed values."
        )
        XCTAssertEqual(typed.messageId, "msg_0147")
    }

    /// A tool call carries the tool's own JSON, which is where the wire's numbers live.
    ///
    /// `offset: 0`, `limit: 1` and `replace_all: false` are in the fixture on purpose: read
    /// through a cast that asks whether an `NSNumber` *can* be a `Bool`, the first two come back
    /// as `false` and `true`.
    func testTheToolCallArmsAgreeAndKeepTheWiresNumbersAsNumbers() throws {
        let call = ProviderWirePayloads.acpToolCall()
        let update = try XCTUnwrap(acpUpdate(in: call.line))

        let typed = ACPWireAdapter.toolInput(from: update)
        XCTAssertEqual(typed["file_path"], .string("/repo/Sources/Threading/Core/Agent/ACPWireAdapter.swift"))
        XCTAssertEqual(typed["offset"], .integer(0))
        XCTAssertEqual(typed["limit"], .integer(1))
        XCTAssertEqual(typed["replace_all"], .bool(false))
        XCTAssertEqual(typed["title"], .string("Edit ACPWireAdapter.swift"))
        XCTAssertEqual(typed["kind"], .string("edit"))

        let legacy = LegacyACPWireReader.toolInput(from: update)
        XCTAssertEqual(legacy["file_path"], .string("/repo/Sources/Threading/Core/Agent/ACPWireAdapter.swift"))
        XCTAssertEqual(legacy["title"], .string("Edit ACPWireAdapter.swift"))
        XCTAssertEqual(legacy["kind"], .string("edit"))
        // The legacy reader is the pre-`3277a3a0` conversion order as well as the pre-`2536faf9`
        // reader, so this is the shipped bug preserved for measurement, not a new one.
        XCTAssertEqual(legacy["offset"], .bool(false))
        XCTAssertEqual(legacy["limit"], .bool(true))
        XCTAssertEqual(legacy["replace_all"], .bool(false))

        let decoded = try JSONDecoder().decode(ACPCodableLine.self, from: call.data)
        guard case .toolCall(let call) = try XCTUnwrap(decoded.params?.update) else {
            return XCTFail("the tool call did not decode as a tool call")
        }
        XCTAssertEqual(call.toolCallId, "call_0007")
        XCTAssertEqual(call.title, "Edit ACPWireAdapter.swift")
        XCTAssertEqual(call.kind, "edit")
        XCTAssertEqual(call.rawInput?.objectValue?["offset"], .integer(0))
        XCTAssertEqual(call.rawInput?.objectValue?["limit"], .integer(1))
        XCTAssertEqual(call.rawInput?.objectValue?["replace_all"], .bool(false))
        XCTAssertEqual(call.locations?.first?.path, "/repo/Sources/Threading/Core/Agent/ACPWireAdapter.swift")
    }

    func testThePlanArmsAgree() throws {
        let plan = ProviderWirePayloads.acpPlan()
        let update = try XCTUnwrap(acpUpdate(in: plan.line))

        let steps = ACPWireAdapter.planSteps(in: update)
        XCTAssertEqual(steps.count, 6)
        XCTAssertEqual(steps.first?.title, "Read the wire adapter")
        XCTAssertEqual(steps.first?.status, .completed)
        XCTAssertEqual(steps.last?.title, "Record the baseline")
        XCTAssertEqual(steps.last?.status, .pending)

        let legacy = LegacyACPWireReader.planSteps(in: update)
        XCTAssertEqual(legacy.count, 6)
        XCTAssertEqual(legacy.first?.title, "Read the wire adapter")
        XCTAssertEqual(legacy.last?.status, .pending)

        let decoded = try JSONDecoder().decode(ACPCodableLine.self, from: plan.data)
        guard case .plan(let typed) = try XCTUnwrap(decoded.params?.update) else {
            return XCTFail("the plan did not decode as a plan")
        }
        XCTAssertEqual(typed.entries.count, 6)
        XCTAssertEqual(typed.entries.first?.content, "Read the wire adapter")
        XCTAssertEqual(typed.entries.first?.status, "completed")
    }

    func testTheCodexArmsAgree() throws {
        let delta = ProviderWirePayloads.codexTextDelta()
        let parameters = try XCTUnwrap(codexParameters(in: delta.line))
        let events = CodexAppServerEvent.streamEvents(
            method: "item/agentMessage/delta",
            parameters: parameters
        )
        XCTAssertEqual(events.count, 1)
        guard case .textDelta(let text) = try XCTUnwrap(events.first) else {
            return XCTFail("a Codex message delta did not produce a text delta")
        }
        XCTAssertEqual(text, " reading the transport now")

        let decoded = try JSONDecoder().decode(CodexCodableLine.self, from: delta.data)
        XCTAssertEqual(decoded.method, "item/agentMessage/delta")
        XCTAssertEqual(decoded.params?.delta, " reading the transport now")

        let started = ProviderWirePayloads.codexItemStarted()
        let startedParameters = try XCTUnwrap(codexParameters(in: started.line))
        let startedEvents = CodexAppServerEvent.streamEvents(
            method: "item/started",
            parameters: startedParameters
        )
        guard case .assistantMessage(let blocks) = try XCTUnwrap(startedEvents.first),
              case .toolUse(let id, let tool, let input) = try XCTUnwrap(blocks.first) else {
            return XCTFail("a started command execution did not produce a tool use block")
        }
        XCTAssertEqual(id, "item_0031")
        XCTAssertEqual(tool.rawName, "Bash")
        XCTAssertEqual(input["command"], .string("swift build 2>&1 | tail -40"))
    }

    // MARK: - Baseline

    /// The routine reading: every arm on every payload at default cardinalities.
    ///
    /// This runs in `fast` so the path stays covered and a shape change fails on an ordinary
    /// run. The numbers it prints are Debug unless the suite was built for Release; the recorded
    /// baseline in `performance.md` is the Release stress run.
    func testStreamedChunkPhasesStayWithinTheirShape() throws {
        let manufacture = time { _ = ProviderWirePayloads.all() }
        let samples = ProviderWirePayloads.all()

        let floor = measure("timer-floor", iterations: smallIterations) { self.sink &+ 1 }

        var report: [String] = []
        var byName: [String: [String: Stat]] = [:]
        for sample in samples {
            let stats = measureEveryArm(sample)
            byName[sample.name] = Dictionary(uniqueKeysWithValues: stats.map { ($0.name, $0) })
            for stat in stats {
                report.append("\(sample.name) bytes=\(sample.data.count) \(stat.render())")
            }
        }

        // One `print` per line. A single multi-line string is spliced through by the runner's
        // own stdout — a stress sweep lost a row to an interleaved "Test Case … passed" line.
        print(
            "THREADING_PERF provider-wire mode=baseline "
            + "configuration=\(Self.configuration) "
            + "fixture_ms=\(String(format: "%.2f", manufacture * 1_000)) "
            + "iterations=\(smallIterations)/\(largeIterations) "
            + "timer_floor_us=\(String(format: "%.3f", floor.medianUS))"
        )
        for line in report { print(line) }

        // Shape assertions. A small line is a few microseconds of work on any machine this ships
        // on; a hundred is a different algorithm, not a slower Mac.
        let chunk = try XCTUnwrap(byName["acp-text-chunk"])
        for arm in ["jsonobject", "envelope", "adapter-typed", "adapter-legacy", "whole-line-typed"] {
            let stat = try XCTUnwrap(chunk[arm], "no \(arm) reading for the text chunk")
            XCTAssertLessThan(
                stat.medianUS,
                200,
                "reading one streamed text chunk through \(arm) took \(stat.render())"
            )
        }

        // Payload size must buy linear work. The large tool result is roughly 100× the small
        // chunk; anything quadratic shows up here long before it reaches a user.
        let large = try XCTUnwrap(byName["acp-tool-result-large"])
        let smallBytes = Double(ProviderWirePayloads.acpTextChunk().data.count)
        let largeBytes = Double(ProviderWirePayloads.acpToolResultLarge().data.count)
        XCTAssertGreaterThan(largeBytes / smallBytes, 50, "the large payload is not large")
        let smallPerByte = try XCTUnwrap(chunk["jsonobject"]).medianUS / smallBytes
        let largePerByte = try XCTUnwrap(large["jsonobject"]).medianUS / largeBytes
        XCTAssertLessThan(
            largePerByte,
            smallPerByte * 4,
            "JSONSerialization cost per byte grew with size: "
            + "\(smallPerByte) us/byte small, \(largePerByte) us/byte large"
        )
    }

    /// The full sweep behind `THREADING_WIRE_STRESS=1`.
    ///
    /// Same arms, two orders of magnitude more iterations, and no ceilings — this one exists to
    /// produce the table, not to gate a commit.
    func testStressProviderWireParsingWhenEnabled() throws {
        try XCTSkipUnless(
            isStressRun,
            "Set THREADING_WIRE_STRESS=1 to run the provider wire parsing sweep."
        )

        let manufacture = time { _ = ProviderWirePayloads.all() }
        let samples = ProviderWirePayloads.all()
        let floor = measure("timer-floor", iterations: smallIterations) { self.sink &+ 1 }

        var rows: [String] = []
        for sample in samples {
            for stat in measureEveryArm(sample) {
                rows.append(
                    "\(sample.name)\t\(stat.name)\t\(sample.data.count)"
                    + "\t\(String(format: "%.3f", stat.medianUS))"
                    + "\t\(String(format: "%.3f", stat.p95US))"
                    + "\t\(String(format: "%.3f", stat.maxUS))"
                )
            }
        }

        print(
            "THREADING_PERF provider-wire mode=stress "
            + "configuration=\(Self.configuration) "
            + "fixture_ms=\(String(format: "%.2f", manufacture * 1_000)) "
            + "iterations=\(smallIterations)/\(largeIterations) "
            + "timer_floor_us=\(String(format: "%.3f", floor.medianUS))"
        )
        print("payload\tarm\tbytes\tmedian_us\tp95_us\tmax_us")
        for row in rows { print(row) }
        XCTAssertGreaterThan(sink, 0)
    }

    // MARK: - Arms

    private func measureEveryArm(_ sample: WireSample) -> [Stat] {
        let iterations = sample.isLarge ? largeIterations : smallIterations
        let line = sample.line
        let data = sample.data
        let decoder = JSONDecoder()

        var stats: [Stat] = []

        // 1. Serialization alone: what `JSONRPCLineEnvelope.parse` spends inside Foundation.
        stats.append(measure("jsonobject", iterations: iterations) {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return object?.count ?? 0
        })

        // 1b. The shipped transport entry point, from the `String` the framer hands it. Includes
        //     the UTF-8 round trip `parse` performs and the envelope's own casts.
        stats.append(measure("envelope", iterations: iterations) {
            guard let envelope = JSONRPCLineEnvelope.parse(line) else { return 0 }
            switch envelope {
            case .notification(_, let parameters): return parameters.count
            case .request(_, _, let parameters): return parameters.count
            case .response(_, let result, _): return result?.count ?? 0
            }
        })

        switch sample.kind {
        case .acp(let read):
            let update = acpUpdate(in: line) ?? [:]

            // 2. The conversion the leaf performs before it reads anything.
            stats.append(measure("fields", iterations: iterations) {
                ACPWireAdapter.fields(of: update).count
            })

            // 2b/2c. The shipped reader, and the reader it replaced.
            stats.append(measure("adapter-typed", iterations: iterations) {
                read.typed(update)
            })
            stats.append(measure("adapter-legacy", iterations: iterations) {
                read.legacy(update)
            })

            // The whole line as it is read today, and as it was read before `2536faf9`.
            stats.append(measure("whole-line-typed", iterations: iterations) {
                guard case .notification(_, let parameters)? = JSONRPCLineEnvelope.parse(line),
                      let update = parameters["update"] as? [String: Any] else { return 0 }
                return read.typed(update)
            })
            stats.append(measure("whole-line-legacy", iterations: iterations) {
                guard case .notification(_, let parameters)? = JSONRPCLineEnvelope.parse(line),
                      let update = parameters["update"] as? [String: Any] else { return 0 }
                return read.legacy(update)
            })

            if sample.isToolCall {
                // The second whole-payload conversion the shipped tool-call path performs, on
                // top of `ACPToolCallState`'s. It is its own arm because it is its own decision.
                stats.append(measure("audit-event", iterations: iterations) {
                    let event = ACPProviderExecutionAdapter.event(
                        update: update,
                        operation: "Edit ACPWireAdapter.swift",
                        kind: .edit,
                        phase: .requested,
                        asInput: true
                    )
                    return event == nil ? 0 : 1
                })
            }

            stats.append(measure("codable-typed", iterations: iterations) {
                guard let decoded = try? decoder.decode(ACPCodableLine.self, from: data),
                      let update = decoded.params?.update else { return 0 }
                return update.readWeight
            })

        case .codex(let method):
            let parameters = codexParameters(in: line) ?? [:]

            stats.append(measure("adapter-typed", iterations: iterations) {
                CodexAppServerEvent.streamEvents(method: method, parameters: parameters).count
            })
            stats.append(measure("whole-line-typed", iterations: iterations) {
                guard case .notification(let method, let parameters)? =
                    JSONRPCLineEnvelope.parse(line) else { return 0 }
                return CodexAppServerEvent.streamEvents(
                    method: method,
                    parameters: parameters
                ).count
            })
            stats.append(measure("codable-typed", iterations: iterations) {
                guard let decoded = try? decoder.decode(CodexCodableLine.self, from: data) else {
                    return 0
                }
                return decoded.readWeight
            })
        }

        // The generic typed tree, decoded straight off the transport. This is the arm the
        // "convert at the transport" recommendation actually asks for, because every reader
        // downstream of `fields(of:)` already works on `JSONValue`.
        //
        // It is not hypothetical: `ClaudeWireContentBlock` in `StreamEvent.swift` decodes a tool
        // call's `input` and `content` exactly this way, and `CodexStreamEvent.arguments(from:)`
        // does it to a nested argument string. Whatever this arm costs, that path already pays.
        stats.append(measure("codable-jsonvalue", iterations: iterations) {
            guard let value = try? decoder.decode(JSONValue.self, from: data) else { return 0 }
            return value.objectValue?.count ?? 0
        })

        // The other way to reach the same typed tree, and the one the transport already has half
        // of: Foundation parses, then `JSONValue` converts. Same destination, so this is the
        // honest head-to-head for "convert at the transport".
        stats.append(measure("serialize-then-jsonvalue", iterations: iterations) {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let converted = JSONValue.object(from: object) else { return 0 }
            return converted.count
        })

        return stats
    }

    // MARK: - Helpers

    private static var configuration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    private func acpUpdate(in line: String) -> [String: Any]? {
        guard case .notification(_, let parameters)? = JSONRPCLineEnvelope.parse(line) else {
            return nil
        }
        return parameters["update"] as? [String: Any]
    }

    private func codexParameters(in line: String) -> [String: Any]? {
        guard case .notification(_, let parameters)? = JSONRPCLineEnvelope.parse(line) else {
            return nil
        }
        return parameters
    }

    private func time(_ body: () -> Void) -> Double {
        let started = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    }

    private func measure(
        _ name: String,
        iterations: Int,
        warmup: Int = 32,
        _ body: () -> Int
    ) -> Stat {
        for _ in 0..<warmup { sink = sink &+ body() }
        var samples = [Double](repeating: 0, count: iterations)
        for index in 0..<iterations {
            let started = DispatchTime.now().uptimeNanoseconds
            let value = body()
            let finished = DispatchTime.now().uptimeNanoseconds
            samples[index] = Double(finished - started) / 1_000
            sink = sink &+ value
        }
        samples.sort()
        return Stat(
            name: name,
            count: iterations,
            medianUS: samples[iterations / 2],
            p95US: samples[min(iterations - 1, Int(Double(iterations) * 0.95))],
            maxUS: samples[iterations - 1]
        )
    }
}

// MARK: - Measurement

private struct Stat {
    let name: String
    let count: Int
    let medianUS: Double
    let p95US: Double
    let maxUS: Double

    func render() -> String {
        "\(name) n=\(count) median=\(fixed(medianUS))us p95=\(fixed(p95US))us max=\(fixed(maxUS))us"
    }

    private func fixed(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

// MARK: - Payloads

/// One wire line, kept as both the `String` the framer produces and the `Data` a decoder reads.
private struct WireSample {
    enum Kind {
        case acp(ACPRead)
        case codex(String)
    }

    let name: String
    let line: String
    let data: Data
    let kind: Kind
    let isLarge: Bool
    let isToolCall: Bool
}

/// Forces a produced string to exist without walking it.
///
/// `String.count` counts graphemes, which is O(n): on a 48 KB tool result it was costing more
/// than the adapter under test and reading as an app cost. The arms are timed on producing the
/// value, not on inspecting it.
private func weigh(_ text: String) -> Int {
    text.isEmpty ? 0 : 1
}

/// The pair of readers a given ACP update goes through, shipped and pre-`2536faf9`.
///
/// Each returns a cheap number derived from its result so the call cannot be optimised away and
/// the two arms do the same amount of work with what they read.
private struct ACPRead {
    let typed: ([String: Any]) -> Int
    let legacy: ([String: Any]) -> Int

    static var messageChunk: ACPRead { ACPRead(
        typed: { ACPWireAdapter.textContent(in: $0).map(weigh) ?? 0 },
        legacy: { LegacyACPWireReader.textContent(in: $0).map(weigh) ?? 0 }
    ) }

    static var toolCall: ACPRead { ACPRead(
        typed: { update in
            var state = ACPToolCallState(update: update)
            state.didEmitCall = true
            let identity = ACPWireAdapter.toolIdentity(kind: state.kind, title: state.title)
            return ACPWireAdapter.toolInput(from: update).count &+ weigh(identity.rawName)
        },
        legacy: { update in
            var state = LegacyACPToolCallState(update: update)
            state.didEmitCall = true
            let identity = ACPWireAdapter.toolIdentity(kind: state.kind, title: state.title)
            return LegacyACPWireReader.toolInput(from: update).count &+ weigh(identity.rawName)
        }
    ) }

    static var toolResult: ACPRead { ACPRead(
        typed: { weigh(ACPWireAdapter.toolResultText(from: $0)) },
        legacy: { weigh(LegacyACPWireReader.toolResultText(from: $0)) }
    ) }

    static var plan: ACPRead { ACPRead(
        typed: { ACPWireAdapter.planSteps(in: $0).count },
        legacy: { LegacyACPWireReader.planSteps(in: $0).count }
    ) }
}

/// Realistic streamed chunks, written as JSON text.
///
/// The filler is a deterministic word walk rather than a repeated sentence: identical repeated
/// bytes flatter a parser's caches, and a random one would move the baseline between runs.
private enum ProviderWirePayloads {

    static func all() -> [WireSample] {
        [
            acpTextChunk(),
            acpToolCall(),
            acpPlan(),
            acpToolResultLarge(),
            acpToolResultStructured(),
            codexTextDelta(),
            codexItemStarted(),
            codexPlan(),
            codexItemCompletedLarge()
        ]
    }

    // MARK: ACP

    static func acpTextChunk() -> WireSample {
        sample(
            name: "acp-text-chunk",
            kind: .acp(.messageChunk),
            line: #"""
            {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_01HXQ4M7","update":{"sessionUpdate":"agent_message_chunk","messageId":"msg_0147","content":{"type":"text","text":"The adapter converts once at the door, then reads typed values."}}}}
            """#
        )
    }

    static func acpToolCall() -> WireSample {
        sample(
            name: "acp-tool-call",
            kind: .acp(.toolCall),
            isToolCall: true,
            line: #"""
            {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_01HXQ4M7","update":{"sessionUpdate":"tool_call","toolCallId":"call_0007","title":"Edit ACPWireAdapter.swift","kind":"edit","status":"in_progress","rawInput":{"file_path":"/repo/Sources/Threading/Core/Agent/ACPWireAdapter.swift","old_string":"static func fields(of payload: [String: Any])","new_string":"static func fields(of payload: [String: Any]) -> [String: JSONValue]","offset":0,"limit":1,"replace_all":false},"locations":[{"path":"/repo/Sources/Threading/Core/Agent/ACPWireAdapter.swift","line":128}]}}}
            """#
        )
    }

    static func acpPlan() -> WireSample {
        sample(
            name: "acp-plan",
            kind: .acp(.plan),
            line: #"""
            {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_01HXQ4M7","update":{"sessionUpdate":"plan","entries":[{"content":"Read the wire adapter","status":"completed","priority":"high"},{"content":"Read the Codex adapter","status":"completed","priority":"high"},{"content":"Generate the payload corpus","status":"completed","priority":"medium"},{"content":"Measure each phase","status":"in_progress","priority":"high"},{"content":"Compare the transport arm","status":"pending","priority":"medium"},{"content":"Record the baseline","status":"pending","priority":"low"}]}}}
            """#
        )
    }

    /// A finished tool call whose `rawOutput` is one long string, plus the diff content block a
    /// real edit reports beside it. This is the search/read result shape.
    static func acpToolResultLarge() -> WireSample {
        let output = filler(seed: 11, words: 6_400)
        let oldText = filler(seed: 12, words: 240)
        let newText = filler(seed: 13, words: 240)
        return sample(
            name: "acp-tool-result-large",
            kind: .acp(.toolResult),
            isLarge: true,
            isToolCall: true,
            line: #"""
            {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_01HXQ4M7","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_0007","status":"completed","rawOutput":"\#(output)","content":[{"type":"diff","path":"/repo/Sources/Threading/Core/Agent/ACPWireAdapter.swift","oldText":"\#(oldText)","newText":"\#(newText)"},{"type":"content","content":{"type":"text","text":"Applied one hunk."}}]}}}
            """#
        )
    }

    /// The same size of payload as a structured object instead of one string, because that is
    /// where a whole-payload conversion actually costs something: 320 members to walk rather
    /// than one string to copy.
    static func acpToolResultStructured() -> WireSample {
        var members: [String] = []
        members.reserveCapacity(320)
        for index in 0..<320 {
            members.append(#"""
            {"path":"\#(filler(seed: UInt64(index) &+ 200, words: 4))","line":\#(index * 7),"hits":\#(index % 5),"pinned":\#(index % 2 == 0 ? "true" : "false"),"excerpt":"\#(filler(seed: UInt64(index) &+ 900, words: 14))"}
            """#)
        }
        return sample(
            name: "acp-tool-result-structured",
            kind: .acp(.toolResult),
            isLarge: true,
            isToolCall: true,
            line: #"""
            {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_01HXQ4M7","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_0011","status":"completed","rawOutput":{"matches":[\#(members.joined(separator: ","))],"truncated":false,"scanned":4096}}}}
            """#
        )
    }

    // MARK: Codex

    static func codexTextDelta() -> WireSample {
        sample(
            name: "codex-text-delta",
            kind: .codex("item/agentMessage/delta"),
            line: #"""
            {"method":"item/agentMessage/delta","params":{"threadId":"th_0f2a","itemId":"item_0029","delta":" reading the transport now"}}
            """#
        )
    }

    static func codexItemStarted() -> WireSample {
        sample(
            name: "codex-item-started",
            kind: .codex("item/started"),
            line: #"""
            {"method":"item/started","params":{"threadId":"th_0f2a","item":{"id":"item_0031","type":"commandExecution","command":"swift build 2>&1 | tail -40","cwd":"/repo","status":"inProgress"}}}
            """#
        )
    }

    static func codexPlan() -> WireSample {
        sample(
            name: "codex-plan",
            kind: .codex("turn/plan/updated"),
            line: #"""
            {"method":"turn/plan/updated","params":{"threadId":"th_0f2a","plan":[{"step":"Read the wire adapter","status":"completed"},{"step":"Read the Codex adapter","status":"completed"},{"step":"Generate the payload corpus","status":"completed"},{"step":"Measure each phase","status":"in_progress"},{"step":"Compare the transport arm","status":"pending"},{"step":"Record the baseline","status":"pending"}]}}
            """#
        )
    }

    static func codexItemCompletedLarge() -> WireSample {
        let output = filler(seed: 21, words: 6_400)
        return sample(
            name: "codex-item-completed-large",
            kind: .codex("item/completed"),
            isLarge: true,
            line: #"""
            {"method":"item/completed","params":{"threadId":"th_0f2a","item":{"id":"item_0031","type":"commandExecution","command":"swift build 2>&1 | tail -40","status":"completed","exitCode":0,"aggregatedOutput":"\#(output)"}}}
            """#
        )
    }

    // MARK: Manufacture

    private static func sample(
        name: String,
        kind: WireSample.Kind,
        isLarge: Bool = false,
        isToolCall: Bool = false,
        line: String
    ) -> WireSample {
        WireSample(
            name: name,
            line: line,
            data: Data(line.utf8),
            kind: kind,
            isLarge: isLarge,
            isToolCall: isToolCall
        )
    }

    /// Words only — no quote, backslash or newline reaches the template, so the fixture text is
    /// valid JSON without an escaping pass that would itself have to be trusted.
    private static func filler(seed: UInt64, words: Int) -> String {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var out: [String] = []
        out.reserveCapacity(words)
        for _ in 0..<words {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            out.append(vocabulary[Int(truncatingIfNeeded: state >> 33) % vocabulary.count])
        }
        return out.joined(separator: " ")
    }

    private static let vocabulary: [String] = [
        "adapter", "transport", "session", "chunk", "payload", "identifier", "notification",
        "serialization", "conversion", "boundary", "dictionary", "envelope", "framing",
        "streamed", "provider", "content", "diff", "terminal", "location", "measurement",
        "median", "iteration", "baseline", "regression", "fixture", "corpus", "vocabulary",
        "unrecognised", "completed", "pending", "progress", "adapterless", "typed", "cast"
    ]
}

// MARK: - Transport-level Codable arm

/// The ACP line decoded straight into typed Swift, which is what "convert at the transport"
/// means concretely.
///
/// The union is discriminator-driven rather than one flat struct, and it has to be: `update.content`
/// is a single content block for a message chunk and an array of tool-call content for a tool
/// call. A flat `Codable` model cannot hold both under one key, so this is the honest shape of
/// the alternative rather than a stub that decodes less than the adapter reads.
private struct ACPCodableLine: Decodable {
    let method: String?
    let params: Params?

    struct Params: Decodable {
        let sessionId: String?
        let update: ACPCodableUpdate?
    }
}

private enum ACPCodableUpdate: Decodable {
    case userMessageChunk(Chunk)
    case agentMessageChunk(Chunk)
    case agentThoughtChunk(Chunk)
    case toolCall(ToolCall)
    case toolCallUpdate(ToolCall)
    case plan(Plan)
    case usage(Usage)
    case sessionInfo(SessionInfo)
    case other(String?)

    struct Block: Decodable {
        let type: String
        let text: String?
    }

    struct Chunk: Decodable {
        let messageId: String?
        let content: Block?
    }

    struct ToolCall: Decodable {
        struct Location: Decodable {
            let path: String?
            let line: Int?
        }

        struct Content: Decodable {
            let type: String?
            let content: Block?
            let path: String?
            let oldText: String?
            let newText: String?
            let terminalId: String?
        }

        let toolCallId: String
        let title: String?
        let kind: String?
        let status: String?
        let rawInput: JSONValue?
        let rawOutput: JSONValue?
        let locations: [Location]?
        let content: [Content]?
    }

    struct Plan: Decodable {
        struct Entry: Decodable {
            let content: String?
            let status: String?
        }

        let entries: [Entry]
    }

    struct Usage: Decodable {
        let used: Int?
        let size: Int?
    }

    struct SessionInfo: Decodable {
        let title: String?
    }

    private enum Discriminator: String, CodingKey {
        case sessionUpdate
    }

    init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: Discriminator.self)
        switch try keyed.decodeIfPresent(String.self, forKey: .sessionUpdate) {
        case "user_message_chunk": self = .userMessageChunk(try Chunk(from: decoder))
        case "agent_message_chunk": self = .agentMessageChunk(try Chunk(from: decoder))
        case "agent_thought_chunk": self = .agentThoughtChunk(try Chunk(from: decoder))
        case "tool_call": self = .toolCall(try ToolCall(from: decoder))
        case "tool_call_update": self = .toolCallUpdate(try ToolCall(from: decoder))
        case "plan": self = .plan(try Plan(from: decoder))
        case "usage_update": self = .usage(try Usage(from: decoder))
        case "session_info_update": self = .sessionInfo(try SessionInfo(from: decoder))
        case .some(let value): self = .other(value)
        case .none: self = .other(nil)
        }
    }

    /// Comparable work to the adapter arms: reach the same fields and count something.
    var readWeight: Int {
        switch self {
        case .userMessageChunk(let chunk),
             .agentMessageChunk(let chunk),
             .agentThoughtChunk(let chunk):
            return chunk.content?.text.map(weigh) ?? 0
        case .toolCall(let call), .toolCallUpdate(let call):
            return (call.rawInput?.objectValue?.count ?? 0)
                &+ (call.rawOutput?.objectValue?.count ?? 0)
                &+ (call.content?.count ?? 0)
                &+ (call.locations?.count ?? 0)
                &+ (call.title.map(weigh) ?? 0)
        case .plan(let plan):
            return plan.entries.count
        case .usage(let usage):
            return (usage.used ?? 0) &+ (usage.size ?? 0)
        case .sessionInfo(let info):
            return info.title.map(weigh) ?? 0
        case .other(let value):
            return value.map(weigh) ?? 0
        }
    }
}

private struct CodexCodableLine: Decodable {
    let method: String?
    let params: Params?

    struct Params: Decodable {
        let threadId: String?
        let delta: String?
        let item: Item?
        let plan: [PlanEntry]?
        let turn: Turn?
    }

    struct Item: Decodable {
        let id: String?
        let type: String?
        let text: String?
        let command: String?
        let status: String?
        let exitCode: Int?
        let aggregatedOutput: String?
        let server: String?
        let tool: String?
        let arguments: JSONValue?
    }

    struct PlanEntry: Decodable {
        let step: String?
        let status: String?
    }

    struct Turn: Decodable {
        let status: String?
        let durationMs: Int?
    }

    var readWeight: Int {
        (params?.delta.map(weigh) ?? 0)
            &+ (params?.item?.command.map(weigh) ?? 0)
            &+ (params?.item?.aggregatedOutput.map(weigh) ?? 0)
            &+ (params?.plan?.count ?? 0)
            &+ (params?.turn?.status.map(weigh) ?? 0)
    }
}

// MARK: - The reader this replaced

/// `ACPWireAdapter` as it stood at `2536faf9^`, copied verbatim so the before/after arm compares
/// two readers that both shipped.
///
/// It is kept private to this file and is never reachable from the app. The one visible
/// difference from the shipping reader — `0` and `1` arriving as booleans — is the bug
/// `3277a3a0` fixed; it is preserved rather than corrected, because correcting it would measure
/// something that never ran.
private enum LegacyACPWireReader {

    static func currentModel(in result: [String: Any]?) -> String? {
        let models = result?["models"] as? [String: Any]
        return models?["currentModelId"] as? String
    }

    static func sessionTitle(in update: [String: Any]) -> String? {
        guard let title = update["title"] as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func textContent(in update: [String: Any]) -> String? {
        guard let content = update["content"] as? [String: Any],
              content["type"] as? String == "text" else { return nil }
        return content["text"] as? String
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    static func planSteps(in update: [String: Any]) -> [RunProgress.Step] {
        let entries = update["entries"] as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let title = entry["content"] as? String,
                  let rawStatus = entry["status"] as? String,
                  let status = RunProgress.Step.Status(providerValue: rawStatus)
            else { return nil }
            return RunProgress.Step(id: nil, title: title, status: status)
        }
    }

    static func toolInput(from payload: [String: Any]) -> [String: JSONValue] {
        LegacyJSONValueBridge.object(from: toolInputFoundation(from: payload)) ?? [:]
    }

    static func toolInputFoundation(from payload: [String: Any]) -> [String: Any] {
        var input: [String: Any]
        if let object = payload["rawInput"] as? [String: Any] {
            input = object
        } else if let rawInput = payload["rawInput"], !(rawInput is NSNull) {
            input = ["input": rawInput]
        } else {
            input = [:]
        }

        if input["title"] == nil, let title = payload["title"] as? String {
            input["title"] = title
        }
        if input["kind"] == nil, let kind = payload["kind"] as? String {
            input["kind"] = kind
        }
        if input["file_path"] == nil,
           let locations = payload["locations"] as? [[String: Any]],
           let path = locations.first?["path"] as? String {
            input["file_path"] = path
        }
        if let contents = payload["content"] as? [[String: Any]],
           let diff = contents.first(where: { $0["type"] as? String == "diff" }) {
            input["file_path"] = input["file_path"] ?? diff["path"]
            input["old_string"] = input["old_string"] ?? diff["oldText"]
            input["new_string"] = input["new_string"] ?? diff["newText"]
        }
        return input
    }

    static func toolResultText(from payload: [String: Any]) -> String {
        if let rawOutput = payload["rawOutput"], !(rawOutput is NSNull) {
            if let text = rawOutput as? String { return text }
            return JSONRPCLineEnvelope.encodedText(rawOutput)
        }

        let contents = payload["content"] as? [[String: Any]] ?? []
        return contents.compactMap { item -> String? in
            switch item["type"] as? String {
            case "content":
                guard let content = item["content"] as? [String: Any] else { return nil }
                if content["type"] as? String == "text" {
                    return content["text"] as? String
                }
                return nil
            case "diff":
                return item["path"] as? String
            case "terminal":
                return item["terminalId"] as? String
            default:
                return nil
            }
        }.joined(separator: "\n")
    }
}

/// `JSONValue.init?(foundationValue:)` as it stood at `3277a3a0^`.
///
/// The `Bool` case ahead of the `NSNumber` case is the bug, kept because the legacy arm has to
/// pay what the legacy arm paid — `NSNumber as? Bool` is not free, and it succeeded on every `0`
/// and every `1` the wire carried.
private enum LegacyJSONValueBridge {

    static func value(from any: Any) -> JSONValue? {
        switch any {
        case is NSNull:
            return .null
        case let value as Bool:
            return .bool(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            } else if value.doubleValue.rounded(.towardZero) == value.doubleValue {
                return .integer(value.int64Value)
            } else {
                return .number(value.doubleValue)
            }
        case let value as String:
            return .string(value)
        case let value as [Any]:
            let converted = value.compactMap(LegacyJSONValueBridge.value(from:))
            guard converted.count == value.count else { return nil }
            return .array(converted)
        case let value as [String: Any]:
            guard let converted = object(from: value) else { return nil }
            return .object(converted)
        default:
            return nil
        }
    }

    static func object(from value: [String: Any]) -> [String: JSONValue]? {
        var converted: [String: JSONValue] = [:]
        converted.reserveCapacity(value.count)
        for (key, raw) in value {
            guard let item = LegacyJSONValueBridge.value(from: raw) else { return nil }
            converted[key] = item
        }
        return converted
    }
}

/// `ACPToolCallState` as it stood at `2536faf9^`: the payload is retained as `[String: Any]` and
/// nothing is converted until a reader asks.
private struct LegacyACPToolCallState {
    var payload: [String: Any]
    var title: String
    var kind: ACPToolCallKind?
    var status: ACPToolCallStatus?
    var didEmitCall = false
    var didEmitResult = false

    init(update: [String: Any]) {
        payload = update
        title = update["title"] as? String ?? "tool"
        kind = (update["kind"] as? String).map(ACPToolCallKind.init(providerValue:))
        status = (update["status"] as? String).map(ACPToolCallStatus.init(providerValue:))
    }

    mutating func merge(_ update: [String: Any]) {
        payload.merge(update) { _, new in new }
        if let value = update["title"] as? String { title = value }
        if let value = update["kind"] as? String {
            kind = ACPToolCallKind(providerValue: value)
        }
        if let value = update["status"] as? String {
            status = ACPToolCallStatus(providerValue: value)
        }
    }
}
