import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

/// The `sessionOpen*` span: one record set per chat opening, from the tap to a usable surface.
///
/// Each case drives a real `RemoteSessionConnection` through the same frame handler a socket
/// reaches and then reads the share-safe journal, so what is asserted is what a capture copied
/// to the Mac would carry.
@MainActor
final class MobileSessionOpenSpanTests: XCTestCase {
    func testAConversationIsUsableAtItsHello() async throws {
        let session = Self.session(surface: .conversation, agentKind: "codex")
        let connection = Self.connection(for: session)
        let span = MobileSessionOpenSpan(session: session)
        span.reached(.catalogue)
        connection.openSpan = span

        connection.receiveServerTextForTesting(Self.encoded(RemoteHelloDTO(
            surface: .conversation,
            capability: .interact,
            cols: 80,
            rows: 24,
            title: "Conversation"
        )))

        let records = try await Self.openRecords(for: session)
        let ended = try XCTUnwrap(records.last { $0.event == .sessionOpenEnded })
        XCTAssertEqual(ended.fields[RemoteDiagnosticField.result.rawValue], "succeeded")
        XCTAssertEqual(ended.fields[RemoteDiagnosticField.phase.rawValue], "hello")
        XCTAssertEqual(ended.fields[RemoteDiagnosticField.reason.rawValue], "fresh")
        XCTAssertEqual(ended.fields[RemoteDiagnosticField.detail.rawValue], "codex")
        XCTAssertNotNil(ended.fields[RemoteDiagnosticField.durationMS.rawValue].flatMap(Int.init))
        XCTAssertEqual(
            records.filter { $0.event == .sessionOpenProgress }
                .compactMap { $0.fields[RemoteDiagnosticField.phase.rawValue] },
            ["catalogue", "hello"]
        )
        XCTAssertEqual(
            Set(records.compactMap { $0.fields[RemoteDiagnosticField.trace.rawValue] }).count,
            1,
            "every record of one opening shares its trace"
        )
        XCTAssertNil(connection.openSpan)
    }

    /// A terminal is not usable at its hello: it is revealed by the Mac's ordered boundary, and
    /// the span says so, which is what separates a slow wire from a long hydration hold.
    func testATerminalIsUsableAtItsBoundaryNotItsHello() async throws {
        let session = Self.session(surface: .terminal, agentKind: "claude")
        let connection = Self.connection(for: session)
        connection.onTerminalOutput = { _ in }
        connection.openSpan = MobileSessionOpenSpan(session: session)

        connection.receiveServerTextForTesting(Self.encoded(RemoteHelloDTO(
            surface: .terminal,
            capability: .interact,
            cols: 80,
            rows: 24,
            title: "Terminal",
            features: [RemoteWebSocketFeature.terminalHydrationBoundary.rawValue]
        )))
        XCTAssertNotNil(connection.openSpan, "a hello alone does not reveal a terminal")
        connection.updateTerminalViewport(cols: 69, rows: 59)
        let requestID = try XCTUnwrap(connection.terminalHydrationRequestIDForTesting)
        connection.receiveServerTextForTesting(Self.encoded(
            RemoteTerminalReadyDTO(requestID: requestID)
        ))

        let records = try await Self.openRecords(for: session)
        let ended = try XCTUnwrap(records.last { $0.event == .sessionOpenEnded })
        XCTAssertEqual(ended.fields[RemoteDiagnosticField.result.rawValue], "succeeded")
        XCTAssertEqual(ended.fields[RemoteDiagnosticField.phase.rawValue], "boundary")
        XCTAssertEqual(ended.fields[RemoteDiagnosticField.detail.rawValue], "claude")
        connection.disconnect()
    }

    func testLeavingBeforeTheSurfaceIsUsableIsRecordedAsAbandoned() async throws {
        let session = Self.session(surface: .terminal, agentKind: "grok")
        let connection = Self.connection(for: session)
        let span = MobileSessionOpenSpan(session: session)
        span.path = .pooled
        connection.openSpan = span

        connection.leave()

        let records = try await Self.openRecords(for: session)
        let ended = try XCTUnwrap(records.last { $0.event == .sessionOpenEnded })
        XCTAssertEqual(ended.fields[RemoteDiagnosticField.result.rawValue], "abandoned")
        XCTAssertEqual(ended.fields[RemoteDiagnosticField.reason.rawValue], "pooled")
        XCTAssertEqual(records.filter { $0.event == .sessionOpenEnded }.count, 1)
    }

    /// A chat the Mac closes moments after its hello is not an opening that succeeded.
    ///
    /// The hold that keeps a terminal's first screen from arriving in pieces used to outlive the
    /// socket: the loader stayed over an empty terminal until the hold's own ceiling, and the
    /// span then recorded `succeeded` by `ceiling` — which is what the 2026-09-20 report's
    /// journal says about a chat whose agent had failed to launch 300 ms earlier.
    func testAHostThatEndsTheSessionEndsTheOpeningInsteadOfHoldingItToTheCeiling() async throws {
        let session = Self.session(surface: .terminal, agentKind: "claude")
        let connection = Self.connection(for: session)
        connection.onTerminalOutput = { _ in }
        connection.openSpan = MobileSessionOpenSpan(session: session)

        connection.receiveServerTextForTesting(Self.encoded(RemoteHelloDTO(
            surface: .terminal,
            capability: .interact,
            cols: 80,
            rows: 24,
            title: "Terminal"
        )))
        XCTAssertTrue(connection.isTerminalHydrating)

        connection.receiveServerTextForTesting(#"{"type":"ended","reason":"sessionClosed"}"#)

        XCTAssertFalse(
            connection.isTerminalHydrating,
            "the opening loader must not outlive the connection it was opening"
        )
        let records = try await Self.openRecords(for: session)
        let ended = try XCTUnwrap(records.last { $0.event == .sessionOpenEnded })
        XCTAssertEqual(ended.fields[RemoteDiagnosticField.result.rawValue], "failed")
        XCTAssertEqual(
            ended.fields[RemoteDiagnosticField.code.rawValue],
            "ended.sessionClosed"
        )
        XCTAssertEqual(records.filter { $0.event == .sessionOpenEnded }.count, 1)
        XCTAssertNil(connection.openSpan)
    }

    /// A runtime this build does not know is recorded as `other`, never as the wire's string.
    func testAnUnknownRuntimeIsNotCopiedIntoTheJournal() async throws {
        let session = Self.session(surface: .conversation, agentKind: "someone-elses-agent")
        let span = MobileSessionOpenSpan(session: session)
        span.failed(code: "open.noHost")

        let records = try await Self.openRecords(for: session)
        XCTAssertTrue(records.allSatisfy {
            $0.fields[RemoteDiagnosticField.detail.rawValue] == "other"
        })
        let ended = try XCTUnwrap(records.last { $0.event == .sessionOpenEnded })
        XCTAssertEqual(ended.fields[RemoteDiagnosticField.result.rawValue], "failed")
        XCTAssertEqual(ended.fields[RemoteDiagnosticField.code.rawValue], "open.noHost")
    }

    // MARK: - Fixture

    private static func session(
        surface: RemoteSessionSurface,
        agentKind: String
    ) -> RemoteSessionSummaryDTO {
        RemoteSessionSummaryDTO(
            id: UUID().uuidString.lowercased(),
            title: "Open span fixture",
            agentKind: agentKind,
            surface: surface,
            state: .idle,
            projectName: "Fixture"
        )
    }

    private static func connection(for session: RemoteSessionSummaryDTO) -> RemoteSessionConnection {
        let link = RemoteConnectionLink(string: "https://demo.threading.invalid/#open-span")!
        return RemoteSessionConnection(
            session: session,
            client: RemoteClient(link: link),
            terminalHydrationQuietDelay: .seconds(2),
            terminalHydrationMaximumDelay: .seconds(2)
        )
    }

    /// The span writes on its own queue; cross that boundary once, then read the journal.
    private static func openRecords(
        for session: RemoteSessionSummaryDTO
    ) async throws -> [RemoteDiagnosticRecord] {
        await MobileSessionOpenSpan.waitForWritesForTesting()
        let pseudonym = MobileDiagnostics.pseudonym(session.id, prefix: "session")
        return MobileDiagnostics.journal.records().filter {
            $0.event.rawValue.hasPrefix("sessionOpen")
                && $0.fields[RemoteDiagnosticField.session.rawValue] == pseudonym
        }
    }

    private static func encoded<T: Encodable>(_ value: T) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }
}
