import AppKit
#if os(Linux)
@testable import CoreSlice
#endif

/// The permission choice's rows and chip title on both desktop hosts. Each host resolves which
/// mode governs the next launch and which mode merely reports an earlier run.
enum PermissionModeMenuContent {
    static var defaultSuffix: String { L10n.string("  (default)") }
    static var lastUsedSuffix: String { L10n.string("  (last used)") }

    static func rowTitle(
        _ mode: AgentPermissionMode,
        for kind: AgentKind,
        governingMode: AgentPermissionMode?,
        reportedMode: AgentPermissionMode?
    ) -> String {
        let title = mode.displayName(for: kind)
        if mode == governingMode { return title + defaultSuffix }
        if mode == reportedMode { return title + lastUsedSuffix }
        return title
    }

    static func chipTitle(
        for kind: AgentKind,
        selected: AgentPermissionMode?,
        nameableMode: AgentPermissionMode?
    ) -> String {
        (selected ?? nameableMode)?.displayName(for: kind)
            ?? PermissionModeLabels.agentSettingTitle
    }

    static func rows(
        for kind: AgentKind,
        selected: AgentPermissionMode?,
        governingMode: AgentPermissionMode?,
        reportedMode: AgentPermissionMode?,
        note: String? = nil,
        onChoose: ((AgentPermissionMode?) -> Void)? = nil
    ) -> [ThemedMenuEntry] {
        var rows: [ThemedMenuEntry] = []

        // Only a setting can stand in for inherit. A reported mode must remain a pinning row.
        if governingMode == nil {
            rows.append(.item(ThemedMenuItem(
                title: PermissionModeLabels.agentSettingRowTitle,
                representedValue: nil,
                isSelected: selected == nil,
                onChoose: onChoose.map { choose in { choose(nil) } }
            )))
        }

        for mode in AgentPermissionMode.allCases {
            let isDefault = mode == governingMode
            let detail = [mode.menuDescription(for: kind), mode.caveat(for: kind)]
                .compactMap { $0 }
                .joined(separator: " ")
            rows.append(.item(ThemedMenuItem(
                title: rowTitle(mode, for: kind, governingMode: governingMode,
                    reportedMode: reportedMode),
                subtitle: detail,
                representedValue: isDefault ? nil : mode,
                isSelected: isDefault ? (selected == nil || selected == mode) : selected == mode,
                onChoose: onChoose.map { choose in { choose(isDefault ? nil : mode) } }
            )))
        }

        if let note {
            rows.append(.separator)
            rows.append(.item(ThemedMenuItem(title: note, isEnabled: false)))
        }

        return rows
    }
}
