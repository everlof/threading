import SwiftUI
import ThreadingRemoteKit
import UIKit

/// The inbox as the person has paged it: each section's rows and where it resumes.
///
/// The Mac pages every section by 20 and says where each stopped. Paging one section asks for
/// the whole inbox with only that section's cursor moved and keeps only that section of the
/// answer, so the others are never duplicated or skipped.
struct WorkroomInboxPages: Equatable {
    struct Section: Equatable {
        let kind: RemoteWorkroomSectionKind
        var items: [RemoteWorkroomQuestionSummaryDTO]
        var next: Int64
        var more: Bool
    }

    private(set) var sections: [Section] = []

    var isEmpty: Bool { sections.allSatisfy(\.items.isEmpty) }

    mutating func replace(with inbox: RemoteWorkroomInboxDTO) {
        sections = inbox.sections.map {
            Section(kind: $0.kind, items: $0.items, next: $0.next, more: $0.more)
        }
    }

    mutating func append(_ page: RemoteWorkroomSectionDTO) {
        guard let index = sections.firstIndex(where: { $0.kind == page.kind }) else { return }
        let known = Set(sections[index].items.map(\.id))
        sections[index].items += page.items.filter { !known.contains($0.id) }
        sections[index].next = page.next
        sections[index].more = page.more
    }

    /// The cursors that ask for the next page of `kind` and the first page of the rest.
    func cursors(advancing kind: RemoteWorkroomSectionKind) -> MobileWorkroomInboxCursors {
        var cursors = MobileWorkroomInboxCursors()
        guard let next = sections.first(where: { $0.kind == kind })?.next else { return cursors }
        switch kind {
        case .replies: cursors.replies = next
        case .open: cursors.open = next
        case .recent, .latest: cursors.recent = next
        case .unknown: break
        }
        return cursors
    }
}

/// A participant's questions, or — pushed from an owner's dashboard — the latest questions on
/// this Mac. The participant's is their root screen: it is everything a workroom link reaches.
struct WorkroomInboxView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @EnvironmentObject private var notifications: RemoteNotificationManager
    @Environment(\.remoteTheme) private var theme

    /// The participant's root carries the Mac switcher and Settings; the owner's list is pushed.
    let isRoot: Bool
    let openSettings: () -> Void

    // Loaders (status-integrity review): each spinner is one awaited `RemoteClient` request —
    // the first inbox load, one section's next page, the notification permission prompt — bounded
    // by the client's request timeout. Success replaces it with rows, failure with
    // `WorkroomFailureCard` or the section's error; a newer load replaces an older one, and nothing
    // is restored from cache, so what is shown is always live.
    @State private var inbox: RemoteWorkroomInboxDTO?
    @State private var pages = WorkroomInboxPages()
    @State private var failure: String?
    @State private var loadingMore: RemoteWorkroomSectionKind?

    private var viewer: RemoteWorkroomViewer {
        inbox?.viewer ?? (model.showsWorkroomInbox ? .participant : .owner)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                if viewer == .participant {
                    WorkroomNotificationCard()
                }
                content
            }
            .padding(MobileDesign.Spacing.inset)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await reload() }
        .background(theme.ground.ignoresSafeArea())
        .navigationTitle(viewer == .owner ? MobileL10n.string("Linked Workrooms") : MobileL10n.string("Your questions"))
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbar { toolbar }
        .task(id: model.activeHostID) { await poll() }
    }

    @ViewBuilder
    private var content: some View {
        if inbox == nil {
            if let failure {
                WorkroomFailureCard(
                    title: MobileL10n.string("Couldn’t load the questions"),
                    message: failure,
                    retry: { Task { await reload() } }
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        } else if pages.isEmpty {
            WorkroomEmptyCard(viewer: viewer)
        } else {
            ForEach(pages.sections.filter { !$0.items.isEmpty }, id: \.kind.rawValue) { section in
                sectionView(section)
            }
        }
    }

    private func sectionView(_ section: WorkroomInboxPages.Section) -> some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            Text(Self.title(of: section.kind))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.secondaryLabel)
                .padding(.top, MobileDesign.Spacing.small)
                .padding(.horizontal, MobileDesign.Spacing.tight)
            ForEach(section.items) { item in
                Button {
                    model.navigationPath.append(.workroomQuestion(item.id))
                } label: {
                    WorkroomQuestionRow(item: item, viewer: viewer, isNew: section.kind == .replies)
                }
                .buttonStyle(.plain)
            }
            if section.more {
                Button {
                    Task { await loadMore(section.kind) }
                } label: {
                    HStack {
                        if loadingMore == section.kind { ProgressView().controlSize(.small) }
                        Text(MobileL10n.string("Show more"))
                    }
                    .frame(maxWidth: .infinity, minHeight: MobileDesign.Size.minimumTapTarget)
                }
                .buttonStyle(MobileThemedActionButtonStyle(kind: .secondary, theme: theme))
                .disabled(loadingMore != nil)
            }
        }
    }

    static func title(of kind: RemoteWorkroomSectionKind) -> String {
        switch kind {
        case .replies: return MobileL10n.string("New messages")
        case .open: return MobileL10n.string("Waiting for your answer")
        case .recent: return MobileL10n.string("Answered and closed")
        case .latest: return MobileL10n.string("Latest questions")
        case .unknown: return MobileL10n.string("Questions")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isRoot {
            if model.hosts.count > 1 {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(model.hosts) { host in
                            Button {
                                model.selectHost(host.id)
                            } label: {
                                Label(
                                    host.menuTitle,
                                    systemImage: host.id == model.activeHostID ? "checkmark" : "laptopcomputer"
                                )
                            }
                        }
                    } label: {
                        Image(systemName: "laptopcomputer")
                            .frame(width: MobileDesign.Size.compactControl, height: MobileDesign.Size.compactControl)
                            .background(theme.controlResting, in: Circle())
                    }
                    .accessibilityLabel(MobileL10n.string("Choose Mac"))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        model.isPairing = true
                    } label: {
                        Label(MobileL10n.string("Add a connection"), systemImage: "qrcode.viewfinder")
                    }
                    Button(action: openSettings) {
                        Label(MobileL10n.string("Settings"), systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: MobileDesign.Size.compactControl, height: MobileDesign.Size.compactControl)
                        .background(theme.controlResting, in: Circle())
                }
                .accessibilityLabel(MobileL10n.string("Settings"))
            }
        }
    }

    // MARK: Loading

    /// Loads, then asks for the cheap fingerprint while the screen is in front and the app is
    /// active, and reloads only when it moved. Leaving the screen cancels the loop.
    private func poll() async {
        await reload()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(RemoteWorkroomLimits.pollInterval))
            guard !Task.isCancelled else { return }
            guard UIApplication.shared.applicationState == .active else { continue }
            guard let state = try? await model.fetchWorkroomState() else { continue }
            if state.version != inbox?.state.version { await reload() }
        }
    }

    private func reload() async {
        do {
            let fresh = try await model.fetchWorkroomInbox()
            inbox = fresh
            pages.replace(with: fresh)
            failure = nil
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }

    private func loadMore(_ kind: RemoteWorkroomSectionKind) async {
        loadingMore = kind
        defer { loadingMore = nil }
        do {
            let page = try await model.fetchWorkroomInbox(cursors: pages.cursors(advancing: kind))
            if let section = page.sections.first(where: { $0.kind == kind }) { pages.append(section) }
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - Rows and cards

struct WorkroomQuestionRow: View {
    @Environment(\.remoteTheme) private var theme
    let item: RemoteWorkroomQuestionSummaryDTO
    let viewer: RemoteWorkroomViewer
    let isNew: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
            HStack(alignment: .top, spacing: MobileDesign.Spacing.small) {
                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(theme.label)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                Spacer(minLength: MobileDesign.Spacing.small)
                if isNew {
                    WorkroomBadge(text: MobileL10n.string("New message"), emphasis: .new)
                } else {
                    WorkroomStateBadge(state: item.state)
                }
            }
            Text(viewer == .owner
                 ? MobileL10n.string("To %@ · %@", item.personName, item.roomTitle)
                 : MobileL10n.string("From %@ · %@", item.askerName, item.roomTitle))
                .font(.footnote)
                .foregroundStyle(theme.secondaryLabel)
                .lineLimit(2)
            if let preview = item.unreadPreview {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(theme.label)
                    .lineLimit(2)
                    .padding(.top, MobileDesign.Spacing.hairline)
            }
            // A sentence, not a ticking timer: "för 5 minuter sedan", read once per load.
            Text(Date(timeIntervalSince1970: item.updatedAt).formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(theme.tertiaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MobileDesign.Spacing.inset)
        .workroomCard(theme, emphasized: isNew)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct WorkroomBadge: View {
    enum Emphasis { case neutral, waiting, done, new }

    @Environment(\.remoteTheme) private var theme
    let text: String
    let emphasis: Emphasis

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, MobileDesign.Spacing.small)
            .padding(.vertical, MobileDesign.Spacing.hairline)
            .foregroundStyle(foreground)
            .background(emphasis == .new ? theme.accent : theme.controlResting, in: Capsule())
    }

    private var foreground: Color {
        switch emphasis {
        case .neutral: return theme.secondaryLabel
        case .waiting: return theme.warning
        case .done: return theme.positive
        case .new: return theme.accentForeground
        }
    }
}

struct WorkroomStateBadge: View {
    let state: RemoteWorkroomQuestionState

    var body: some View {
        switch state {
        case .open: WorkroomBadge(text: MobileL10n.string("Waiting"), emphasis: .waiting)
        case .answered: WorkroomBadge(text: MobileL10n.string("Answered"), emphasis: .done)
        case .declined: WorkroomBadge(text: MobileL10n.string("Declined"), emphasis: .neutral)
        case .withdrawn: WorkroomBadge(text: MobileL10n.string("Withdrawn"), emphasis: .neutral)
        case .unknown: EmptyView()
        }
    }
}

private struct WorkroomEmptyCard: View {
    @Environment(\.remoteTheme) private var theme
    let viewer: RemoteWorkroomViewer

    var body: some View {
        VStack(spacing: MobileDesign.Spacing.medium) {
            Image(systemName: "checkmark.bubble")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.accent)
            Text(MobileL10n.string("No questions right now"))
                .font(.headline)
            Text(viewer == .owner
                 ? MobileL10n.string("Questions agents ask in open workrooms appear here.")
                 : MobileL10n.string("When an AI agent needs your help, the question appears here and you get a notification."))
                .font(.subheadline)
                .foregroundStyle(theme.secondaryLabel)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(MobileDesign.Spacing.pane)
        .workroomCard(theme)
    }
}

struct WorkroomFailureCard: View {
    @Environment(\.remoteTheme) private var theme
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(theme.negative)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(theme.secondaryLabel)
            Button(MobileL10n.string("Retry"), action: retry)
                .buttonStyle(MobileThemedActionButtonStyle(kind: .secondary, theme: theme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MobileDesign.Spacing.inset)
        .workroomCard(theme)
    }
}

/// Asks once, with the reason in view, before iOS asks. A participant who says no is told
/// where the switch is instead of being asked again.
struct WorkroomNotificationCard: View {
    @EnvironmentObject private var notifications: RemoteNotificationManager
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @State private var isRequesting = false

    var body: some View {
        switch notifications.authorizationStatus {
        case .notDetermined:
            card(
                title: MobileL10n.string("Get a notification when you’re asked something"),
                message: MobileL10n.string("Threading tells you when a new question or message arrives, and nothing else."),
                action: MobileL10n.string("Turn on notifications")
            ) {
                isRequesting = true
                Task {
                    await notifications.requestAuthorization()
                    await notifications.sync(hosts: model.hosts)
                    isRequesting = false
                }
            }
        case .denied:
            card(
                title: MobileL10n.string("Notifications are off"),
                message: MobileL10n.string("Turn them on in Settings to hear about new questions."),
                action: MobileL10n.string("Open Settings")
            ) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        default:
            EmptyView()
        }
    }

    private func card(title: String, message: String, action: String,
                      perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
            HStack(alignment: .top, spacing: MobileDesign.Spacing.medium) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                    Text(title).font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: perform) {
                HStack {
                    if isRequesting { ProgressView().controlSize(.small) }
                    Text(action)
                }
            }
            .buttonStyle(MobileThemedActionButtonStyle(kind: .primary, theme: theme))
            .disabled(isRequesting)
        }
        .padding(MobileDesign.Spacing.inset)
        .workroomCard(theme)
    }
}

extension View {
    /// The one card these screens stand on: the theme's panel, radius and border.
    func workroomCard(_ theme: RemoteThemePalette, emphasized: Bool = false) -> some View {
        background(theme.panel, in: RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous)
                    .strokeBorder(emphasized ? theme.accent : theme.border,
                                  lineWidth: max(theme.borderWidth, emphasized ? 1.5 : 1))
            }
    }
}
