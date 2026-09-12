import AppKit
import XCTest
@testable import Threading

/// The complete destination for listening rules: authority before activation, the durable run
/// receipt, and source health. These are one feature but three independently navigable pages, so
/// the evidence keeps all three visible under both system appearances.
@MainActor
final class TriggerCenterRenderTests: XCTestCase {
    private var outputDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "ThreadingRenders",
            isDirectory: true
        )
    }

    func testRendersConfigurationActivityAndSources() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TriggerCenterRender-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let store = TriggerStore(url: directory.appendingPathComponent("triggers.db"))
        addTeardownBlock {
            await store.close()
            try? FileManager.default.removeItem(at: directory)
        }
        try await seed(store)
        let pages = [(0, "configuration"), (1, "activity"), (2, "sources")]
        let appearances = [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)]

        for (page, pageName) in pages {
            for (appearanceName, appearanceNameValue) in appearances {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceNameValue))
                let controller = TriggerCenterViewController(store: store)
                _ = controller.view
                try await controller.prepareEvidencePage(index: page)
                var png: Data?
                var violations: [ThemeBoundaryAudit.Violation] = []

                appearance.performAsCurrentDrawingAppearance {
                    let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
                    host.appearance = appearance
                    controller.view.translatesAutoresizingMaskIntoConstraints = false
                    host.addSubview(controller.view)
                    NSLayoutConstraint.activate([
                        host.widthAnchor.constraint(equalToConstant: 900),
                        host.heightAnchor.constraint(equalToConstant: 640),
                        controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                        controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                        controller.view.topAnchor.constraint(equalTo: host.topAnchor),
                        controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                    ])
                    host.wantsLayer = true
                    host.layer?.backgroundColor = Design.Surface.ground.cgColor
                    AppThemeRefresh.repaint(host)
                    host.layoutSubtreeIfNeeded()
                    host.layoutSubtreeIfNeeded()
                    violations = ThemeBoundaryAudit.violations(in: controller.view)
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                        return
                    }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    png = bitmap.representation(using: .png, properties: [:])
                }

                XCTAssertTrue(
                    violations.isEmpty,
                    violations.map(\.description).joined(separator: "\n")
                )
                let data = try XCTUnwrap(png)
                XCTAssertGreaterThan(data.count, 1_000)
                try data.write(to: outputDirectory.appendingPathComponent(
                    "trigger-center-\(pageName)-\(appearanceName).png"
                ))
            }
        }
    }

    private func seed(_ store: TriggerStore) async throws {
        let now = Date(timeIntervalSince1970: 1_788_966_000)
        let source = TriggerSourceInstallation(
            id: TriggerSourceInstallationID(),
            sourceType: "sonda",
            displayName: "Demo review feed",
            configuration: ["base_url": .string("https://demo.example.com")],
            credentialReference: "render-fixture",
            enabled: true,
            health: .healthy,
            lastCheckedAt: now.addingTimeInterval(-45),
            lastEventAt: now.addingTimeInterval(-180),
            boundedDiagnostic: nil,
            createdAt: now.addingTimeInterval(-86_400),
            updatedAt: now
        )
        try await store.saveSource(source)

        let triggerID = TriggerID()
        let revisionID = TriggerRevisionID()
        let definition = TriggerDefinition(
            id: triggerID,
            name: "Review incoming cases",
            enabled: false,
            activeRevisionID: nil,
            draftRevisionID: revisionID,
            createdAt: now,
            updatedAt: now
        )
        let revision = TriggerRevision(
            id: revisionID,
            triggerID: triggerID,
            sequence: 1,
            sourceInstallationID: source.id,
            eventKind: "case.review-required",
            conditions: [TriggerCondition(
                attribute: "status",
                comparison: .equals,
                value: .string("needs_review")
            )],
            projectID: ProjectID(),
            instructions: "Assess the report and explain the likely cause. If the change is local and straightforward, prepare the smallest safe fix and run the focused tests.",
            agentKind: .codex,
            accountHandleName: nil,
            model: nil,
            reasoningEffort: "high",
            executionMode: .assessThenFix,
            checkoutPolicy: .managedWorktree,
            limits: .conservative,
            quietHours: nil,
            notifications: .standard,
            allowSourceResources: false,
            proposedBySessionID: nil,
            createdAt: now
        )
        try await store.saveDraft(definition, revision: revision)
        try await store.activate(triggerID: triggerID, revisionID: revisionID, at: now)

        let event = TriggerEvent(
            sourceInstallationID: source.id,
            externalID: "case-1042",
            revision: "2",
            kind: revision.eventKind,
            occurredAt: now.addingTimeInterval(-420),
            receivedAt: now.addingTimeInterval(-415),
            title: "Report upload needs review",
            attributes: ["status": .string("needs_review")],
            deepLink: URL(string: "https://demo.example.com/admin/review-required-uploads/case-1042"),
            resources: []
        )
        _ = try await store.accept(event)
        _ = try await store.createRun(TriggerRun(
            id: TriggerRunID(),
            triggerID: triggerID,
            triggerRevisionID: revisionID,
            eventKey: event.storageKey,
            state: .completed,
            queuedAt: now.addingTimeInterval(-400),
            startedAt: now.addingTimeInterval(-390),
            settledAt: now.addingTimeInterval(-60),
            sessionID: SessionID(),
            managedWorkspaceID: UUID(),
            holdReason: nil,
            result: TriggerRunResult(
                disposition: .fixed,
                summary: "Small validation fix is ready; focused tests passed.",
                changedPaths: ["src/review.ts"],
                tests: ["review-required tests"]
            ),
            boundedDiagnostic: nil
        ))
    }
}
