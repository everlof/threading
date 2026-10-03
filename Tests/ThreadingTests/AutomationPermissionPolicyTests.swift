import XCTest
@testable import Threading

/// The policy an automation revision carries for its unattended runs: a small grammar refused
/// on doubt, persisted strictly inside the revision, and read as read-only for revisions saved
/// before it existed.
@MainActor
final class AutomationPermissionPolicyTests: XCTestCase {

    // MARK: - Grammar

    func testTheSupportedRulesParseToTheirCanonicalSpelling() throws {
        let policy = try AutomationPermissionPolicy.allowList(parsing: [
            "Bash(python3 /x/collect.py *)", "  Bash(git -C /repo fetch --quiet origin develop)  ", "",
            "Edit(//Users/david/Downloads/Sonda-bevakning/**)", "WebFetch(domain:EUR-Lex.europa.eu)",
            "mcp__claude_ai__fetch_page",
        ])
        XCTAssertEqual(policy.rules.map(\.text), [
            "Bash(python3 /x/collect.py *)", "Bash(git -C /repo fetch --quiet origin develop)",
            "Write(/Users/david/Downloads/Sonda-bevakning/**)", "WebFetch(domain:eur-lex.europa.eu)",
            "mcp__claude_ai__fetch_page",
        ])
        XCTAssertEqual(try AutomationPermissionRule(parsing: "Write(~/Downloads/x/**)").text,
                       "Write(\(NSHomeDirectory())/Downloads/x/**)")
    }

    func testAnythingOutsideTheGrammarIsRefusedWithItsReason() {
        let cases: [(String, AutomationPermissionPolicyError)] = [
            ("Read(/Users/david/**)", .readsAreAlwaysAllowed("Read(/Users/david/**)")),
            ("Write(Downloads/**)", .relativePath("Write(Downloads/**)")),
            ("Write(/Users/david/../etc/**)", .relativePath("Write(/Users/david/../etc/**)")),
            ("Bash(make test && make deploy)", .compoundCommand("Bash(make test && make deploy)")),
            ("Bash(cat x > y)", .compoundCommand("Bash(cat x > y)")),
            ("Bash(*)", .everyCommand("Bash(*)")),
            ("Bash(FOO=1 make)", .unsupported("Bash(FOO=1 make)")),
            ("Bash(rm -rf *.tmp)", .unsupported("Bash(rm -rf *.tmp)")),
            ("WebFetch(eur-lex.europa.eu)", .unsupported("WebFetch(eur-lex.europa.eu)")),
            ("WebSearch", .unsupported("WebSearch")),
            ("mcp__only", .unsupported("mcp__only")),
        ]
        for (rule, expected) in cases {
            XCTAssertThrowsError(try AutomationPermissionRule(parsing: rule), rule) { error in
                XCTAssertEqual(error as? AutomationPermissionPolicyError, expected, rule)
            }
        }
        XCTAssertThrowsError(try AutomationPermissionPolicy.allowList(
            parsing: Array(repeating: "Bash(true)", count: AutomationPermissionPolicy.maximumRules + 1)))
    }

    func testPrefixRulesMatchWordsNotCharacters() throws {
        guard case .shell(let pattern) = try AutomationPermissionRule(parsing: "Bash(python3 /x/collect.py *)") else {
            return XCTFail("not a shell rule")
        }
        XCTAssertTrue(pattern.matches(words: ["python3", "/x/collect.py"]))
        XCTAssertTrue(pattern.matches(words: ["python3", "\"/x/collect.py\"", "collect"]))
        XCTAssertFalse(pattern.matches(words: ["python3", "/x/collect.py.evil"]))
        XCTAssertFalse(pattern.matches(words: ["\"python3\"", "/x/collect.py"]))
    }

    // MARK: - Persistence

    func testAPolicyRoundTripsAndDecodesStrictly() throws {
        let policy = try AutomationPermissionPolicy.allowList(parsing: ["Bash(true)", "Write(/tmp/**)"])
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(policy)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"mode":"allowList","rules":["Bash(true)","Write(\/tmp\/**)"]}"#)
        XCTAssertEqual(try JSONDecoder().decode(AutomationPermissionPolicy.self, from: data), policy)
        XCTAssertEqual(try JSONDecoder().decode(AutomationPermissionPolicy.self, from: Data(#"{"mode":"full"}"#.utf8)), .full)

        for invalid in [#"{"mode":"everything"}"#, #"{"mode":"full","rules":[]}"#,
                        #"{"mode":"allowList"}"#, #"{"mode":"allowList","rules":["Read(/x)"]}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(AutomationPermissionPolicy.self, from: Data(invalid.utf8)), invalid)
        }
    }

    func testARevisionSavedBeforePoliciesExistedIsReadOnly() throws {
        let revision = AutomationApprovalSheetRenderTests.scheduleRevision(account: "claude-sonda-02")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(revision)) as? [String: Any])
        object.removeValue(forKey: "permissions")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(TriggerRevision.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertNil(legacy.permissions)
        XCTAssertEqual(legacy.effectivePermissions, .readOnly)
    }

    // MARK: - The store

    private func scratchStore() throws -> TriggerStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("automation-policy-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = TriggerStore(url: directory.appendingPathComponent("db"))
        addTeardownBlock { await store.close(); try? FileManager.default.removeItem(at: directory) }
        return store
    }

    private func configuration(_ mode: TriggerExecutionMode, _ policy: AutomationPermissionPolicy?) -> AutomationConfiguration {
        var config = AutomationConfiguration(projectID: ProjectID())
        config.name = "Report"; config.instructions = "Summarize"; config.agent = .claude
        config.executionMode = mode; config.permissions = policy
        return config
    }

    func testTheStoreSavesAnExplicitPolicyAndRefusesFullForAReadOnlyMode() async throws {
        let store = try scratchStore()
        let saved = try await store.configureAutomation(
            configuration(.taskLocalEdits, nil), id: TriggerID(), expectedRevision: nil, proposedBy: nil)
        XCTAssertEqual(saved.permissions, .readOnly)

        let full = try await store.configureAutomation(
            configuration(.taskLocalEdits, .full), id: TriggerID(), expectedRevision: nil, proposedBy: nil)
        let reloaded = try await store.trigger(id: full.triggerID)
        XCTAssertEqual(reloaded?.revision.permissions, .full)
        XCTAssertEqual(reloaded.flatMap { AutomationConfiguration(definition: $0.definition, revision: $0.revision).permissions }, .full)

        do {
            _ = try await store.configureAutomation(
                configuration(.taskReadOnly, .full), id: TriggerID(), expectedRevision: nil, proposedBy: nil)
            XCTFail("full permission was saved for a read-only task")
        } catch let error as AutomationPermissionPolicyError {
            XCTAssertEqual(error, .fullNeedsEditingMode)
        }
    }

    func testAnAgentsConfigurationCarriesItsRulesThroughTheToolArguments() throws {
        let json = #"{"operation":"configure","configuration":{"name":"R","projectID":"\#(UUID().uuidString)","instructions":"x","agent":"claude","executionMode":"taskLocalEdits","checkoutPolicy":"projectCheckout","maximumRuntimeMinutes":60,"options":{"missedRunPolicy":"skip","archiveOnSuccess":true},"conditions":[],"permissions":{"mode":"allowList","rules":["Bash(make test)"]}}}"#
        let arguments = try JSONDecoder().decode(AutomationToolArguments.self, from: Data(json.utf8))
        XCTAssertEqual(arguments.configuration?.permissions?.rules.map(\.text), ["Bash(make test)"])

        let refused = json.replacingOccurrences(of: "Bash(make test)", with: "Read(/x)")
        XCTAssertThrowsError(try JSONDecoder().decode(AutomationToolArguments.self, from: Data(refused.utf8))) { error in
            XCTAssertEqual(error as? AutomationPermissionPolicyError, .readsAreAlwaysAllowed("Read(/x)"))
        }
    }
}
