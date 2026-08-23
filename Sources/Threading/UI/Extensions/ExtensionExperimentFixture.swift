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
                                        frame: .init(
                                            x: 0.100950,
                                            y: 0.325687,
                                            width: 0.565163,
                                            height: 0.565163
                                        ),
                                        shape: .ellipse,
                                        color: .category1,
                                        label: ".build",
                                        detail: L10n.string("43.0 GiB")
                                    ),
                                    .init(
                                        id: "build-products",
                                        parentID: "build",
                                        frame: .init(
                                            x: 0.339042,
                                            y: 0.531944,
                                            width: 0.208656,
                                            height: 0.208656
                                        ),
                                        shape: .ellipse,
                                        color: .category1,
                                        label: L10n.string("Products"),
                                        detail: L10n.string("18.4 GiB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "build-dependencies",
                                        parentID: "build",
                                        frame: .init(
                                            x: 0.183957,
                                            y: 0.617191,
                                            width: 0.166385,
                                            height: 0.166385
                                        ),
                                        shape: .ellipse,
                                        color: .category2,
                                        label: L10n.string("Dependencies"),
                                        detail: L10n.string("11.7 GiB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "build-index",
                                        parentID: "build",
                                        frame: .init(
                                            x: 0.397673,
                                            y: 0.412433,
                                            width: 0.120140,
                                            height: 0.120140
                                        ),
                                        shape: .ellipse,
                                        color: .category5,
                                        label: L10n.string("Index"),
                                        detail: L10n.string("6.1 GiB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "build-cache",
                                        parentID: "build",
                                        frame: .init(
                                            x: 0.488283,
                                            y: 0.709281,
                                            width: 0.094823,
                                            height: 0.094823
                                        ),
                                        shape: .ellipse,
                                        color: .category6,
                                        label: L10n.string("Cache"),
                                        detail: L10n.string("3.8 GiB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "build-other",
                                        parentID: "build",
                                        frame: .init(
                                            x: 0.270644,
                                            y: 0.527871,
                                            width: 0.084252,
                                            height: 0.084252
                                        ),
                                        shape: .ellipse,
                                        color: .neutral,
                                        label: L10n.string("Other"),
                                        detail: L10n.string("3.0 GiB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "sources",
                                        parentID: "artifact-root",
                                        frame: .init(
                                            x: 0.308749,
                                            y: 0.109150,
                                            width: 0.218037,
                                            height: 0.218037
                                        ),
                                        shape: .ellipse,
                                        color: .category2,
                                        label: L10n.string("Sources"),
                                        detail: L10n.string("6.4 GiB")
                                    ),
                                    .init(
                                        id: "threading-source",
                                        parentID: "sources",
                                        frame: .init(
                                            x: 0.385048,
                                            y: 0.195216,
                                            width: 0.110833,
                                            height: 0.110833
                                        ),
                                        shape: .ellipse,
                                        color: .category4,
                                        label: L10n.string("Threading"),
                                        detail: L10n.string("3.1 GiB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "mobile-source",
                                        parentID: "sources",
                                        frame: .init(
                                            x: 0.339654,
                                            y: 0.130287,
                                            width: 0.084455,
                                            height: 0.084455
                                        ),
                                        shape: .ellipse,
                                        color: .category1,
                                        label: L10n.string("Mobile"),
                                        detail: L10n.string("1.8 GiB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "resources",
                                        parentID: "sources",
                                        frame: .init(
                                            x: 0.426351,
                                            y: 0.136964,
                                            width: 0.059719,
                                            height: 0.059719
                                        ),
                                        shape: .ellipse,
                                        color: .category6,
                                        label: L10n.string("Resources"),
                                        detail: L10n.string("0.9 GiB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "other",
                                        parentID: "artifact-root",
                                        frame: .init(
                                            x: 0.661450,
                                            y: 0.428463,
                                            width: 0.237600,
                                            height: 0.237600
                                        ),
                                        shape: .ellipse,
                                        color: .category3,
                                        label: L10n.string("Other"),
                                        detail: L10n.string("7.6 GiB")
                                    ),
                                    .init(
                                        id: "packages",
                                        parentID: "other",
                                        frame: .init(
                                            x: 0.738901,
                                            y: 0.460504,
                                            width: 0.131312,
                                            height: 0.131312
                                        ),
                                        shape: .ellipse,
                                        color: .category5,
                                        label: L10n.string("Packages"),
                                        detail: L10n.string("5.7 GiB"),
                                        actionID: "inspect-artifact"
                                    ),
                                    .init(
                                        id: "documents",
                                        parentID: "other",
                                        frame: .init(
                                            x: 0.690287,
                                            y: 0.558209,
                                            width: 0.075813,
                                            height: 0.075813
                                        ),
                                        shape: .ellipse,
                                        color: .category2,
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
