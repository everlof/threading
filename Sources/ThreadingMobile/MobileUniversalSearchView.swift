import Foundation
import SwiftUI
import ThreadingRemoteKit

enum MobileUniversalSearchScope: Hashable {
    case everywhere
    case project(id: String, name: String)
    case session(id: String, projectID: String?, projectName: String)

    var title: String {
        switch self {
        case .everywhere: return MobileL10n.string("Everywhere")
        case .project: return MobileL10n.string("Project")
        case .session: return MobileL10n.string("View")
        }
    }

    func request(query: String, generation: UInt64) -> RemoteSearchRequestDTO {
        switch self {
        case .everywhere:
            return RemoteSearchRequestDTO(
                query: query,
                scope: .everywhere,
                generation: generation
            )
        case let .project(id, name):
            return RemoteSearchRequestDTO(
                query: query,
                scope: .project,
                projectID: id,
                projectName: name,
                generation: generation
            )
        case let .session(id, _, _):
            return RemoteSearchRequestDTO(
                query: query,
                scope: .session,
                sessionID: id,
                generation: generation
            )
        }
    }
}

private struct MobileSearchLanding: Identifiable, Hashable {
    let id = UUID()
    let hit: RemoteSearchHitDTO
    let resolution: RemoteSearchResolutionDTO

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The phone's native projection of the Mac search graph. It renders only bounded wire values;
/// choosing a row resolves its opaque token before this view decides which typed destination to
/// open, so presentation text is never routing authority.
struct MobileUniversalSearchView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let initialScope: MobileUniversalSearchScope
    let onRoute: (MobileNavigationRoute) -> Void
    private let performsRemoteSearch: Bool

    @State private var selectedScope: MobileUniversalSearchScope
    @State private var query = ""
    // The Mac keeps completed result tokens alive for one minute and rejects an older request
    // that arrives after a newer response. Start each presentation from a wall-clock epoch so
    // reopening Search (or restarting the phone app) cannot look like a delayed generation zero.
    @State private var generation = UInt64(Date().timeIntervalSince1970 * 1_000_000)
    @State private var response: RemoteSearchResponseDTO?
    @State private var errorMessage: String?
    @State private var isSearching = false
    @State private var resolvingToken: String?
    @State private var landing: MobileSearchLanding?

    init(
        initialScope: MobileUniversalSearchScope = .everywhere,
        initialQuery: String = "",
        initialResponse: RemoteSearchResponseDTO? = nil,
        performsRemoteSearch: Bool = true,
        onRoute: @escaping (MobileNavigationRoute) -> Void = { _ in }
    ) {
        self.initialScope = initialScope
        self.onRoute = onRoute
        self.performsRemoteSearch = performsRemoteSearch
        _selectedScope = State(initialValue: initialScope)
        _query = State(initialValue: initialQuery)
        _response = State(initialValue: initialResponse)
    }

    private var scopes: [MobileUniversalSearchScope] {
        switch initialScope {
        case .everywhere:
            return [.everywhere]
        case .project:
            return [initialScope, .everywhere]
        case let .session(_, projectID, projectName):
            var result = [initialScope]
            if let projectID {
                result.append(.project(id: projectID, name: projectName))
            }
            result.append(.everywhere)
            return result
        }
    }

    private var visibleGroups: [RemoteSearchGroupResultDTO] {
        response?.groups.filter { !$0.hits.isEmpty } ?? []
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileDesign.Spacing.pane) {
                if scopes.count > 1 {
                    Picker(MobileL10n.string("Search scope"), selection: $selectedScope) {
                        ForEach(scopes, id: \.self) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, MobileDesign.Spacing.inset)
                }

                if isSearching, response == nil {
                    ProgressView(MobileL10n.string("Searching…"))
                        .tint(theme.accent)
                        .foregroundStyle(theme.secondaryLabel)
                        .frame(maxWidth: .infinity)
                        .padding(.top, MobileDesign.Spacing.large)
                } else if let errorMessage {
                    ContentUnavailableView(
                        MobileL10n.string("Search unavailable"),
                        systemImage: "magnifyingglass",
                        description: Text(errorMessage)
                    )
                    .foregroundStyle(theme.label)
                } else if visibleGroups.isEmpty, response?.isComplete == true {
                    ContentUnavailableView(
                        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? MobileL10n.string("No recent destinations")
                            : MobileL10n.string("No matches"),
                        systemImage: "magnifyingglass"
                    )
                    .foregroundStyle(theme.label)
                } else {
                    ForEach(visibleGroups) { group in
                        resultGroup(group)
                    }
                }
            }
            .padding(.vertical, MobileDesign.Spacing.pane)
        }
        .background(theme.ground)
        .navigationTitle(MobileL10n.string("Search"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: MobileL10n.string("Search conversations, files, and destinations")
        )
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(MobileL10n.string("Done")) { dismiss() }
            }
        }
        .task(id: searchIdentity) {
            guard performsRemoteSearch else { return }
            await runSearch()
        }
        .navigationDestination(item: $landing) { landing in
            MobileSearchLandingView(landing: landing)
        }
        .accessibilityIdentifier("mobile-universal-search")
    }

    private var searchIdentity: String {
        "\(String(describing: selectedScope))\u{1f}\(query)"
    }

    @ViewBuilder
    private func resultGroup(_ group: RemoteSearchGroupResultDTO) -> some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            Label(groupTitle(group.group), systemImage: groupSymbol(group.group))
                .font(.headline)
                .foregroundStyle(theme.label)
                .padding(.horizontal, MobileDesign.Spacing.inset)

            LazyVStack(spacing: 0) {
                ForEach(Array(group.hits.enumerated()), id: \.element.id) { index, hit in
                    Button {
                        resolve(hit)
                    } label: {
                        resultRow(hit)
                    }
                    .buttonStyle(.plain)
                    .disabled(resolvingToken != nil)
                    .accessibilityIdentifier("mobile-search-result-\(hit.id)")

                    if index < group.hits.count - 1 {
                        Divider()
                            .overlay(theme.border)
                            .padding(.leading, MobileDesign.Spacing.inset)
                    }
                }
            }
            .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.panelRadius))
            .overlay {
                RoundedRectangle(cornerRadius: theme.panelRadius)
                    .stroke(theme.border, lineWidth: theme.borderWidth)
            }
            .padding(.horizontal, MobileDesign.Spacing.inset)

            if group.isCapped {
                Text("More matches are available — refine the query.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryLabel)
                    .padding(.horizontal, MobileDesign.Spacing.inset)
            }
            ForEach(Array(group.coverage.enumerated()), id: \.offset) { _, coverage in
                if let detail = coverage.detail, coverage.kind != .complete {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryLabel)
                        .padding(.horizontal, MobileDesign.Spacing.inset)
                }
            }
        }
    }

    private func resultRow(_ hit: RemoteSearchHitDTO) -> some View {
        HStack(alignment: .top, spacing: MobileDesign.Spacing.inset) {
            Image(systemName: hitSymbol(hit.kind))
                .font(.body.weight(.semibold))
                .foregroundStyle(theme.accent)
                .frame(width: MobileDesign.Size.compactControl)

            VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                Text(hit.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.label)
                    .lineLimit(1)
                if let snippet = hit.snippet, !snippet.text.isEmpty {
                    highlightedText(snippet)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryLabel)
                        .lineLimit(2)
                }
                let provenance = provenanceText(hit.provenance)
                if !provenance.isEmpty {
                    Text(provenance)
                        .font(.caption)
                        .foregroundStyle(theme.tertiaryLabel)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: MobileDesign.Spacing.small)
            if resolvingToken == hit.token {
                ProgressView().tint(theme.accent)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.tertiaryLabel)
            }
        }
        .contentShape(Rectangle())
        .padding(MobileDesign.Spacing.inset)
    }

    private func runSearch() async {
        do {
            try await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            generation &+= 1
            let requestedGeneration = generation
            isSearching = true
            errorMessage = nil
            guard let client = model.client else {
                response = nil
                isSearching = false
                errorMessage = MobileL10n.string(
                    "Connect to your Mac to search projects and conversations."
                )
                return
            }
            let result = try await client.search(
                selectedScope.request(query: query, generation: requestedGeneration)
            )
            guard !Task.isCancelled, result.generation == requestedGeneration else { return }
            response = result
            isSearching = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            response = nil
            isSearching = false
            errorMessage = error.localizedDescription
        }
    }

    private func resolve(_ hit: RemoteSearchHitDTO) {
        guard resolvingToken == nil, let client = model.client else { return }
        resolvingToken = hit.token
        errorMessage = nil
        Task {
            do {
                let resolution = try await client.resolveSearchResult(token: hit.token)
                resolvingToken = nil
                open(resolution, hit: hit)
            } catch {
                resolvingToken = nil
                errorMessage = MobileL10n.string("That result is no longer available.")
                await runSearch()
            }
        }
    }

    private func open(_ resolution: RemoteSearchResolutionDTO, hit: RemoteSearchHitDTO) {
        switch resolution.kind {
        case .project:
            guard let id = resolution.projectID, let name = resolution.projectName else { return }
            onRoute(.searchProject(id: id, name: name))
            dismiss()
        case .session:
            guard let id = resolution.sessionID else { return }
            onRoute(.session(id))
            dismiss()
        case .projectTerminal:
            guard let id = resolution.terminalID else { return }
            onRoute(.terminal(id))
            dismiss()
        case .archivedSession:
            guard let id = resolution.sessionID else { return }
            onRoute(.session(id))
            dismiss()
        case .conversation, .file:
            landing = MobileSearchLanding(hit: hit, resolution: resolution)
        case .attachment:
            guard let sessionID = resolution.sessionID,
                  let attachmentID = resolution.attachmentID else { return }
            onRoute(.sessionWorkspace(
                sessionID,
                .attachment(attachmentID)
            ))
            dismiss()
        case .browserTab:
            guard let sessionID = resolution.sessionID,
                  let browserTabID = resolution.browserTabID else { return }
            onRoute(.sessionWorkspace(
                sessionID,
                .browserTab(browserTabID)
            ))
            dismiss()
        }
    }

    private func highlightedText(_ snippet: RemoteSearchSnippetDTO) -> Text {
        let source = snippet.text as NSString
        let ranges = snippet.matches
            .map { NSRange(location: $0.utf16Location, length: $0.utf16Length) }
            .filter { $0.location >= 0 && $0.length > 0 && NSMaxRange($0) <= source.length }
            .sorted { $0.location < $1.location }
        guard !ranges.isEmpty else { return Text(snippet.text) }

        var result = Text("")
        var cursor = 0
        for range in ranges where range.location >= cursor {
            if range.location > cursor {
                result = result + Text(source.substring(
                    with: NSRange(location: cursor, length: range.location - cursor)
                ))
            }
            result = result + Text(source.substring(with: range))
                .bold()
                .foregroundColor(theme.accent)
            cursor = NSMaxRange(range)
        }
        if cursor < source.length {
            result = result + Text(source.substring(from: cursor))
        }
        return result
    }

    private func provenanceText(_ provenance: RemoteSearchProvenanceDTO) -> String {
        [
            provenance.projectName,
            provenance.sessionTitle,
            provenance.relativePath,
            provenance.provider,
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func groupTitle(_ group: RemoteSearchGroupDTO) -> String {
        switch group {
        case .destinations: return MobileL10n.string("Destinations")
        case .currentView: return MobileL10n.string("Current View")
        case .conversations: return MobileL10n.string("Conversations")
        case .files: return MobileL10n.string("Files")
        case .settings: return MobileL10n.string("Settings")
        case .archived: return MobileL10n.string("Archived")
        }
    }

    private func groupSymbol(_ group: RemoteSearchGroupDTO) -> String {
        switch group {
        case .destinations: return "arrow.turn.down.right"
        case .currentView: return "rectangle.and.text.magnifyingglass"
        case .conversations: return "bubble.left.and.text.bubble.right"
        case .files: return "doc.text.magnifyingglass"
        case .settings: return "gearshape"
        case .archived: return "archivebox"
        }
    }

    private func hitSymbol(_ kind: RemoteSearchHitKindDTO) -> String {
        switch kind {
        case .project: return "folder"
        case .session, .conversationMessage, .toolSummary: return "bubble.left.and.bubble.right"
        case .projectTerminal: return "terminal"
        case .file, .projectText: return "doc.text"
        case .command: return "command"
        case .setting: return "gearshape"
        case .archivedSession: return "archivebox"
        case .attachment: return "paperclip"
        case .browserTab: return "safari"
        case .gitReview: return "arrow.triangle.branch"
        }
    }
}

private struct MobileSearchLandingView: View {
    @Environment(\.remoteTheme) private var theme
    let landing: MobileSearchLanding

    var body: some View {
        Group {
            if let conversation = landing.resolution.conversation {
                conversationView(conversation)
            } else if let file = landing.resolution.file {
                fileView(file)
            }
        }
        .background(theme.ground)
        .navigationTitle(landing.hit.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func conversationView(_ window: RemoteSearchConversationWindowDTO) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
                    Text(window.projectName + " · " + window.sessionTitle)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryLabel)
                    if window.hasEarlier {
                        contextNotice(MobileL10n.string(
                            "Earlier conversation history is not shown"
                        ))
                    }
                    ForEach(window.rows) { row in
                        VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                            HStack {
                                Text(row.title ?? authorTitle(row.author))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(row.isError ? theme.negative : theme.accent)
                                Spacer()
                                if let timestamp = row.timestamp {
                                    Text(Date(timeIntervalSince1970: timestamp), style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(theme.tertiaryLabel)
                                }
                            }
                            highlightedBody(
                                row.body,
                                match: row.id == window.anchorRowID ? window.anchorMatch : nil
                            )
                            .font(.body)
                            .foregroundStyle(theme.label)
                            .textSelection(.enabled)
                        }
                        .padding(MobileDesign.Spacing.inset)
                        .background(
                            row.id == window.anchorRowID ? theme.controlResting : theme.panel,
                            in: RoundedRectangle(cornerRadius: theme.panelRadius)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.panelRadius)
                                .stroke(
                                    row.id == window.anchorRowID ? theme.accent : theme.border,
                                    lineWidth: theme.borderWidth
                                )
                        }
                        .id(row.id)
                    }
                    if window.hasLater {
                        contextNotice(MobileL10n.string(
                            "Later conversation history is not shown"
                        ))
                    }
                }
                .padding(MobileDesign.Spacing.inset)
            }
            .onAppear { proxy.scrollTo(window.anchorRowID, anchor: .center) }
        }
        .accessibilityIdentifier("mobile-search-conversation-window")
    }

    private func fileView(_ window: RemoteSearchFileWindowDTO) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                Text(window.relativePath)
                    .font(.headline)
                    .foregroundStyle(theme.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(window.projectName)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryLabel)
            }
            .padding(MobileDesign.Spacing.inset)

            Divider().overlay(theme.border)
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if window.hasEarlier {
                            contextNotice(MobileL10n.string("Earlier lines are not shown"))
                        }
                        ForEach(window.lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: MobileDesign.Spacing.inset) {
                                Text(String(line.number))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(theme.tertiaryLabel)
                                    .frame(width: 44, alignment: .trailing)
                                highlightedBody(line.text, match: line.match)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(theme.label)
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, MobileDesign.Spacing.inset)
                            .frame(minHeight: 34)
                            .background(
                                line.number == window.anchorLine
                                    ? theme.controlResting
                                    : Color.clear
                            )
                            .id(line.number)
                        }
                        if window.hasLater {
                            contextNotice(MobileL10n.string("Later lines are not shown"))
                        }
                    }
                }
                .onAppear {
                    if let anchor = window.anchorLine { proxy.scrollTo(anchor, anchor: .center) }
                }
            }
        }
        .accessibilityIdentifier("mobile-search-file-window")
    }

    private func contextNotice(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(theme.tertiaryLabel)
            .frame(maxWidth: .infinity)
            .padding(MobileDesign.Spacing.small)
    }

    private func highlightedBody(_ body: String, match: RemoteSearchTextRangeDTO?) -> Text {
        guard let match else { return Text(body) }
        let source = body as NSString
        let range = NSRange(location: match.utf16Location, length: match.utf16Length)
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= source.length else {
            return Text(body)
        }
        return Text(source.substring(to: range.location))
            + Text(source.substring(with: range)).bold().foregroundColor(theme.accent)
            + Text(source.substring(from: NSMaxRange(range)))
    }

    private func authorTitle(_ author: String?) -> String {
        switch author {
        case "you": return MobileL10n.string("You")
        case "agent": return MobileL10n.string("Agent")
        case "system": return MobileL10n.string("System")
        default: return MobileL10n.string("Conversation")
        }
    }
}
