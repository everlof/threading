import OSLog
import QuartzCore
import SwiftTerm
import ThreadingRemoteKit
import UIKit

/// Carries only the sampled input's id across SwiftTerm's nonisolated delegate boundary.
/// The one character exists only during insertText; it is never journaled or uploaded.
final class MobileTerminalInputSampleContext: Sendable {
    private let state = OSAllocatedUnfairLock<(UInt8, String)?>(initialState: nil)

    func set(ascii: UInt8, requestID: String) {
        state.withLock { $0 = (ascii, requestID) }
    }

    func clear() { state.withLock { $0 = nil } }

    func sample(for bytes: ArraySlice<UInt8>) -> (id: String, matches: Bool)? {
        return state.withLock { pending in
            guard let value = pending else { return nil }
            pending = nil
            return (value.1, bytes.count == 1 && bytes.first == value.0)
        }
    }
}

/// Permanent, content-free instrumentation. One expected cursor cell and one display link,
/// active for at most ten seconds, sampled by the connection's existing five-second gate.
@MainActor
final class MobileTerminalInputLatencyProbe: NSObject {
    typealias Recorder = (RemoteDiagnosticEvent, String, String, String, String) -> Void

    private enum Defaults {
        static let timeout: Duration = .seconds(10)
        static let millisecondsPerSecond = 1_000.0
    }

    private struct Sample {
        let id: String
        let startedAt: TimeInterval
        var firstOutputRecorded = false
        var parsedRecorded = false
        var drawnAt: TimeInterval?
    }

    private weak var view: RemoteTerminalView?
    private var sample: Sample?
    private var timeoutTask: Task<Void, Never>?
    private let timeout: Duration
    private var displayLink: CADisplayLink?
    var record: Recorder?

    override convenience init() { self.init(timeout: Defaults.timeout) }

    init(timeout: Duration) {
        self.timeout = timeout
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil
        )
    }

    var isPending: Bool { sample != nil }

    @discardableResult
    func begin(ascii: UInt8, requestID: String, startedAt: TimeInterval,
               view: RemoteTerminalView) -> Bool {
        guard sample == nil, view.window != nil else { return false }
        let armed = view.beginInputEchoObservation(ascii: ascii, parsed: { [weak self] parsedAt in
            Task { @MainActor in self?.didParse(requestID: requestID, at: parsedAt) }
        }, completion: { [weak self] parsedAt, drawnAt in
            Task { @MainActor in
                self?.didDraw(requestID: requestID, parsedAt: parsedAt, drawnAt: drawnAt)
            }
        })
        guard armed else { return false }
        self.view = view
        sample = Sample(id: requestID, startedAt: startedAt)
        emit(.terminalInputVisualProbeStarted, phase: "keypress", result: "started", at: startedAt)
        let timeout = timeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.cancel(result: "unmatchedTimeout")
        }
        return true
    }

    func sent(requestID: String) {
        guard sample?.id == requestID else { return }
        view?.markInputEchoObservationSent()
        emit(.terminalInputVisualProbeProgress, phase: "send", result: "observed")
    }

    func outputReceived() {
        guard sample != nil, sample?.firstOutputRecorded == false else { return }
        sample?.firstOutputRecorded = true
        // This is deliberately first output, not a claim that those bytes echoed the input.
        emit(.terminalInputVisualProbeProgress, phase: "firstOutput", result: "observed")
    }

    private func didParse(requestID: String, at parsedAt: TimeInterval) {
        guard sample?.id == requestID, sample?.parsedRecorded == false else { return }
        sample?.parsedRecorded = true
        emit(.terminalInputVisualProbeProgress, phase: "echoParsed", result: "cellMatched", at: parsedAt)
    }

    private func didDraw(requestID: String, parsedAt: TimeInterval, drawnAt: TimeInterval) {
        guard sample?.id == requestID else { return }
        guard isVisible else { cancel(result: "notVisible"); return }
        sample?.drawnAt = drawnAt
        didParse(requestID: requestID, at: parsedAt)
        emit(.terminalInputVisualProbeProgress, phase: "echoDrawn", result: "cellMatched", at: drawnAt)
        let link = CADisplayLink(target: self, selector: #selector(displayTick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        guard isVisible else { cancel(result: "notVisible"); return }
        guard let drawnAt = sample?.drawnAt, link.timestamp >= drawnAt else { return }
        // UIKit supplies no actual scanout callback for Core Graphics. This is the first
        // display opportunity after the matched draw, explicitly an estimate, not photons.
        emit(.terminalInputVisualProbeEnded, phase: "displayOpportunity",
             result: "estimated", at: link.timestamp)
        clear()
    }

    private var isVisible: Bool {
        guard let view, view.window != nil,
              UIApplication.shared.applicationState == .active else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            guard !current.isHidden, current.alpha > 0 else { return false }
            ancestor = current.superview
        }
        return true
    }

    @objc private func applicationWillResignActive() { cancel(result: "backgrounded") }

    func cancel(result: String = "cancelled") {
        guard sample != nil else { return }
        emit(.terminalInputVisualProbeEnded, phase: "displayOpportunity", result: result)
        clear()
    }

    private func clear() {
        view?.cancelInputEchoObservation()
        timeoutTask?.cancel()
        timeoutTask = nil
        displayLink?.invalidate()
        displayLink = nil
        sample = nil
        view = nil
    }

    private func emit(_ event: RemoteDiagnosticEvent, phase: String, result: String,
                      at time: TimeInterval = CACurrentMediaTime()) {
        guard let sample else { return }
        let duration = UInt64(max(0, time - sample.startedAt) * Defaults.millisecondsPerSecond)
        record?(event, sample.id, phase, result, String(duration))
    }
}
