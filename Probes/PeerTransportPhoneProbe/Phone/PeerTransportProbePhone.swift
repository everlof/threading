import Foundation
@preconcurrency import Network
import SwiftUI
import ThreadingPeerTransport

@main
struct PeerTransportProbePhoneApp: App {
    @StateObject private var model = PhoneProbeModel()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 18) {
                ProgressView()
                    .opacity(model.isFinished ? 0 : 1)
                Text(model.title)
                    .font(.title2.weight(.semibold))
                Text(model.detail)
                    .font(.body.monospaced())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .task { await model.runOnce() }
        }
    }
}

@MainActor
private final class PhoneProbeModel: ObservableObject {
    @Published private(set) var title = "Finding your Mac…"
    @Published private(set) var detail = "Allow Local Network access if iOS asks."
    @Published private(set) var isFinished = false
    private var hasRun = false

    func runOnce() async {
        guard !hasRun else { return }
        hasRun = true
        do {
            let result = try await PhoneProbeSession.run { [weak self] status in
                Task { @MainActor in self?.detail = status }
            }
            title = "Direct connection passed"
            detail = result
            isFinished = true
            print("THREADING_PHONE_PROBE PHONE PASS \(result)")
        } catch {
            title = "Probe failed"
            detail = error.localizedDescription
            isFinished = true
            print("THREADING_PHONE_PROBE PHONE FAIL \(error.localizedDescription)")
        }
    }
}

private enum PhoneProbeSession {
    static func run(status: @escaping @Sendable (String) -> Void) async throws -> String {
        let rendezvous = ProbeRendezvousClient(
            baseURL: ProbeConstants.remoteRendezvousURL,
            token: ProbeConstants.rendezvousToken
        )
        status("Contacting one-use hosted rendezvous…")
        let request = try await rendezvous.wait(for: ProbeOffer.self, slot: "offer")

        let stun = try PeerIceServer(urls: [ProbeConstants.stunURL])
        let configuration = try PeerTransportConfiguration(iceServers: [stun])
        let peer = try WebRTCPeerTransport(role: .answerer, configuration: configuration)
        let started = ContinuousClock.now
        let answer = try await peer.makeTrickleAnswer(to: request.offer)
        try await rendezvous.publish(
            ProbeAnswer(identifier: request.identifier, answer: answer),
            slot: "answer"
        )
        let publishing = Task {
            try await publishProbeCandidates(from: peer, side: "phone", through: rendezvous)
        }
        defer { publishing.cancel() }
        let applying = Task {
            try await applyProbeCandidates(to: peer, remoteSide: "mac", through: rendezvous)
        }
        defer { applying.cancel() }
        status("Candidates are trickling; trying a direct ICE path…")
        try await peer.waitUntilOpen()

        let challenge = try await peer.receive()
        guard challenge == probeChallenge() else {
            throw ProbeNetworkError.challengeMismatch
        }
        try await peer.send(challenge)
        let acknowledgement = try await peer.receive()
        guard acknowledgement == probeAcknowledgement() else {
            throw ProbeNetworkError.challengeMismatch
        }
        let route = await peer.selectedRoute()
        let elapsed = started.duration(to: .now)
        try await rendezvous.publish(
            ProbeCompletion(
                identifier: request.identifier,
                phoneRoute: describe(route),
                phoneElapsed: String(describing: elapsed)
            ),
            slot: "completion"
        )
        let result = "route=\(describe(route)) bytes=\(challenge.count) elapsed=\(elapsed)"
        await peer.close()
        return result
    }

    private static func firstProbeEndpoint() async throws -> NWEndpoint {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ProbeOneShot(continuation)
            let queue = DispatchQueue(label: "codes.threading.peer-probe.browser")
            let browser = NWBrowser(
                for: .bonjour(type: ProbeConstants.serviceType, domain: nil),
                using: .tcp
            )
            browser.browseResultsChangedHandler = { results, _ in
                guard let endpoint = results.first?.endpoint else { return }
                browser.cancel()
                gate.succeed(endpoint)
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    gate.fail(ProbeNetworkError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    break
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + ProbeConstants.discoveryTimeout) {
                browser.cancel()
                gate.fail(ProbeNetworkError.discoveryTimedOut)
            }
            browser.start(queue: queue)
        }
    }
}
