import SwiftUI
import ThreadingRemoteKit

// MARK: - The invitation

/// A freshly minted invitation, held until the person handing it over is done with it.
struct SharedSessionLink: Identifiable {
    let id = UUID()
    let sessionTitle: String
    let url: URL
    let capability: RemoteAdvertisedCapability
    let canApprovePermissions: Bool
    let expiresAt: Date
}

// MARK: - The grants

/// One of the three grants a chat invitation can carry.
///
/// The same three the Mac's `ShareLinkGrant` offers, in the same order and with the same rule
/// about which one a dormant chat cannot mint. The phone says each in one line rather than the
/// Mac's two, because a row in a sheet is read while a finger is already reaching for it.
enum ShareChatRole: String, CaseIterable, Identifiable, Sendable {
    /// Watch, and nothing else.
    case view
    /// Watch and drive, while permission requests still come back to the owner.
    case collaborate
    /// Watch, drive, and answer permission requests in the owner's place.
    case collaborateAndApprove

    var id: String { rawValue }

    var capability: RemoteCapability {
        switch self {
        case .view: return .view
        case .collaborate, .collaborateAndApprove: return .interact
        }
    }

    var canApprovePermissions: Bool { self == .collaborateAndApprove }

    /// A chat that has never run has nothing to watch, and a viewer cannot wake it — only a
    /// participant who may act can. So this is the one grant that waits for a running chat.
    var requiresRunningChat: Bool { self == .view }

    /// The glyph the role wore when the chooser was a floating card, kept because it is the
    /// half of the row a reader recognises before the words.
    var systemImage: String {
        switch self {
        case .view: return "eye"
        case .collaborate: return "person.2"
        case .collaborateAndApprove: return "checkmark.shield"
        }
    }

    var title: String {
        switch self {
        case .view: return MobileL10n.string("View only")
        case .collaborate: return MobileL10n.string("Allow collaboration")
        case .collaborateAndApprove: return MobileL10n.string("Collaboration + approvals")
        }
    }

    /// One line, read as a ladder: the second grant adds writing to the first, and the third
    /// adds answering to the second. Each says what the holder does, never what they cannot,
    /// because the row above it already said that.
    var detail: String {
        switch self {
        case .view:
            return MobileL10n.string("Reads the chat, writes nothing.")
        case .collaborate:
            return MobileL10n.string("Writes messages and steers the agent.")
        case .collaborateAndApprove:
            return MobileL10n.string("Also answers requests for you.")
        }
    }

    /// Why a dormant chat leaves the first row dimmed, said once under the group rather than
    /// left for the reader to guess from a faded row.
    static var unavailableUntilRunning: String {
        MobileL10n.string("Start the chat first to share it view-only.")
    }
}

// MARK: - The two stages

/// Which half of Share Chat is on screen. The sheet is one presentation; this is what it holds.
enum ShareChatStage {
    case chooseRole
    case link(SharedSessionLink)

    /// A stable name for the stage, so the sheet can crossfade between two of them without
    /// comparing the invitation inside one.
    var identity: String {
        switch self {
        case .chooseRole: return "role"
        case .link: return "link"
        }
    }

    var isChoosingRole: Bool {
        if case .chooseRole = self { return true }
        return false
    }

    var link: SharedSessionLink? {
        if case .link(let link) = self { return link }
        return nil
    }
}

/// Share Chat as a state machine, so the stage transition can be held to without a sheet.
///
/// The chooser used to be a system action sheet that dismissed itself and then presented a
/// second sheet, which is two presentations for one question and read as two unrelated
/// answers. Choosing a role now mints the link and moves this flow's own stage, and the one
/// sheet redraws around it.
@MainActor
final class ShareChatFlow: ObservableObject {
    typealias Mint = @MainActor (ShareChatRole) async throws -> SharedSessionLink

    @Published private(set) var stage: ShareChatStage = .chooseRole
    /// The role whose link is being minted, which is also what makes the group wait: a second
    /// tap while a request is in flight would mint a second invitation to the same chat.
    @Published private(set) var pendingRole: ShareChatRole?
    @Published var errorMessage: String?

    let chatTitle: String
    let isChatRunning: Bool
    private let mint: Mint

    init(
        chatTitle: String,
        isChatRunning: Bool,
        mint: @escaping Mint
    ) {
        self.chatTitle = chatTitle
        self.isChatRunning = isChatRunning
        self.mint = mint
    }

    var isMinting: Bool { pendingRole != nil }

    var roles: [ShareChatRole] { ShareChatRole.allCases }

    func isEnabled(_ role: ShareChatRole) -> Bool {
        guard !isMinting else { return false }
        return isChatRunning || !role.requiresRunningChat
    }

    /// The one sentence a blocked chat adds, or nothing.
    var blockedNotice: String? {
        isChatRunning ? nil : ShareChatRole.unavailableUntilRunning
    }

    /// Mints the invitation and moves to the link stage.
    ///
    /// `async` rather than a fire-and-forget `Task`, so a test can await the transition instead
    /// of polling for it. The view starts the task; the flow decides what the tap means.
    func choose(_ role: ShareChatRole) async {
        guard stage.isChoosingRole, isEnabled(role) else { return }
        pendingRole = role
        defer { pendingRole = nil }
        do {
            stage = .link(try await mint(role))
        } catch is CancellationError {
            return
        } catch {
            MobileDiagnostics.logDegraded(.sessionAction, error: error)
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - The sheet

/// The one bottom sheet Share Chat opens.
///
/// It owns the flow for as long as the presentation lives; `ShareChatSheetContent` draws it.
/// The split is what lets a debug fixture drive the same content with a flow it can reach.
struct ShareChatSheet: View {
    @StateObject private var flow: ShareChatFlow

    init(
        chatTitle: String,
        isChatRunning: Bool,
        mint: @escaping ShareChatFlow.Mint
    ) {
        _flow = StateObject(
            wrappedValue: ShareChatFlow(
                chatTitle: chatTitle,
                isChatRunning: isChatRunning,
                mint: mint
            )
        )
    }

    var body: some View {
        ShareChatSheetContent(flow: flow)
    }
}

struct ShareChatSheetContent: View {
    private enum Metrics {
        static let stageCrossfade: Double = 0.24
    }

    @ObservedObject var flow: ShareChatFlow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ShareChatSheetChrome(
            closeTitle: closeTitle,
            prefersFullHeight: !flow.stage.isChoosingRole
        ) {
            Group {
                switch flow.stage {
                case .chooseRole:
                    ShareChatRoleStage(flow: flow)
                case .link(let link):
                    SharedSessionLinkStage(link: link)
                }
            }
            .id(flow.stage.identity)
            .transition(.opacity)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: Metrics.stageCrossfade),
                value: flow.stage.identity
            )
        }
        .themedAlert(
            "Couldn’t create link",
            message: flow.errorMessage ?? "",
            isPresented: Binding(
                get: { flow.errorMessage != nil },
                set: { if !$0 { flow.errorMessage = nil } }
            ),
            actions: [ThemedDialogAction("OK")]
        )
    }

    /// The trailing button says what leaving now would mean: at the chooser nothing has been
    /// minted yet, and at the link stage the invitation already exists.
    private var closeTitle: String {
        flow.stage.isChoosingRole
            ? MobileL10n.string("Cancel")
            : MobileL10n.string("Done")
    }
}

/// The chrome both stages stand in: the theme's ground, one centred title, one trailing button,
/// and one place that decides how tall the sheet opens.
private struct ShareChatSheetChrome<Content: View>: View {
    @Environment(\.remoteTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let closeTitle: String
    let prefersFullHeight: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            // The content stands in the middle of the height the sheet opened at, rather than
            // at the top of it. A stage shorter than its sheet used to hang from the navigation
            // bar with the rest of the screen empty under it, which reads as a page that failed
            // to load; a stage taller than its sheet is unaffected and scrolls as before.
            GeometryReader { proxy in
                ScrollView {
                    content()
                        .frame(maxWidth: .infinity)
                        .padding(MobileDesign.Spacing.pane)
                        .frame(minHeight: proxy.size.height - proxy.safeAreaInsets.bottom)
                }
            }
            .background(theme.ground)
            .navigationTitle("Share chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(closeTitle) { dismiss() }
                }
            }
        }
        .presentationDetents(detents)
    }

    /// How tall the sheet opens, decided by what the stage has to say rather than measured.
    ///
    /// Both stages have a fixed shape, so their heights are known. The chooser is a name, a
    /// question and three rows, and fits half a screen with room under it. The link stage is a
    /// mark, three sentences, two full-width actions and a closing paragraph, and does not: at
    /// the system's own default text size the paragraph's last line was cut by the fold, which
    /// is the defect that line was already reported for once. It opens at full height instead.
    /// Neither fits half a screen at an accessibility size.
    ///
    /// Stated rather than measured for the reason the link stage was already given: a content
    /// height read back from a `GeometryReader` arrives a layout pass after the sheet has
    /// chosen, so the first thing the reader sees is the wrong height either way.
    private var detents: Set<PresentationDetent> {
        dynamicTypeSize.isAccessibilitySize || prefersFullHeight
            ? [.large]
            : [.medium, .large]
    }
}

/// The name and the line under it that both stages open with, over a mark when the stage has
/// one to draw.
///
/// The link stage does: its mark says which of the two invitations was minted, which is a fact
/// and not decoration. The chooser has none, and had one for a while. It cost sixty points at
/// the top of a sheet whose content already reached the bottom of the half-screen detent, so a
/// chat that could not offer the first grant had the sentence saying why cut in half — the same
/// defect, in a new place, that the closing line on the link stage was reported for. A generic
/// person glyph over three rows that each already carry their own was the one thing on the stage
/// saying nothing.
private struct ShareChatStageHeader: View {
    private enum Metrics {
        static let markSize: CGFloat = 42
    }

    @Environment(\.remoteTheme) private var theme

    var systemImage: String?
    let title: String
    let message: String
    var footnote: String?

    var body: some View {
        VStack(spacing: MobileDesign.Spacing.large) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: Metrics.markSize, weight: .light))
                    .foregroundStyle(theme.accent)
                    .accessibilityHidden(true)
            }

            VStack(spacing: MobileDesign.Spacing.small) {
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(theme.label)

                Text(message)
                    .font(.body)
                    .foregroundStyle(theme.secondaryLabel)

                if let footnote {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryLabel)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Stage one: the grant

private struct ShareChatRoleStage: View {
    @ObservedObject var flow: ShareChatFlow
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        VStack(spacing: MobileDesign.Spacing.large) {
            ShareChatStageHeader(
                title: flow.chatTitle,
                message: MobileL10n.string("Choose what this person can do.")
            )

            ThemedRowGroup {
                ForEach(Array(flow.roles.enumerated()), id: \.element) { offset, role in
                    if offset > 0 {
                        ThemedRowDivider(
                            leadingInset: ShareChatRoleRow.textLeadingEdge,
                            trailingInset: 0
                        )
                    }
                    ShareChatRoleRow(
                        role: role,
                        isEnabled: flow.isEnabled(role),
                        isPending: flow.pendingRole == role
                    ) {
                        Task { await flow.choose(role) }
                    }
                }
            }

            if let notice = flow.blockedNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One grant, as a row of the group rather than a button in a stack: a tile, the name, and the
/// line that says what it does.
private struct ShareChatRoleRow: View {
    /// Where the row's words begin, which is where the hairline above the next row begins too.
    static let textLeadingEdge = MobileDesign.Spacing.inset
        + MobileDesign.Size.rowMark
        + MobileDesign.Spacing.medium

    @Environment(\.remoteTheme) private var theme

    let role: ShareChatRole
    let isEnabled: Bool
    let isPending: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: MobileDesign.Spacing.medium) {
                ZStack {
                    RoundedRectangle(
                        cornerRadius: MobileDesign.Size.rowMarkRadius,
                        style: .continuous
                    )
                    .fill(theme.controlResting)

                    Image(systemName: role.systemImage)
                        .font(.system(size: MobileDesign.Size.rowMarkGlyph, weight: .medium))
                        .foregroundStyle(theme.accent)
                }
                .frame(width: MobileDesign.Size.rowMark, height: MobileDesign.Size.rowMark)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: MobileDesign.Spacing.hairline) {
                    Text(role.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.label)
                    Text(role.detail)
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryLabel)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                trailingMark
            }
            .padding(.horizontal, MobileDesign.Spacing.inset)
            .padding(.vertical, MobileDesign.Spacing.medium)
            .frame(minHeight: MobileDesign.Size.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : MobileDesign.Opacity.disabledAction)
    }

    @ViewBuilder
    private var trailingMark: some View {
        if isPending {
            ProgressView()
                .tint(theme.accent)
        } else {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.tertiaryLabel)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Stage two: the link

/// What a freshly minted invitation says about itself, and the two ways to hand it over.
///
/// **Three text styles, not five.** It used to set a title, the chat's name, the grant, the
/// expiry and a closing paragraph in five different sizes down one narrow column, which reads as
/// five unrelated announcements rather than one answer. The chat's name moved into the sentence
/// that says what the link grants — that sentence is *about* the chat, so it may as well name it
/// — and the expiry and the closing line share the footnote they were always both saying.
///
/// **Two buttons the same size.** The secondary used to be a bordered pill about half the width
/// of the primary, which made copying look like a different class of action rather than the same
/// action through a different door. Both are now the dialog action height, both full width, one
/// filled with the accent and one with the theme's quiet control fill; the border is gone,
/// matching the resting controls everywhere else on the phone.
///
/// **The closing line wraps.** It was a `Text` built by concatenating two literals, which is a
/// `String` expression rather than a literal — so SwiftUI chose `Text(verbatim:)` and the
/// sentence was never localized at all, appearing in English inside a Swedish app. It was also
/// clipped mid-word, because the content stood in a fixed `.medium` sheet with no way to scroll
/// and the last view in the stack is the one that gets compressed. It goes through `MobileL10n`
/// now, and the sheet it stands in scrolls.
private struct SharedSessionLinkStage: View {
    @Environment(\.remoteTheme) private var theme
    @State private var copied = false

    let link: SharedSessionLink

    var body: some View {
        VStack(spacing: MobileDesign.Spacing.large) {
            ShareChatStageHeader(
                systemImage: markSymbol,
                title: MobileL10n.string("Link ready"),
                message: grantLine,
                footnote: expiryLine
            )

            VStack(spacing: MobileDesign.Spacing.medium) {
                ShareLink(item: sharedText) {
                    actionLabel(
                        MobileL10n.string("Share link"),
                        systemImage: "square.and.arrow.up"
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accentForeground)
                .background(
                    theme.accent,
                    in: RoundedRectangle(cornerRadius: theme.controlRadius)
                )

                Button {
                    UIPasteboard.general.string = sharedText
                    copied = true
                } label: {
                    actionLabel(
                        MobileL10n.string(copied ? "Copied" : "Copy link"),
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.label)
                .background(
                    theme.controlResting,
                    in: RoundedRectangle(cornerRadius: theme.controlRadius)
                )
            }

            Text(SharedSessionLinkCopy.footer)
                .font(.footnote)
                .foregroundStyle(theme.secondaryLabel)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Both actions, the same shape: full width, the dialog action height, one filled with the
    /// accent and one with the theme's quiet control fill. The title arrives localized, because
    /// a `MobileL10n` key has to be readable where it is written.
    private func actionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(minHeight: MobileDesign.Size.dialogActionHeight)
            .contentShape(Rectangle())
    }

    private var markSymbol: String {
        link.capability == .interact
            ? "person.2.badge.gearshape"
            : "person.2"
    }

    private var grantLine: String {
        SharedSessionLinkCopy.grant(
            chatTitle: link.sessionTitle,
            capability: link.capability,
            canApprovePermissions: link.canApprovePermissions
        )
    }

    private var expiryLine: String {
        MobileL10n.string(
            "Unused invite expires %@",
            link.expiresAt.formatted(.relative(presentation: .named))
        )
    }

    private var sharedText: String {
        SharedSessionLinkCopy.sharedText(for: link.url)
    }
}

/// The link stage on its own, for a surface that never asks the grant question: a project
/// terminal is shared from its own menu, which has already chosen.
struct SharedSessionLinkView: View {
    let link: SharedSessionLink

    var body: some View {
        ShareChatSheetChrome(
            closeTitle: MobileL10n.string("Done"),
            prefersFullHeight: true
        ) {
            SharedSessionLinkStage(link: link)
        }
    }
}

// MARK: - The words an invitation leaves with

/// A value rather than three computed properties on the view, so a test can hold the sentence
/// the recipient reads without standing a sheet up first.
enum SharedSessionLinkCopy {
    /// One line saying what the link grants, naming the chat it grants.
    static func grant(
        chatTitle: String,
        capability: RemoteAdvertisedCapability,
        canApprovePermissions: Bool
    ) -> String {
        guard capability == .interact else {
            return MobileL10n.string("Can view “%@”", chatTitle)
        }
        return canApprovePermissions
            ? MobileL10n.string("Can collaborate in “%@” and approve requests", chatTitle)
            : MobileL10n.string("Can collaborate in “%@”", chatTitle)
    }

    static var footer: String {
        MobileL10n.string(
            "The invite works once. After acceptance, access lasts until you stop sharing "
                + "and never extends to another chat."
        )
    }

    /// What the recipient is actually sent.
    ///
    /// The invitation used to travel as the bare `https` URL of a private door, so tapping it on
    /// the recipient's phone opened Safari at a LAN address with a certificate no browser can
    /// vouch for. The composition is `ThreadingRemoteKit`'s, shared with the Mac's own copy
    /// actions so the two cannot drift.
    static func sharedText(for shareURL: URL) -> String {
        RemoteInvitationShare.text(shareURL: shareURL, guidance: guidance)
    }

    static var guidance: String {
        MobileL10n.string(
            "Open in the Threading app. Works for someone on your Wi-Fi or tailnet."
        )
    }
}

#if DEBUG
/// The fixture both share stages are photographed from, so the chooser and the link it mints
/// cannot drift apart in review.
@MainActor
enum ShareChatDemo {
    static let chatTitle = "Remote access review"

    /// A pinned invitation to a LAN door, which is what a real one is: the fixture used to hold
    /// a fragment-less `threading.example` URL, so the share text it composed fell back to the
    /// bare address and the demo exercised none of the routing.
    static let link = SharedSessionLink(
        sessionTitle: chatTitle,
        url: URL(
            string: "https://192.168.1.181:8760/#demo-invitation."
                + String(repeating: "A", count: 26)
        )!,
        capability: .interact,
        canApprovePermissions: true,
        expiresAt: Date().addingTimeInterval(86_400)
    )

    static func flow(isChatRunning: Bool = true) -> ShareChatFlow {
        ShareChatFlow(chatTitle: chatTitle, isChatRunning: isChatRunning) { role in
            SharedSessionLink(
                sessionTitle: chatTitle,
                url: link.url,
                capability: RemoteAdvertisedCapability(role.capability),
                canApprovePermissions: role.canApprovePermissions,
                expiresAt: link.expiresAt
            )
        }
    }
}
#endif
