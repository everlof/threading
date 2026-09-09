import SwiftUI
import ThreadingPluginKit

@MainActor
final class T3NavigatorTheme: ObservableObject {
    @Published private(set) var background = Color(nsColor: .windowBackgroundColor)
    @Published private(set) var surface = Color(nsColor: .controlBackgroundColor)
    @Published private(set) var text = Color(nsColor: .labelColor)
    @Published private(set) var secondaryText = Color(nsColor: .secondaryLabelColor)
    @Published private(set) var accent = Color(nsColor: .controlAccentColor)
    @Published private(set) var fontSize: CGFloat = NSFont.monospacedSystemFont(
        ofSize: NSFont.smallSystemFontSize,
        weight: .regular
    ).pointSize
    @Published private(set) var rowHeight: CGFloat = 44
    @Published private(set) var isDark = false

    func apply(_ theme: PluginTheme) {
        background = Color(nsColor: theme.background)
        surface = Color(nsColor: theme.surface)
        text = Color(nsColor: theme.text)
        secondaryText = Color(nsColor: theme.secondaryText)
        accent = Color(nsColor: theme.accent)
        fontSize = theme.monospacedFont.pointSize
        rowHeight = theme.rowHeight
        isDark = theme.isDark
    }
}

struct T3NavigatorView: View {
    @ObservedObject var store: T3NavigatorStore
    @ObservedObject var theme: T3NavigatorTheme
    @State private var collapsedSections = Set<T3NavigatorSection>()
    @State private var isProjectPickerPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            search
            Divider().overlay(theme.secondaryText.opacity(0.18))
            threadList
        }
        .background(theme.background)
        .foregroundStyle(theme.text)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .accessibilityIdentifier("t3.navigator")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Threads")
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 8)
            Button {
                isProjectPickerPresented.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(store.selectedProjectTitle)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 170, alignment: .trailing)
            .accessibilityLabel("Filter threads by project")
            .accessibilityValue(store.selectedProjectTitle)
            .accessibilityIdentifier("t3.navigator.project-picker")
            .popover(isPresented: $isProjectPickerPresented, arrowEdge: .bottom) {
                T3ProjectPickerView(
                    store: store,
                    theme: theme,
                    isPresented: $isProjectPickerPresented
                )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(theme.surface)
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.secondaryText)
            TextField("Search threads", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(theme.text)
                .accessibilityIdentifier("t3.navigator.search")
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear thread search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 29)
        .background(theme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.secondaryText.opacity(0.18), lineWidth: 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.background)
    }

    private var threadList: some View {
        let pinned = store.visibleRows(in: .pinned)
        let active = store.visibleRows(in: .active)
        let archived = store.visibleRows(in: .archived)

        return Group {
            if pinned.isEmpty && active.isEmpty && archived.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 20))
                    Text("No threads")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Try another search or project.")
                        .font(.system(size: 11))
                }
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2, pinnedViews: [.sectionHeaders]) {
                        navigatorSection(.pinned, rows: pinned)
                        navigatorSection(.active, rows: active)
                        navigatorSection(.archived, rows: archived)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func navigatorSection(
        _ section: T3NavigatorSection,
        rows: [T3NavigatorRow]
    ) -> some View {
        if !rows.isEmpty {
            Section {
                if !collapsedSections.contains(section) {
                    ForEach(rows) { row in
                        T3NavigatorRowView(row: row, store: store, theme: theme)
                    }
                }
            } header: {
                Button {
                    if collapsedSections.contains(section) {
                        collapsedSections.remove(section)
                    } else {
                        collapsedSections.insert(section)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: collapsedSections.contains(section)
                              ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                        Text(section.rawValue.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.6)
                        Text("\(rows.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(theme.secondaryText.opacity(0.8))
                        Spacer()
                    }
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .frame(height: 27)
                    .contentShape(Rectangle())
                    .background(theme.background.opacity(0.96))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("t3.navigator.section.\(section.rawValue.lowercased())")
            }
        }
    }
}

private struct T3ProjectPickerView: View {
    @ObservedObject var store: T3NavigatorStore
    @ObservedObject var theme: T3NavigatorTheme
    @Binding var isPresented: Bool
    @State private var searchText = ""
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        let projects = store.visibleProjects(matching: searchText)
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.secondaryText)
                TextField("Search projects", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchIsFocused)
                    .accessibilityLabel("Search projects")
                    .accessibilityIdentifier("t3.navigator.project-search")
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(theme.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
            .padding(8)

            Divider().overlay(theme.secondaryText.opacity(0.18))

            ScrollView {
                // Project count comes from workspace data. LazyVStack is load-bearing here: a
                // 2,000-project snapshot must not construct 2,000 button views to open a picker.
                LazyVStack(spacing: 2) {
                    projectButton(identifier: nil, title: "All projects")
                    ForEach(projects) { project in
                        projectButton(identifier: project.id, title: project.title)
                    }
                }
                .padding(6)
            }
            .frame(height: 260)
        }
        .frame(width: 300)
        .background(theme.background)
        .foregroundStyle(theme.text)
        .onAppear { searchIsFocused = true }
        .accessibilityIdentifier("t3.navigator.project-list")
    }

    private func projectButton(identifier: String?, title: String) -> some View {
        let isSelected = store.selectedProjectIdentifier == identifier
        return Button {
            store.selectProject(identifier)
            isPresented = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark" : "folder")
                    .frame(width: 14)
                Text(title).lineLimit(1)
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(
                isSelected ? theme.accent.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(
            "t3.navigator.project.\(identifier ?? "all")"
        )
    }
}

private struct T3NavigatorRowView: View {
    @ObservedObject var row: T3NavigatorRow
    @ObservedObject var store: T3NavigatorStore
    @ObservedObject var theme: T3NavigatorTheme
    @State private var isHovered = false
    @FocusState private var activationIsFocused: Bool
    @FocusState private var pinIsFocused: Bool
    @FocusState private var archiveIsFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Button {
                store.activate(row)
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    activityMark
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title.isEmpty ? "Untitled thread" : row.title)
                            .font(.system(size: 12, weight: row.isSelected ? .semibold : .medium))
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(activityLabel)
                                .foregroundStyle(activityColor)
                            metadataDivider
                            Text(store.projectTitle(for: row.projectIdentifier))
                                .lineLimit(1)
                            if let branch = row.branch, !branch.isEmpty {
                                metadataDivider
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 8))
                                Text(branch).lineLimit(1)
                            }
                        }
                        .font(.system(size: max(9, theme.fontSize - 1), design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($activationIsFocused)
            .accessibilityLabel(row.title)
            .accessibilityValue("\(activityLabel), \(store.projectTitle(for: row.projectIdentifier))")
            .accessibilityHint("Open thread")
            .accessibilityAddTraits(row.isSelected ? .isSelected : [])
            .accessibilityIdentifier("t3.navigator.row.\(row.identity.identifier)")

            rowActions
                .opacity(actionsAreEmphasized ? 1 : 0.48)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: max(46, theme.rowHeight), alignment: .leading)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
        .contextMenu {
            if !row.isArchived {
                Button(row.isPinned ? "Unpin" : "Pin") { store.togglePin(row) }
                Button("Archive") { store.archive(row) }
            }
        }
    }

    private var rowBackground: Color {
        if row.isSelected { return theme.accent.opacity(0.18) }
        if isHovered || activationIsFocused || pinIsFocused || archiveIsFocused {
            return theme.surface.opacity(0.78)
        }
        return .clear
    }

    private var actionsAreEmphasized: Bool {
        row.isSelected || isHovered || activationIsFocused || pinIsFocused || archiveIsFocused
    }

    @ViewBuilder
    private var activityMark: some View {
        if row.activity == .working {
            ProgressView()
                .controlSize(.mini)
                .tint(theme.accent)
                .scaleEffect(0.65)
        } else {
            Circle()
                .fill(activityColor)
                .frame(width: 7, height: 7)
                .overlay {
                    if row.activity == .needsAttention || row.activity == .limitReached {
                        Circle().stroke(activityColor.opacity(0.35), lineWidth: 4)
                    }
                }
        }
    }

    @ViewBuilder
    private var rowActions: some View {
        if !row.isArchived {
            Button {
                store.togglePin(row)
            } label: {
                Image(systemName: row.isPinned ? "pin.slash" : "pin")
            }
            .buttonStyle(.plain)
            .focused($pinIsFocused)
            .help(row.isPinned ? "Unpin thread" : "Pin thread")
            .accessibilityLabel(row.isPinned ? "Unpin \(row.title)" : "Pin \(row.title)")
            .accessibilityIdentifier("t3.navigator.pin.\(row.identity.identifier)")

            Button {
                store.archive(row)
            } label: {
                Image(systemName: "archivebox")
            }
            .buttonStyle(.plain)
            .focused($archiveIsFocused)
            .help("Archive thread")
            .accessibilityLabel("Archive \(row.title)")
            .accessibilityIdentifier("t3.navigator.archive.\(row.identity.identifier)")
        }
    }

    private var metadataDivider: some View {
        Text("·").foregroundStyle(theme.secondaryText.opacity(0.6))
    }

    private var activityLabel: String {
        switch row.activity {
        case .none: return "Thread"
        case .dormant: return "Dormant"
        case .idle: return "Idle"
        case .working: return "Working"
        case .readyWithBackgroundWork: return "Ready"
        case .awaitingUser: return "Waiting"
        case .needsAttention: return "Attention"
        case .limitReached: return "Limit"
        @unknown default: return "Unknown"
        }
    }

    private var activityColor: Color {
        switch row.activity {
        case .working, .readyWithBackgroundWork:
            return theme.accent
        case .awaitingUser, .needsAttention, .limitReached:
            return theme.accent.opacity(0.9)
        case .none, .dormant, .idle:
            return theme.secondaryText
        @unknown default:
            return theme.secondaryText
        }
    }
}
