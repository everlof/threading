import Foundation
import ThreadingSimulatorKit

struct SimulatorCompatibilityProbeRequest: Equatable, Sendable {
    let deviceID: SimulatorDeviceID
    let reportURL: URL
}

enum SimulatorCompatibilityProbeArgumentResolution: Equatable, Sendable {
    case notRequested
    case requested(SimulatorCompatibilityProbeRequest)
    case refused(String)
}

/// Parses the deliberately narrow launch contract used to exercise an exported app bundle.
///
/// The probe runs before stores, windows and the single-instance lock. A release matrix can
/// therefore verify the exact signed host/helper pair without disturbing a person's workspace.
enum SimulatorCompatibilityProbeArguments {
    static let flag = "--simulator-compatibility-probe"
    private static let outputFlag = "--simulator-compatibility-report"

    static func resolve(_ arguments: [String]) -> SimulatorCompatibilityProbeArgumentResolution {
        guard let flagIndex = arguments.firstIndex(of: flag) else { return .notRequested }
        guard arguments.indices.contains(flagIndex + 1),
              let deviceID = SimulatorDeviceID(arguments[flagIndex + 1]) else {
            return .refused("The Simulator compatibility probe requires an exact device UUID.")
        }
        guard let outputIndex = arguments.firstIndex(of: outputFlag),
              arguments.indices.contains(outputIndex + 1) else {
            return .refused("The Simulator compatibility probe requires an output report path.")
        }
        let outputPath = arguments[outputIndex + 1]
        guard outputPath.hasPrefix("/") else {
            return .refused("The Simulator compatibility report path must be absolute.")
        }
        return .requested(SimulatorCompatibilityProbeRequest(
            deviceID: deviceID,
            reportURL: URL(fileURLWithPath: outputPath).standardizedFileURL
        ))
    }

    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.contains(flag)
    }
}

struct SimulatorCompatibilityProbeReport: Codable, Equatable, Sendable {
    // v2 adds the accessibility-snapshot evidence, so a shift in the private AXPTranslator ABI on a
    // new Xcode surfaces as `accessibility != "ok"` instead of silently returning empty trees.
    static let schemaVersion = 2

    let schemaVersion: Int
    let outcome: String
    let protocolVersion: Int
    let hostBundleIdentifier: String?
    let hostVersion: String?
    let hostBuild: String?
    let codec: String?
    let coreSimulatorVersion: String?
    let simulatorKitVersion: String?
    let frameWidth: Int?
    let frameHeight: Int?
    let elapsedMilliseconds: Int
    let failure: String?
    /// "ok" when the accessibility tree read back, "unavailable" when the read failed, or
    /// "not-attempted" when the stream itself was incompatible so no read was tried.
    let accessibility: String
    let accessibilityElementCount: Int?
    let accessibilityFailure: String?

    private enum CodingKeys: String, CodingKey {
        case outcome, codec, failure, accessibility
        case schemaVersion = "schema_version"
        case protocolVersion = "protocol_version"
        case hostBundleIdentifier = "host_bundle_identifier"
        case hostVersion = "host_version"
        case hostBuild = "host_build"
        case coreSimulatorVersion = "core_simulator_version"
        case simulatorKitVersion = "simulator_kit_version"
        case frameWidth = "frame_width"
        case frameHeight = "frame_height"
        case elapsedMilliseconds = "elapsed_milliseconds"
        case accessibilityElementCount = "accessibility_element_count"
        case accessibilityFailure = "accessibility_failure"
    }
}

/// Read-only, one-shot compatibility evidence from the exact app bundle being launched.
///
/// This does not prepare, boot or control a device. The matrix runner supplies an already-booted
/// UDID, then the normal live coordinator verifies the embedded helper, active Xcode frameworks,
/// protocol handshake and two decoded frames in sequence order before the app exits.
enum SimulatorCompatibilityProbe {
    private struct Evidence: Sendable {
        /// Nil when the stream used the shared-memory transport, which has no codec.
        let codec: SimulatorBridgeCodec?
        let coreSimulatorVersion: String?
        let simulatorKitVersion: String?
        let width: Int
        let height: Int
    }

    /// A stream proves it flows with two decoded frames in sequence order, not one. A helper
    /// whose encoder holds frames delivers exactly one picture and then idles, which a
    /// first-frame check reported as compatible.
    static let requiredFrames = 2

    private enum ProbeError: LocalizedError {
        case endedBeforeFrames
        case failed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .endedBeforeFrames:
                return "The direct Simulator stream ended before delivering \(requiredFrames) frames."
            case .failed(let detail):
                return detail
            case .timedOut:
                return "The direct Simulator stream did not deliver \(requiredFrames) frames before its deadline."
            }
        }
    }

    static func run(
        request: SimulatorCompatibilityProbeRequest,
        bundle: Bundle = .main,
        coordinator: any SimulatorLiveStreamCoordinating = SimulatorLiveStreamCoordinator.shared,
        timeout: Duration = .seconds(12)
    ) async -> SimulatorCompatibilityProbeReport {
        let startedAt = ContinuousClock.now
        do {
            let session = try await coordinator.openStream(for: request.deviceID)
            defer {
                session.setVisible(false)
                session.stop()
            }
            session.setVisible(true)
            let evidence = try await flowingStream(from: session, timeout: timeout)
            // The stream is compatible; now check the accessibility read on the same session. A
            // failure here does not make the device incompatible — it is a separate capability — but
            // it is recorded so private-AX-ABI drift is caught rather than silently degrading.
            let accessibility = await probeAccessibility(session: session)
            return report(
                bundle: bundle,
                startedAt: startedAt,
                outcome: "compatible",
                evidence: evidence,
                accessibility: accessibility,
                failure: nil
            )
        } catch {
            return report(
                bundle: bundle,
                startedAt: startedAt,
                outcome: "incompatible",
                evidence: nil,
                accessibility: AccessibilityEvidence(status: "not-attempted", count: nil, failure: nil),
                failure: error.localizedDescription
            )
        }
    }

    private struct AccessibilityEvidence: Sendable {
        let status: String
        let count: Int?
        let failure: String?
    }

    /// Read the foreground app's accessibility tree once and count it, so the report proves the
    /// private AXPTranslator path still works on this Xcode. Bounded by its own timeout.
    private static func probeAccessibility(
        session: any SimulatorLiveStreamSession,
        timeout: Duration = .seconds(10)
    ) async -> AccessibilityEvidence {
        do {
            let root = try await withThrowingTaskGroup(of: SimulatorAccessibilityElement.self) { group in
                group.addTask { try await session.requestAccessibilitySnapshot() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ProbeError.timedOut
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw ProbeError.timedOut }
                return first
            }
            return AccessibilityEvidence(status: "ok", count: elementCount(root), failure: nil)
        } catch {
            return AccessibilityEvidence(
                status: "unavailable", count: nil, failure: error.localizedDescription
            )
        }
    }

    private static func elementCount(_ element: SimulatorAccessibilityElement) -> Int {
        1 + element.children.reduce(0) { $0 + elementCount($1) }
    }

    static func write(
        _ report: SimulatorCompatibilityProbeReport,
        to url: URL
    ) throws {
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private static func flowingStream(
        from session: any SimulatorLiveStreamSession,
        timeout: Duration
    ) async throws -> Evidence {
        try await withThrowingTaskGroup(of: Evidence.self) { group in
            group.addTask {
                var ready: (
                    SimulatorBridgeCodec?,
                    String?,
                    String?
                )?
                var evidence: Evidence?
                var lastSequence: UInt64?
                var frames = 0
                for await event in session.events {
                    switch event {
                    case .ready(
                        let backend,
                        _,
                        let coreSimulatorVersion,
                        let simulatorKitVersion
                    ):
                        // The shared-memory transport is valid compatibility evidence too; it just
                        // has no codec. A screenshot fallback is not — keep waiting for a direct
                        // backend.
                        let codec: SimulatorBridgeCodec?
                        switch backend {
                        case .direct(let selected): codec = selected
                        case .sharedMemory: codec = nil
                        case .screenshotFallback: continue
                        }
                        ready = (codec, coreSimulatorVersion, simulatorKitVersion)
                    case .frame(let frame):
                        guard let ready else { continue }
                        if let lastSequence, frame.sequence <= lastSequence { continue }
                        lastSequence = frame.sequence
                        frames += 1
                        if evidence == nil {
                            evidence = Evidence(
                                codec: ready.0,
                                coreSimulatorVersion: ready.1,
                                simulatorKitVersion: ready.2,
                                width: frame.image.width,
                                height: frame.image.height
                            )
                        }
                        if frames >= requiredFrames, let evidence { return evidence }
                    case .failed(let detail):
                        throw ProbeError.failed(detail)
                    case .ended:
                        throw ProbeError.endedBeforeFrames
                    case .statistics:
                        continue
                    }
                }
                throw ProbeError.endedBeforeFrames
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProbeError.timedOut
            }
            defer { group.cancelAll() }
            guard let evidence = try await group.next() else {
                throw ProbeError.endedBeforeFrames
            }
            return evidence
        }
    }

    private static func report(
        bundle: Bundle,
        startedAt: ContinuousClock.Instant,
        outcome: String,
        evidence: Evidence?,
        accessibility: AccessibilityEvidence,
        failure: String?
    ) -> SimulatorCompatibilityProbeReport {
        let elapsed = startedAt.duration(to: .now)
        let milliseconds = Int(elapsed.components.seconds * 1_000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        return SimulatorCompatibilityProbeReport(
            schemaVersion: SimulatorCompatibilityProbeReport.schemaVersion,
            outcome: outcome,
            protocolVersion: SimulatorBridgeProtocol.current,
            hostBundleIdentifier: bundle.bundleIdentifier,
            hostVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            hostBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            codec: evidence.flatMap { $0.codec.map(codecName) },
            coreSimulatorVersion: evidence?.coreSimulatorVersion,
            simulatorKitVersion: evidence?.simulatorKitVersion,
            frameWidth: evidence?.width,
            frameHeight: evidence?.height,
            elapsedMilliseconds: milliseconds,
            failure: failure,
            accessibility: accessibility.status,
            accessibilityElementCount: accessibility.count,
            accessibilityFailure: accessibility.failure
        )
    }

    private static func codecName(_ codec: SimulatorBridgeCodec) -> String {
        switch codec {
        case .h264: "h264"
        case .jpeg: "jpeg"
        }
    }
}
