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
                title: L10n.string("Refresh artifact map"),
                description: L10n.string(
                    "Scan the appointed artifact or folder again."
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
                        .text(L10n.string("AnotherTerminal folder"), role: .heading),
                        .text(
                            L10n.string(
                                "Area represents size. Select a circle to open that branch; "
                                    + "select a file to inspect it."
                            ),
                            role: .detail
                        ),
                        .stack(
                            axis: .horizontal,
                            spacing: .small,
                            children: [
                                .status(L10n.string("57.0 GiB total"), role: .neutral),
                                .status(L10n.string("Build output dominates"), role: .warning),
                                .flexibleSpacer,
                                .picker(
                                    id: "select-grouping",
                                    selection: "folder",
                                    options: [
                                        .init(value: "folder", title: L10n.string("By folder")),
                                        .init(value: "type", title: L10n.string("By type"))
                                    ],
                                    accessibilityLabel: L10n.string("Grouping"),
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
                                    "Disk-usage map for the AnotherTerminal folder"
                                ),
                                preferredAspectRatio: 1,
                                hierarchy: ExtensionSceneHierarchy(rootID: "artifact-root"),
                                items: [
                                    .init(
                                        id: "artifact-root",
                                        frame: .init(x: 0.02, y: 0.02, width: 0.96, height: 0.96),
                                        shape: .ellipse,
                                        color: .category4,
                                        label: L10n.string("AnotherTerminal"),
                                        detail: L10n.string("57.0 GiB"),
                                        isSelected: true
                                    ),
                                    .init(
                                        id: "build",
                                        parentID: "artifact-root",
                                        frame: .init(x: 0.06, y: 0.18, width: 0.58, height: 0.58),
                                        shape: .ellipse,
                                        color: .category1,
                                        label: ".build",
                                        detail: L10n.string("43.0 GiB")
                                    ),
                                    .init(
                                        id: "build-products",
                                        parentID: "build",
                                        frame: .init(x: 0.09, y: 0.27, width: 0.34, height: 0.34),
                                        shape: .ellipse,
                                        color: .category1,
                                        label: L10n.string("Products"),
                                        detail: L10n.string("18.4 GiB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "build-dependencies",
                                        parentID: "build",
                                        frame: .init(x: 0.37, y: 0.37, width: 0.23, height: 0.23),
                                        shape: .ellipse,
                                        color: .category1,
                                        label: L10n.string("Dependencies"),
                                        detail: L10n.string("11.7 GiB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "build-index",
                                        parentID: "build",
                                        frame: .init(x: 0.17, y: 0.55, width: 0.17, height: 0.17),
                                        shape: .ellipse,
                                        color: .category1,
                                        label: L10n.string("Index"),
                                        detail: L10n.string("6.1 GiB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "build-cache",
                                        parentID: "build",
                                        frame: .init(x: 0.35, y: 0.59, width: 0.13, height: 0.13),
                                        shape: .ellipse,
                                        color: .category1,
                                        label: L10n.string("Cache"),
                                        detail: L10n.string("3.8 GiB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "build-other",
                                        parentID: "build",
                                        frame: .init(x: 0.46, y: 0.57, width: 0.10, height: 0.10),
                                        shape: .ellipse,
                                        color: .category1,
                                        label: L10n.string("Other"),
                                        detail: L10n.string("3.0 GiB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "sources",
                                        parentID: "artifact-root",
                                        frame: .init(x: 0.61, y: 0.25, width: 0.34, height: 0.34),
                                        shape: .ellipse,
                                        color: .category2,
                                        label: L10n.string("Sources"),
                                        detail: L10n.string("6.4 GiB")
                                    ),
                                    .init(
                                        id: "threading-source",
                                        parentID: "sources",
                                        frame: .init(x: 0.63, y: 0.29, width: 0.18, height: 0.18),
                                        shape: .ellipse,
                                        color: .category2,
                                        label: L10n.string("Threading"),
                                        detail: L10n.string("3.1 GiB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "mobile-source",
                                        parentID: "sources",
                                        frame: .init(x: 0.785, y: 0.375, width: 0.11, height: 0.11),
                                        shape: .ellipse,
                                        color: .category2,
                                        label: L10n.string("Mobile"),
                                        detail: L10n.string("1.8 GiB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "resources",
                                        parentID: "sources",
                                        frame: .init(x: 0.73, y: 0.45, width: 0.10, height: 0.10),
                                        shape: .ellipse,
                                        color: .category2,
                                        label: L10n.string("Resources"),
                                        detail: L10n.string("0.9 GiB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "other",
                                        parentID: "artifact-root",
                                        frame: .init(x: 0.64, y: 0.61, width: 0.25, height: 0.25),
                                        shape: .ellipse,
                                        color: .category3,
                                        label: L10n.string("Other"),
                                        detail: L10n.string("7.6 GiB")
                                    ),
                                    .init(
                                        id: "packages",
                                        parentID: "other",
                                        frame: .init(x: 0.66, y: 0.64, width: 0.14, height: 0.14),
                                        shape: .ellipse,
                                        color: .category3,
                                        label: L10n.string("Packages"),
                                        detail: L10n.string("5.7 GiB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "documents",
                                        parentID: "other",
                                        frame: .init(x: 0.78, y: 0.73, width: 0.09, height: 0.09),
                                        shape: .ellipse,
                                        color: .category3,
                                        label: L10n.string("Docs"),
                                        detail: L10n.string("1.9 GiB"),
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
                                    title: L10n.string("Refresh scan"),
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
