import AppKit
import ThreadingController
import XCTest
@testable import Threading

/// The probe rows on Automations ▸ Sources and the approval sheet that is the only way a probe
/// starts running. The facts half pins what a person is shown before approving; the render half
/// writes both surfaces light and dark (`THREADING_RENDER_OUT` redirects them).
@MainActor
final class TriggerProbeSourceRenderTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private var outputDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("ThreadingRenders", isDirectory: true)
    }

    static func probe(name: String, approved: Bool, enabled: Bool, secrets: [String: String] = [:]) -> TriggerSourceInstallation {
        let spec = ControllerSourceSpec(
            name: name, executable: "/usr/bin/python3", script: "/Users/me/probes/imap_probe.py",
            arguments: ["/Users/me/probes/imap_probe.py", "--folder", "INBOX"],
            environment: ["IMAP_HOST": "imap.example.com", "IMAP_USER": "support@example.com"],
            secrets: secrets, intervalSeconds: 600, timeoutSeconds: 30, limit: 50)
        let hash = "9f2c4be0a1d37e55c0b8f6a2d9e41c7b3a5f8e0d2c6b9a1f4e7d0c3b6a9f2e5d"
        return TriggerSourceInstallation(
            id: TriggerSourceInstallationID(), sourceType: TriggerProbeDefaults.sourceType, displayName: name,
            configuration: [:], credentialReference: nil, enabled: enabled, health: enabled ? .healthy : .disconnected,
            lastCheckedAt: now.addingTimeInterval(-90), lastEventAt: nil, boundedDiagnostic: nil,
            createdAt: now, updatedAt: now,
            probe: TriggerProbeSourceSettings(spec: spec, revision: approved ? 2 : 1, hash: hash,
                                              approvedHash: approved ? hash : nil))
    }

    // MARK: - Facts

    func testTheApprovalSheetNamesTheFilesHashScheduleEnvironmentAndSecrets() throws {
        let source = Self.probe(name: "Support mailbox", approved: false, enabled: false,
                                secrets: ["IMAP_PASSWORD": "imap-support", "API_TOKEN": "crm-token"])
        let facts = TriggerProbePresentation.reviewFacts(source, storedSecrets: ["imap-support"])
        XCTAssertEqual(facts.compactMap(\.identifier),
                       ["executable", "script", "hash", "when", "arguments", "environment", "secrets", "limits", "revision"])
        func fact(_ id: String) -> FactSheetView.Fact? { facts.first { $0.identifier == id } }
        XCTAssertEqual(fact("executable")?.value, "/usr/bin/python3")
        XCTAssertEqual(fact("script")?.value, "/Users/me/probes/imap_probe.py")
        XCTAssertEqual(fact("hash")?.value, source.probe?.hash, "the whole hash, not a prefix")
        XCTAssertEqual(fact("arguments")?.value, "--folder\nINBOX")
        XCTAssertEqual(fact("environment")?.value, "IMAP_HOST, IMAP_USER", "keys only")
        XCTAssertFalse(facts.contains { $0.value.contains("imap.example.com") })
        XCTAssertEqual(fact("secrets")?.tone, .caution)
        XCTAssertEqual(fact("secrets")?.detail, L10n.format("Not set yet: %@", "crm-token"))

        let request = TriggerProbePresentation.approvalRequest(source, storedSecrets: [])
        let review = try XCTUnwrap(request.accessory as? AutomationReviewView).review
        XCTAssertEqual(review.instructions, TriggerProbePresentation.authorityWarning)
        XCTAssertTrue(review.instructions.contains("sandbox"))
    }

    func testRowsOfferRunNowOnlyOnceApprovedAndSayWhenTheFilesChanged() {
        let draft = TriggerProbePresentation.row(Self.probe(name: "Draft", approved: false, enabled: false), daemonStatus: nil)
        XCTAssertEqual(draft.state, .needsApproval)
        XCTAssertEqual(draft.primaryTitle, L10n.string("Review & Approve…"))
        XCTAssertFalse(draft.canRunNow)

        let live = Self.probe(name: "Live", approved: true, enabled: true)
        let listening = TriggerProbePresentation.row(live, daemonStatus: TriggerDaemonSourceStatus(
            sourceInstallationID: live.id, health: .backingOff, lastCheckedAt: Self.now, lastEventAt: nil,
            boundedDiagnostic: "HTTP 429 from the feed"), relativeTo: Self.now)
        XCTAssertEqual(listening.state, .listening(.backingOff))
        XCTAssertTrue(listening.canRunNow)
        XCTAssertEqual(listening.primaryTitle, L10n.string("Pause"))
        XCTAssertTrue(listening.detail.contains("SHA-256 9f2c4be0a1d3"))
        XCTAssertTrue(listening.detail.hasSuffix("\nHTTP 429 from the feed"))

        let changed = TriggerProbePresentation.row(live, daemonStatus: TriggerDaemonSourceStatus(
            sourceInstallationID: live.id, health: .changed, lastCheckedAt: Self.now, lastEventAt: nil,
            boundedDiagnostic: nil))
        XCTAssertEqual(changed.state, .changed)
        XCTAssertFalse(changed.canRunNow)
        XCTAssertEqual(changed.primaryTitle, L10n.string("Review & Approve…"))

        let paused = TriggerProbePresentation.row(Self.probe(name: "Paused", approved: true, enabled: false), daemonStatus: nil)
        XCTAssertEqual(paused.primaryTitle, L10n.string("Resume"))
        XCTAssertTrue(paused.canRunNow, "a paused, approved probe can still be polled by hand")
    }

    // MARK: - Renders

    func testRendersTheSourcesPageWithProbeRows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProbeRender-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let store = TriggerStore(url: directory.appendingPathComponent("triggers.db"))
        addTeardownBlock {
            await store.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let live = Self.probe(name: "Support mailbox", approved: true, enabled: true,
                              secrets: ["IMAP_PASSWORD": "imap-support"])
        let draft = Self.probe(name: "Release feed (agent draft)", approved: false, enabled: false)
        try await store.saveSource(live)
        try await store.saveSource(draft)

        for (appearanceName, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let controller = TriggerCenterViewController(store: store)
            _ = controller.view
            try await controller.prepareEvidencePage(index: 2)
            let identifiers = Self.identifiers(in: controller.view)
            XCTAssertTrue(identifiers.contains("probe.new"))
            XCTAssertTrue(identifiers.contains("probe.\(live.id.uuidString)"))
            XCTAssertTrue(identifiers.contains("probe.\(draft.id.uuidString)"))
            let png = render(controller.view, appearance: appearance, size: NSSize(width: 1_000, height: 560))
            let data = try XCTUnwrap(png)
            XCTAssertGreaterThan(data.count, 1_000)
            try data.write(to: outputDirectory.appendingPathComponent("probe-sources-\(appearanceName).png"))
        }
    }

    func testRendersTheProbeApprovalSheet() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let source = Self.probe(name: "Support mailbox", approved: false, enabled: false,
                                secrets: ["IMAP_PASSWORD": "imap-support"])
        for (appearanceName, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated {
                    let request = TriggerProbePresentation.approvalRequest(source, storedSecrets: [])
                    let content = ConfirmationAlert.makeAlert(request).makeContentView()
                    content.appearance = appearance
                    content.layoutSubtreeIfNeeded()
                    content.frame = NSRect(origin: .zero, size: content.fittingSize)
                    AppThemeRefresh.repaint(content)
                    content.layoutSubtreeIfNeeded()
                    XCTAssertTrue(ThemeBoundaryAudit.violations(in: content).isEmpty)
                    guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
                    content.cacheDisplay(in: content.bounds, to: rep)
                    data = rep.representation(using: .png, properties: [:])
                }
            }
            let png = try XCTUnwrap(data)
            XCTAssertGreaterThan(png.count, 1_000)
            try png.write(to: outputDirectory.appendingPathComponent("probe-approval-\(appearanceName).png"))
        }
    }

    private static func identifiers(in view: NSView) -> Set<String> {
        var result: Set<String> = []
        if !view.accessibilityIdentifier().isEmpty { result.insert(view.accessibilityIdentifier()) }
        for child in view.subviews { result.formUnion(identifiers(in: child)) }
        return result
    }

    private func render(_ view: NSView, appearance: NSAppearance, size: NSSize) -> Data? {
        var png: Data?
        appearance.performAsCurrentDrawingAppearance {
            let host = NSView(frame: NSRect(origin: .zero, size: size))
            host.appearance = appearance
            view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(view)
            NSLayoutConstraint.activate([
                host.widthAnchor.constraint(equalToConstant: size.width),
                host.heightAnchor.constraint(equalToConstant: size.height),
                view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                view.topAnchor.constraint(equalTo: host.topAnchor),
                view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            host.wantsLayer = true
            host.layer?.backgroundColor = Design.Surface.ground.cgColor
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(ThemeBoundaryAudit.violations(in: view).isEmpty,
                          ThemeBoundaryAudit.violations(in: view).map(\.description).joined(separator: "\n"))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            png = bitmap.representation(using: .png, properties: [:])
        }
        return png
    }
}
