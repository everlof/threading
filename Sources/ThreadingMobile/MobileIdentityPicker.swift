import SwiftUI
import ThreadingRemoteKit

#if os(iOS)
import UIKit

// MARK: - Mobile Account Glyph

/// What a login's disc shows: the emoji it was given, else the initial of its address or name.
///
/// The Mac's `AccountBadge.initial(for:)` rule, restated for the catalogue's account choice —
/// which carries the address and the name, not the resolved chip a session row receives. The
/// address comes first because a person keeps one address across the agents they are logged
/// into while a derived name can differ, then the name, then a mark for a login with neither, so
/// one login leads with one letter on both screens.
enum MobileAccountGlyph: Equatable {
    case emoji(String)
    case initial(String)
    case symbol(String)

    static let fallbackSymbol = "person.crop.circle"

    static func resolve(emoji: String?, email: String?, name: String) -> MobileAccountGlyph {
        if let emoji, let first = emoji.first(where: { !$0.isWhitespace }) {
            return .emoji(String(first))
        }
        for candidate in [email, name] {
            if let letter = candidate?.first(where: { $0.isLetter || $0.isNumber }) {
                return .initial(String(letter).uppercased())
            }
        }
        return .symbol(fallbackSymbol)
    }
}

// MARK: - Mobile Account Usage Words

/// The line under a login's name in the identity picker: the exact reading the row's rings stand
/// for, or why there is none.
///
/// The words the rings are drawn from win, because they are scoped to the model the draft will
/// run; the catalogue's account-wide summary stands in for a host that sends no windows. A login
/// whose reading failed says so rather than standing beside its neighbours' numbers as if it had
/// none to report, and one still being read says that. The system menu folded both states into
/// the login's title behind three spaces, which is not a state, it is a wider name.
enum MobileAccountUsageWords: Equatable {
    case reading(String)
    case unavailable
    case loading

    static func resolve(
        account: RemoteAccountChoiceDTO,
        reading: MobileAccountUsageReading?
    ) -> MobileAccountUsageWords {
        if let summary = reading?.summary ?? account.usageSummary { return .reading(summary) }
        if account.usageError != nil { return .unavailable }
        return .loading
    }

    var text: String {
        switch self {
        case .reading(let words): return words
        case .unavailable: return MobileL10n.string("Usage unavailable")
        case .loading: return MobileL10n.string("Loading usage…")
        }
    }
}

// MARK: - Mobile Identity Picker Reading

/// Which model each login's row is ringed for.
///
/// The chosen login is ringed for the model the draft will actually start — the reading the
/// toolbar disc wears, so the checked row and the disc that opened the picker agree. Every other
/// login is ringed for its own default, which is what the next turn would spend there: the
/// draft's model belongs to the chosen identity and a switch re-resolves it from the new
/// identity's memory (`SessionDraftRunChoiceResolution`), so ringing another login for this
/// one's model would promise a window the switch may not keep.
enum MobileIdentityPickerReading {
    static func resolve(
        account: RemoteAccountChoiceDTO,
        selectedAccountID: String,
        draftModelID: String?,
        now: Date = Date()
    ) -> MobileAccountUsageReading? {
        MobileAccountUsageReading.resolve(
            account: account,
            model: account.id == selectedAccountID ? draftModelID : nil,
            now: now
        )
    }
}

// MARK: - Mobile Identity Picker Strip

/// The runtime strip's rows: tiles of one width, in rows of at most `tilesPerRow`.
///
/// A strip that fits one row shares the plate among the tiles it has — two runtimes are two
/// halves, not two fifths and a gap. Once it wraps, every row holds `tilesPerRow` and the last
/// is padded to that count, so a sixth runtime does not draw twice as wide as the five above it.
enum MobileIdentityPickerStrip {
    static func rows<Element>(_ elements: [Element], tilesPerRow: Int) -> [[Element?]] {
        guard tilesPerRow > 0, !elements.isEmpty else { return [] }
        let perRow = min(elements.count, tilesPerRow)
        return stride(from: 0, to: elements.count, by: perRow).map { start in
            let end = min(start + perRow, elements.count)
            let row: [Element?] = elements[start..<end].map { $0 }
            return row + Array(repeating: nil, count: perRow - row.count)
        }
    }
}

// MARK: - Mobile Identity Picker

/// The draft's *who*: the runtime and the login, chosen on one surface.
///
/// A system menu listed both as one column — five identical sparkles for five runtimes, the
/// chosen one's glyph replaced by a checkmark, and every login's usage folded into its title with
/// spaces, so "Default 5h 38% · 7d 36% · 7d Fable 33%" wrapped to three lines and the whole
/// thing scrolled. Choosing a runtime closed it, and the login had to be chosen on a second
/// opening. Here the two decisions are the two things they are, in the popover the draft's other
/// choosers already stand in: the runtimes as a strip of their own marks, one width each, and
/// the logins as rows on one plate, each led by a disc ringed by that login's usage — the rings
/// the toolbar disc wears once it is chosen, so the picker is a row of the discs the bar might
/// show. The strip is a live control: tapping a runtime keeps the popover open and the rows
/// beneath follow it; tapping a login commits and closes, because that is the last thing there
/// is to say. So is a runtime that routes no login at all, and its owner closes the popover on
/// one — this view reports a choice and never decides when the surface ends.
struct MobileIdentityPicker: View {
    private enum Metrics {
        // Computed accessors, so an InjectionNext session can retune them after launch.
        /// One fixed width, and one the popover can grant; `pane` is the margin the popover
        /// keeps on each side. `MobileDraftChooser` measures the same way, for the same reason.
        static var preferredWidth: CGFloat { 356 }
        @MainActor static var width: CGFloat {
            min(
                preferredWidth,
                UIScreen.main.bounds.width
                    - 2 * MobileDesign.Spacing.pane
                    - MobileDesign.Spacing.tight
            )
        }
        /// Five runtimes fit a phone's width at one tile each; a sixth starts a second row. Fewer
        /// share the plate between them.
        static var tilesPerRow: Int { 5 }
        /// The disc a tile and a row lead with: the toolbar's own, because it is that disc.
        static var disc: CGFloat { MobileDesign.Size.compactControl }
        /// How far a long runtime name may shrink before it is clipped. "Claude Code" at the
        /// caption size is the widest name the strip carries today.
        static var nameMinimumScale: CGFloat { 0.8 }
        /// The plate the chosen tile and the chosen row stand on.
        static var selectionWash: Double { 0.12 }
        /// A login list that outgrows the room under the bar scrolls rather than being clipped.
        static var maximumAccountListHeight: CGFloat { 300 }
    }

    @Environment(\.remoteTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let agents: [RemoteAgentChoiceDTO]
    let selectedAgentID: String
    let accounts: [RemoteAccountChoiceDTO]
    let selectedAccountID: String
    /// The model the draft will start on the chosen login, for its row's rings.
    let draftModelID: String?
    let onChooseAgent: (String) -> Void
    let onChooseAccount: (String) -> Void
    @State private var feedback = UISelectionFeedbackGenerator()

    var body: some View {
        let motion: Animation? = reduceMotion
            ? nil
            : .snappy(duration: MobileDesign.Motion.controlResponse)
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            if !agents.isEmpty {
                heading(MobileL10n.string("Agent"))
                agentStrip
            }
            if !accounts.isEmpty {
                heading(MobileL10n.string("Account"))
                    .padding(.top, MobileDesign.Spacing.tight)
                accountList
            }
        }
        .padding(MobileDesign.Spacing.inset)
        .frame(width: Metrics.width)
        // The popover sizes its hosting controller from the content's ideal size; see
        // `MobileDraftChooser` for the row that was drawn over its neighbour without this.
        .fixedSize(horizontal: false, vertical: true)
        // The login rows follow the runtime: they change under the finger that chose it, on the
        // chrome's own response, and the popover's frame follows them.
        .animation(motion, value: selectedAgentID)
        .onAppear { feedback.prepare() }
        .accessibilityElement(children: .contain)
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.secondaryLabel)
            .lineLimit(1)
    }

    // MARK: - Runtimes

    private var agentStrip: some View {
        ThemedRowGroup {
            VStack(spacing: 0) {
                ForEach(
                    Array(
                        MobileIdentityPickerStrip.rows(agents, tilesPerRow: Metrics.tilesPerRow)
                            .enumerated()
                    ),
                    id: \.offset
                ) { _, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, agent in
                            if let agent {
                                agentTile(agent)
                            } else {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            .padding(MobileDesign.Spacing.tight)
        }
    }

    private func agentTile(_ agent: RemoteAgentChoiceDTO) -> some View {
        let selected = agent.id == selectedAgentID
        return Button {
            guard !selected else { return }
            feedback.selectionChanged()
            onChooseAgent(agent.id)
        } label: {
            VStack(spacing: MobileDesign.Spacing.tight) {
                ZStack {
                    Circle().fill(theme.controlResting)
                    MobileAgentMarkGlyph(
                        identity: .resolve(agent.id),
                        tint: selected ? theme.label : nil
                    )
                }
                .frame(width: Metrics.disc, height: Metrics.disc)
                .overlay {
                    // The chosen disc takes the accent as a ring rather than a fill: a brand
                    // mark keeps its own colour by design, and Claude's coral on an
                    // accent-filled disc is two brands arguing.
                    Circle()
                        .strokeBorder(theme.accent, lineWidth: MobileDesign.Size.badgeStroke)
                        .opacity(selected ? 1 : 0)
                }
                Text(agent.name)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(selected ? theme.label : theme.secondaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(Metrics.nameMinimumScale)
            }
            .padding(.vertical, MobileDesign.Spacing.small)
            .padding(.horizontal, MobileDesign.Spacing.hairline)
            .frame(maxWidth: .infinity)
            .background(
                selected ? theme.accent.opacity(Metrics.selectionWash) : Color.clear,
                in: RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agent.name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }

    // MARK: - Logins

    private var accountList: some View {
        ScrollView(.vertical) {
            ThemedRowGroup {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 {
                        ThemedRowDivider(
                            leadingInset: MobileDesign.Spacing.inset
                                + Metrics.disc
                                + MobileDesign.Spacing.medium
                        )
                    }
                    accountRow(account)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: Metrics.maximumAccountListHeight)
    }

    private func accountRow(_ account: RemoteAccountChoiceDTO) -> some View {
        let selected = account.id == selectedAccountID
        let reading = MobileIdentityPickerReading.resolve(
            account: account,
            selectedAccountID: selectedAccountID,
            draftModelID: draftModelID
        )
        let words = MobileAccountUsageWords.resolve(account: account, reading: reading)
        return Button {
            feedback.selectionChanged()
            onChooseAccount(account.id)
        } label: {
            HStack(spacing: MobileDesign.Spacing.medium) {
                MobileAccountGlyphDisc(
                    glyph: .resolve(
                        emoji: account.emoji,
                        email: account.email,
                        name: account.name
                    ),
                    reading: reading
                )

                // The text column owns the width the disc and the checkmark leave it, the way
                // `MobileDraftChooser`'s does; a spacer here measured a wrapping line one tall.
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.hairline) {
                    Text(account.name)
                        .font(.subheadline.weight(selected ? .semibold : .medium))
                        .foregroundStyle(theme.label)
                    Text(words.text)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryLabel)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.accent)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, MobileDesign.Spacing.inset)
            .padding(.vertical, MobileDesign.Spacing.small)
            .frame(minHeight: MobileDesign.Size.minimumTapTarget)
            .background(selected ? theme.accent.opacity(Metrics.selectionWash) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(account.name)
        .accessibilityValue(words.text)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }
}

// MARK: - Mobile Account Glyph Disc

/// A login as a disc: its glyph on the toolbar's own circle, ringed by its usage the way the
/// bar's disc rings the runtime's mark, so a row in the picker is the disc the bar would wear.
struct MobileAccountGlyphDisc: View {
    let glyph: MobileAccountGlyph
    let reading: MobileAccountUsageReading?
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        ZStack {
            Circle().fill(theme.controlResting)
            mark
            if let reading {
                MobileAccountUsageRings(reading: reading, theme: theme)
            }
        }
        .frame(
            width: MobileDesign.Size.compactControl,
            height: MobileDesign.Size.compactControl
        )
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        switch glyph {
        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: MobileDesign.Size.accountDiscEmoji))
        case .initial(let letter):
            Text(letter)
                .font(.system(size: MobileDesign.Size.rowMarkGlyph, weight: .semibold))
                .foregroundStyle(theme.secondaryLabel)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: MobileDesign.Size.rowMarkGlyph, weight: .medium))
                .foregroundStyle(theme.secondaryLabel)
        }
    }
}
#endif
