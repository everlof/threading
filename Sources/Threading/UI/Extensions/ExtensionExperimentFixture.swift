import ThreadingExtensionKit

/// The first extension-shaped UI Threading renders.
///
/// Kept in application source rather than in the gallery so the renderer tests and the live
/// catalogue exercise exactly the same value tree. It is a fixture, not an installed extension;
/// process discovery will replace its source without changing its rendering path.
enum ExtensionExperimentFixture {

    static let manifest = ExtensionManifest(
        identifier: "codes.threading.hello-status",
        name: "Hello Status",
        version: "0.1.0",
        runtime: .native,
        executable: "bin/hello-status",
        capabilities: [.commands, .panels]
    )

    static let registration = ExtensionRegistration(
        commands: [
            ExtensionCommand(
                id: "refresh",
                title: L10n.string("Refresh status"),
                description: L10n.string(
                    "Refresh the example extension's project status."
                )
            )
        ],
        panels: [
            ExtensionPanel(
                id: "status",
                title: L10n.string("Status"),
                root: .stack(
                    axis: .vertical,
                    spacing: .medium,
                    children: [
                        .text(L10n.string("Example extension"), role: .heading),
                        .text(
                            L10n.string(
                                "This entire panel is a value tree. "
                                    + "Threading owns every view below it."
                            ),
                            role: .detail
                        ),
                        .status(L10n.string("Ready"), role: .positive),
                        .divider,
                        .stack(
                            axis: .horizontal,
                            spacing: .small,
                            children: [
                                .button(
                                    id: "refresh",
                                    title: L10n.string("Refresh"),
                                    role: .primary,
                                    isEnabled: true
                                ),
                                .button(
                                    id: "remove",
                                    title: L10n.string("Remove"),
                                    role: .destructive,
                                    isEnabled: true
                                ),
                                .button(
                                    id: "unavailable",
                                    title: L10n.string("Unavailable"),
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
