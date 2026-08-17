import Foundation
import NativeDiffCore
import NativeDiffUIKit
import ThreadingRemoteKit
import SwiftUI
import UIKit

enum RemoteGitReviewSection: CaseIterable {
    case changed
    case allFiles

    var title: String {
        switch self {
        case .changed: return MobileL10n.string("Changed")
        case .allFiles: return MobileL10n.string("All Files")
        }
    }
}

/// A compact, read-only review surface backed by the checkout on the paired Mac.
///
/// The shape follows the mobile review reference: a comparison picker in the title, totals,
/// changed/all-file segments, collapsible file cards, and a stacked diff that wraps long lines.
struct RemoteGitReviewView: View {

    let session: RemoteSessionSummaryDTO
    let client: RemoteClient
    let showsCloseButton: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteTheme) private var theme
    @State private var mode = RemoteGitReviewMode.uncommitted
    @State private var section: RemoteGitReviewSection
    @State private var snapshot: RemoteGitReviewSnapshotDTO?
    @State private var repositoryFiles: RemoteRepositoryFilesDTO?
    @State private var expandedPaths: Set<String> = []
    @State private var searchText = ""
    @State private var isLoadingReview = false
    @State private var isLoadingFiles = false
    @State private var loadingFilePath: String?
    @State private var errorMessage: String?
    @State private var selectedFile: RemoteRepositoryFileDTO?
    @State private var isAllFilesAtBottom = true
    @State private var hasAllFilesOverflow = false
    @FocusState private var searchIsFocused: Bool

    private let allFilesScrollEndID = "git-review-all-files-end"

    private var isTurnInFlight: Bool {
        // localization-ignore: remote activity wire discriminators, not user-facing copy.
        session.state == "working" || session.state == "awaitingUser"
    }

    init(
        session: RemoteSessionSummaryDTO,
        client: RemoteClient,
        initialSection: RemoteGitReviewSection = .changed,
        showsCloseButton: Bool = true
    ) {
        self.session = session
        self.client = client
        self.showsCloseButton = showsCloseButton
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Contents", selection: $section) {
                ForEach(RemoteGitReviewSection.allCases, id: \.self) { section in
                    Text(sectionTitle(section)).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Rectangle()
                .fill(theme.divider)
                .frame(height: theme.borderWidth)

            switch section {
            case .changed:
                changedContent
            case .allFiles:
                allFilesContent
            }
        }
        .background(theme.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close review")
                }
            }

            ToolbarItem(placement: .principal) {
                Menu {
                    ForEach(RemoteGitReviewMode.allCases, id: \.rawValue) { candidate in
                        Button {
                            mode = candidate
                        } label: {
                            if candidate == mode {
                                Label(candidate.title(isTurnInFlight: isTurnInFlight), systemImage: "checkmark")
                            } else {
                                Text(candidate.title(isTurnInFlight: isTurnInFlight))
                            }
                        }
                    }
                } label: {
                    VStack(spacing: 1) {
                        HStack(spacing: 4) {
                            Text(mode.title(isTurnInFlight: isTurnInFlight))
                                .font(.headline)
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.bold))
                        }
                        HStack(spacing: 6) {
                                Text("+\(compactChangeCount(snapshot?.added ?? 0))")
                                    .foregroundStyle(theme.positive)
                                Text("−\(compactChangeCount(snapshot?.removed ?? 0))")
                                    .foregroundStyle(theme.negative)
                        }
                        .font(.caption2.monospacedDigit())
                        .opacity(snapshot == nil ? 0 : 1)
                        .accessibilityHidden(snapshot == nil)
                    }
                    .foregroundStyle(theme.label)
                }
                .accessibilityLabel(
                    "Review comparison, \(mode.title(isTurnInFlight: isTurnInFlight))"
                )
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoadingReview || isLoadingFiles)
                .accessibilityLabel("Refresh review")
            }
        }
        .task(id: mode) {
            await loadReview(for: mode)
        }
        .task(id: section) {
            guard section == .allFiles, repositoryFiles == nil else { return }
            await loadRepositoryFiles()
        }
        .sheet(item: $selectedFile) { file in
            NavigationStack {
                RemoteRepositoryFileView(file: file)
            }
            .mobileTheme(theme)
        }
    }

    @ViewBuilder
    private var changedContent: some View {
        if isLoadingReview, snapshot == nil {
            loadingView("Reading changes…")
        } else if let errorMessage, snapshot == nil {
            unavailableView(errorMessage)
        } else if let snapshot, snapshot.files.isEmpty {
            unavailableView(message(for: snapshot))
        } else if let snapshot {
            RemoteDiffCollectionView(
                document: snapshot.diffDocument,
                expandedPaths: $expandedPaths,
                theme: theme,
                isRefreshing: isLoadingReview,
                onRefresh: { Task { await loadReview(for: mode) } }
            )
        } else {
            loadingView("Reading changes…")
        }
    }

    @ViewBuilder
    private var allFilesContent: some View {
        if isLoadingFiles, repositoryFiles == nil {
            loadingView("Reading repository…")
        } else if let errorMessage, repositoryFiles == nil {
            unavailableView(errorMessage)
        } else if let repositoryFiles {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.tertiaryLabel)
                    TextField("Find a file", text: $searchText)
                        .focused($searchIsFocused)
                        .mobileUIEvidenceKeyboardFocus($searchIsFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(
                    theme.controlResting,
                    in: RoundedRectangle(cornerRadius: theme.controlRadius)
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                GeometryReader { viewport in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filteredPaths, id: \.self) { path in
                                    Button {
                                        Task { await openFile(path) }
                                    } label: {
                                        RemoteRepositoryFileRow(
                                            path: path,
                                            change: changedFiles[path],
                                            isLoading: loadingFilePath == path
                                        )
                                    }
                                    .buttonStyle(.plain)

                                    Rectangle()
                                        .fill(theme.divider)
                                        .frame(height: theme.borderWidth)
                                        .padding(.leading, 52)
                                }

                                if repositoryFiles.isTruncated {
                                    Text("Only the first \(repositoryFiles.paths.count) files are shown.")
                                        .font(.caption)
                                        .foregroundStyle(theme.tertiaryLabel)
                                        .padding(18)
                                }

                                Color.clear
                                    .frame(height: 68)
                                    .id(allFilesScrollEndID)
                            }
                            .background {
                                ReviewScrollBottomReader(
                                    coordinateSpace: "git-review-all-files"
                                )
                                ReviewScrollContentHeightReader()
                            }
                        }
                        .coordinateSpace(name: "git-review-all-files")
                        .onPreferenceChange(ReviewScrollBottomPreferenceKey.self) { bottom in
                            isAllFilesAtBottom = bottom <= viewport.size.height + 2
                        }
                        .onPreferenceChange(ReviewScrollContentHeightPreferenceKey.self) { height in
                            hasAllFilesOverflow = height > viewport.size.height + 2
                        }
                        .refreshable { await loadRepositoryFiles() }
                        .overlay(alignment: .bottom) {
                            if hasAllFilesOverflow && !isAllFilesAtBottom {
                                reviewBottomControls(
                                ) {
                                    withAnimation(.easeOut(duration: 0.22)) {
                                        proxy.scrollTo(allFilesScrollEndID, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            loadingView("Reading repository…")
        }
    }

    private var changedFiles: [String: RemoteGitFileDiffDTO] {
        Dictionary(uniqueKeysWithValues: (snapshot?.files ?? []).map { ($0.path, $0) })
    }

    private var filteredPaths: [String] {
        guard let paths = repositoryFiles?.paths else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return paths }
        return paths.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private func sectionTitle(_ section: RemoteGitReviewSection) -> String {
        switch section {
        case .changed:
            guard let count = snapshot?.files.count else { return section.title }
            return "\(section.title) (\(compactChangeCount(count)))"
        case .allFiles:
            // The repository total does not describe an action or review state, and large
            // worktrees made this segment compete with the change totals already in the title.
            return section.title
        }
    }

    private func loadingView(_ label: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text(MobileL10n.string(label))
                .font(.subheadline)
                .foregroundStyle(theme.secondaryLabel)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailableView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Nothing to review", systemImage: "plus.forwardslash.minus")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task { await reload() }
            }
        }
        .foregroundStyle(theme.secondaryLabel)
    }

    private func message(for snapshot: RemoteGitReviewSnapshotDTO) -> String {
        if let localization = snapshot.messageLocalization {
            return MobileL10n.string(
                localization.key,
                arguments: localization.arguments
            )
        }
        return snapshot.message ?? MobileL10n.string("No changes.")
    }

    private func reviewBottomControls(
        scrollToBottom: @escaping () -> Void
    ) -> some View {
        Button(action: scrollToBottom) {
            Image(systemName: "arrow.down")
                .font(.subheadline.weight(.semibold))
                .frame(width: 40, height: 40)
                .foregroundStyle(theme.label)
                .background(theme.surface, in: Circle())
                .overlay(
                    Circle()
                        .stroke(theme.border, lineWidth: theme.borderWidth)
                )
                .shadow(color: theme.ground.opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .transition(.scale(scale: 0.82).combined(with: .opacity))
        .accessibilityLabel("Scroll to the end of the repository")
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func reload() async {
        errorMessage = nil
        await loadReview(for: mode)
        if section == .allFiles {
            await loadRepositoryFiles()
        }
    }

    private func loadReview(for requestedMode: RemoteGitReviewMode) async {
        isLoadingReview = true
        errorMessage = nil
#if DEBUG
        if isReviewDemo {
            let loaded = Self.demoSnapshot(mode: requestedMode)
            snapshot = loaded
            expandedPaths = automaticExpansion(for: loaded.files)
            isLoadingReview = false
            return
        }
#endif
        do {
            let loaded = try await client.gitReview(
                sessionID: session.id,
                mode: requestedMode
            )
            try Task.checkCancellation()
            guard requestedMode == mode else { return }
            snapshot = loaded
            expandedPaths = automaticExpansion(for: loaded.files)
        } catch is CancellationError {
            return
        } catch {
            guard requestedMode == mode else { return }
            MobileDiagnostics.logDegraded(.gitReview, error: error)
            snapshot = nil
            errorMessage = error.localizedDescription
        }
        isLoadingReview = false
    }

    private func loadRepositoryFiles() async {
        isLoadingFiles = true
#if DEBUG
        if isReviewDemo {
            let isMassive = ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                == "review-files-massive"
            repositoryFiles = RemoteRepositoryFilesDTO(
                paths: isMassive
                    ? (0..<20_000).map { index in
                        "Sources/Generated/Feature\(index / 100)/GeneratedFile\(index).swift"
                    }
                    : [
                        "AGENTS.md",
                        "README.md",
                        "Packages/ThreadingRemoteKit/Sources/ThreadingRemoteKit/RemoteWireDTO.swift",
                        "Sources/ThreadingMobile/RemoteGitReviewView.swift",
                        "Sources/ThreadingMobile/SessionDetailView.swift",
                    ]
            )
            isLoadingFiles = false
            return
        }
#endif
        do {
            let loaded = try await client.repositoryFiles(sessionID: session.id)
            try Task.checkCancellation()
            repositoryFiles = loaded
        } catch is CancellationError {
            return
        } catch {
            MobileDiagnostics.logDegraded(.gitRepositoryFiles, error: error)
            repositoryFiles = nil
            errorMessage = error.localizedDescription
        }
        isLoadingFiles = false
    }

    private func openFile(_ path: String) async {
        guard loadingFilePath == nil else { return }
        loadingFilePath = path
        defer { loadingFilePath = nil }
#if DEBUG
        if isReviewDemo {
            selectedFile = RemoteRepositoryFileDTO(
                path: path,
                content: """
                import SwiftUI

                struct ExampleView: View {
                    var body: some View {
                        Text("A source preview from the paired Mac")
                    }
                }
                """,
                isBinary: false
            )
            return
        }
#endif
        do {
            selectedFile = try await client.repositoryFile(sessionID: session.id, path: path)
        } catch is CancellationError {
            return
        } catch {
            MobileDiagnostics.logDegraded(.gitRepositoryFile, error: error)
            errorMessage = error.localizedDescription
        }
    }

    private func automaticExpansion(for files: [RemoteGitFileDiffDTO]) -> Set<String> {
        DiffPresentationPolicy.default.initiallyExpandedPaths(
            in: DiffDocument(files: files.map(\.diffFile))
        )
    }

#if DEBUG
    private var isReviewDemo: Bool {
        ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]?
            .hasPrefix("review") == true
    }

    private static func demoSnapshot(
        mode: RemoteGitReviewMode
    ) -> RemoteGitReviewSnapshotDTO {
        let isMassive = ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]?
            .contains("massive") == true
        let first = RemoteGitFileDiffDTO(
            path: "Sources/ThreadingMobile/RemoteGitReviewView.swift",
            change: "modified",
            hunks: [
                RemoteGitHunkDTO(
                    header: "@@ -34,5 +34,8 @@ struct RemoteGitReviewView: View",
                    lines: [
                        .init(
                            kind: "context",
                            text: "    @State private var searchText = \"\"",
                            oldNumber: 34,
                            newNumber: 34
                        ),
                        .init(
                            kind: "removal",
                            text: "    @State private var isLoading = false",
                            oldNumber: 35,
                            newNumber: nil
                        ),
                        .init(
                            kind: "addition",
                            text: "    @State private var isLoadingReview = false",
                            oldNumber: nil,
                            newNumber: 35
                        ),
                        .init(
                            kind: "addition",
                            text: "    @State private var isLoadingFiles = false",
                            oldNumber: nil,
                            newNumber: 36
                        ),
                        .init(
                            kind: "context",
                            text: "    @State private var errorMessage: String?",
                            oldNumber: 36,
                            newNumber: 37
                        ),
                    ]
                )
            ],
            added: isMassive ? 24_691 : 73,
            removed: isMassive ? 8_032 : 12
        )
        let second = RemoteGitFileDiffDTO(
            path: "Packages/ThreadingRemoteKit/Sources/ThreadingRemoteKit/RemoteWireDTO.swift",
            change: "modified",
            hunks: [
                RemoteGitHunkDTO(
                    header: "@@ -560,2 +560,5 @@",
                    lines: [
                        .init(
                            kind: "context",
                            text: "// MARK: - Git review",
                            oldNumber: 560,
                            newNumber: 560
                        ),
                        .init(
                            kind: "addition",
                            text: "public enum RemoteGitReviewMode: String, Codable {",
                            oldNumber: nil,
                            newNumber: 561
                        ),
                        .init(
                            kind: "addition",
                            text: "    case unstaged, staged, branch, lastTurn",
                            oldNumber: nil,
                            newNumber: 562
                        ),
                        .init(
                            kind: "addition",
                            text: "}",
                            oldNumber: nil,
                            newNumber: 563
                        ),
                    ]
                )
            ],
            added: 92,
            removed: 0
        )
        return RemoteGitReviewSnapshotDTO(mode: mode, files: [first, second])
    }
#endif
}

/// The SwiftUI sheet remains responsible for navigation and loading, while every diff row is
/// rendered by the reusable UIKit collection view. This keeps the hot scrolling path out of
/// SwiftUI and makes large diffs proportional to the visible viewport rather than file size.
private struct RemoteDiffCollectionView: UIViewControllerRepresentable {
    let document: DiffDocument
    @Binding var expandedPaths: Set<String>
    let theme: RemoteThemePalette
    let isRefreshing: Bool
    let onRefresh: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(owner: self)
    }

    func makeUIViewController(context: Context) -> DiffUIKitViewController {
        let controller = DiffUIKitViewController(
            document: document,
            expandedPaths: expandedPaths,
            theme: theme.diffUIKitTheme
        )
        controller.onExpansionChange = { paths in
            context.coordinator.owner.expandedPaths = paths
        }
        controller.onRefresh = {
            context.coordinator.owner.onRefresh()
        }
        return controller
    }

    func updateUIViewController(
        _ controller: DiffUIKitViewController,
        context: Context
    ) {
        context.coordinator.owner = self
        controller.update(
            document: document,
            expandedPaths: expandedPaths,
            theme: theme.diffUIKitTheme,
            isRefreshing: isRefreshing
        )
    }

    final class Coordinator {
        var owner: RemoteDiffCollectionView

        init(owner: RemoteDiffCollectionView) {
            self.owner = owner
        }
    }
}

private extension RemoteGitReviewSnapshotDTO {
    var diffDocument: DiffDocument {
        DiffDocument(files: files.map(\.diffFile))
    }
}

private extension RemoteGitFileDiffDTO {
    var diffFile: DiffFile {
        DiffFile(
            path: path,
            change: diffChange,
            hunks: hunks.map {
                DiffHunk(
                    header: $0.header,
                    lines: $0.lines.map(\.diffLine)
                )
            },
            added: added,
            removed: removed,
            isTruncated: isTruncated
        )
    }

    var diffChange: DiffFile.Change {
        switch change {
        case "added": return .added
        case "deleted": return .deleted
        case "untracked": return .untracked
        case "renamed": return .renamed(from: renamedFrom ?? "")
        case "binary": return .binary
        default: return .modified
        }
    }
}

private extension RemoteGitDiffLineDTO {
    var diffLine: DiffLine {
        DiffLine(
            kind: {
                switch kind {
                case "addition": return .added
                case "removal": return .removed
                default: return .context
                }
            }(),
            text: text,
            oldNumber: oldNumber,
            newNumber: newNumber
        )
    }
}

private extension RemoteThemePalette {
    var diffUIKitTheme: DiffUIKitTheme {
        let added = uiColor("diff_added", fallback: "#55B978")
        let removed = uiColor("diff_removed", fallback: "#D87878")
        return DiffUIKitTheme(
            ground: uiColor("ground", fallback: "#16181D"),
            surface: uiColor("surface", fallback: "#1B1E24"),
            panel: uiColor("panel", fallback: "#22252C"),
            border: uiColor("border", fallback: "#FFFFFF14"),
            label: uiColor("label", fallback: "#F3F4F6"),
            secondaryLabel: uiColor("secondary_label", fallback: "#A7ABB4"),
            tertiaryLabel: uiColor("tertiary_label", fallback: "#747983"),
            added: added,
            removed: removed,
            addedBackground: added.withAlphaComponent(0.18),
            removedBackground: removed.withAlphaComponent(0.18),
            syntaxKeyword: uiColor("syntax_keyword", fallback: "#BF5AF2"),
            syntaxType: uiColor("syntax_type", fallback: "#64D2FF"),
            syntaxString: uiColor("syntax_string", fallback: "#FF9F0A"),
            syntaxNumber: uiColor("syntax_number", fallback: "#0A84FF"),
            syntaxComment: uiColor("syntax_comment", fallback: "#747983"),
            cardRadius: controlRadius,
            borderWidth: borderWidth
        )
    }
}

private struct ReviewScrollBottomPreferenceKey: PreferenceKey {
    static let defaultValue = CGFloat.greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ReviewScrollBottomReader: View {
    let coordinateSpace: String

    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: ReviewScrollBottomPreferenceKey.self,
                value: geometry.frame(in: .named(coordinateSpace)).maxY
            )
        }
    }
}

private struct ReviewScrollContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ReviewScrollContentHeightReader: View {
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: ReviewScrollContentHeightPreferenceKey.self,
                value: geometry.size.height
            )
        }
    }
}

private func compactChangeCount(_ value: Int) -> String {
    value.formatted(.number.notation(.compactName))
}

private struct RemoteRepositoryFileRow: View {
    let path: String
    let change: RemoteGitFileDiffDTO?
    let isLoading: Bool

    @Environment(\.remoteTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.subheadline)
                .foregroundStyle(change == nil ? theme.tertiaryLabel : theme.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text((path as NSString).lastPathComponent)
                    .font(.subheadline)
                    .foregroundStyle(theme.label)
                    .lineLimit(1)
                let directory = (path as NSString).deletingLastPathComponent
                if directory != "." {
                    Text(directory)
                        .font(.caption2)
                        .foregroundStyle(theme.tertiaryLabel)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let change {
                HStack(spacing: 5) {
                    if change.added > 0 {
                        Text("+\(change.added)").foregroundStyle(theme.positive)
                    }
                    if change.removed > 0 {
                        Text("−\(change.removed)").foregroundStyle(theme.negative)
                    }
                }
                .font(.caption.monospacedDigit())
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.tertiaryLabel)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}

private struct RemoteRepositoryFileView: View {
    let file: RemoteRepositoryFileDTO

    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        Group {
            if file.isBinary {
                ContentUnavailableView(
                    "Binary file",
                    systemImage: "doc.badge.ellipsis",
                    description: Text("This file has no text preview.")
                )
            } else if let content = file.content {
                let lines = content.components(separatedBy: "\n")
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 10) {
                                Text(String(index + 1))
                                    .foregroundStyle(theme.tertiaryLabel)
                                    .frame(width: 38, alignment: .trailing)
                                Text(lines[index].isEmpty ? " " : lines[index])
                                    .foregroundStyle(theme.label)
                                    .textSelection(.enabled)
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.vertical, 1)
                        }

                        if file.isTruncated {
                            Text("… file preview shortened")
                                .font(.caption)
                                .foregroundStyle(theme.tertiaryLabel)
                                .padding(.top, 12)
                        }
                    }
                    .padding(12)
                }
            } else {
                ContentUnavailableView("No preview", systemImage: "doc")
            }
        }
        .navigationTitle((file.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .background(theme.ground)
    }
}

private extension RemoteGitReviewMode {
    func title(isTurnInFlight: Bool) -> String {
        switch self {
        case .uncommitted: return MobileL10n.string("Uncommitted")
        case .unstaged: return MobileL10n.string("Unstaged")
        case .staged: return MobileL10n.string("Staged")
        case .branch: return MobileL10n.string("Branch")
        case .lastTurn:
            return isTurnInFlight
                ? MobileL10n.string("This Turn")
                : MobileL10n.string("Last Turn")
        }
    }
}
