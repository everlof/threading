import XCTest
@testable import Threading

final class SessionAttachmentTurnSectioningTests: XCTestCase {
    private let sessionID = SessionID()
    private let root = URL(fileURLWithPath: "/tmp/attachment-turn-sectioning", isDirectory: true)

    func testPlacementMapsBackwardForAgentOutputAndForwardForPromptHandoffs() throws {
        let first = boundary(ordinal: 1, turnID: "first", seconds: 10)
        let latest = boundary(ordinal: 2, turnID: "latest", seconds: 20)
        let agentOutput = attachment("agent.png", seconds: 21, placement: .current)
        let promptFile = attachment("prompt.png", seconds: 15, placement: .next)

        let sections = SessionAttachmentTurnSectioning.sections(
            attachments: [agentOutput, promptFile],
            boundaries: [latest, first]
        )

        XCTAssertEqual(sections.map(\.id), [.checkpoint(latest.id)])
        XCTAssertEqual(sections[0].attachments.map(\.name), ["agent.png", "prompt.png"])
        XCTAssertTrue(sections[0].isLatest)
    }

    func testExactQueuedTurnIdentityOverridesTheRecordingTime() throws {
        let first = boundary(ordinal: 1, turnID: "first", seconds: 10)
        let latest = boundary(ordinal: 2, turnID: "latest", seconds: 20)
        let queued = attachment(
            "queued.png",
            seconds: 30,
            turnID: first.userTurnID,
            placement: .next
        )

        let sections = SessionAttachmentTurnSectioning.sections(
            attachments: [queued],
            boundaries: [first, latest]
        )

        XCTAssertEqual(sections.map(\.id), [
            .checkpoint(latest.id),
            .checkpoint(first.id)
        ])
        XCTAssertTrue(sections[0].attachments.isEmpty, "the latest turn must remain visible")
        XCTAssertEqual(sections[1].attachments.map(\.name), ["queued.png"])
    }

    func testUpcomingAndBetweenTurnFilesDoNotClaimAnUnrelatedCheckpoint() throws {
        let latest = boundary(ordinal: 4, turnID: "latest", seconds: 20)
        let upcoming = attachment("next.png", seconds: 30, placement: .next)
        let local = attachment("comparison.png", seconds: 30, placement: .none)

        let sections = SessionAttachmentTurnSectioning.sections(
            attachments: [upcoming, local],
            boundaries: [latest]
        )

        XCTAssertEqual(sections.map(\.id), [
            .upcoming,
            .checkpoint(latest.id),
            .betweenTurns
        ])
        XCTAssertEqual(sections[0].attachments.map(\.name), ["next.png"])
        XCTAssertEqual(sections[2].attachments.map(\.name), ["comparison.png"])
    }

    func testCollapseRemovesAttachmentRowsBeforeViewConstruction() throws {
        let latest = boundary(ordinal: 2, turnID: "latest", seconds: 20)
        let sections = SessionAttachmentTurnSectioning.sections(
            attachments: [attachment("latest.png", seconds: 21, placement: .current)],
            boundaries: [latest]
        )

        let items = SessionAttachmentTurnSectioning.items(
            sections: sections,
            collapsed: [.checkpoint(latest.id)]
        )

        XCTAssertEqual(items, [.header(sections[0])])
    }

    func testSessionWithoutCheckpointMetadataKeepsItsFlatList() throws {
        let files = [
            attachment("new.png", seconds: 2, placement: .current),
            attachment("next.png", seconds: 1, placement: .next),
            attachment("local.png", seconds: 0, placement: .none)
        ]

        XCTAssertTrue(SessionAttachmentTurnSectioning.sections(
            attachments: files,
            boundaries: []
        ).isEmpty)
    }

    private func boundary(
        ordinal: Int,
        turnID: String,
        seconds: TimeInterval
    ) -> SessionAttachmentTurnBoundary {
        SessionAttachmentTurnBoundary(
            id: GitTurnCheckpointID(),
            ordinal: ordinal,
            userTurnID: turnID,
            requestedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private func attachment(
        _ name: String,
        seconds: TimeInterval,
        turnID: String? = nil,
        placement: SessionAttachment.TurnPlacement
    ) -> SessionAttachment {
        let url = root.appendingPathComponent(name)
        return SessionAttachment(
            sessionID: sessionID,
            root: root,
            url: url,
            relativePath: name,
            sourcePath: url.path,
            kind: .image,
            origin: placement == .current ? .agent : .user,
            turnID: turnID,
            turnPlacement: placement,
            referencedAt: Date(timeIntervalSince1970: seconds)
        )
    }
}
