import XCTest
@testable import Threading

@MainActor
final class RemoteTerminalApplicationCapabilityTests: XCTestCase {
    func testLiveCapabilityProjectsAndMutatesOnlyTheInjectedRunningSurface() throws {
        let sessionID = SessionID()
        let snapshot = RemoteTerminalSnapshot(
            grid: RemoteTerminalGrid(cols: 92, rows: 31),
            title: "Remote terminal",
            screenSeed: Data("seed".utf8),
            remoteViewport: nil
        )
        let surface = RecordingSurface(isRunning: true, snapshot: snapshot)
        let query = RecordingQuery(surfaces: [sessionID: surface])
        let capability = LiveRemoteTerminalApplicationCapability(surfaces: query)

        XCTAssertEqual(capability.sessionIDs, Set([sessionID]))
        XCTAssertEqual(capability.state(for: sessionID), .available(snapshot.state))
        XCTAssertEqual(surface.snapshotReadCount, 0, "cheap state must not synthesize a repaint")

        var output: [Data] = []
        XCTAssertEqual(
            capability.beginCapture(for: sessionID) { output.append($0) },
            .captured(snapshot)
        )
        XCTAssertEqual(surface.snapshotReadCount, 1)
        surface.emit(Data("next".utf8))
        XCTAssertEqual(output, [Data("next".utf8)])

        let bytes = Array("hello".utf8)
        XCTAssertEqual(capability.sendInput(bytes, to: sessionID), .applied)
        XCTAssertEqual(surface.inputs, [bytes])

        let viewport = RemoteTerminalGrid(cols: 48, rows: 16)
        XCTAssertEqual(capability.setViewport(viewport, for: sessionID), .applied)
        XCTAssertEqual(surface.viewports, [viewport])

        XCTAssertEqual(capability.endCapture(for: sessionID), .applied)
        surface.emit(Data("ignored".utf8))
        XCTAssertEqual(output, [Data("next".utf8)])
    }

    func testLiveCapabilityRefusesMissingAndStoppedRuntimeMutations() {
        let stoppedID = SessionID()
        let missingID = SessionID()
        let surface = RecordingSurface(
            isRunning: false,
            snapshot: RemoteTerminalSnapshot(
                grid: RemoteTerminalGrid(cols: 80, rows: 24),
                title: "Stopped",
                screenSeed: Data(),
                remoteViewport: RemoteTerminalGrid(cols: 40, rows: 12)
            )
        )
        let capability = LiveRemoteTerminalApplicationCapability(
            surfaces: RecordingQuery(surfaces: [stoppedID: surface])
        )

        XCTAssertEqual(capability.state(for: stoppedID), .unavailable)
        XCTAssertEqual(
            capability.beginCapture(for: stoppedID) { _ in
                XCTFail("A stopped terminal must not begin capture")
            },
            .unavailable
        )
        XCTAssertEqual(capability.sendInput([1], to: stoppedID), .unavailable)
        XCTAssertEqual(
            capability.setViewport(RemoteTerminalGrid(cols: 40, rows: 12), for: stoppedID),
            .unavailable
        )
        XCTAssertTrue(surface.inputs.isEmpty)
        XCTAssertTrue(surface.viewports.isEmpty)

        // Teardown operations are allowed against an allocated but stopped surface so a socket
        // close can release capture and presentation geometry after the process exits.
        XCTAssertEqual(capability.setViewport(nil, for: stoppedID), .applied)
        XCTAssertEqual(capability.endCapture(for: stoppedID), .applied)
        XCTAssertEqual(surface.viewports, [nil])

        XCTAssertEqual(capability.state(for: missingID), .unavailable)
        XCTAssertEqual(capability.sendInput([2], to: missingID), .unavailable)
        XCTAssertEqual(capability.setViewport(nil, for: missingID), .unavailable)
        XCTAssertEqual(capability.endCapture(for: missingID), .unavailable)
    }

    func testMirrorConsumesTheInjectedApplicationCapability() {
        let sessionID = SessionID()
        let snapshot = RemoteTerminalSnapshot(
            grid: RemoteTerminalGrid(cols: 86, rows: 27),
            title: "Injected terminal",
            screenSeed: Data("bounded seed".utf8),
            remoteViewport: nil
        )
        let capability = RecordingApplicationCapability(
            sessionID: sessionID,
            snapshot: snapshot
        )
        let registry = RemoteSessionMirrorRegistry(terminalApplication: capability)

        XCTAssertEqual(registry.beginCapturing(sessionID: sessionID), snapshot.state)
        XCTAssertEqual(capability.captureSessionIDs, [sessionID])
        XCTAssertTrue(capability.stateSessionIDs.isEmpty)

        // An existing mirror asks only for cheap live state; it neither captures twice nor
        // regenerates the bounded screen seed.
        XCTAssertEqual(registry.beginCapturing(sessionID: sessionID), snapshot.state)
        XCTAssertEqual(capability.captureSessionIDs, [sessionID])
        XCTAssertEqual(capability.stateSessionIDs, [sessionID])

        registry.remoteAccessStopped()
        XCTAssertEqual(capability.viewportCalls, [
            .init(sessionID: sessionID, grid: nil)
        ])
        XCTAssertEqual(capability.endedSessionIDs, [sessionID])
    }

    private final class RecordingQuery: RemoteTerminalSurfaceQuerying {
        let surfaces: [SessionID: RecordingSurface]

        init(surfaces: [SessionID: RecordingSurface]) {
            self.surfaces = surfaces
        }

        var remoteTerminalSessionIDs: Set<SessionID> {
            Set(surfaces.keys)
        }

        func remoteTerminalSurface(for sessionID: SessionID) -> (any RemoteTerminalSurface)? {
            surfaces[sessionID]
        }
    }

    private final class RecordingSurface: RemoteTerminalSurface {
        var isRunning: Bool
        let remoteTerminalState: RemoteTerminalState
        private let snapshot: RemoteTerminalSnapshot
        private(set) var snapshotReadCount = 0
        private var outputSink: RemoteTerminalOutputSink?
        private(set) var inputs: [[UInt8]] = []
        private(set) var viewports: [RemoteTerminalGrid?] = []

        init(isRunning: Bool, snapshot: RemoteTerminalSnapshot) {
            self.isRunning = isRunning
            remoteTerminalState = snapshot.state
            self.snapshot = snapshot
        }

        var remoteTerminalSnapshot: RemoteTerminalSnapshot {
            snapshotReadCount += 1
            return snapshot
        }

        func setRemoteOutputSink(_ sink: RemoteTerminalOutputSink?) {
            outputSink = sink
        }

        func sendRemoteInput(_ bytes: [UInt8]) {
            inputs.append(bytes)
        }

        func setRemoteViewport(_ grid: RemoteTerminalGrid?) {
            viewports.append(grid)
        }

        func emit(_ data: Data) {
            outputSink?(data)
        }
    }

    private final class RecordingApplicationCapability: RemoteTerminalApplicationCapability {
        struct ViewportCall: Equatable {
            let sessionID: SessionID
            let grid: RemoteTerminalGrid?
        }

        let sessionID: SessionID
        let snapshot: RemoteTerminalSnapshot
        private(set) var stateSessionIDs: [SessionID] = []
        private(set) var captureSessionIDs: [SessionID] = []
        private(set) var endedSessionIDs: [SessionID] = []
        private(set) var viewportCalls: [ViewportCall] = []

        init(sessionID: SessionID, snapshot: RemoteTerminalSnapshot) {
            self.sessionID = sessionID
            self.snapshot = snapshot
        }

        var sessionIDs: Set<SessionID> { [sessionID] }

        func state(for sessionID: SessionID) -> RemoteTerminalStateResult {
            stateSessionIDs.append(sessionID)
            return sessionID == self.sessionID ? .available(snapshot.state) : .unavailable
        }

        func beginCapture(
            for sessionID: SessionID,
            output: @escaping RemoteTerminalOutputSink
        ) -> RemoteTerminalCaptureResult {
            captureSessionIDs.append(sessionID)
            return sessionID == self.sessionID ? .captured(snapshot) : .unavailable
        }

        func endCapture(for sessionID: SessionID) -> RemoteTerminalMutationResult {
            guard sessionID == self.sessionID else { return .unavailable }
            endedSessionIDs.append(sessionID)
            return .applied
        }

        func sendInput(
            _ bytes: [UInt8],
            to sessionID: SessionID
        ) -> RemoteTerminalMutationResult {
            sessionID == self.sessionID ? .applied : .unavailable
        }

        func setViewport(
            _ grid: RemoteTerminalGrid?,
            for sessionID: SessionID
        ) -> RemoteTerminalMutationResult {
            guard sessionID == self.sessionID else { return .unavailable }
            viewportCalls.append(.init(sessionID: sessionID, grid: grid))
            return .applied
        }
    }
}

@MainActor
final class AgentTerminalRuntimeCapabilityTests: XCTestCase {
    func testRuntimeProjectsNarrowCapabilitiesAndRefusesStoppedInput() throws {
        let liveID = SessionID()
        let stoppedID = SessionID()
        let missingID = SessionID()
        let runtime = AgentRuntime(
            currentSessionProjection: CurrentSessionProjection { _ in nil }
        )
        let live = RecordingRuntimeSurface(
            isRunning: true,
            processIdentifier: 4_242,
            screenLines: ["Stop and wait for limit to reset"]
        )
        let stopped = RecordingRuntimeSurface(
            isRunning: false,
            processIdentifier: nil,
            screenLines: []
        )

        XCTAssertTrue(runtime.registerTerminalRuntimeSurface(live, for: liveID))
        XCTAssertTrue(runtime.registerTerminalRuntimeSurface(stopped, for: stoppedID))
        XCTAssertFalse(
            runtime.registerTerminalRuntimeSurface(RecordingRuntimeSurface(), for: liveID),
            "one session must retain one runtime adapter and one source of live state"
        )

        let input = try XCTUnwrap(runtime.runningTerminalInputSurface(for: liveID))
        input.pasteTerminalText("continue")
        input.insertTerminalText(TerminalDefaults.submitSequence)
        XCTAssertEqual(live.pasted, ["continue"])
        XCTAssertEqual(live.inserted, [TerminalDefaults.submitSequence])

        let recovery = try XCTUnwrap(runtime.runningLimitRecoverySurface(for: liveID))
        XCTAssertEqual(recovery.visibleTerminalScreenLines(), live.screenLines)
        recovery.noteLimitParked(recoveryArmed: true)
        recovery.noteLimitCleared()
        XCTAssertEqual(live.parked, [true])
        XCTAssertEqual(live.limitClearCount, 1)

        XCTAssertEqual(runtime.terminalRootProcessIdentifier(for: liveID), 4_242)
        XCTAssertNil(runtime.runningTerminalInputSurface(for: stoppedID))
        XCTAssertNil(runtime.runningLimitRecoverySurface(for: stoppedID))
        XCTAssertNotNil(
            runtime.limitRecoverySurface(for: stoppedID),
            "an allocated stopped surface may still lower the park raised by its transcript"
        )
        XCTAssertNil(runtime.terminalRootProcessIdentifier(for: stoppedID))
        XCTAssertNil(runtime.runningTerminalInputSurface(for: missingID))
        XCTAssertNil(runtime.limitRecoverySurface(for: missingID))
        XCTAssertNil(runtime.terminalRootProcessIdentifier(for: missingID))
    }

    private final class RecordingRuntimeSurface: AgentTerminalRuntimeSurface {
        var isRunning: Bool
        var activity: SessionActivity { activityTracker.activity }
        let activityTracker = SessionActivityTracker()
        var isVisible = false
        let remoteTerminalSurface: any RemoteTerminalSurface = EmptyRemoteTerminalSurface()
        let terminalRootProcessIdentifier: pid_t?
        let screenLines: [String]
        private(set) var pasted: [String] = []
        private(set) var inserted: [String] = []
        private(set) var parked: [Bool] = []
        private(set) var limitClearCount = 0

        init(
            isRunning: Bool = false,
            processIdentifier: pid_t? = nil,
            screenLines: [String] = []
        ) {
            self.isRunning = isRunning
            terminalRootProcessIdentifier = processIdentifier
            self.screenLines = screenLines
            if isRunning { activityTracker.markRunning() }
        }

        func pasteTerminalText(_ text: String) { pasted.append(text) }
        func insertTerminalText(_ text: String) { inserted.append(text) }
        func visibleTerminalScreenLines() -> [String] { screenLines }
        func noteLimitCleared() { limitClearCount += 1 }
        func noteLimitParked(recoveryArmed: Bool) { parked.append(recoveryArmed) }
        func noteStateChanged() {}
        func noteReportedCodexTranscript(path: String?, providerSessionID: TranscriptID?) {}
        func noteTurnFinishedForAttachmentDetection(lastAssistantMessage: String?) {}
        func terminate() { isRunning = false }
        func removeFromPresentation() {}
    }

    private final class EmptyRemoteTerminalSurface: RemoteTerminalSurface {
        var isRunning = false
        var remoteTerminalState: RemoteTerminalState {
            RemoteTerminalState(
                grid: RemoteTerminalGrid(cols: 0, rows: 0),
                title: "",
                remoteViewport: nil
            )
        }
        var remoteTerminalSnapshot: RemoteTerminalSnapshot {
            RemoteTerminalSnapshot(
                grid: remoteTerminalState.grid,
                title: remoteTerminalState.title,
                screenSeed: Data(),
                remoteViewport: nil
            )
        }

        func setRemoteOutputSink(_ sink: RemoteTerminalOutputSink?) {}
        func sendRemoteInput(_ bytes: [UInt8]) {}
        func setRemoteViewport(_ grid: RemoteTerminalGrid?) {}
    }
}
