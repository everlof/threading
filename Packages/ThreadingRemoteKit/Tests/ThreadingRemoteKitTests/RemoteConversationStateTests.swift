import XCTest
@testable import ThreadingRemoteKit

final class RemoteConversationStateTests: XCTestCase {
    func testOlderSnapshotDefaultsPaginationMetadata() throws {
        let data = Data(#"{"type":"conversation","rows":[],"canSend":true}"#.utf8)
        let snapshot = try JSONDecoder().decode(RemoteConversationSnapshotDTO.self, from: data)

        XCTAssertEqual(snapshot.revision, 0)
        XCTAssertFalse(snapshot.hasEarlier)
        XCTAssertEqual(snapshot.streamingText, "")
        XCTAssertTrue(snapshot.composerCapabilities.isEmpty)
    }

    func testComposerCatalogIsReplacedOnlyWhenDeltaCarriesOne() {
        let compact = RemoteComposerCapabilityDTO(
            id: "codex.command:compact",
            name: "compact",
            displayName: "compact",
            description: "Reduce context",
            argumentHint: "",
            kind: .command,
            trigger: .slash,
            presentation: .command
        )
        let skill = RemoteComposerCapabilityDTO(
            id: "codex.skill:release",
            name: "release",
            displayName: "Release",
            description: "Prepare a release",
            argumentHint: "[version]",
            kind: .skill,
            trigger: .dollar,
            presentation: .turn
        )
        var state = RemoteConversationState(
            composerCapabilities: [compact],
            revision: 1
        )

        _ = state.apply(RemoteConversationDeltaDTO(
            baseRevision: 1,
            revision: 2,
            streamingText: "working",
            canSend: false
        ))
        XCTAssertEqual(state.composerCapabilities, [compact])

        _ = state.apply(RemoteConversationDeltaDTO(
            baseRevision: 2,
            revision: 3,
            streamingText: "",
            canSend: true,
            composerCapabilities: [compact, skill]
        ))
        XCTAssertEqual(state.composerCapabilities, [compact, skill])
    }

    func testRemoteComposerQuerySeparatesSlashCommandsAndDollarSkills() throws {
        let capabilities = [
            RemoteComposerCapabilityDTO(
                id: "command:review",
                name: "review",
                displayName: "Review",
                description: "Review changes",
                argumentHint: "",
                aliases: ["inspect"],
                kind: .command,
                trigger: .slash,
                presentation: .turn
            ),
            RemoteComposerCapabilityDTO(
                id: "skill:inspect",
                name: "inspect-ui",
                displayName: "Inspect UI",
                description: "Inspect a screen",
                argumentHint: "[screen]",
                kind: .skill,
                trigger: .dollar,
                presentation: .turn
            )
        ]

        let slash = try XCTUnwrap(RemoteComposerCompletionQuery.parse("/ins"))
        XCTAssertEqual(slash.suggestions(from: capabilities).map(\.id), ["command:review"])
        let dollar = try XCTUnwrap(RemoteComposerCompletionQuery.parse("$ins"))
        XCTAssertEqual(dollar.suggestions(from: capabilities).map(\.id), ["skill:inspect"])
        XCTAssertNil(RemoteComposerCompletionQuery.parse("/review now"))
    }

    func testRemoteComposerPresentationUsesDisabledReasonAndBoundsSuggestions() throws {
        let disabled = RemoteComposerCapabilityDTO(
            id: "skill:blocked",
            name: "blocked",
            displayName: "Blocked",
            description: "Ordinary description",
            argumentHint: "",
            kind: .skill,
            trigger: .dollar,
            presentation: .turn,
            isEnabled: false,
            unavailableReason: "Disabled by policy"
        )
        XCTAssertEqual(disabled.presentationDetail, "Disabled by policy")

        let commands = (0..<200).map { index in
            RemoteComposerCapabilityDTO(
                id: "command:\(index)",
                name: "command-\(index)",
                displayName: "Command \(index)",
                description: "",
                argumentHint: "",
                kind: .command,
                trigger: .slash,
                presentation: .command
            )
        }
        let query = try XCTUnwrap(RemoteComposerCompletionQuery.parse("/"))
        XCTAssertEqual(
            query.suggestions(from: commands).count,
            RemoteComposerCatalog.maximumPresentedSuggestions
        )

        let skills = [
            RemoteComposerCapabilityDTO(
                id: "claude.command:provisional",
                name: "provisional",
                displayName: "Provisional",
                description: "",
                argumentHint: "",
                kind: .command,
                isAvailableInSkillCatalog: true,
                trigger: .slash,
                presentation: .command
            ),
            RemoteComposerCapabilityDTO(
                id: "claude.skill:release",
                name: "release",
                displayName: "Release",
                description: "",
                argumentHint: "",
                kind: .skill,
                trigger: .slash,
                presentation: .turn
            ),
        ]
        XCTAssertEqual(
            query.suggestions(from: commands + skills, matchingKind: .skill).map(\.id),
            skills.map(\.id),
            "The skill filter must run before the rendered-row limit"
        )
    }

    func testDeltaUpdatesOneRowAndAppendsWithoutReplacingHistory() {
        var state = RemoteConversationState()
        state.apply(RemoteConversationSnapshotDTO(
            rows: [
                .init(id: "8", kind: .user, text: "Run it"),
                .init(id: "9", kind: .tool, toolName: "Bash", summary: "swift test"),
            ],
            streamingText: "Working",
            canSend: false,
            revision: 4,
            hasEarlier: true
        ))

        let result = state.apply(RemoteConversationDeltaDTO(
            baseRevision: 4,
            revision: 5,
            appendedRows: [
                .init(id: "10", kind: .assistant, text: "All green.")
            ],
            updatedRows: [
                .init(
                    id: "9",
                    kind: .tool,
                    toolName: "Bash",
                    summary: "swift test",
                    result: "Passed"
                )
            ],
            streamingText: "",
            canSend: true
        ))

        XCTAssertEqual(
            result,
            .changed(inserted: ["10"], updated: ["9"])
        )
        XCTAssertEqual(state.rows.map(\.id), ["8", "9", "10"])
        XCTAssertEqual(state.rows[1].result, "Passed")
        XCTAssertTrue(state.canSend)
        XCTAssertTrue(state.hasEarlier, "a live delta must not reset the page boundary")
    }

    func testRevisionGapRequestsSnapshotWithoutMutation() {
        var state = RemoteConversationState(revision: 7)
        let result = state.apply(RemoteConversationDeltaDTO(
            baseRevision: 6,
            revision: 8,
            streamingText: "missed",
            canSend: false
        ))

        XCTAssertEqual(result, .requiresSnapshot)
        XCTAssertEqual(state.revision, 7)
        XCTAssertEqual(state.streamingText, "")
    }

    func testHistoryPagesPrependIdempotently() {
        var state = RemoteConversationState(
            rows: [
                .init(id: "2", kind: .assistant, text: "Two"),
                .init(id: "3", kind: .assistant, text: "Three"),
            ],
            hasEarlier: true
        )
        let page = RemoteConversationPageDTO(
            rows: [
                .init(id: "0", kind: .user, text: "Zero"),
                .init(id: "1", kind: .assistant, text: "One"),
                .init(id: "2", kind: .assistant, text: "Two"),
            ],
            beforeRowID: "2",
            hasEarlier: false
        )

        XCTAssertEqual(state.prepend(page), .prepended(["0", "1"]))
        XCTAssertEqual(state.rows.map(\.id), ["0", "1", "2", "3"])
        XCTAssertEqual(state.prepend(page), .unchanged)
        XCTAssertFalse(state.hasEarlier)
    }

    func testTenThousandStreamingDeltasDoNotRebuildRows() {
        let rows = (0..<1_000).map {
            RemoteConversationRowDTO(id: String($0), kind: .assistant, text: "Message \($0)")
        }
        let state = RemoteConversationState(rows: rows, revision: 1)

        measure {
            var measured = state
            for revision in 2...10_001 {
                _ = measured.apply(RemoteConversationDeltaDTO(
                    baseRevision: revision - 1,
                    revision: revision,
                    streamingText: "token \(revision)",
                    canSend: false
                ))
            }
            XCTAssertEqual(measured.rows.count, rows.count)
        }
    }
}
