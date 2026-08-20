#if DEBUG
import Foundation
import QuartzCore
import ThreadingRemoteKit
import UIKit

/// Measures the real iOS terminal path only while the loopback wire lab is active.
///
/// The probe deliberately sits at boundaries instead of sampling every renderer callback:
/// WebSocket bytes, SwiftTerm feed, the next display tick, viewport leases, normal scrollback,
/// and application-owned mouse scrolling. Release builds contain none of these calls.
@MainActor
enum MobileTerminalWirePerformanceProbe {
    private static let quietPeriod = Duration.milliseconds(250)
    private static var runs: [String: Run] = [:]
    private static var attempts: [String: Int] = [:]
    private static var displayTicks: [UUID: DisplayTick] = [:]
    private static var preparedLog = false

    static var isActive: Bool {
        MobileTerminalWireFixtureConfiguration.current != nil
    }

    static var logURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-terminal-wire-performance.log")
    }

    static func connectionStarted(_ session: RemoteSessionSummaryDTO) {
        guard isActive, session.surface == .terminal else { return }
        let attempt = (attempts[session.agentKind] ?? 0) + 1
        attempts[session.agentKind] = attempt
        runs[session.id] = Run(
            provider: session.agentKind,
            attempt: attempt,
            connectedAt: CACurrentMediaTime()
        )
    }

    static func helloReceived(_ session: RemoteSessionSummaryDTO) {
        guard let run = runs[session.id] else { return }
        run.helloAt = run.helloAt ?? CACurrentMediaTime()
    }

    static func terminalViewCreated(_ session: RemoteSessionSummaryDTO) {
        guard let run = runs[session.id] else { return }
        run.viewCreatedAt = run.viewCreatedAt ?? CACurrentMediaTime()
    }

    static func outputReceived(_ data: Data, session: RemoteSessionSummaryDTO) {
        guard let run = runs[session.id] else { return }
        let now = CACurrentMediaTime()
        run.firstOutputAt = run.firstOutputAt ?? now
        run.lastOutputAt = now
        run.outputFrames += 1
        run.outputBytes += data.count
        run.clearScreenCount += occurrences(of: [0x1b, 0x5b, 0x32, 0x4a], in: data)
        run.clearHistoryCount += occurrences(of: [0x1b, 0x5b, 0x33, 0x4a], in: data)
        run.alternateScreenEntries += occurrences(
            of: Array("\u{1b}[?1049h".utf8),
            in: data
        )
        scheduleEntryQuiet(for: session.id, run: run)

        if let typing = run.typing {
            typing.outputFrames += 1
            typing.outputBytes += data.count
        }
        if let turn = run.turn {
            turn.firstOutputAt = turn.firstOutputAt ?? now
            turn.lastOutputAt = now
            turn.outputFrames += 1
            turn.outputBytes += data.count
            scheduleTurnQuiet(for: session.id, run: run, turn: turn)
        }
        if let wheel = run.wheelScroll {
            wheel.firstOutputAt = wheel.firstOutputAt ?? now
            wheel.lastOutputAt = now
            wheel.outputFrames += 1
            wheel.outputBytes += data.count
            scheduleWheelQuiet(for: session.id, run: run, wheel: wheel)
        }
    }

    static func feed(
        _ data: Data,
        session: RemoteSessionSummaryDTO,
        body: () -> Void
    ) {
        guard let run = runs[session.id] else {
            body()
            return
        }
        let start = CACurrentMediaTime()
        body()
        let end = CACurrentMediaTime()
        let elapsed = end - start
        run.firstFeedAt = run.firstFeedAt ?? start
        run.lastFeedAt = end
        run.feedCalls += 1
        run.feedSeconds += elapsed
        run.maximumFeedSeconds = max(run.maximumFeedSeconds, elapsed)
        if !run.entryDisplayScheduled {
            run.entryDisplayScheduled = true
            scheduleDisplayTick {
                guard let current = runs[session.id], current === run else { return }
                current.firstDisplayAt = current.firstDisplayAt ?? $0
            }
        }
        scheduleEntryQuiet(for: session.id, run: run)

        if let typing = run.typing {
            typing.feedCalls += 1
            typing.feedSeconds += elapsed
            typing.maximumFeedSeconds = max(typing.maximumFeedSeconds, elapsed)
        }
        if let turn = run.turn {
            turn.feedCalls += 1
            turn.feedSeconds += elapsed
            turn.maximumFeedSeconds = max(turn.maximumFeedSeconds, elapsed)
            if !turn.displayScheduled {
                turn.displayScheduled = true
                scheduleDisplayTick { timestamp in
                    guard let current = runs[session.id], current.turn === turn else { return }
                    turn.firstDisplayAt = timestamp
                }
            }
            scheduleTurnQuiet(for: session.id, run: run, turn: turn)
        }
        if let wheel = run.wheelScroll {
            wheel.feedCalls += 1
            wheel.feedSeconds += elapsed
            wheel.maximumFeedSeconds = max(wheel.maximumFeedSeconds, elapsed)
            if !wheel.displayScheduled {
                wheel.displayScheduled = true
                scheduleDisplayTick { timestamp in
                    guard let current = runs[session.id], current.wheelScroll === wheel else {
                        return
                    }
                    wheel.firstDisplayAt = timestamp
                }
            }
            scheduleWheelQuiet(for: session.id, run: run, wheel: wheel)
        }
    }

    static func terminalInput(
        _ data: ArraySlice<UInt8>,
        session: RemoteSessionSummaryDTO
    ) {
        guard let run = runs[session.id], !data.isEmpty else { return }
        let bytes = Array(data)
        let now = CACurrentMediaTime()
        if isWheelReport(bytes) {
            let wheel = run.wheelScroll ?? WheelScroll(startedAt: now)
            wheel.lastInputAt = now
            wheel.reportCount += 1
            run.wheelScroll = wheel
            scheduleWheelQuiet(for: session.id, run: run, wheel: wheel)
            return
        }

        let submitsLine = bytes.contains(0x0d) || bytes.contains(0x0a)
        if submitsLine {
            if let typing = run.typing {
                writeMetric("ios-terminal-typing", run: run, fields: [
                    "duration_ms": milliseconds(now - typing.startedAt),
                    "keystrokes": String(typing.keystrokes),
                    "output_frames": String(typing.outputFrames),
                    "output_bytes": String(typing.outputBytes),
                    "feed_calls": String(typing.feedCalls),
                    "feed_ms": milliseconds(typing.feedSeconds),
                    "max_feed_ms": milliseconds(typing.maximumFeedSeconds),
                ])
                run.typing = nil
            }
            run.turn?.quietTask?.cancel()
            run.turn = Turn(startedAt: now)
            return
        }

        let printableCount = bytes.filter { $0 >= 0x20 || $0 == 0x08 || $0 == 0x7f }.count
        guard printableCount > 0 else { return }
        let typing = run.typing ?? Typing(startedAt: now)
        typing.keystrokes += printableCount
        run.typing = typing
    }

    static func viewportSent(
        columns: Int,
        rows: Int,
        session: RemoteSessionSummaryDTO
    ) {
        guard let run = runs[session.id] else { return }
        let now = CACurrentMediaTime()
        run.firstViewportAt = run.firstViewportAt ?? now
        run.lastViewportAt = now
        run.viewportCount += 1
        run.lastColumns = columns
        run.lastRows = rows
    }

    static func localScrollChanged(_ session: RemoteSessionSummaryDTO) {
        guard let run = runs[session.id] else { return }
        let now = CACurrentMediaTime()
        let scroll = run.localScroll ?? LocalScroll(startedAt: now)
        if let previous = scroll.lastEventAt {
            scroll.maximumGap = max(scroll.maximumGap, now - previous)
        }
        scroll.lastEventAt = now
        scroll.eventCount += 1
        scroll.quietTask?.cancel()
        scroll.quietTask = Task { @MainActor in
            try? await Task.sleep(for: quietPeriod)
            guard !Task.isCancelled, let current = runs[session.id],
                  current === run, current.localScroll === scroll else { return }
            writeMetric("ios-terminal-scroll", run: run, fields: [
                "mode": "terminal_scrollback",
                "duration_ms": milliseconds((scroll.lastEventAt ?? now) - scroll.startedAt),
                "events": String(scroll.eventCount),
                "max_event_gap_ms": milliseconds(scroll.maximumGap),
            ])
            current.localScroll = nil
        }
        run.localScroll = scroll
    }

    private static func scheduleEntryQuiet(for sessionID: String, run: Run) {
        guard !run.entryLogged else { return }
        run.entryQuietTask?.cancel()
        run.entryQuietTask = Task { @MainActor in
            try? await Task.sleep(for: quietPeriod)
            guard !Task.isCancelled, let current = runs[sessionID], current === run,
                  !run.entryLogged, let lastFeedAt = run.lastFeedAt else { return }
            run.entryLogged = true
            writeMetric("ios-terminal-entry", run: run, fields: [
                "connect_to_hello_ms": interval(run.connectedAt, run.helloAt),
                "connect_to_first_bytes_ms": interval(run.connectedAt, run.firstOutputAt),
                "connect_to_view_ms": interval(run.connectedAt, run.viewCreatedAt),
                "connect_to_settle_ms": milliseconds(lastFeedAt - run.connectedAt),
                "first_feed_to_display_ms": interval(run.firstFeedAt, run.firstDisplayAt),
                "output_frames": String(run.outputFrames),
                "output_bytes": String(run.outputBytes),
                "feed_calls": String(run.feedCalls),
                "feed_ms": milliseconds(run.feedSeconds),
                "max_feed_ms": milliseconds(run.maximumFeedSeconds),
                "clear_screen": String(run.clearScreenCount),
                "clear_history": String(run.clearHistoryCount),
                "alternate_entries": String(run.alternateScreenEntries),
                "viewport_updates": String(run.viewportCount),
                "grid": "\(run.lastColumns)x\(run.lastRows)",
            ])
        }
    }

    private static func scheduleTurnQuiet(for sessionID: String, run: Run, turn: Turn) {
        turn.quietTask?.cancel()
        turn.quietTask = Task { @MainActor in
            try? await Task.sleep(for: quietPeriod)
            guard !Task.isCancelled, let current = runs[sessionID], current === run,
                  current.turn === turn, let lastOutput = turn.lastOutputAt else { return }
            writeMetric("ios-terminal-turn", run: run, fields: [
                "submit_to_first_bytes_ms": interval(turn.startedAt, turn.firstOutputAt),
                "submit_to_settle_ms": milliseconds(lastOutput - turn.startedAt),
                "submit_to_display_ms": interval(turn.startedAt, turn.firstDisplayAt),
                "output_frames": String(turn.outputFrames),
                "output_bytes": String(turn.outputBytes),
                "feed_calls": String(turn.feedCalls),
                "feed_ms": milliseconds(turn.feedSeconds),
                "max_feed_ms": milliseconds(turn.maximumFeedSeconds),
            ])
            current.turn = nil
        }
    }

    private static func scheduleWheelQuiet(
        for sessionID: String,
        run: Run,
        wheel: WheelScroll
    ) {
        wheel.quietTask?.cancel()
        wheel.quietTask = Task { @MainActor in
            try? await Task.sleep(for: quietPeriod)
            guard !Task.isCancelled, let current = runs[sessionID], current === run,
                  current.wheelScroll === wheel else { return }
            writeMetric("ios-terminal-scroll", run: run, fields: [
                "mode": "alternate_mouse",
                "duration_ms": milliseconds(wheel.lastInputAt - wheel.startedAt),
                "reports": String(wheel.reportCount),
                "first_response_ms": interval(wheel.startedAt, wheel.firstOutputAt),
                "first_display_ms": interval(wheel.startedAt, wheel.firstDisplayAt),
                "output_frames": String(wheel.outputFrames),
                "output_bytes": String(wheel.outputBytes),
                "feed_calls": String(wheel.feedCalls),
                "feed_ms": milliseconds(wheel.feedSeconds),
                "max_feed_ms": milliseconds(wheel.maximumFeedSeconds),
            ])
            current.wheelScroll = nil
        }
    }

    private static func scheduleDisplayTick(_ action: @escaping (CFTimeInterval) -> Void) {
        let id = UUID()
        let tick = DisplayTick { timestamp in
            action(timestamp)
            displayTicks[id] = nil
        }
        displayTicks[id] = tick
        tick.start()
    }

    private static func writeMetric(
        _ name: String,
        run: Run,
        fields: [String: String]
    ) {
        let fixed = [
            "provider=\(run.provider)",
            "attempt=\(run.attempt)",
        ]
        let dynamic = fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }
        let line = "THREADING_PERF \(name) " + (fixed + dynamic).joined(separator: " ")
        if !preparedLog {
            try? FileManager.default.removeItem(at: logURL)
            _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
            preparedLog = true
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
            try? handle.close()
        }
        print(line)
    }

    private static func interval(_ start: CFTimeInterval?, _ end: CFTimeInterval?) -> String {
        guard let start, let end else { return "pending" }
        return milliseconds(end - start)
    }

    private static func milliseconds(_ seconds: CFTimeInterval) -> String {
        String(format: "%.2f", max(seconds, 0) * 1_000)
    }

    private static func isWheelReport(_ bytes: [UInt8]) -> Bool {
        let text = String(decoding: bytes, as: UTF8.self)
        return text.contains("\u{1b}[<64;") || text.contains("\u{1b}[<65;")
    }

    private static func occurrences(of pattern: [UInt8], in data: Data) -> Int {
        guard !pattern.isEmpty, data.count >= pattern.count else { return 0 }
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var count = 0
            for start in 0...(bytes.count - pattern.count) {
                var matches = true
                for offset in pattern.indices where bytes[start + offset] != pattern[offset] {
                    matches = false
                    break
                }
                if matches { count += 1 }
            }
            return count
        }
    }

    private final class Run {
        let provider: String
        let attempt: Int
        let connectedAt: CFTimeInterval
        var helloAt: CFTimeInterval?
        var viewCreatedAt: CFTimeInterval?
        var firstOutputAt: CFTimeInterval?
        var lastOutputAt: CFTimeInterval?
        var firstFeedAt: CFTimeInterval?
        var lastFeedAt: CFTimeInterval?
        var firstDisplayAt: CFTimeInterval?
        var outputFrames = 0
        var outputBytes = 0
        var feedCalls = 0
        var feedSeconds: CFTimeInterval = 0
        var maximumFeedSeconds: CFTimeInterval = 0
        var clearScreenCount = 0
        var clearHistoryCount = 0
        var alternateScreenEntries = 0
        var viewportCount = 0
        var firstViewportAt: CFTimeInterval?
        var lastViewportAt: CFTimeInterval?
        var lastColumns = 0
        var lastRows = 0
        var entryDisplayScheduled = false
        var entryLogged = false
        var entryQuietTask: Task<Void, Never>?
        var typing: Typing?
        var turn: Turn?
        var localScroll: LocalScroll?
        var wheelScroll: WheelScroll?

        init(provider: String, attempt: Int, connectedAt: CFTimeInterval) {
            self.provider = provider
            self.attempt = attempt
            self.connectedAt = connectedAt
        }
    }

    private final class Typing {
        let startedAt: CFTimeInterval
        var keystrokes = 0
        var outputFrames = 0
        var outputBytes = 0
        var feedCalls = 0
        var feedSeconds: CFTimeInterval = 0
        var maximumFeedSeconds: CFTimeInterval = 0

        init(startedAt: CFTimeInterval) { self.startedAt = startedAt }
    }

    private final class Turn {
        let startedAt: CFTimeInterval
        var firstOutputAt: CFTimeInterval?
        var lastOutputAt: CFTimeInterval?
        var firstDisplayAt: CFTimeInterval?
        var outputFrames = 0
        var outputBytes = 0
        var feedCalls = 0
        var feedSeconds: CFTimeInterval = 0
        var maximumFeedSeconds: CFTimeInterval = 0
        var displayScheduled = false
        var quietTask: Task<Void, Never>?

        init(startedAt: CFTimeInterval) { self.startedAt = startedAt }
    }

    private final class LocalScroll {
        let startedAt: CFTimeInterval
        var lastEventAt: CFTimeInterval?
        var eventCount = 0
        var maximumGap: CFTimeInterval = 0
        var quietTask: Task<Void, Never>?

        init(startedAt: CFTimeInterval) { self.startedAt = startedAt }
    }

    private final class WheelScroll {
        let startedAt: CFTimeInterval
        var lastInputAt: CFTimeInterval
        var firstOutputAt: CFTimeInterval?
        var lastOutputAt: CFTimeInterval?
        var firstDisplayAt: CFTimeInterval?
        var reportCount = 0
        var outputFrames = 0
        var outputBytes = 0
        var feedCalls = 0
        var feedSeconds: CFTimeInterval = 0
        var maximumFeedSeconds: CFTimeInterval = 0
        var displayScheduled = false
        var quietTask: Task<Void, Never>?

        init(startedAt: CFTimeInterval) {
            self.startedAt = startedAt
            lastInputAt = startedAt
        }
    }

    private final class DisplayTick: NSObject {
        private let action: (CFTimeInterval) -> Void
        private var link: CADisplayLink?

        init(action: @escaping (CFTimeInterval) -> Void) {
            self.action = action
        }

        func start() {
            let link = CADisplayLink(target: self, selector: #selector(fired(_:)))
            self.link = link
            link.add(to: .main, forMode: .common)
        }

        @objc private func fired(_ sender: CADisplayLink) {
            sender.invalidate()
            link = nil
            action(sender.timestamp)
        }
    }
}
#endif
