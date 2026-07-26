import AppKit
import SkalmanExtensionKit

/// Isolated stories for the component-customization pipeline. The final story uses the real
/// sidebar row; the earlier generic shell keeps the composition mechanics isolated while the
/// production stories prove both its additive slot and compact full-content replacement.
@MainActor
enum ComponentCustomizationGalleryFixture {
    struct Story {
        let title: String
        let detail: String
        let view: NSView
    }

    static func stories() -> [Story] {
        [
            defaultStory(),
            slotStory(),
            replacementStory(),
            invalidFallbackStory(),
            realSessionRowStory(),
            realSessionRowReplacementStory(),
            realProjectAndSessionCIStory()
        ]
    }

    private static let contract = ExtensionComponentContract(
        id: "gallery.compact-row",
        version: 1,
        context: .sessionPresentation,
        properties: [.title],
        slots: [
            .init(id: "after-title", maximumInlineItems: 2)
        ],
        replacement: .contentOnly,
        hostOwnedBehavior: [.selection, .rowActions, .accessibilityContainer]
    )

    private static func defaultStory() -> Story {
        let registry = makeRegistry()
        let view = makeRow(
            registry: registry,
            identifier: "gallery.extension.component.default"
        )
        return Story(
            title: "Customization · native default",
            detail: "No provider value: the original AppKit subtree is the complete result.",
            view: view
        )
    }

    private static func slotStory() -> Story {
        let registry = makeRegistry()
        try? registry.replacePatches(
            [
                .init(
                    id: "ci-accessory",
                    target: target,
                    slots: [
                        .init(
                            slot: "after-title",
                            children: [.status("CI passed", role: .positive)]
                        )
                    ]
                )
            ],
            from: source
        )
        let view = makeRow(
            registry: registry,
            identifier: "gallery.extension.component.slot"
        )
        return Story(
            title: "Customization · additive slot",
            detail: "The native content remains while a host-rendered CI accessory is composed.",
            view: view
        )
    }

    private static func replacementStory() -> Story {
        let registry = makeRegistry()
        try? registry.replacePatches(
            [
                .init(
                    id: "ci-renderer",
                    target: target,
                    replacement: .stack(
                        axis: .horizontal,
                        spacing: .small,
                        children: [
                            .image(
                                .systemSymbol("shippingbox.fill"),
                                role: .identity,
                                accessibilityLabel: "Deployment"
                            ),
                            .text("Deploy production", role: .compactBody),
                            .flexibleSpacer,
                            .status("CI passed", role: .positive)
                        ]
                    )
                )
            ],
            from: source
        )
        let view = makeRow(
            registry: registry,
            identifier: "gallery.extension.component.replacement"
        )
        return Story(
            title: "Customization · full HStack",
            detail: "The visual subtree is replaced; the surrounding host shell remains native.",
            view: view
        )
    }

    private static func invalidFallbackStory() -> Story {
        let registry = makeRegistry()
        let invalid = ExtensionComponentPatch(
            id: "invalid-private-slot",
            target: target,
            slots: [
                .init(
                    slot: "private-slot",
                    children: [.status("Must not render", role: .negative)]
                )
            ]
        )
        let wasRejected: Bool
        do {
            try registry.replacePatches([invalid], from: source)
            wasRejected = false
        } catch {
            wasRejected = true
        }

        let view = makeRow(
            registry: registry,
            identifier: "gallery.extension.component.invalid"
        )
        view.setAccessibilityHelp(
            wasRejected
                ? "Invalid patch rejected; native content restored."
                : "Fixture error: invalid patch was accepted."
        )
        return Story(
            title: "Customization · invalid fallback",
            detail: "An undeclared slot is rejected atomically and the native row stays visible.",
            view: view
        )
    }

    private static func realSessionRowStory() -> Story {
        let registry = ComponentCustomizationRegistry()
        try? registry.register(HostComponentContracts.sidebarSessionRow)
        let session = AgentSession(kind: .codex, title: "Deploy production")
        let rowTarget = ExtensionComponentTarget(
            component: HostComponentContracts.sidebarSessionRow.id,
            contractVersion: HostComponentContracts.sidebarSessionRow.version,
            entityID: session.id.uuidString.lowercased()
        )
        try? registry.replacePatches(
            [
                .init(
                    id: "ci-accessory",
                    target: rowTarget,
                    slots: [
                        .init(
                            slot: "after-title",
                            children: [.status("CI passed", role: .positive)]
                        )
                    ]
                )
            ],
            from: source
        )

        let row = SessionRowView(customizationLookup: registry.customization(for:))
        row.configure(with: session, activity: .idle)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 420).isActive = true
        row.heightAnchor.constraint(equalToConstant: SidebarDefaults.rowHeight).isActive = true
        row.setAccessibilityIdentifier("gallery.extension.component.session-row")

        return Story(
            title: "Customization · real session row",
            detail: "A fake CI provider fills the real row's after-title slot; actions and activity remain host-owned.",
            view: row
        )
    }

    private static func realSessionRowReplacementStory() -> Story {
        let registry = ComponentCustomizationRegistry()
        try? registry.register(HostComponentContracts.sidebarSessionRow)
        let session = AgentSession(kind: .codex, title: "Native session title")
        let rowTarget = ExtensionComponentTarget(
            component: HostComponentContracts.sidebarSessionRow.id,
            contractVersion: HostComponentContracts.sidebarSessionRow.version,
            entityID: session.id.uuidString.lowercased()
        )
        try? registry.replacePatches(
            [
                .init(
                    id: "ci-renderer",
                    target: rowTarget,
                    replacement: .stack(
                        axis: .horizontal,
                        spacing: .small,
                        children: [
                            .image(
                                .hostAsset("session.provider-image"),
                                role: .identity,
                                accessibilityLabel: "Agent"
                            ),
                            .text("Deploy production", role: .compactBody),
                            .flexibleSpacer,
                            .status("Passed", role: .positive),
                            .button(
                                id: "inspect-build",
                                title: "Details",
                                role: .standard,
                                isEnabled: true
                            )
                        ]
                    )
                )
            ],
            from: source
        )

        let row = SessionRowView(customizationLookup: registry.customization(for:))
        row.onCustomizationAction = { [weak row] action in
            row?.setAccessibilityHelp(
                "\(action.extensionIdentifier ?? "unknown"):\(action.actionID)"
            )
        }
        row.configure(with: session, activity: .working)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 420).isActive = true
        row.heightAnchor.constraint(equalToConstant: SidebarDefaults.rowHeight).isActive = true
        row.setAccessibilityIdentifier(
            "gallery.extension.component.session-row-replacement"
        )

        return Story(
            title: "Customization · real session-row HStack",
            detail: "The native visual subtree is replaced while the working indicator, hover actions, selection and row identity stay in Skalman's shell.",
            view: row
        )
    }

    /// One source publishes entity-scoped state for both public row families. This is the
    /// smallest useful model of a CI extension without placing fake build state in the app.
    private static func realProjectAndSessionCIStory() -> Story {
        let registry = ComponentCustomizationRegistry()
        try? registry.register(HostComponentContracts.sidebarProjectRow)
        try? registry.register(HostComponentContracts.sidebarSessionRow)

        let project = Project(
            name: "Skalman",
            folderURL: URL(fileURLWithPath: "/tmp/Skalman")
        )
        let session = AgentSession(kind: .codex, title: "Deploy production")
        let projectTarget = ExtensionComponentTarget(
            component: HostComponentContracts.sidebarProjectRow.id,
            contractVersion: HostComponentContracts.sidebarProjectRow.version,
            entityID: project.id.uuidString.lowercased()
        )
        let sessionTarget = ExtensionComponentTarget(
            component: HostComponentContracts.sidebarSessionRow.id,
            contractVersion: HostComponentContracts.sidebarSessionRow.version,
            entityID: session.id.uuidString.lowercased()
        )

        try? registry.replacePatches(
            [
                .init(
                    id: "project-ci",
                    target: projectTarget,
                    slots: [
                        .init(
                            slot: "after-title",
                            children: [.status("CI passed", role: .positive)]
                        )
                    ]
                ),
                .init(
                    id: "session-ci",
                    target: sessionTarget,
                    slots: [
                        .init(
                            slot: "after-title",
                            children: [.status("Build 481", role: .positive)]
                        )
                    ]
                )
            ],
            from: source
        )

        let projectRow = ProjectRowView(
            customizationLookup: registry.customization(for:)
        )
        projectRow.configure(with: project, collapsedSessionCount: 3)
        let sessionRow = SessionRowView(
            customizationLookup: registry.customization(for:)
        )
        sessionRow.configure(with: session, activity: .idle)

        for row in [projectRow, sessionRow] {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: 420).isActive = true
            row.heightAnchor.constraint(equalToConstant: SidebarDefaults.rowHeight).isActive = true
        }

        let rows = NSStackView(views: [projectRow, sessionRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Design.Spacing.tight
        rows.setAccessibilityIdentifier(
            "gallery.extension.component.project-session-ci"
        )

        return Story(
            title: "Customization · project + session CI",
            detail: "One extension generation publishes scoped CI state to both real row shells; project count and both rows' actions remain host-owned.",
            view: rows
        )
    }

    private static var target: ExtensionComponentTarget {
        .init(
            component: contract.id,
            contractVersion: contract.version,
            entityID: "gallery-session"
        )
    }

    private static let source = ComponentCustomizationSource(
        extensionIdentifier: "com.example.gallery",
        processGeneration: "fixture",
        order: 0
    )

    private static func makeRegistry() -> ComponentCustomizationRegistry {
        let registry = ComponentCustomizationRegistry()
        try? registry.register(contract)
        return registry
    }

    private static func makeRow(
        registry: ComponentCustomizationRegistry,
        identifier: String
    ) -> NSView {
        let nativeIcon = NSImageView(
            image: NSImage(
                systemSymbolName: "bubble.left.fill",
                accessibilityDescription: "Conversation"
            ) ?? NSImage()
        )
        nativeIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            nativeIcon.widthAnchor.constraint(equalToConstant: 18),
            nativeIcon.heightAnchor.constraint(equalToConstant: 18)
        ])

        let nativeTitle = NSTextField(labelWithString: "Native session row")
        nativeTitle.font = Design.Typography.control()
        nativeTitle.textColor = Design.Text.label
        nativeTitle.lineBreakMode = .byTruncatingTail

        let native = NSStackView(views: [nativeIcon, nativeTitle])
        native.orientation = .horizontal
        native.alignment = .centerY
        native.spacing = Design.Spacing.small

        let content = ComponentContentContainer(defaultContent: native)
        content.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let slot = NSStackView()
        slot.orientation = .horizontal
        slot.alignment = .centerY
        slot.spacing = Design.Spacing.tight

        let shell = NSStackView(views: [content, slot])
        shell.orientation = .horizontal
        shell.alignment = .centerY
        shell.spacing = Design.Spacing.small
        shell.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.tight,
            left: Design.Spacing.small,
            bottom: Design.Spacing.tight,
            right: Design.Spacing.small
        )
        shell.translatesAutoresizingMaskIntoConstraints = false
        shell.widthAnchor.constraint(equalToConstant: 420).isActive = true
        shell.applySurface(
            fill: Design.Surface.panel,
            radius: .control,
            border: Design.Surface.border
        )
        shell.setAccessibilityIdentifier(identifier)

        let host = ComponentCustomizationHost(
            target: target,
            contentContainer: content,
            slots: ["after-title": slot],
            lookup: registry.customization(for:)
        )
        host.refresh()
        return shell
    }
}
