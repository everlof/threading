#!/usr/bin/env python3
"""Keep Linux from rebuilding shared UI classes, values or menu row layouts.

No platform-only shared-source view leaves remain; adding one fails the build.
"""

from __future__ import annotations

import re
import sys
from hashlib import sha256
from bisect import bisect_right
from pathlib import Path

from check_ui_structure import executable_text


DECLARATION = re.compile(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*:")
EXPECTED_DUPLICATES: set[str] = set()
# These names are host service, theme or narrow fixture adapters, not second view implementations.
# A new top-level collision must be reviewed rather than silently becoming another shim.
# ThemedPopover and HostPopoverFactory bridge the shared HelpPopoverButton's panel contract to
# SDL's in-window surface; the button and explanatory content remain unchanged shared sources.
EXPECTED_TOP_LEVEL_SHIMS = {
    "AppTheme", "AppThemeDidChange", "AppThemeLibrary", "AppThemePalette",
    "BevelArtwork", "ControlRowMember", "ControlRowMetrics", "Design",
    "DesignSettings", "HostPopoverFactory", "L10n", "PermissionBroker",
    "ProfileDidChange", "RemoteConversationWirePolicy", "SidebarAppearance",
    "SoftBevelArtwork", "SurfaceBevel", "SurfaceRadius",
    "ThemedFloatingSurfaceChrome", "ThemedMenuPresenter", "ThemedPopover",
    "WindowBackdrop", "WindowChromeAppearance",
    "WindowSnapshot",
}
TOP_LEVEL_TYPE = re.compile(
    r"^(?:(?:public|private|internal|fileprivate|open|final|indirect|@MainActor)\s+)*"
    r"(?:class|struct|enum|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)\b", re.MULTILINE
)
HOST_RENDER_LEAVES = {"LinuxActivityBeamHostView", "MorphingLabel"}
PLATFORM_VIEW_LEAVES: set[str] = set()
SHARED_VALUE_SOURCES = {
    "AgentWorkloadValue.swift": "Sources/Threading/Core/Session/AgentWorkloadValue.swift",
    "ProjectIconDefaults.swift": "Sources/Threading/Core/Session/ProjectIconDefaults.swift",
    "SidebarDefaults.swift": "Sources/Threading/Core/Constants/SidebarDefaults.swift",
    "StatusIndicatorDefaults.swift": "Sources/Threading/UI/Design/StatusIndicatorDefaults.swift",
}
CORE_SLICE_SHARED_SOURCES = {
    "AgentStartupSpeed.swift": "Sources/Threading/Core/Settings/AgentStartupSpeed.swift",
    "GitTurnCheckpointID.swift": "Sources/Threading/Core/Agent/GitTurnCheckpointID.swift",
    "SessionAttachmentKind.swift": "Sources/Threading/Core/Session/SessionAttachmentKind.swift",
    "SessionAttachmentTurnSections.swift": "Sources/Threading/Core/Session/SessionAttachmentTurnSections.swift",
    "AttachmentAgentSource.swift": "Sources/Threading/Core/Session/AttachmentAgentSource.swift",
    "AttachmentReferenceDetector.swift": "Sources/Threading/Core/Session/AttachmentReferenceDetector.swift",
    "AttachmentDetection+Recording.swift": "Sources/Threading/Core/Session/AttachmentDetection+Recording.swift",
    "AttachmentMediaTypeRegistry.swift": "Sources/Threading/Core/Session/AttachmentMediaTypeRegistry.swift",
    "SessionAttachmentStore.swift": "Sources/Threading/Core/Session/SessionAttachmentStore.swift",
    "TerminalAttachmentObservers.swift": "Sources/Threading/Core/Session/TerminalAttachmentObservers.swift",
    "PersistedSessionAttachments.swift": "Sources/Threading/Models/PersistedSessionAttachments.swift",
    "MediaContentProbe.swift": "Sources/Threading/Core/Media/MediaContentProbe.swift",
    "ConfirmationPrompt.swift": "Sources/Threading/Core/Settings/ConfirmationPrompt.swift",
    "NewChatDefaults.swift": "Sources/Threading/Core/Settings/NewChatDefaults.swift",
    "NewChatOpeningMessage.swift": "Sources/Threading/Core/Agent/NewChatOpeningMessage.swift",
    "SessionPromptTitle.swift": "Sources/Threading/Core/Agent/SessionPromptTitle.swift",
    "ScratchpadDefaults.swift": "Sources/Threading/Core/Session/ScratchpadDefaults.swift",
    "ScratchpadLocation.swift": "Sources/Threading/Core/Session/ScratchpadLocation.swift",
}
SHARED_VIEW_SOURCES = {
    "AttachmentFilter.swift": "Sources/Threading/UI/Design/AttachmentFilter.swift",
    "PaneFoldDivider.swift": "Sources/Threading/UI/Design/PaneFoldDivider.swift",
    "ThemedSegmentedControl.swift": "Sources/Threading/UI/Design/ThemedSegmentedControl.swift",
    "SessionAttachmentListView.swift":
        "Sources/Threading/UI/Design/SessionAttachmentListView.swift",
    "SessionAttachmentTurnHeaderView.swift":
        "Sources/Threading/UI/Design/SessionAttachmentTurnHeaderView.swift",
    "SessionAttachmentRowView.swift":
        "Sources/Threading/UI/Design/SessionAttachmentRowView.swift",
    "SessionAttachmentsContentView.swift":
        "Sources/Threading/UI/Design/SessionAttachmentsContentView.swift",
    "SessionPlaceholderView.swift": "Sources/Threading/UI/Views/SessionPlaceholderView.swift",
    "ScheduleMomentPickerStrings.swift":
        "Sources/Threading/UI/Design/ScheduleMomentPickerStrings.swift",
    "ThemedMenuSurfaceView.swift": "Sources/Threading/UI/Design/ThemedMenuSurfaceView.swift",
    "ThemedMenuPresentationTypes.swift":
        "Sources/Threading/UI/Design/ThemedMenuPresentationTypes.swift",
    "ThemeRefreshContracts.swift": "Sources/Threading/Core/Theme/ThemeRefreshContracts.swift",
    "ThemeBoundaryContracts.swift": "Sources/Threading/UI/Design/ThemeBoundaryContracts.swift",
    "OpticalInsets.swift": "Sources/Threading/UI/Design/OpticalInsets.swift",
    "WindowBackdropDidChange.swift": "Sources/Threading/UI/Design/WindowBackdropDidChange.swift",
    "GeneralSettingsPageStructure.swift":
        "Sources/Threading/UI/Design/GeneralSettingsPageStructure.swift",
    "NewChatsSettingsStructure.swift":
        "Sources/Threading/UI/Design/NewChatsSettingsStructure.swift",
    "ChatsSettingsPageStructure.swift":
        "Sources/Threading/UI/Design/ChatsSettingsPageStructure.swift",
    "AttachmentSettingsStructure.swift":
        "Sources/Threading/UI/Design/AttachmentSettingsStructure.swift",
    "OpeningMessageSettingsStructure.swift":
        "Sources/Threading/UI/Design/OpeningMessageSettingsStructure.swift",
    "ScratchpadSettingsStructure.swift":
        "Sources/Threading/UI/Design/ScratchpadSettingsStructure.swift",
    "HelpPopoverButton.swift":
        "Sources/Threading/UI/Design/HelpPopoverButton.swift",
    "AgentStartupSpeed+Presentation.swift":
        "Sources/Threading/UI/Design/AgentStartupSpeed+Presentation.swift",
    "SidebarTerminalMenuContent.swift":
        "Sources/Threading/UI/Design/SidebarTerminalMenuContent.swift",
    "SidebarSessionMenuContent.swift":
        "Sources/Threading/UI/Design/SidebarSessionMenuContent.swift",
    "PermissionModeMenuContent.swift":
        "Sources/Threading/UI/Design/PermissionModeMenuContent.swift",
    "ConversationSpeedMenuContent.swift":
        "Sources/Threading/UI/Design/ConversationSpeedMenuContent.swift",
    "ThemedPopUp.swift": "Sources/Threading/UI/Design/ThemedPopUp.swift",
    "ProjectTerminalRowView.swift": "Sources/Threading/UI/Views/ProjectTerminalRowView.swift",
    "SessionInfoCardView.swift": "Sources/Threading/UI/Design/SessionInfoCardView.swift",
    "SessionInfoCardSurface.swift": "Sources/Threading/UI/Design/SessionInfoCardSurface.swift",
    "ThemedFloatingGlyphView.swift": "Sources/Threading/UI/Design/ThemedFloatingGlyphView.swift",
    "HoverPopoverScheduler.swift": "Sources/Threading/UI/Design/HoverPopoverScheduler.swift",
}
SHARED_TERMINAL_MENU_HOSTS = (
    "Sources/Threading/UI/Views/ProjectSidebarViewController.swift",
    "Platforms/Linux/Sources/WindowHarness/SidebarTerminalMenu.swift",
)
SHARED_SESSION_MENU_HOSTS = (
    "Sources/Threading/UI/Views/ProjectSidebarSessionActions.swift",
    "Platforms/Linux/Sources/WindowHarness/SidebarSessionMenu.swift",
)
SHARED_PERMISSION_MENU_HOSTS = (
    "Sources/Threading/UI/Views/ProjectSidebarSessionActions.swift",
    "Platforms/Linux/Sources/WindowHarness/WindowHarness.swift",
    "Platforms/Linux/Sources/WindowHarness/NativeWorkspaceSession.swift",
)
SHARED_SPEED_MENU_ROW_HOSTS = (
    "Sources/Threading/UI/Views/ProjectSidebarSessionActions.swift",
    "Platforms/Linux/Sources/WindowHarness/WorkspacePlaceholderPane.swift",
    "Platforms/Linux/Sources/WindowHarness/WorkspaceConversationPane.swift",
)
SHARED_SPEED_MENU_CHIP_HOSTS = (
    "Sources/Threading/UI/Views/ProjectSidebarSessionActions.swift",
    "Platforms/Linux/Sources/WindowHarness/WindowHarness.swift",
    "Platforms/Linux/Sources/WindowHarness/NativeWorkspaceSession.swift",
)
SHARED_NEW_CHATS_SETTINGS_HOSTS = (
    "Sources/Threading/UI/Preferences/ChatsPreferencesViewController.swift",
    "Platforms/Linux/Sources/WindowHarness/WorkspaceSettingsPane.swift",
)
DESIGN_KIT_SIDEBAR_LINK = (
    "Packages/ThreadingDesignKit/Sources/ThreadingDesignKit/Shared/SidebarDefaults.swift"
)
DESIGN_KIT_MENU_LINK = (
    "Packages/ThreadingDesignKit/Sources/ThreadingDesignKit/Shared/ThemedMenuSurfaceView.swift"
)
DESIGN_KIT_MENU_TYPES_LINK = (
    "Packages/ThreadingDesignKit/Sources/ThreadingDesignKit/Shared/ThemedMenuPresentationTypes.swift"
)
DESIGN_KIT_THEME_CONTRACT_LINK = (
    "Packages/ThreadingDesignKit/Sources/ThreadingDesignKit/Shared/ThemeRefreshContracts.swift"
)
DESIGN_KIT_THEME_BOUNDARY_LINK = (
    "Packages/ThreadingDesignKit/Sources/ThreadingDesignKit/Shared/ThemeBoundaryContracts.swift"
)
DESIGN_KIT_BACKDROP_EVENT_LINK = (
    "Packages/ThreadingDesignKit/Sources/ThreadingDesignKit/Shared/WindowBackdropDidChange.swift"
)
MENU_TYPE_FIXTURE_LINKS = tuple(
    f"Platforms/Linux/tests/{fixture}/ThemedMenuPresentationTypes.swift"
    for fixture in ("icon_button", "subagent_row", "pane_header", "page_title")
)
THEME_CONTRACT_FIXTURE_LINKS = tuple(
    f"Platforms/Linux/tests/{fixture}/ThemeRefreshContracts.swift"
    for fixture in ("icon_button", "subagent_row", "pane_header", "page_title")
)
THEME_BOUNDARY_FIXTURE_LINKS = tuple(
    f"Platforms/Linux/tests/{fixture}/ThemeBoundaryContracts.swift"
    for fixture in ("icon_button", "subagent_row", "pane_header", "page_title")
)
OPTICAL_FIXTURE_LINKS = tuple(
    f"Platforms/Linux/tests/{fixture}/OpticalInsets.swift"
    for fixture in ("icon_button", "subagent_row", "pane_header", "page_title")
)
NAVIGATOR_FIXTURE_LINKS = tuple(
    (f"Platforms/Linux/tests/sidebar_visible_rows/{name}.swift",
     f"Platforms/Linux/Sources/WindowHarness/{name}.swift")
    for name in ("CheckoutBranchDisplay", "NavigatorOutline", "SidebarVisibleRows")
)
CLASS_BASE = re.compile(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([A-Za-z_][A-Za-z0-9_]*)")
VIEW_BASES = {
    "NSView", "NSStackView", "NSScrollView", "NSClipView", "NSTableView",
    "NSTableRowView", "NSTableCellView", "NSOutlineView", "NSControl", "NSButton",
    "NSTextField", "NSTextView", "NSImageView", "ThemedControl", "ThemedScrollView",
}
MENU_ROW_FRAME = re.compile(r"\b(?:row|separator)\.frame\s*=")
MENU_PLACEMENT_FRAME = re.compile(
    r"\b(?:configurationMenu|speedMenu|choiceSurface|sessionMenuFrame|"
    r"actionMenuFrame|accountMenuFrame)(?:\.frame)?\s*=\s*NSRect\s*\("
)
MENU_HOST_FILES = (
    "WorkspaceConversationPane.swift",
    "WorkspacePlaceholderPane.swift",
    "WorkspacePaneChrome.swift",
    "WindowHarness.swift",
)
HOST_MENU_PANEL = re.compile(r"\bThemedMenuPanelView\s*\(")
HOST_MENU_DOCUMENT = re.compile(r"\bThemedMenuDocumentView\s*\(")
HOST_TERMINAL_ASSEMBLY = re.compile(r"\bSidebarTerminalRowAssembly\s*\(")
# The model/effort grid is a distinct production view hosted in a shared panel, not a row menu.
EXPECTED_HOST_MENU_PANELS = {"WorkspacePlaceholderPane.swift": 1}
STATIC_VALUE = re.compile(r"\bstatic\s+(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\b")
DESIGN_EXTENSION = re.compile(r"\bextension\s+Design\.([A-Za-z_][A-Za-z0-9_]*)\s*\{")
DESIGN_ROOT_ENUM = re.compile(r"\b(?:public\s+)?enum\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{")
DESIGN_ROOT_SHIM_FILES = {
    "GlyphThemeBoundary.swift", "MenuThemeBoundary.swift", "DiffThemeBoundary.swift",
}
SHARED_MODEL_SOURCES = {
    "ChatNameMorphStyle":
        "Packages/ThreadingDomain/Sources/ThreadingDomain/ChatNameMorphStyle.swift",
    "ControlPermissionDecision":
        "Sources/Threading/Core/Control/ControlPermissionDecision.swift",
}
MORPH_STYLE_ALIASES = {
    "Sources/Threading/Core/Settings/MotionPreferences.swift":
        "public typealias ChatNameMorphStyle = ThreadingDomain.ChatNameMorphStyle",
    "Packages/ThreadingDesignKit/Sources/ThreadingDesignKit/Seam/HostSeam.swift":
        "public typealias ChatNameMorphStyle = ThreadingDomain.ChatNameMorphStyle",
    "Platforms/Linux/Sources/WindowHarness/LinuxMorphingLabel.swift":
        "public typealias ChatNameMorphStyle = CoreSlice.ChatNameMorphStyle",
}


def block_body(source: str, opening_brace: int) -> str:
    """Return a declaration body without relying on line layout in Swift extensions."""
    depth = 1
    for index in range(opening_brace + 1, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening_brace + 1:index]
    raise ValueError("unclosed Swift declaration")


def duplicate_design_shim_values(directory: Path) -> list[tuple[str, str, Path, Path]]:
    """A boundary may extend a Design token, but must not redefine an existing token."""
    owners: dict[tuple[str, str], Path] = {}
    duplicates = []
    for path in sorted(directory.glob("*Boundary.swift")):
        source = executable_text(path.read_text(encoding="utf-8"))
        declarations = list(DESIGN_EXTENSION.finditer(source))
        if path.name in DESIGN_ROOT_SHIM_FILES:
            declarations.extend(DESIGN_ROOT_ENUM.finditer(source))
        for match in declarations:
            type_name = match.group(1)
            if type_name == "Design":
                continue
            body = block_body(source, match.end() - 1)
            for value in STATIC_VALUE.finditer(body):
                key = (type_name, value.group(1))
                if previous := owners.get(key):
                    duplicates.append((*key, previous, path))
                else:
                    owners[key] = path
    return duplicates


def classes(in_directory: Path, *, skip_links: bool = False, recursive: bool = False) -> dict[str, Path]:
    result = {}
    paths = in_directory.rglob("*.swift") if recursive else in_directory.glob("*.swift")
    for path in sorted(paths):
        if skip_links and path.is_symlink():
            continue
        for name in DECLARATION.findall(executable_text(path.read_text(encoding="utf-8"))):
            result[name] = path
    return result


def top_level_types(in_directory: Path, *, skip_links: bool = False) -> dict[str, Path]:
    result = {}
    for path in sorted(in_directory.rglob("*.swift")):
        if skip_links and path.is_symlink():
            continue
        for name in TOP_LEVEL_TYPE.findall(executable_text(path.read_text(encoding="utf-8"))):
            result[name] = path
    return result


def linux_only_view_classes(in_directory: Path) -> dict[str, Path]:
    """Find view types declared in Linux branches of otherwise shared UI sources."""
    result = {}
    for path in sorted(in_directory.rglob("*.swift")):
        source = path.read_text(encoding="utf-8")
        if "os(Linux)" not in source:
            continue
        code = executable_text(source)
        branches: list[bool | None] = []
        linux_lines = []
        line_starts = []
        offset = 0
        for line in code.splitlines(keepends=True):
            line_starts.append(offset)
            offset += len(line)
            directive = line.strip()
            if directive.startswith("#if ") or directive.startswith("#elseif "):
                expression = directive.split(maxsplit=1)[1].replace(" ", "")
                linux_branch = expression == "os(Linux)"
                mac_branch = expression == "!os(Linux)"
                branch = linux_branch if linux_branch or mac_branch else None
                if directive.startswith("#if "):
                    branches.append(branch)
                elif branches:
                    branches[-1] = branch
            elif directive == "#else" and branches:
                if branches[-1] is not None:
                    branches[-1] = not branches[-1]
            elif directive == "#endif" and branches:
                branches.pop()
            linux_lines.append(True in branches)
        for match in CLASS_BASE.finditer(code):
            line_index = bisect_right(line_starts, match.start()) - 1
            if linux_lines[line_index] and match.group(2) in VIEW_BASES:
                result[match.group(1)] = path
    return result


def copied_production_sources(root: Path) -> list[tuple[Path, Path]]:
    """Find Linux Swift files that repeat an exact production body instead of linking it."""
    production_by_digest = {
        sha256(path.read_bytes()).digest(): path
        for path in (root / "Sources/Threading").rglob("*.swift")
    }
    copies = []
    for path in (root / "Platforms/Linux/Sources").rglob("*.swift"):
        if path.is_symlink():
            continue
        if original := production_by_digest.get(sha256(path.read_bytes()).digest()):
            copies.append((path, original))
    return copies


def shared_model_violations(root: Path) -> list[str]:
    """Value types extracted from host seams retain exactly one production declaration."""
    violations = []
    for relative, alias in MORPH_STYLE_ALIASES.items():
        path = root / relative
        if alias not in executable_text(path.read_text()):
            violations.append(f"{path} must alias the canonical ChatNameMorphStyle")
    directories = ("Sources/Threading", "Packages/ThreadingDesignKit/Sources",
                   "Platforms/Linux/Sources")
    for name, relative in SHARED_MODEL_SOURCES.items():
        definition = (root / relative).resolve()
        declaration = re.compile(rf"\benum\s+{name}\s*:")
        if not declaration.search(executable_text(definition.read_text())):
            violations.append(f"{definition} must define {name}")
        for directory in directories:
            for path in (root / directory).rglob("*.swift"):
                if path.is_symlink() or path.resolve() == definition:
                    continue
                if declaration.search(executable_text(path.read_text())):
                    violations.append(f"{path} redeclares {name}")
    return violations


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    mac = classes(root / "Sources/Threading/UI", recursive=True)
    linux_directory = root / "Platforms/Linux/Sources/WindowHarness"
    linux = classes(linux_directory, skip_links=True)
    invalid_shared_values = []
    for name, production in (SHARED_VALUE_SOURCES | SHARED_VIEW_SOURCES).items():
        link = linux_directory / name
        if not link.is_symlink() or link.resolve() != (root / production).resolve():
            invalid_shared_values.append(name)
            print(f"linux-shared-views: {link} must link the production {production}",
                  file=sys.stderr)
    for name, production in CORE_SLICE_SHARED_SOURCES.items():
        link = root / "Platforms/Linux/Sources/CoreSlice" / name
        if not link.is_symlink() or link.resolve() != (root / production).resolve():
            invalid_shared_values.append(name)
            print(f"linux-shared-views: {link} must link the production {production}",
                  file=sys.stderr)
    design_kit_sidebar = root / DESIGN_KIT_SIDEBAR_LINK
    production_sidebar = (root / SHARED_VALUE_SOURCES["SidebarDefaults.swift"]).resolve()
    if not design_kit_sidebar.is_symlink() or design_kit_sidebar.resolve() != production_sidebar:
        invalid_shared_values.append(DESIGN_KIT_SIDEBAR_LINK)
        print(f"linux-shared-views: {design_kit_sidebar} must link the production SidebarDefaults",
              file=sys.stderr)
    design_kit_menu = root / DESIGN_KIT_MENU_LINK
    production_menu = (root / SHARED_VIEW_SOURCES["ThemedMenuSurfaceView.swift"]).resolve()
    if not design_kit_menu.is_symlink() or design_kit_menu.resolve() != production_menu:
        invalid_shared_values.append(DESIGN_KIT_MENU_LINK)
        print(f"linux-shared-views: {design_kit_menu} must link the production menu surface",
              file=sys.stderr)
    design_kit_menu_types = root / DESIGN_KIT_MENU_TYPES_LINK
    production_menu_types = (
        root / SHARED_VIEW_SOURCES["ThemedMenuPresentationTypes.swift"]
    ).resolve()
    if (not design_kit_menu_types.is_symlink()
            or design_kit_menu_types.resolve() != production_menu_types):
        invalid_shared_values.append(DESIGN_KIT_MENU_TYPES_LINK)
        print(f"linux-shared-views: {design_kit_menu_types} must link the production menu types",
              file=sys.stderr)
    design_kit_theme_contract = root / DESIGN_KIT_THEME_CONTRACT_LINK
    production_theme_contract = (
        root / SHARED_VIEW_SOURCES["ThemeRefreshContracts.swift"]
    ).resolve()
    production_theme_boundary = (
        root / SHARED_VIEW_SOURCES["ThemeBoundaryContracts.swift"]
    ).resolve()
    production_optical = (root / SHARED_VIEW_SOURCES["OpticalInsets.swift"]).resolve()
    if (not design_kit_theme_contract.is_symlink()
            or design_kit_theme_contract.resolve() != production_theme_contract):
        invalid_shared_values.append(DESIGN_KIT_THEME_CONTRACT_LINK)
        print(f"linux-shared-views: {design_kit_theme_contract} must link the theme contract",
              file=sys.stderr)
    design_kit_theme_boundary = root / DESIGN_KIT_THEME_BOUNDARY_LINK
    if (not design_kit_theme_boundary.is_symlink()
            or design_kit_theme_boundary.resolve() != production_theme_boundary):
        invalid_shared_values.append(DESIGN_KIT_THEME_BOUNDARY_LINK)
        print(f"linux-shared-views: {design_kit_theme_boundary} must link the theme boundary",
              file=sys.stderr)
    design_kit_backdrop_event = root / DESIGN_KIT_BACKDROP_EVENT_LINK
    production_backdrop_event = (
        root / SHARED_VIEW_SOURCES["WindowBackdropDidChange.swift"]
    ).resolve()
    if (not design_kit_backdrop_event.is_symlink()
            or design_kit_backdrop_event.resolve() != production_backdrop_event):
        invalid_shared_values.append(DESIGN_KIT_BACKDROP_EVENT_LINK)
        print(f"linux-shared-views: {design_kit_backdrop_event} must link the backdrop event",
              file=sys.stderr)
    invalid_fixture_links = []
    for relative, production in (
        *((path, production_menu_types) for path in MENU_TYPE_FIXTURE_LINKS),
        *((path, production_theme_contract) for path in THEME_CONTRACT_FIXTURE_LINKS),
        *((path, production_theme_boundary) for path in THEME_BOUNDARY_FIXTURE_LINKS),
        *((path, production_optical) for path in OPTICAL_FIXTURE_LINKS),
        *((path, (root / production).resolve()) for path, production in NAVIGATOR_FIXTURE_LINKS),
    ):
        link = root / relative
        if not link.is_symlink() or link.resolve() != production:
            invalid_fixture_links.append(relative)
            print(f"linux-shared-views: {link} must link its production contract",
                  file=sys.stderr)
    duplicates = mac.keys() & linux.keys()
    added = duplicates - EXPECTED_DUPLICATES
    removed = EXPECTED_DUPLICATES - duplicates
    for name in sorted(added):
        print(f"linux-shared-views: {name} duplicates {mac[name]} in {linux[name]}", file=sys.stderr)
    for name in sorted(removed):
        print(f"linux-shared-views: {name} is shared; remove it from the debt list", file=sys.stderr)
    mac_types = top_level_types(root / "Sources/Threading")
    linux_types = top_level_types(linux_directory, skip_links=True)
    top_level_collisions = mac_types.keys() & linux_types.keys()
    new_type_collisions = top_level_collisions - EXPECTED_TOP_LEVEL_SHIMS
    removed_shims = EXPECTED_TOP_LEVEL_SHIMS - top_level_collisions
    for name in sorted(new_type_collisions):
        print(f"linux-shared-views: {name} redeclared in {mac_types[name]} and "
              f"{linux_types[name]}; share its contract or justify a host shim", file=sys.stderr)
    for name in sorted(removed_shims):
        print(f"linux-shared-views: {name} no longer needs a host shim allowance", file=sys.stderr)
    host_views = {
        name
        for path in linux_directory.glob("*.swift") if not path.is_symlink()
        for name, base in CLASS_BASE.findall(executable_text(path.read_text(encoding="utf-8")))
        if base in VIEW_BASES
    }
    for name in sorted(host_views - HOST_RENDER_LEAVES):
        print(f"linux-shared-views: new Linux view {name} needs a shared UI review", file=sys.stderr)
    for name in sorted(HOST_RENDER_LEAVES - host_views):
        print(f"linux-shared-views: {name} was removed; update the host leaf list", file=sys.stderr)
    platform_views = linux_only_view_classes(root / "Sources/Threading/UI")
    new_platform_views = platform_views.keys() - PLATFORM_VIEW_LEAVES
    removed_platform_views = PLATFORM_VIEW_LEAVES - platform_views.keys()
    for name in sorted(new_platform_views):
        print(f"linux-shared-views: new Linux-only view {name} in {platform_views[name]}; "
              "extend the AppKit shim or review it as a platform leaf", file=sys.stderr)
    for name in sorted(removed_platform_views):
        print(f"linux-shared-views: {name} is shared; remove it from the leaf list", file=sys.stderr)
    shared_view_subclasses = []
    for path in linux_directory.glob("*.swift"):
        if path.is_symlink():
            continue
        for name, base in CLASS_BASE.findall(executable_text(path.read_text(encoding="utf-8"))):
            if base in mac and base.endswith("View"):
                shared_view_subclasses.append((name, base, path))
                print(f"linux-shared-views: {name} subclasses shared {base} in {path}; "
                      "mount the shared view directly", file=sys.stderr)
    frame_assignments = []
    for name in MENU_HOST_FILES:
        path = linux_directory / name
        source = executable_text(path.read_text(encoding="utf-8"))
        for match in MENU_ROW_FRAME.finditer(source):
            line = source.count("\n", 0, match.start()) + 1
            frame_assignments.append((path, line))
            print(f"linux-shared-views: menu row frame in {path}:{line}; use the shared document",
                  file=sys.stderr)
        for match in MENU_PLACEMENT_FRAME.finditer(source):
            line = source.count("\n", 0, match.start()) + 1
            frame_assignments.append((path, line))
            print(f"linux-shared-views: menu panel frame in {path}:{line}; "
                  "use ThemedMenuLayout", file=sys.stderr)
    host_menu_surfaces = []
    host_menu_documents = []
    host_terminal_assemblies = []
    for path in sorted((root / "Platforms/Linux/Sources").rglob("*.swift")):
        if path.is_symlink():
            continue
        source = executable_text(path.read_text(encoding="utf-8"))
        panels = len(HOST_MENU_PANEL.findall(source))
        expected = EXPECTED_HOST_MENU_PANELS.get(path.name, 0)
        if panels != expected:
            host_menu_surfaces.append(path)
            print(f"linux-shared-views: {path} constructs {panels} host menu panels; "
                  f"expected {expected}. Mount ThemedMenuSurfaceView for row menus",
                  file=sys.stderr)
        if HOST_MENU_DOCUMENT.search(source):
            host_menu_documents.append(path)
            print(f"linux-shared-views: {path} constructs a menu document; "
                  "the shared menu surface owns it", file=sys.stderr)
        if HOST_TERMINAL_ASSEMBLY.search(source):
            host_terminal_assemblies.append(path)
            print(f"linux-shared-views: {path} builds terminal row contents; "
                  "mount ProjectTerminalRowView instead", file=sys.stderr)
    duplicate_shim_values = duplicate_design_shim_values(linux_directory)
    for type_name, value, first, second in duplicate_shim_values:
        print(f"linux-shared-views: Design.{type_name}.{value} is declared in "
              f"both {first} and {second}", file=sys.stderr)
    copied_sources = copied_production_sources(root)
    for copy, original in copied_sources:
        print(f"linux-shared-views: {copy} copies {original}; link the production source",
              file=sys.stderr)
    model_violations = shared_model_violations(root)
    for violation in model_violations:
        print(f"linux-shared-views: {violation}", file=sys.stderr)
    terminal_menu_hosts = []
    for relative in SHARED_TERMINAL_MENU_HOSTS:
        source = executable_text((root / relative).read_text(encoding="utf-8"))
        if "SidebarTerminalMenuContent.entries(" not in source:
            terminal_menu_hosts.append(relative)
            print(f"linux-shared-views: {relative} must build its terminal actions with "
                  "SidebarTerminalMenuContent", file=sys.stderr)
    session_menu_hosts = []
    for relative in SHARED_SESSION_MENU_HOSTS:
        source = executable_text((root / relative).read_text(encoding="utf-8"))
        if ("SidebarSessionMenuContent.entries(" not in source
                or "SidebarSessionMenuContent.snoozeEntries(" not in source
                or any(label in source for label in (
                    '"In an hour"', '"Tomorrow at ', '"Monday at ',
                    '"Custom time…"', '"snoozeChoice:'
                ))):
            session_menu_hosts.append(relative)
            print(f"linux-shared-views: {relative} must build its session actions and "
                  "Snooze choices with SidebarSessionMenuContent", file=sys.stderr)
    permission_menu_hosts = []
    for relative in SHARED_PERMISSION_MENU_HOSTS:
        source = executable_text((root / relative).read_text(encoding="utf-8"))
        if ("PermissionModeMenuContent.rows(" not in source
                or "PermissionModeMenuContent.chipTitle(" not in source
                or "AgentPermissionMode.allCases" in source
                or '"  (default)"' in source
                or '"  (last used)"' in source):
            permission_menu_hosts.append(relative)
            print(f"linux-shared-views: {relative} must use PermissionModeMenuContent "
                  "for permission rows and chip titles", file=sys.stderr)
    speed_menu_hosts = []
    for relative in SHARED_SPEED_MENU_ROW_HOSTS:
        source = executable_text((root / relative).read_text(encoding="utf-8"))
        if ("ConversationSpeedMenuContent.rows(" not in source
                or '"Normal speed and usage"' in source
                or '"1.5× speed, increased usage"' in source):
            speed_menu_hosts.append(relative)
            print(f"linux-shared-views: {relative} must build speed rows with "
                  "ConversationSpeedMenuContent", file=sys.stderr)
    for relative in SHARED_SPEED_MENU_CHIP_HOSTS:
        source = executable_text((root / relative).read_text(encoding="utf-8"))
        if "ConversationSpeedMenuContent.chip(" not in source:
            speed_menu_hosts.append(relative)
            print(f"linux-shared-views: {relative} must get its speed chip from "
                  "ConversationSpeedMenuContent", file=sys.stderr)
    speed_accessibility = executable_text((root /
        "Platforms/Linux/Sources/LinuxWindowBridge/Accessibility.c").read_text(encoding="utf-8"))
    reply_source = executable_text((root /
        "Platforms/Linux/Sources/WindowHarness/WorkspaceConversationPane.swift").read_text(encoding="utf-8"))
    if (any(label in speed_accessibility for label in (
            '"Follow Agent Setting"', '"Follow General Setting"',
            '"Normal speed and usage"', '"1.5x speed, increased usage"'))
            or "tw_accessibility_conversation_speed_row(window" not in reply_source):
        speed_menu_hosts.append("Linux conversation Speed accessibility")
        print("linux-shared-views: Linux Speed accessibility must publish labels from "
              "the mounted shared menu", file=sys.stderr)
    chats_settings_violations = []
    for relative in SHARED_NEW_CHATS_SETTINGS_HOSTS:
        source = executable_text((root / relative).read_text(encoding="utf-8"))
        if ("NewChatsSettingsStructure.rows(" not in source
                or "ChatsSettingsPageStructure.sections(" not in source
                or "NewChatsSettingsStructure.permissionChoices(for:" not in source
                or "OpeningMessageSettingsStructure.rows(" not in source
                or "ScratchpadSettingsStructure.row(" not in source):
            chats_settings_violations.append(relative)
            print(f"linux-shared-views: {relative} must build Chats sections, New Chats, "
                  "Opening Message and Scratchpad from their shared structures", file=sys.stderr)
        if ("WorkspaceSettingsPane.swift" in relative
                and "SettingsPageStructure.section(" in source.split(
                    "private func buildChatsPage()", 1)[-1].split(
                        "func updateScratchpadFolder()", 1)[0]):
            chats_settings_violations.append(relative)
            print(f"linux-shared-views: {relative} must not assemble Chats sections locally",
                  file=sys.stderr)
        if ("ChatsPreferencesViewController.swift" in relative
                and "SettingsUI.section(" in source.split(
                    "private func setupLayout()", 1)[-1].split(
                        "private func newChatsCard()", 1)[0]):
            chats_settings_violations.append(relative)
            print(f"linux-shared-views: {relative} must not assemble Chats sections locally",
                  file=sys.stderr)
        if ("AttachmentSettingsStructure.card(" not in source
                or "Detect attachments from \\(kind.displayName)" in source
                or "Lists paths from anywhere, copying each one in." in source
                or ("WorkspaceSettingsPane.swift" in relative
                    and "attachments: nil" in source)):
            chats_settings_violations.append(relative)
            print(f"linux-shared-views: {relative} must build Attachments rows from the "
                  "shared structure", file=sys.stderr)
    for relative, required in (
        ("Sources/Threading/Core/Settings/AppSettingDefinitions.swift",
         ("NewChatDefaults.agentPersistenceKey", "NewChatDefaults.permissionPersistenceKey",
          "NewChatDefaults.openingPrefixPersistenceKey",
          "NewChatDefaults.openingSuffixPersistenceKey")),
        ("Platforms/Linux/Sources/WindowHarness/LinuxGeneralSettings.swift",
         ("NewChatDefaults.agentPersistenceKey", "NewChatDefaults.permissionPersistenceKey",
          "NewChatDefaults.permissionMode(", "NewChatOpeningMessage.compose(")),
        ("Platforms/Linux/Sources/WindowHarness/WindowHarness.swift",
         ("LinuxGeneralSettings.defaultAgentKind", "LinuxGeneralSettings.defaultPermissionMode",
          "LinuxGeneralSettings.openingMessage(for:", "SessionPromptTitle.from(")),
        ("Sources/Threading/Core/Agent/SessionNaming.swift",
         ("SessionPromptTitle.from(prompt)",)),
    ):
        source = executable_text((root / relative).read_text(encoding="utf-8"))
        if not all(token in source for token in required):
            chats_settings_violations.append(relative)
            print(f"linux-shared-views: {relative} must use shared New Chats defaults",
                  file=sys.stderr)
    snooze_presentation_violations = []
    for relative in (
        "Sources/Threading/Core/Session/ScheduledTimePresets.swift",
        "Sources/Threading/UI/Design/SidebarSessionMenuContent.swift",
    ):
        source = executable_text((root / relative).read_text(encoding="utf-8"))
        if "SnoozeWallClockMoments.presentations(for:" not in source:
            snooze_presentation_violations.append(relative)
            print(f"linux-shared-views: {relative} must use the shared wall-clock Snooze "
                  "presentation", file=sys.stderr)
    shared_copy_violations = []
    dormant_copy = (
        "The conversation is saved and will pick up where it left off.",
        "No saved conversation was found, so this will start fresh.",
        "Starting again opens a new shell.",
    )
    close_copy = (
        "The agent will stop. The session stays in the sidebar and can be resumed.",
        "The shell will stop. The session stays in the sidebar.",
    )
    for relative, owner, copied_literals in (
        ("Sources/Threading/UI/Views/TerminalContainerViewController.swift",
         "DormantSessionPlaceholderContent.agent(", dormant_copy),
        ("Platforms/Linux/Sources/WindowHarness/WorkspaceDormantPane.swift",
         "DormantSessionPlaceholderContent.agent(", dormant_copy),
        ("Sources/Threading/UI/Windows/SessionCoordinator.swift",
         "CloseRunningSessionConfirmationCopy.", close_copy),
        ("Platforms/Linux/Sources/WindowHarness/WindowHarness.swift",
         "CloseRunningSessionConfirmationCopy.", close_copy),
        ("Sources/Threading/UI/Views/ProjectSidebarSessionActions.swift",
         "ScheduleMomentPickerStrings.sessionSnoozeDetail",
         ("The session keeps running while snoozed.",)),
        ("Platforms/Linux/Sources/WindowHarness/LinuxScheduleMomentPicker.swift",
         "ScheduleMomentPickerStrings.sessionSnoozeDetail",
         ("The session keeps running while snoozed.",)),
    ):
        source = executable_text((root / relative).read_text(encoding="utf-8"))
        if owner not in source or any(copy in source for copy in copied_literals):
            shared_copy_violations.append(relative)
            print(f"linux-shared-views: {relative} must use shared session copy",
                  file=sys.stderr)
    pane_header_menu_violations = []
    pane_header = executable_text((root / "Platforms/Linux/Sources/WindowHarness/WorkspacePaneChrome.swift")
                                  .read_text(encoding="utf-8"))
    window_host = executable_text((root / "Platforms/Linux/Sources/WindowHarness/WindowHarness.swift")
                                  .read_text(encoding="utf-8"))
    if "SessionMenuCommand" in pane_header or "Copy Session ID" in pane_header:
        pane_header_menu_violations.append("WorkspacePaneChrome rebuilds session actions")
    if "fromPaneHeader: true" not in window_host:
        pane_header_menu_violations.append("WindowHarness does not route pane Actions to the shared session menu")
    for violation in pane_header_menu_violations:
        print(f"linux-shared-views: {violation}", file=sys.stderr)
    attachment_list_violations = []
    for relative, mount in (
        ("Sources/Threading/UI/Views/SessionAttachmentsViewController.swift",
         "scrollView = SessionAttachmentListView("),
        ("Platforms/Linux/Sources/WindowHarness/AttachmentShellFixture.swift",
         "list = SessionAttachmentListView("),
    ):
        source = executable_text((root / relative).read_text(encoding="utf-8"))
        if mount not in source:
            attachment_list_violations.append(relative)
            print(f"linux-shared-views: {relative} must mount the shared attachment list",
                  file=sys.stderr)
    print(f"linux-shared-views: {len(duplicates)} named duplicate classes, "
          f"{len(platform_views)} Linux-only shared-source view leaves remain, "
          f"{len(SHARED_VALUE_SOURCES) + len(SHARED_VIEW_SOURCES) + len(CORE_SLICE_SHARED_SOURCES) + 6 - len(invalid_shared_values)} "
          "shared source links valid, "
          f"{len(MENU_TYPE_FIXTURE_LINKS) + len(THEME_CONTRACT_FIXTURE_LINKS) + len(THEME_BOUNDARY_FIXTURE_LINKS) + len(OPTICAL_FIXTURE_LINKS) + len(NAVIGATOR_FIXTURE_LINKS) - len(invalid_fixture_links)} fixture contract links valid, "
          f"{len(duplicate_shim_values)} duplicate Design shim values, "
          f"{len(host_menu_surfaces) + len(host_menu_documents)} host menu construction violations, "
          f"{len(host_terminal_assemblies)} terminal row construction violations, "
          f"{len(copied_sources)} copied production sources, "
          f"{len(model_violations)} duplicate shared-model violations, "
          f"{len(terminal_menu_hosts)} terminal menu composition violations, "
          f"{len(session_menu_hosts)} session menu composition violations, "
          f"{len(permission_menu_hosts)} permission menu composition violations, "
          f"{len(chats_settings_violations)} Chats Settings composition violations, "
          f"{len(speed_menu_hosts)} speed menu composition violations, "
          f"{len(snooze_presentation_violations)} Snooze presentation violations, "
          f"{len(shared_copy_violations)} session copy violations, "
          f"{len(pane_header_menu_violations)} pane-header session menu violations, "
          f"{len(attachment_list_violations)} attachment list mount violations, "
          f"{len(top_level_collisions)} reviewed host type shims")
    return 1 if (added or removed or host_views != HOST_RENDER_LEAVES
                 or new_type_collisions or removed_shims
                 or new_platform_views or removed_platform_views
                 or shared_view_subclasses or frame_assignments
                 or invalid_shared_values or invalid_fixture_links or duplicate_shim_values
                 or host_menu_surfaces or host_menu_documents
                 or host_terminal_assemblies or copied_sources or model_violations
                 or terminal_menu_hosts or session_menu_hosts or permission_menu_hosts
                 or speed_menu_hosts or chats_settings_violations
                 or snooze_presentation_violations
                 or shared_copy_violations
                 or pane_header_menu_violations or attachment_list_violations) else 0


if __name__ == "__main__":
    raise SystemExit(main())
