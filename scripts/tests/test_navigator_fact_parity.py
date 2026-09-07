from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
CHECKER = REPOSITORY / "scripts/check_navigator_fact_parity.py"


CATALOG = """
enum NativeSidebarFactDependency: String, CaseIterable, Sendable {
    case sessionTitle
    case sessionPinned
    case sessionManagerRelationship
    case sessionManagerRole
    case sessionProjectMembership
    case sessionManualOrder
    case projectManualOrder
    case sessionBranch
    case projectBranch
    case terminalBranch
}

enum NativeSidebarMemberAlias: String, CaseIterable, Sendable {
    case sessionDisplayTitle = "AgentSession.displayTitle"
    case projectSessions = "Project.sessions"
}

enum NativeSidebarProviderAlias: String, CaseIterable, Sendable {
    case managerOverview = "ControlGrantStore.overview"
    case managerRole = "ControlGrantStore.isManager"
}

enum NativeSidebarFactInputAlias: String, CaseIterable, Sendable {
    case rootProjects = "SidebarTreeBuilder.rootNodes.projects"
    case projectNodeProjects = "SidebarTreeBuilder.projectNode.projects"
}

enum HostFactCatalog {
    static let nativeInputOwnership: [
        NativeSidebarFactInputAlias: NativeSidebarFactDependency
    ] = [
        .rootProjects: .projectManualOrder,
        .projectNodeProjects: .projectManualOrder,
    ]

    static let all: [HostFactDescriptor] = [
        session(
            parity: [.sessionTitle],
            nativeAliases: [.sessionDisplayTitle]
        ) { $0.title },
        session(parity: [.sessionPinned]) { $0.isPinned },
        session(
            parity: [.sessionManagerRelationship],
            providerAliases: [.managerOverview]
        ) { $0.managerID },
        session(
            parity: [.sessionManagerRole],
            providerAliases: [.managerRole]
        ) { $0.isManager },
        session(
            parity: [.sessionProjectMembership],
            nativeAliases: [.projectSessions]
        ),
        session(
            parity: [.sessionManualOrder],
            nativeAliases: [.projectSessions]
        ),
        project(parity: [.projectManualOrder]),
        session(parity: [.sessionBranch]) { $0.branch },
        project(parity: [.projectBranch]) { $0.branch },
        terminal(parity: [.terminalBranch]) { $0.branch },
    ]
}
"""

MARKERS = """
enum NativeSidebarOptionDependency: String, CaseIterable, Sendable {
    case sessionOrder
    case branchGrouping
    case compactTree
    case groupByFact
}

enum NativeSidebarHostDependency: String, CaseIterable, Sendable {
    case entityIdentity
    case transientLoading
    case customizationPresentation
    case identityPresentation
    case localRepositoryContext
}

enum NativeSidebarHostProviderAlias: String, CaseIterable, Sendable {
    case componentCustomization = "ComponentCustomizationProviderSlot.customization"
    case extensionImage = "ExtensionManager.imageResourceURL"
    case accountDiscovery = "AgentAccountDiscovery.account"
}

enum NativeSidebarOptionSourceAlias: String, CaseIterable, Sendable {
    case sessionOrder = "AppSettings.sidebarSessionOrder"
    case branchGrouping = "AppSettings.groupsSessionsByBranch"
    case compactTree = "AppSettings.compactsSidebarTree"
    case groupByFact = "AppSettings.nativeSidebarGroupByFact"
}

enum NativeSidebarHostInputAlias: String, CaseIterable, Sendable {
    case rowLoading = "SessionRowView.configure.isLoading"
    case projectNodeIdentity = "SidebarTreeBuilder.projectNode.projectID"
    case repositoryIdentity = "GitInfo.repositoryIdentity"
}

enum NativeSidebarParity {
    static let publicOptionOwnership: [
        NativeSidebarOptionDependency: NativeSidebarPipelineOptionID
    ] = [
        .sessionOrder: .sessionOrder,
        .branchGrouping: .branchGrouping,
        .compactTree: .compactTree,
        .groupByFact: .groupByFact,
    ]

    static let optionSourceOwnership: [
        NativeSidebarOptionSourceAlias: NativeSidebarOptionDependency
    ] = [
        .sessionOrder: .sessionOrder,
        .branchGrouping: .branchGrouping,
        .compactTree: .compactTree,
        .groupByFact: .groupByFact,
    ]

    static let hostInputOwnership: [
        NativeSidebarHostInputAlias: NativeSidebarHostDependency
    ] = [
        .rowLoading: .transientLoading,
        .projectNodeIdentity: .entityIdentity,
        .repositoryIdentity: .localRepositoryContext,
    ]

    static let providerOwnership: [
        NativeSidebarHostProviderAlias: NativeSidebarHostDependency
    ] = [
        .componentCustomization: .customizationPresentation,
        .extensionImage: .identityPresentation,
        .accountDiscovery: .identityPresentation,
    ]

    static func fact<T>(_ dependency: NativeSidebarFactDependency, _ value: T) -> T { value }
    static func facts<T>(_ dependencies: [NativeSidebarFactDependency], _ value: T) -> T { value }
    static func option<T>(_ dependency: NativeSidebarOptionDependency, _ value: T) -> T { value }
    static func host<T>(_ dependency: NativeSidebarHostDependency, _ value: T) -> T { value }
}
"""

MODELS = """
struct AgentSession {
    let id: Int
    let displayTitle: String
    let isPinned: Bool
    let isManager: Bool
    let branch: String?
}

struct Project {
    let id: Int
    let folderPath: String
    let sessions: [AgentSession]
    let branch: String?
}

struct ProjectTerminal {
    let id: Int
    let branch: String?
}

final class ControlGrantStore {
    static let shared = ControlGrantStore()
    func overview(for id: Int) -> Int { 0 }
    func isManager(_ id: Int) -> Bool { false }
}

final class ComponentCustomizationProviderSlot {
    static let shared = ComponentCustomizationProviderSlot()
    func customization(for id: Int) -> Int { id }
}

final class ExtensionManager {
    static let shared = ExtensionManager()
    func imageResourceURL() -> Int { 0 }
}

enum AgentAccountDiscovery {
    static func account() -> Int { 0 }
}
"""

SESSION_ROW = """
final class SessionRowView {
    private let imageURL = NativeSidebarParity.host(
        .identityPresentation,
        ExtensionManager.shared.imageResourceURL()
    )
    private let account = NativeSidebarParity.host(
        .identityPresentation,
        AgentAccountDiscovery.account()
    )

    func configure(with session: AgentSession, isLoading: Bool) {
        let rowID = NativeSidebarParity.host(.entityIdentity, session.id)
        let title = NativeSidebarParity.fact(.sessionTitle, session.displayTitle)
        let relationship = NativeSidebarParity.fact(
            .sessionManagerRelationship,
            ControlGrantStore.shared.overview(for: rowID)
        )
        let manager = NativeSidebarParity.fact(
            .sessionManagerRole,
            ControlGrantStore.shared.isManager(rowID)
        )
        let customization = NativeSidebarParity.host(
            .customizationPresentation,
            ComponentCustomizationProviderSlot.shared.customization(for: rowID)
        )
        let loading = NativeSidebarParity.host(.transientLoading, isLoading)
        _ = relationship
        _ = customization
        _ = (rowID, title, manager, loading)
    }
}
"""

BUILDER = """
enum SidebarTreeBuilder {
    static func rootNodes(from projects: [Project]) {
        let classifiedProjects = NativeSidebarParity.fact(.projectManualOrder, projects)
        let order = NativeSidebarParity.option(.sessionOrder, AppSettings.sidebarSessionOrder)
        let groups = NativeSidebarParity.option(
            .branchGrouping,
            AppSettings.groupsSessionsByBranch
        )
        for project in classifiedProjects {
            let sessions = NativeSidebarParity.facts(
                [.sessionProjectMembership, .sessionManualOrder],
                project.sessions
            )
            _ = NativeSidebarParity.host(
                .localRepositoryContext,
                GitInfo.repositoryIdentity(
                    for: NativeSidebarParity.host(.localRepositoryContext, project.folderPath)
                )
            )
            for session in sessions {
                _ = NativeSidebarParity.fact(.sessionPinned, session.isPinned)
            }
        }
        _ = groups
        _ = order
    }

    static func projectNode(for projectID: Int, from projects: [Project]) {
        _ = NativeSidebarParity.host(.entityIdentity, projectID)
        _ = NativeSidebarParity.fact(.projectManualOrder, projects)
    }
}
"""

PROJECT_SIDEBAR = """
final class ProjectSidebarViewController {
    func applyTreeDensity(initial: Bool = false) {
        let compact = NativeSidebarParity.option(
            .compactTree,
            AppSettings.shared.compactsSidebarTree
        )
        _ = (compact, initial)
    }
}
"""

NATIVE_OPTIONS = """
enum NativeSidebarPipelineOptionID: String, CaseIterable, Sendable {
    case sessionOrder = "session-order"
    case branchGrouping = "branch-grouping"
    case compactTree = "compact-tree"
    case groupByFact = "group-by-fact"
}

enum NativeSidebarPipelineOptions {
    static let declarations: [ExtensionWorkspaceNavigatorOption] = [
        ExtensionWorkspaceNavigatorOption(
            id: NativeSidebarPipelineOptionID.sessionOrder.rawValue
        ),
        ExtensionWorkspaceNavigatorOption(
            id: NativeSidebarPipelineOptionID.branchGrouping.rawValue
        ),
        ExtensionWorkspaceNavigatorOption(
            id: NativeSidebarPipelineOptionID.compactTree.rawValue
        ),
    ]

    static let registeredFactDeclarations: [
        ExtensionWorkspaceNavigatorRegisteredFactOption
    ] = [
        .init(id: NativeSidebarPipelineOptionID.groupByFact.rawValue),
    ]

    static let groupByFact = NativeSidebarParity.option(
        .groupByFact,
        AppSettings.nativeSidebarGroupByFact
    )
}
"""


class NavigatorFactParityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.write(
            "Sources/Threading/Core/Extensions/HostFactCatalog.swift",
            CATALOG,
        )
        self.write("Sources/Threading/UI/Views/NativeSidebarParity.swift", MARKERS)
        self.write("Sources/Threading/Models/Models.swift", MODELS)
        self.write("Sources/Threading/UI/Views/SessionRowView.swift", SESSION_ROW)
        self.write("Sources/Threading/UI/Views/SidebarOutlineNodes.swift", BUILDER)
        self.write(
            "Sources/Threading/UI/Views/ProjectSidebarViewController.swift",
            PROJECT_SIDEBAR,
        )
        self.write(
            "Sources/Threading/Core/Extensions/NativeSidebarPipelineOptions.swift",
            NATIVE_OPTIONS,
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self, relative: str, source: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding="utf-8")

    def read(self, relative: str) -> str:
        return (self.root / relative).read_text(encoding="utf-8")

    def replace(self, relative: str, old: str, new: str) -> None:
        source = self.read(relative)
        self.assertIn(old, source)
        self.write(relative, source.replace(old, new))

    def run_checker(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(CHECKER), str(self.root)],
            check=False,
            capture_output=True,
            text=True,
        )

    def assert_fails_with(self, message: str) -> None:
        result = self.run_checker()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(message, result.stderr)

    def test_complete_literal_contract_is_clean(self) -> None:
        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("navigator-fact-parity: clean", result.stdout)

    def test_public_option_ownership_must_cover_every_dependency(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/NativeSidebarParity.swift",
            "        .groupByFact: .groupByFact,\n",
            "",
        )

        self.assert_fails_with(
            "option dependency .groupByFact has no publicOptionOwnership entry"
        )

    def test_public_option_ownership_must_be_one_to_one(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/NativeSidebarParity.swift",
            "        .groupByFact: .groupByFact,\n",
            "        .groupByFact: .compactTree,\n",
        )

        self.assert_fails_with(
            "pipeline option ID .compactTree has 2 publicOptionOwnership owners"
        )

    def test_pipeline_option_ids_require_unique_literal_wire_values(self) -> None:
        self.replace(
            "Sources/Threading/Core/Extensions/NativeSidebarPipelineOptions.swift",
            '    case groupByFact = "group-by-fact"\n',
            '    case groupByFact = "compact-tree"\n',
        )

        self.assert_fails_with(
            'NativeSidebarPipelineOptionID raw value "compact-tree" is shared by '
            ".compactTree and .groupByFact"
        )

    def test_pipeline_option_ids_reject_implicit_raw_values(self) -> None:
        self.replace(
            "Sources/Threading/Core/Extensions/NativeSidebarPipelineOptions.swift",
            '    case groupByFact = "group-by-fact"\n',
            "    case groupByFact\n",
        )

        self.assert_fails_with(
            "NativeSidebarPipelineOptionID .groupByFact must declare one literal string raw value"
        )

    def test_every_pipeline_option_id_requires_one_public_declaration(self) -> None:
        self.replace(
            "Sources/Threading/Core/Extensions/NativeSidebarPipelineOptions.swift",
            "        .init(id: NativeSidebarPipelineOptionID.groupByFact.rawValue),\n",
            "",
        )

        self.assert_fails_with(
            "pipeline option ID .groupByFact has no public declaration"
        )

    def test_pipeline_option_id_cannot_be_declared_twice(self) -> None:
        self.replace(
            "Sources/Threading/Core/Extensions/NativeSidebarPipelineOptions.swift",
            "        .init(id: NativeSidebarPipelineOptionID.groupByFact.rawValue),\n",
            "        .init(id: NativeSidebarPipelineOptionID.groupByFact.rawValue),\n"
            "        .init(id: NativeSidebarPipelineOptionID.groupByFact.rawValue),\n",
        )

        self.assert_fails_with(
            "pipeline option ID .groupByFact has 2 public declarations"
        )

    def test_public_declaration_id_must_reference_the_typed_inventory(self) -> None:
        self.replace(
            "Sources/Threading/Core/Extensions/NativeSidebarPipelineOptions.swift",
            "        .init(id: NativeSidebarPipelineOptionID.groupByFact.rawValue),\n",
            '        .init(id: "group-by-fact"),\n',
        )

        self.assert_fails_with(
            "NativeSidebarPipelineOptions.registeredFactDeclarations entries must each use "
            "one literal NativeSidebarPipelineOptionID raw value as their top-level ID"
        )

    def test_public_declaration_inventories_must_belong_to_native_options(self) -> None:
        self.replace(
            "Sources/Threading/Core/Extensions/NativeSidebarPipelineOptions.swift",
            "enum NativeSidebarPipelineOptions {\n",
            """enum Decoy {
    static let declarations: [ExtensionWorkspaceNavigatorOption] = []
    static let registeredFactDeclarations: [
        ExtensionWorkspaceNavigatorRegisteredFactOption
    ] = []
}

enum NativeSidebarPipelineOptions {
""",
        )
        self.replace(
            "Sources/Threading/Core/Extensions/NativeSidebarPipelineOptions.swift",
            "    static let declarations: [ExtensionWorkspaceNavigatorOption] = [\n",
            "    static let internalDeclarations: [ExtensionWorkspaceNavigatorOption] = [\n",
        )
        self.replace(
            "Sources/Threading/Core/Extensions/NativeSidebarPipelineOptions.swift",
            "    static let registeredFactDeclarations: [\n",
            "    static let internalRegisteredFactDeclarations: [\n",
        )

        self.assert_fails_with(
            "NativeSidebarPipelineOptions has no direct declarations inventory"
        )

    def test_nested_public_option_ownership_cannot_shadow_the_direct_map(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/NativeSidebarParity.swift",
            "        .groupByFact: .groupByFact,\n",
            "        .groupByFact: .compactTree,\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/NativeSidebarParity.swift",
            "enum NativeSidebarParity {\n",
            """enum NativeSidebarParity {
    enum Decoy {
        static let publicOptionOwnership: [
            NativeSidebarOptionDependency: NativeSidebarPipelineOptionID
        ] = [
            .sessionOrder: .sessionOrder,
            .branchGrouping: .branchGrouping,
            .compactTree: .compactTree,
            .groupByFact: .groupByFact,
        ]
    }

""",
        )

        self.assert_fails_with(
            "pipeline option ID .compactTree has 2 publicOptionOwnership owners"
        )

    def test_nested_declaration_inventories_cannot_shadow_direct_members(self) -> None:
        self.replace(
            "Sources/Threading/Core/Extensions/NativeSidebarPipelineOptions.swift",
            "    static let declarations: [ExtensionWorkspaceNavigatorOption] = [\n",
            "    static let internalDeclarations: [ExtensionWorkspaceNavigatorOption] = [\n",
        )
        self.replace(
            "Sources/Threading/Core/Extensions/NativeSidebarPipelineOptions.swift",
            "    static let registeredFactDeclarations: [\n",
            "    static let internalRegisteredFactDeclarations: [\n",
        )
        self.replace(
            "Sources/Threading/Core/Extensions/NativeSidebarPipelineOptions.swift",
            "enum NativeSidebarPipelineOptions {\n",
            """enum NativeSidebarPipelineOptions {
    enum Decoy {
        static let declarations: [ExtensionWorkspaceNavigatorOption] = [
            .init(id: NativeSidebarPipelineOptionID.sessionOrder.rawValue),
            .init(id: NativeSidebarPipelineOptionID.branchGrouping.rawValue),
            .init(id: NativeSidebarPipelineOptionID.compactTree.rawValue),
        ]
        static let registeredFactDeclarations: [
            ExtensionWorkspaceNavigatorRegisteredFactOption
        ] = [
            .init(id: NativeSidebarPipelineOptionID.groupByFact.rawValue),
        ]
    }

""",
        )

        self.assert_fails_with(
            "NativeSidebarPipelineOptions has no direct declarations inventory"
        )

    def test_nested_choice_id_cannot_disguise_an_invalid_top_level_id(self) -> None:
        self.replace(
            "Sources/Threading/Core/Extensions/NativeSidebarPipelineOptions.swift",
            "        .init(id: NativeSidebarPipelineOptionID.groupByFact.rawValue),\n",
            """        .init(
            id: "group-by-fact",
            control: .choice(
                options: [
                    .init(id: NativeSidebarPipelineOptionID.groupByFact.rawValue)
                ]
            )
        ),
""",
        )

        self.assert_fails_with(
            "NativeSidebarPipelineOptions.registeredFactDeclarations entries must each use "
            "one literal NativeSidebarPipelineOptionID raw value as their top-level ID"
        )

    def test_native_option_adapter_is_a_protected_audit_scope(self) -> None:
        self.replace(
            "Sources/Threading/Core/Extensions/NativeSidebarPipelineOptions.swift",
            "    static let groupByFact = NativeSidebarParity.option(\n"
            "        .groupByFact,\n"
            "        AppSettings.nativeSidebarGroupByFact\n"
            "    )",
            "    static let groupByFact = AppSettings.nativeSidebarGroupByFact",
        )

        self.assert_fails_with(
            "NativeSidebarPipelineOptions reads provider root "
            "AppSettings.nativeSidebarGroupByFact outside NativeSidebarParity"
        )

    def test_typed_option_snapshot_can_cross_builder_entrypoint(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            "static func rootNodes(from projects: [Project]) {",
            """static func rootNodes(
        from projects: [Project],
        optionValues: NativeSidebarPipelineOptionValues
    ) {
        _ = optionValues""",
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("navigator-fact-parity: clean", result.stdout)

    def test_unwrapped_compact_tree_source_fails(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/ProjectSidebarViewController.swift",
            "NativeSidebarParity.option(\n"
            "            .compactTree,\n"
            "            AppSettings.shared.compactsSidebarTree\n"
            "        )",
            "AppSettings.shared.compactsSidebarTree",
        )

        self.assert_fails_with(
            "AppSettings.compactsSidebarTree outside NativeSidebarParity"
        )

    def test_unknown_fact_marker_fails(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            ".fact(.sessionTitle, session.displayTitle)",
            ".fact(.unpublishedState, session.displayTitle)",
        )

        self.assert_fails_with("unknown or unpublished .unpublishedState")

    def test_dependency_without_public_descriptor_fails(self) -> None:
        self.replace(
            "Sources/Threading/Core/Extensions/HostFactCatalog.swift",
            "    case sessionTitle\n",
            "    case sessionTitle\n    case sessionModel\n",
        )

        self.assert_fails_with(".sessionModel has no public HostFactCatalog descriptor")

    def test_dependency_with_two_descriptor_owners_fails(self) -> None:
        self.replace(
            "Sources/Threading/Core/Extensions/HostFactCatalog.swift",
            "        session(\n"
            "            parity: [.sessionTitle],\n"
            "            nativeAliases: [.sessionDisplayTitle]\n"
            "        ) { $0.title },\n",
            "        session(\n"
            "            parity: [.sessionTitle],\n"
            "            nativeAliases: [.sessionDisplayTitle]\n"
            "        ) { $0.title },\n"
            "        session(parity: [.sessionTitle]) { $0.title },\n",
        )

        self.assert_fails_with(".sessionTitle is owned by 2 public descriptors")

    def test_unwrapped_new_session_member_fails(self) -> None:
        self.replace(
            "Sources/Threading/Models/Models.swift",
            "    let isPinned: Bool\n",
            "    let isPinned: Bool\n    let newState: Bool\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        _ = session.newState\n        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with("domain member .newState outside NativeSidebarParity")

    def test_alias_cannot_hide_an_unwrapped_member(self) -> None:
        self.replace(
            "Sources/Threading/Models/Models.swift",
            "    let isPinned: Bool\n",
            "    let isPinned: Bool\n    let newState: Bool\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        let alias = session\n"
            "        _ = alias.newState\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with("domain member .newState outside NativeSidebarParity")

    def test_collection_closure_cannot_hide_an_unwrapped_member(self) -> None:
        self.replace(
            "Sources/Threading/Models/Models.swift",
            "    let isPinned: Bool\n",
            "    let isPinned: Bool\n    let newState: Bool\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            "            for session in sessions {\n",
            "            _ = sessions.filter { $0.newState }\n"
            "            for session in sessions {\n",
        )

        self.assert_fails_with("domain member .newState outside NativeSidebarParity")

    def test_for_each_cannot_hide_an_unwrapped_member(self) -> None:
        self.replace(
            "Sources/Threading/Models/Models.swift",
            "    let isPinned: Bool\n",
            "    let isPinned: Bool\n    let newState: Bool\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            "            for session in sessions {\n",
            "            sessions.forEach { _ = $0.newState }\n"
            "            for session in sessions {\n",
        )

        self.assert_fails_with("domain member .newState outside NativeSidebarParity")

    def test_chained_enumerated_for_each_cannot_hide_a_member(self) -> None:
        self.replace(
            "Sources/Threading/Models/Models.swift",
            "    let isPinned: Bool\n",
            "    let isPinned: Bool\n    let newState: Bool\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            "            for session in sessions {\n",
            "            sessions.enumerated().forEach { _, item in _ = item.newState }\n"
            "            for session in sessions {\n",
        )

        self.assert_fails_with("domain member .newState outside NativeSidebarParity")

    def test_named_sort_closure_cannot_hide_an_unwrapped_member(self) -> None:
        self.replace(
            "Sources/Threading/Models/Models.swift",
            "    let isPinned: Bool\n",
            "    let isPinned: Bool\n    let newState: Bool\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            "            for session in sessions {\n",
            "            _ = sessions.sorted { left, right in left.newState && right.newState }\n"
            "            for session in sessions {\n",
        )

        self.assert_fails_with("domain member .newState outside NativeSidebarParity")

    def test_key_path_cannot_hide_an_unwrapped_member(self) -> None:
        self.replace(
            "Sources/Threading/Models/Models.swift",
            "    let isPinned: Bool\n",
            "    let isPinned: Bool\n    let newState: Bool\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            "            for session in sessions {\n",
            "            _ = sessions.map(\\.newState)\n"
            "            for session in sessions {\n",
        )

        self.assert_fails_with("domain member .newState outside NativeSidebarParity")

    def test_host_lane_cannot_hide_domain_data(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            ".fact(.sessionTitle, session.displayTitle)",
            ".host(.transientLoading, session.displayTitle)",
        )

        self.assert_fails_with("domain .displayTitle cannot use host(.transientLoading)")

    def test_existing_fact_cannot_hide_an_unpublished_domain_member(self) -> None:
        self.replace(
            "Sources/Threading/Models/Models.swift",
            "    let isPinned: Bool\n",
            "    let isPinned: Bool\n    let newState: Bool\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        _ = NativeSidebarParity.fact(.sessionTitle, session.newState)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with(".newState has no catalog-owned fact dependency")

    def test_catalog_semantics_distinguish_manager_role_from_relationship(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            ".sessionManagerRole,\n            ControlGrantStore.shared.isManager",
            ".sessionManagerRelationship,\n            ControlGrantStore.shared.isManager",
        )

        self.assert_fails_with(
            "ControlGrantStore.shared.isManager must use its catalog-owned fact dependency "
            "(.sessionManagerRole)"
        )

    def test_catalog_semantics_distinguish_relationship_from_manager_role(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            ".sessionManagerRelationship,\n"
            "            ControlGrantStore.shared.overview",
            ".sessionManagerRole,\n"
            "            ControlGrantStore.shared.overview",
        )

        self.assert_fails_with(
            "ControlGrantStore.shared.overview must use its catalog-owned fact dependency "
            "(.sessionManagerRelationship)"
        )

    def test_catalog_semantics_are_subject_aware_for_shared_member_names(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        _ = NativeSidebarParity.fact(.terminalBranch, session.branch)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with(
            ".branch must use its catalog-owned fact dependency (.sessionBranch)"
        )

    def test_transformed_native_member_uses_explicit_catalog_alias(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            ".fact(.sessionTitle, session.displayTitle)",
            ".fact(.sessionPinned, session.displayTitle)",
        )

        self.assert_fails_with(
            ".displayTitle must use its catalog-owned fact dependency (.sessionTitle)"
        )

    def test_multi_fact_marker_rejects_an_unowned_extra_dependency(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            "[.sessionProjectMembership, .sessionManualOrder],",
            "[.sessionProjectMembership, .sessionTitle],",
        )

        self.assert_fails_with(
            "facts marker includes .sessionTitle, which no enclosed domain read owns"
        )

    def test_multi_fact_marker_rejects_an_omitted_owned_dependency(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            "[.sessionProjectMembership, .sessionManualOrder],",
            "[.sessionProjectMembership],",
        )

        self.assert_fails_with("facts marker omits catalog-owned .sessionManualOrder")

    def test_single_fact_lane_cannot_hide_a_multi_owned_collection_read(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            "NativeSidebarParity.facts(\n"
            "                [.sessionProjectMembership, .sessionManualOrder],\n"
            "                project.sessions\n"
            "            )",
            "NativeSidebarParity.fact(.sessionProjectMembership, project.sessions)",
        )

        self.assert_fails_with("fact marker omits catalog-owned .sessionManualOrder")

    def test_string_interpolation_cannot_hide_a_member(self) -> None:
        self.replace(
            "Sources/Threading/Models/Models.swift",
            "    let isPinned: Bool\n",
            "    let isPinned: Bool\n    let newState: Bool\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        _ = \"value: \\(session.newState)\"\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with("domain member .newState outside NativeSidebarParity")

    def test_optional_chain_cannot_hide_a_member(self) -> None:
        self.replace(
            "Sources/Threading/Models/Models.swift",
            "    let isPinned: Bool\n",
            "    let isPinned: Bool\n    let newState: Bool\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        let optionalSession: AgentSession? = session\n"
            "        _ = optionalSession?.newState\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with("domain member .newState outside NativeSidebarParity")

    def test_collection_subscript_cannot_hide_a_member(self) -> None:
        self.replace(
            "Sources/Threading/Models/Models.swift",
            "    let isPinned: Bool\n",
            "    let isPinned: Bool\n    let newState: Bool\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            "            for session in sessions {\n",
            "            _ = sessions[0].newState\n"
            "            for session in sessions {\n",
        )

        self.assert_fails_with("domain member .newState outside NativeSidebarParity")

    def test_named_map_closure_cannot_hide_a_member(self) -> None:
        self.replace(
            "Sources/Threading/Models/Models.swift",
            "    let isPinned: Bool\n",
            "    let isPinned: Bool\n    let newState: Bool\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            "            for session in sessions {\n",
            "            _ = sessions.compactMap { candidate in candidate.newState }\n"
            "            for session in sessions {\n",
        )

        self.assert_fails_with("domain member .newState outside NativeSidebarParity")

    def test_renamed_conditional_binding_cannot_hide_a_member(self) -> None:
        self.replace(
            "Sources/Threading/Models/Models.swift",
            "    let isPinned: Bool\n",
            "    let isPinned: Bool\n    let newState: Bool\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            "            for session in sessions {\n",
            "            if let leader = sessions.first { _ = leader.newState }\n"
            "            for session in sessions {\n",
        )

        self.assert_fails_with("domain member .newState outside NativeSidebarParity")

    def test_later_session_row_method_is_still_audited(self) -> None:
        self.replace(
            "Sources/Threading/Models/Models.swift",
            "    let isPinned: Bool\n",
            "    let isPinned: Bool\n    let newState: Bool\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n    }\n}",
            "        _ = (rowID, title, manager, loading)\n"
            "    }\n\n"
            "    func lateRead(from laterSession: AgentSession) {\n"
            "        _ = laterSession.newState\n"
            "    }\n"
            "}",
        )

        self.assert_fails_with("SessionRowView reads domain member .newState")

    def test_later_session_row_provider_is_still_audited(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n    }\n}",
            "        _ = (rowID, title, manager, loading)\n"
            "    }\n\n"
            "    func lateProviderRead() {\n"
            "        _ = SessionBadgeStore.shared.badge(for: 1)\n"
            "    }\n"
            "}",
        )

        self.assert_fails_with("provider root SessionBadgeStore.shared.badge")

    def test_whole_domain_value_cannot_escape_to_an_external_helper(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n    }\n}",
            "        _ = (rowID, title, manager, loading)\n"
            "    }\n\n"
            "    func latePresentation(from laterSession: AgentSession) {\n"
            "        _ = SessionBadge.text(for: laterSession)\n"
            "    }\n"
            "}",
        )

        self.assert_fails_with("whole AgentSession value laterSession")

    def test_qualified_external_call_cannot_borrow_an_internal_method_name(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n    }\n}",
            "        _ = (rowID, title, manager, loading)\n"
            "    }\n\n"
            "    func latePresentation(from laterSession: AgentSession) {\n"
            "        _ = BadgeRenderer.configure(laterSession)\n"
            "    }\n"
            "}",
        )

        self.assert_fails_with("whole AgentSession value laterSession")

    def test_contextual_key_path_subscript_read_fails(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n    }\n}",
            "        _ = (rowID, title, manager, loading)\n"
            "    }\n\n"
            "    func latePresentation(from laterSession: AgentSession) {\n"
            "        _ = laterSession[keyPath: \\.isPinned]\n"
            "    }\n"
            "}",
        )

        self.assert_fails_with("domain member .isPinned outside NativeSidebarParity")

    def test_rooted_key_path_subscript_read_fails(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n    }\n}",
            "        _ = (rowID, title, manager, loading)\n"
            "    }\n\n"
            "    func latePresentation(from laterSession: AgentSession) {\n"
            "        _ = laterSession[keyPath: \\AgentSession.isPinned]\n"
            "    }\n"
            "}",
        )

        self.assert_fails_with("domain member .isPinned outside NativeSidebarParity")

    def test_unrelated_key_path_subscript_stays_clean(self) -> None:
        self.write(
            "Sources/Threading/Models/Unrelated.swift",
            "struct UnrelatedRow { let isPinned: Bool }\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n    }\n}",
            "        _ = (rowID, title, manager, loading)\n"
            "    }\n\n"
            "    func latePresentation(from row: UnrelatedRow) {\n"
            "        _ = row[keyPath: \\.isPinned]\n"
            "    }\n"
            "}",
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_collection_element_key_path_subscript_read_fails(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            "        _ = order\n",
            "        _ = projects[0][keyPath: \\.sessions]\n"
            "        _ = order\n",
        )

        self.assert_fails_with(
            "domain member .sessions outside NativeSidebarParity"
        )

    def test_local_domain_array_literal_preserves_element_type(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n    }\n}",
            "        _ = (rowID, title, manager, loading)\n"
            "    }\n\n"
            "    func latePresentation(from laterSession: AgentSession) {\n"
            "        let local = [laterSession]\n"
            "        _ = local[0].isPinned\n"
            "    }\n"
            "}",
        )

        self.assert_fails_with("domain member .isPinned outside NativeSidebarParity")

    def test_local_domain_tuple_projection_preserves_element_type(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n    }\n}",
            "        _ = (rowID, title, manager, loading)\n"
            "    }\n\n"
            "    func latePresentation(from laterSession: AgentSession) {\n"
            "        let local = (laterSession, true)\n"
            "        _ = local.0.isPinned\n"
            "    }\n"
            "}",
        )

        self.assert_fails_with("domain member .isPinned outside NativeSidebarParity")

    def test_unrelated_local_aggregates_stay_clean(self) -> None:
        self.write(
            "Sources/Threading/Models/Unrelated.swift",
            "struct UnrelatedRow { let isPinned: Bool }\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n    }\n}",
            "        _ = (rowID, title, manager, loading)\n"
            "    }\n\n"
            "    func latePresentation(from row: UnrelatedRow) {\n"
            "        let rows = [row]\n"
            "        let tuple = (row, true)\n"
            "        _ = rows[0].isPinned\n"
            "        _ = tuple.0.isPinned\n"
            "    }\n"
            "}",
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_local_domain_dictionary_literal_preserves_value_type(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n    }\n}",
            "        _ = (rowID, title, manager, loading)\n"
            "    }\n\n"
            "    func latePresentation(from laterSession: AgentSession) {\n"
            "        let byID = [1: laterSession]\n"
            "        _ = byID[1]?.isPinned\n"
            "    }\n"
            "}",
        )

        self.assert_fails_with("domain member .isPinned outside NativeSidebarParity")

    def test_typed_domain_dictionary_preserves_value_type(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n    }\n}",
            "        _ = (rowID, title, manager, loading)\n"
            "    }\n\n"
            "    func latePresentation() {\n"
            "        let byID: [Int: AgentSession] = [:]\n"
            "        _ = byID[1]?.isPinned\n"
            "    }\n"
            "}",
        )

        self.assert_fails_with("domain member .isPinned outside NativeSidebarParity")

    def test_unrelated_local_dictionary_stays_clean(self) -> None:
        self.write(
            "Sources/Threading/Models/Unrelated.swift",
            "struct UnrelatedRow { let isPinned: Bool }\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n    }\n}",
            "        _ = (rowID, title, manager, loading)\n"
            "    }\n\n"
            "    func latePresentation(from row: UnrelatedRow) {\n"
            "        let byID = [1: row]\n"
            "        _ = byID[1]?.isPinned\n"
            "    }\n"
            "}",
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_domain_value_nested_in_tuple_cannot_escape(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n    }\n}",
            "        _ = (rowID, title, manager, loading)\n"
            "    }\n\n"
            "    func latePresentation(from laterSession: AgentSession) {\n"
            "        _ = BadgeRenderer.render((laterSession, true))\n"
            "    }\n"
            "}",
        )

        self.assert_fails_with("whole AgentSession value laterSession")

    def test_new_configure_input_must_be_classified(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "func configure(with session: AgentSession, isLoading: Bool)",
            "func configure(with session: AgentSession, isLoading: Bool, isHighlighted: Bool)",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        _ = isHighlighted\n        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with("entry input isHighlighted outside NativeSidebarParity")

    def test_classified_scalar_input_still_requires_typed_ownership(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "func configure(with session: AgentSession, isLoading: Bool)",
            "func configure(with session: AgentSession, isLoading: Bool, isHighlighted: Bool)",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        _ = NativeSidebarParity.host(.transientLoading, isHighlighted)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with(
            "entry input isHighlighted has no typed ownership inventory"
        )

    def test_stale_fact_input_alias_fails_closed(self) -> None:
        self.replace(
            "Sources/Threading/Core/Extensions/HostFactCatalog.swift",
            'case rootProjects = "SidebarTreeBuilder.rootNodes.projects"',
            'case rootProjects = "SidebarTreeBuilder.rootNodes.projectz"',
        )

        self.assert_fails_with(
            "fact source SidebarTreeBuilder.rootNodes.projectz has no audited native occurrence"
        )

    def test_unwrapped_provider_root_fails(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        _ = ControlGrantStore.shared.isManager(rowID)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with("provider root ControlGrantStore.shared")

    def test_new_store_name_is_audited_without_an_allowlist_edit(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        _ = SessionBadgeStore.shared.badge(for: rowID)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with("provider root SessionBadgeStore.shared.badge")

    def test_manager_family_shared_root_is_audited(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        _ = StateManager.shared.isPinned(rowID)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with(
            "provider root StateManager.shared.isPinned outside NativeSidebarParity"
        )

    def test_static_provider_family_root_is_audited(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        _ = SessionStateDiscovery.isPinned(rowID)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with(
            "provider root SessionStateDiscovery.isPinned outside NativeSidebarParity"
        )

    def test_unknown_provider_cannot_claim_a_host_presentation_lane(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        _ = NativeSidebarParity.host(\n"
            "            .transientLoading,\n"
            "            SessionStateProvider.shared.isPinned(rowID)\n"
            "        )\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with(
            "SessionStateProvider.shared.isPinned must publish a fact"
        )

    def test_unwrapped_shared_provider_alias_read_fails(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        let stateProvider = SessionStateProvider.shared\n"
            "        _ = stateProvider.isPinned(rowID)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with(
            "provider root SessionStateProvider.shared.isPinned outside NativeSidebarParity"
        )

    def test_typed_shared_provider_alias_read_fails(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        let stateProvider: SessionStateProvider = SessionStateProvider.shared\n"
            "        _ = stateProvider.isPinned(rowID)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with(
            "provider root SessionStateProvider.shared.isPinned outside NativeSidebarParity"
        )

    def test_typed_shorthand_shared_provider_alias_read_fails(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        let stateProvider: SessionStateProvider = .shared\n"
            "        _ = stateProvider.isPinned(rowID)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with(
            "provider root SessionStateProvider.shared.isPinned outside NativeSidebarParity"
        )

    def test_self_qualified_stored_provider_alias_read_fails(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "final class SessionRowView {\n",
            "final class SessionRowView {\n"
            "    private let stateProvider = SessionStateProvider.shared\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        _ = self.stateProvider.isPinned(rowID)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with(
            "provider root SessionStateProvider.shared.isPinned outside NativeSidebarParity"
        )

    def test_self_qualified_stored_provider_alias_cannot_escape(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "final class SessionRowView {\n",
            "final class SessionRowView {\n"
            "    private let stateProvider = SessionStateProvider.shared\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        _ = BadgeRenderer.render(self!.stateProvider)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with(
            "provider root SessionStateProvider.shared outside NativeSidebarParity"
        )

    def test_self_qualified_stored_provider_alias_propagates(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "final class SessionRowView {\n",
            "final class SessionRowView {\n"
            "    private let stateProvider = SessionStateProvider.shared\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        let provider = self?.stateProvider\n"
            "        _ = provider?.isPinned(rowID)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with(
            "provider root SessionStateProvider.shared.isPinned outside NativeSidebarParity"
        )

    def test_weak_self_stored_provider_alias_read_fails(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "final class SessionRowView {\n",
            "final class SessionRowView {\n"
            "    private let stateProvider = SessionStateProvider.shared\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        let callback = { [weak self] in\n"
            "            _ = self?.stateProvider.isPinned(rowID)\n"
            "        }\n"
            "        _ = (rowID, title, manager, loading, callback)\n",
        )

        self.assert_fails_with(
            "provider root SessionStateProvider.shared.isPinned outside NativeSidebarParity"
        )

    def test_capture_list_shared_provider_alias_read_fails(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        let callback = { [stateProvider = SessionStateProvider.shared] in\n"
            "            _ = stateProvider.isPinned(rowID)\n"
            "        }\n"
            "        _ = (rowID, title, manager, loading, callback)\n",
        )

        self.assert_fails_with(
            "provider root SessionStateProvider.shared.isPinned outside NativeSidebarParity"
        )

    def test_capture_list_propagates_a_stored_provider_alias(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "final class SessionRowView {\n",
            "final class SessionRowView {\n"
            "    private let stateProvider = SessionStateProvider.shared\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        let callback = { [provider = self.stateProvider] in\n"
            "            _ = provider.isPinned(rowID)\n"
            "        }\n"
            "        _ = (rowID, title, manager, loading, callback)\n",
        )

        self.assert_fails_with(
            "provider root SessionStateProvider.shared.isPinned outside NativeSidebarParity"
        )

    def test_direct_whole_shared_provider_cannot_escape(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        _ = BadgeRenderer.render(SessionStateProvider.shared)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with(
            "provider root SessionStateProvider.shared outside NativeSidebarParity"
        )

    def test_conditional_shared_provider_initializer_fails_closed(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        let stateProvider = true ? SessionStateProvider.shared : nil\n"
            "        _ = stateProvider?.isPinned(rowID)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with(
            "provider root SessionStateProvider.shared outside NativeSidebarParity"
        )

    def test_collection_shared_provider_initializer_fails_closed(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        let stateProviders = [SessionStateProvider.shared]\n"
            "        _ = stateProviders[0].isPinned(rowID)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with(
            "provider root SessionStateProvider.shared outside NativeSidebarParity"
        )

    def test_typed_provider_function_parameter_read_fails(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n    }\n}",
            "        _ = (rowID, title, manager, loading)\n"
            "    }\n\n"
            "    func lateState(from provider: SessionStateProvider = .shared) {\n"
            "        _ = provider.isPinned(1)\n"
            "    }\n"
            "}",
        )

        self.assert_fails_with(
            "provider root SessionStateProvider.shared.isPinned outside NativeSidebarParity"
        )

    def test_typed_provider_closure_parameter_read_fails(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        let callback = { (provider: SessionStateProvider) in\n"
            "            _ = provider.isPinned(rowID)\n"
            "        }\n"
            "        _ = (rowID, title, manager, loading, callback)\n",
        )

        self.assert_fails_with(
            "provider root SessionStateProvider.shared.isPinned outside NativeSidebarParity"
        )

    def test_constructor_injected_provider_can_use_its_owned_fact(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "final class SessionRowView {\n",
            "final class SessionRowView {\n"
            "    private let grantStore: ControlGrantStore\n\n"
            "    init(grantStore: ControlGrantStore = .shared) {\n"
            "        self.grantStore = grantStore\n"
            "    }\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "ControlGrantStore.shared.isManager(rowID)",
            "self.grantStore.isManager(rowID)",
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_constructor_injected_provider_still_requires_its_owned_fact(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "final class SessionRowView {\n",
            "final class SessionRowView {\n"
            "    private let grantStore: ControlGrantStore\n\n"
            "    init(grantStore: ControlGrantStore = .shared) {\n"
            "        self.grantStore = grantStore\n"
            "    }\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            ".sessionManagerRole,\n            ControlGrantStore.shared.isManager(rowID)",
            ".sessionManagerRelationship,\n            self.grantStore.isManager(rowID)",
        )

        self.assert_fails_with(
            "ControlGrantStore.shared.isManager must use its catalog-owned fact dependency"
        )

    def test_closure_typealias_ending_in_provider_is_not_a_provider_root(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "final class SessionRowView {\n",
            "final class SessionRowView {\n"
            "    typealias BadgeProvider = (Int) -> Int\n"
            "    private let badgeProvider: BadgeProvider = { $0 }\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        _ = badgeProvider(rowID)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_whole_shared_provider_alias_cannot_escape(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        let stateProvider = SessionStateProvider.shared\n"
            "        _ = BadgeRenderer.render(stateProvider)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        self.assert_fails_with(
            "provider root SessionStateProvider.shared outside NativeSidebarParity"
        )

    def test_owned_host_provider_remains_owned_through_a_local_alias(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        let rowID = NativeSidebarParity.host(.entityIdentity, session.id)\n",
            "        let rowID = NativeSidebarParity.host(.entityIdentity, session.id)\n"
            "        let componentProvider = ComponentCustomizationProviderSlot.shared\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "ComponentCustomizationProviderSlot.shared.customization(for: rowID)",
            "componentProvider.customization(for: rowID)",
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_provider_alias_does_not_leak_into_another_method_parameter(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        let rowID = NativeSidebarParity.host(.entityIdentity, session.id)\n",
            "        let rowID = NativeSidebarParity.host(.entityIdentity, session.id)\n"
            "        let provider = ComponentCustomizationProviderSlot.shared\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "ComponentCustomizationProviderSlot.shared.customization(for: rowID)",
            "provider.customization(for: rowID)",
        )
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n    }\n}",
            "        _ = (rowID, title, manager, loading)\n"
            "    }\n\n"
            "    func describe(provider: String) {\n"
            "        _ = provider.count\n"
            "    }\n"
            "}",
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_reassignment_stops_tracking_a_shared_provider_alias(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        var stateProvider = SessionStateProvider.shared\n"
            "        stateProvider = SessionStateProvider()\n"
            "        _ = stateProvider.isPinned(rowID)\n"
            "        _ = (rowID, title, manager, loading)\n",
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_host_provider_requires_its_exact_owned_dependency(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            ".customizationPresentation,\n"
            "            ComponentCustomizationProviderSlot.shared.customization",
            ".transientLoading,\n"
            "            ComponentCustomizationProviderSlot.shared.customization",
        )

        self.assert_fails_with(
            "ComponentCustomizationProviderSlot.shared.customization must use its "
            "host-owned dependency (.customizationPresentation)"
        )

    def test_extension_image_provider_requires_identity_presentation(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            ".identityPresentation,\n        ExtensionManager.shared.imageResourceURL()",
            ".transientLoading,\n        ExtensionManager.shared.imageResourceURL()",
        )

        self.assert_fails_with(
            "ExtensionManager.shared.imageResourceURL must use its host-owned "
            "dependency (.identityPresentation)"
        )

    def test_account_discovery_requires_identity_presentation(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            ".identityPresentation,\n        AgentAccountDiscovery.account()",
            ".transientLoading,\n        AgentAccountDiscovery.account()",
        )

        self.assert_fails_with(
            "AgentAccountDiscovery.account must use its host-owned dependency "
            "(.identityPresentation)"
        )

    def test_app_setting_cannot_use_host_lane(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            ".option(.sessionOrder, AppSettings.sidebarSessionOrder)",
            ".host(.transientLoading, AppSettings.sidebarSessionOrder)",
        )

        self.assert_fails_with("AppSettings.sidebarSessionOrder must use the option lane")

    def test_app_setting_requires_its_exact_owned_option(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            ".option(.sessionOrder, AppSettings.sidebarSessionOrder)",
            ".option(.branchGrouping, AppSettings.sidebarSessionOrder)",
        )

        self.assert_fails_with(
            "AppSettings.sidebarSessionOrder must use its owned option dependency "
            "(.sessionOrder)"
        )

    def test_project_entry_collection_requires_project_order_fact(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            ".fact(.projectManualOrder, projects)",
            ".fact(.sessionTitle, projects)",
        )

        self.assert_fails_with(
            "entry input projects must use its owned fact dependency "
            "(.projectManualOrder)"
        )

    def test_scalar_entry_input_requires_its_exact_host_dependency(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            ".host(.transientLoading, isLoading)",
            ".host(.entityIdentity, isLoading)",
        )

        self.assert_fails_with(
            "entry input isLoading must use its owned host dependency "
            "(.transientLoading)"
        )

    def test_local_git_grouping_cannot_claim_a_public_fact(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            "NativeSidebarParity.host(\n"
            "                .localRepositoryContext,\n"
            "                GitInfo.repositoryIdentity(",
            "NativeSidebarParity.fact(\n"
            "                .projectManualOrder,\n"
            "                GitInfo.repositoryIdentity(",
        )

        self.assert_fails_with(
            "GitInfo.repositoryIdentity must use its owned host dependency "
            "(.localRepositoryContext)"
        )

    def test_local_folder_path_cannot_claim_a_public_fact(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            "for: NativeSidebarParity.host(.localRepositoryContext, project.folderPath)",
            "for: NativeSidebarParity.fact(.projectManualOrder, project.folderPath)",
        )

        self.assert_fails_with(
            "domain .folderPath must use host(.localRepositoryContext)"
        )

    def test_dependency_argument_must_be_literal(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            ".fact(.sessionTitle, session.displayTitle)",
            ".fact(dependency, session.displayTitle)",
        )

        self.assert_fails_with("dependency must be a literal case")

    def test_unused_host_or_option_case_fails(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/NativeSidebarParity.swift",
            "    case transientLoading\n",
            "    case transientLoading\n    case stalePresentationEscape\n",
        )

        self.assert_fails_with(
            "host dependency .stalePresentationEscape has no protected native read"
        )

    def test_comments_strings_and_generated_sdk_cannot_affect_the_audit(self) -> None:
        self.replace(
            "Sources/Threading/UI/Views/SessionRowView.swift",
            "        _ = (rowID, title, manager, loading)\n",
            "        // session.newState NativeSidebarParity.fact(.unknown, session.newState)\n"
            "        let text = \"session.newState NativeSidebarParity.host(.unknown, x)\"\n"
            "        _ = (rowID, title, manager, loading, text)\n",
        )
        self.write(
            "docs/references/chrome/.generated/SessionRowView.swift",
            "let leaked = session.newState\n",
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unrelated_key_paths_and_shorthand_closures_do_not_fail(self) -> None:
        self.write(
            "Sources/Threading/Models/Unrelated.swift",
            "struct UnrelatedRow { let id: Int }\n",
        )
        self.replace(
            "Sources/Threading/UI/Views/SidebarOutlineNodes.swift",
            "        _ = order\n",
            "        let rows = [UnrelatedRow(id: 1)]\n"
            "        _ = rows.map(\\.id)\n"
            "        _ = rows.map { $0.id }\n"
            "        _ = order\n",
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
