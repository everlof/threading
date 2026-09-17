import Foundation
import Network
import os

/// Whether a connection to the advertised service can wake this Mac, and the two facts that
/// decide it.
///
/// **Both have to hold, and neither is enough on its own.** macOS registers a Bonjour-advertised
/// listener with a Sleep Proxy on the network — an Apple TV, a HomePod, or a capable router — and
/// the proxy answers for the sleeping Mac and wakes it when somebody connects. With "Wake for
/// network access" off, macOS never hands the registration over; with no proxy on the network,
/// there is nothing to hand it to and the Mac sleeps through every attempt exactly as before.
///
/// Each fact is optional because "we have not looked" and "we looked and the answer is no" are
/// different things to render, and a status line that says "cannot wake" because a browse has not
/// finished yet is a lie with a short lifetime.
struct RemoteWakeOnDemandFacts: Equatable, Sendable {

    /// Whether "Wake for network access" is on, as `pmset` reports `womp`. Nil when the setting
    /// could not be read, which is the answer on a machine where the probe did not run.
    let wakeForNetworkAccess: Bool?

    /// Whether a Bonjour Sleep Proxy answered on the network this Mac is on. Nil before the
    /// browse has produced an answer.
    let sleepProxyPresent: Bool?

    /// When these were read, so a settings screen can say how fresh they are and a stale answer
    /// after a network change can be refreshed rather than believed.
    let readAt: Date?

    static let unknown = RemoteWakeOnDemandFacts(
        wakeForNetworkAccess: nil,
        sleepProxyPresent: nil,
        readAt: nil
    )

    /// **True only when "Wake for network access" is on *and* a sleep proxy is present.**
    ///
    /// This is the value a settings screen may render as "can wake this Mac", and it is
    /// deliberately the only one: anything less than both facts holding means a connection to a
    /// sleeping Mac times out, and a screen that promised waking would have promised something
    /// the network cannot do. Unknown is not "yes".
    var canWakeThisMac: Bool {
        wakeForNetworkAccess == true && sleepProxyPresent == true
    }
}

/// Reads the two wake-on-demand facts.
///
/// Both halves touch things the main actor must not: one spawns a child process and the other
/// opens a bounded browse on the network stack. Callers hop off before asking, and every answer
/// is allowed to stay unknown.
enum RemoteWakeOnDemandProbe {

    /// Reads both facts. Blocking on the child process, bounded on the browse.
    static func read() async -> RemoteWakeOnDemandFacts {
        let womp = await Task.detached(priority: .utility) { readWakeForNetworkAccess() }.value
        let proxy = await sleepProxyPresent()
        return RemoteWakeOnDemandFacts(
            wakeForNetworkAccess: womp,
            sleepProxyPresent: proxy,
            readAt: Date()
        )
    }

    // MARK: - Wake for network access

    /// Whether "Wake for network access" is on.
    ///
    /// `pmset -g` prints the settings currently in use, one per line, and `womp` is the one that
    /// names this. Deliberately the CLI rather than `IOPMCopyActivePMPreferences`: the IOKit
    /// answer is a per-power-source dictionary that has to be indexed by the source in use, which
    /// is a second thing to get wrong, and this is a status line rather than a hot path.
    static func readWakeForNetworkAccess(
        runner: (String, [String]) -> String? = runSynchronously
    ) -> Bool? {
        wakeForNetworkAccess(from: runner(executablePath, [settingsArgument]))
    }

    static func wakeForNetworkAccess(from output: String?) -> Bool? {
        guard let output else { return nil }
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] == wompKey else { continue }
            return fields[1] == "1"
        }
        return nil
    }

    // MARK: - Sleep proxy

    /// Whether a Bonjour Sleep Proxy is answering on this network.
    ///
    /// A short browse and then stop: this is a question about right now, not a subscription, and
    /// a browser left running is a multicast listener nobody turned on. The deadline is the
    /// answer's ceiling — a proxy that has not announced itself within it is one a sleeping Mac
    /// could not rely on either.
    static func sleepProxyPresent(
        timeout: TimeInterval = RemoteAccessDefaults.sleepProxyBrowseTimeout
    ) async -> Bool? {
        let browser = NWBrowser(
            for: .bonjour(type: RemoteAccessDefaults.sleepProxyServiceType, domain: nil),
            using: .udp
        )
        defer { browser.cancel() }

        return await withCheckedContinuation { continuation in
            let answered = OSAllocatedUnfairLock<Bool>(initialState: false)
            @Sendable func finish(_ value: Bool?) {
                let alreadyAnswered = answered.withLock { current -> Bool in
                    defer { current = true }
                    return current
                }
                guard !alreadyAnswered else { return }
                continuation.resume(returning: value)
            }

            browser.browseResultsChangedHandler = { results, _ in
                guard !results.isEmpty else { return }
                finish(true)
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed:
                    finish(nil)
                case .waiting:
                    // A browse the system will not run is not the same as a network with no
                    // proxy on it. Local network access being denied lands here.
                    finish(nil)
                default:
                    break
                }
            }
            browser.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }

    // MARK: - Child process

    private static let executablePath = "/usr/bin/pmset"
    private static let settingsArgument = "-g"
    private static let wompKey = "womp"

    /// Blocking; call it off the main actor. `RemoteSleepProbe` reads `pmset` through it too.
    static func runSynchronously(_ executable: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        guard let result = try? BoundedChildProcess.run(
            executable: executable,
            arguments: arguments,
            timeout: RemoteAccessDefaults.wakeSettingProbeTimeout,
            maximumOutputBytes: RemoteAccessDefaults.wakeSettingProbeOutputBytes,
            output: .standardOutput
        ), case .exited(let status) = result.termination, status == 0 else { return nil }
        return String(data: result.output, encoding: .utf8)
    }
}
