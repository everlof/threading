import ThreadingExtensionKit

/// The extension-UI proving fixture Threading renders.
///
/// Kept in application source rather than in the gallery so the renderer tests and the live
/// catalogue exercise exactly the same value tree. It is a fixture, not an installed extension;
/// ArtifactKit gives the generic controls and semantic scene a concrete, demanding use case
/// without giving the renderer an ArtifactKit-specific node.
enum ExtensionExperimentFixture {

    static let manifest = ExtensionManifest(
        identifier: "codes.threading.artifact-preview",
        name: "ArtifactKit Preview",
        version: "0.1.0",
        runtime: .native,
        executable: "bin/artifact-preview",
        capabilities: [.commands, .panels]
    )

    static let registration = ExtensionRegistration(
        commands: [
            ExtensionCommand(
                id: "refresh",
                title: L10n.string("Compare releases"),
                description: L10n.string(
                    "Compare the selected iOS release with its predecessor."
                )
            )
        ],
        panels: [
            ExtensionPanel(
                id: "artifact-map",
                title: L10n.string("Artifact map"),
                root: .stack(
                    axis: .vertical,
                    spacing: .medium,
                    children: [
                        .text(L10n.string("iOS 26.5 release image"), role: .heading),
                        .text(
                            L10n.string(
                                "A native semantic scene supplied by an extension. "
                                    + "Area represents installed size."
                            ),
                            role: .detail
                        ),
                        .stack(
                            axis: .horizontal,
                            spacing: .small,
                            children: [
                                .status(L10n.string("11.84 GB total"), role: .neutral),
                                .status(L10n.string("+326 MB"), role: .warning),
                                .flexibleSpacer,
                                .picker(
                                    id: "select-release",
                                    selection: "ios-26.5",
                                    options: [
                                        .init(value: "ios-26.4", title: "iOS 26.4"),
                                        .init(value: "ios-26.5", title: "iOS 26.5")
                                    ],
                                    accessibilityLabel: L10n.string("Release"),
                                    isEnabled: true
                                )
                            ]
                        ),
                        .textInput(
                            id: "filter-artifacts",
                            value: "",
                            placeholder: L10n.string("Filter files, frameworks, or packages"),
                            accessibilityLabel: L10n.string("Filter artifacts"),
                            role: .search,
                            isEnabled: true
                        ),
                        .scene(
                            ExtensionScene(
                                accessibilityLabel: L10n.string(
                                    "Installed-size map for iOS 26.5"
                                ),
                                preferredAspectRatio: 1.55,
                                items: [
                                    .init(
                                        id: "system-library",
                                        frame: .init(x: 0, y: 0, width: 0.62, height: 0.58),
                                        color: .category1,
                                        label: L10n.string("System Library"),
                                        detail: L10n.string("4.82 GB · +114 MB"),
                                        actionID: "inspect-artifact",
                                        isSelected: true
                                    ),
                                    .init(
                                        id: "dyld-cache",
                                        frame: .init(x: 0.62, y: 0, width: 0.38, height: 0.36),
                                        color: .category2,
                                        label: L10n.string("dyld cache"),
                                        detail: L10n.string("2.31 GB · +92 MB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "frameworks",
                                        frame: .init(x: 0.62, y: 0.36, width: 0.38, height: 0.22),
                                        color: .category3,
                                        label: L10n.string("Frameworks"),
                                        detail: L10n.string("1.18 GB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "applications",
                                        frame: .init(x: 0, y: 0.58, width: 0.48, height: 0.42),
                                        color: .category4,
                                        label: L10n.string("Applications"),
                                        detail: L10n.string("1.94 GB · +121 MB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "fonts",
                                        frame: .init(x: 0.48, y: 0.58, width: 0.22, height: 0.42),
                                        color: .category5,
                                        label: L10n.string("Fonts"),
                                        detail: L10n.string("614 MB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "other",
                                        frame: .init(x: 0.70, y: 0.58, width: 0.30, height: 0.42),
                                        color: .category6,
                                        label: L10n.string("Other"),
                                        detail: L10n.string("986 MB · −1 MB"),
                                        actionID: "inspect-artifact"
                                    )
                                ]
                            )
                        ),
                        .divider,
                        .stack(
                            axis: .horizontal,
                            spacing: .small,
                            children: [
                                .button(
                                    id: "refresh",
                                    title: L10n.string("Compare with iOS 26.4"),
                                    role: .primary,
                                    isEnabled: true
                                ),
                                .button(
                                    id: "remove",
                                    title: L10n.string("Export map"),
                                    role: .standard,
                                    isEnabled: true
                                ),
                                .button(
                                    id: "unavailable",
                                    title: L10n.string("Symbol diff"),
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
