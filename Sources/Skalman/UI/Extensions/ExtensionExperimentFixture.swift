import SkalmanExtensionKit

/// The first extension-shaped UI Skalman renders.
///
/// Kept in application source rather than in the gallery so the renderer tests and the live
/// catalogue exercise exactly the same value tree. It is a fixture, not an installed extension;
/// process discovery will replace its source without changing its rendering path.
enum ExtensionExperimentFixture {

    static let manifest = ExtensionManifest(
        identifier: "se.mjukis.hello-status",
        name: "Hello Status",
        version: "0.1.0",
        executable: "bin/hello-status",
        capabilities: [.commands, .panels]
    )

    static let registration = ExtensionRegistration(
        commands: [
            ExtensionCommand(
                id: "refresh",
                title: "Refresh status",
                description: "Refresh the example extension's project status."
            )
        ],
        panels: [
            ExtensionPanel(
                id: "status",
                title: "Status",
                root: .stack(
                    axis: .vertical,
                    spacing: .medium,
                    children: [
                        .text("Example extension", role: .heading),
                        .text(
                            "This entire panel is a value tree. Skalman owns every view below it.",
                            role: .detail
                        ),
                        .status("Ready", role: .positive),
                        .divider,
                        .stack(
                            axis: .horizontal,
                            spacing: .small,
                            children: [
                                .button(
                                    id: "refresh",
                                    title: "Refresh",
                                    role: .primary,
                                    isEnabled: true
                                ),
                                .button(
                                    id: "remove",
                                    title: "Remove",
                                    role: .destructive,
                                    isEnabled: true
                                ),
                                .button(
                                    id: "unavailable",
                                    title: "Unavailable",
                                    role: .standard,
                                    isEnabled: false
                                )
                            ]
                        )
                    ]
                )
            )
        ]
    )
}
