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

// MARK: - Mobile Identity Picker Hit Test

/// Which item a point in a group belongs to.
///
/// The strip and the login list are each **one** surface with one gesture, and the item under a
/// finger is arithmetic rather than a stack of buttons. Buttons were the first shape and they
/// were wrong twice: the tappable area was each tile's own drawn frame, so the gaps between them
/// and the group's own margin swallowed touches that plainly pointed at a runtime, and a drag
/// across them did nothing at all because a button only answers the finger that lands and lifts
/// on it. Dividing the surface instead means every point inside it belongs to exactly one item,
/// including the padding around what is drawn, and a moving finger is answered continuously —
/// the same reason `MobileModelEffortPicker` hit-tests its matrix this way.
///
/// A point outside the surface returns nil so the caller can hold the last item the finger was
/// on, rather than snapping the choice to an edge the finger has already left.
enum MobileIdentityPickerHitTest {
    static func tile(
        at point: CGPoint,
        in size: CGSize,
        tilesPerRow: Int,
        count: Int
    ) -> Int? {
        guard tilesPerRow > 0, count > 0, size.width > 0, size.height > 0 else { return nil }
        guard point.x >= 0, point.x < size.width, point.y >= 0, point.y < size.height else {
            return nil
        }
        let rowCount = Int(ceil(Double(count) / Double(tilesPerRow)))
        let tileWidth = size.width / CGFloat(tilesPerRow)
        let tileHeight = size.height / CGFloat(max(rowCount, 1))
        let column = min(Int(point.x / tileWidth), tilesPerRow - 1)
        let row = min(Int(point.y / tileHeight), max(rowCount - 1, 0))
        let index = row * tilesPerRow + column
        // The last row of a wrapped strip is padded with blanks; a finger on one of those is on
        // nothing, not on the runtime that happens to be first.
        return index < count ? index : nil
    }

    static func row(at y: CGFloat, rowHeight: CGFloat, count: Int) -> Int? {
        guard rowHeight > 0, count > 0, y >= 0 else { return nil }
        let index = Int(y / rowHeight)
        return index < count ? index : nil
    }

    static func row(
        at point: CGPoint,
        in size: CGSize,
        rowHeight: CGFloat,
        count: Int
    ) -> Int? {
        guard size.width > 0, size.height > 0,
              point.x >= 0, point.x < size.width,
              point.y >= 0, point.y < size.height else { return nil }
        return row(at: point.y, rowHeight: rowHeight, count: count)
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
/// show.
///
/// Each group is one scrub surface — `mobileScrubSurface`, the modifier the model-by-effort
/// matrix stands on: tap takes the item beneath the finger, a drag makes the choice follow it
/// with a selection tick at every crossing, and the lift commits with its own thump. While a
/// finger is down the *scrubbed* item is the one that reads as chosen, and the committed login
/// keeps its checkmark throughout, so the panel says both what is current and what lifting now
/// would take.
///
/// Choosing a runtime keeps the popover open and the rows beneath follow it; choosing a login
/// commits and closes, because that is the last thing there is to say. So is a runtime that
/// routes no login at all, and its owner closes the popover on one — this view reports a choice
/// and never decides when the surface ends.
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
        /// A tile's own height. Well past the 44-point minimum because the whole cell is the
        /// target now, and because a strip of five needs the height a narrow tile loses in width.
        static var tileHeight: CGFloat { 68 }
        /// A login row's height, fixed so the surface can be divided by it.
        static var rowHeight: CGFloat { 56 }
        /// The disc a tile and a row lead with: the toolbar's own, because it is that disc.
        static var disc: CGFloat { MobileDesign.Size.compactControl }
        /// How far a long runtime name may shrink before it is clipped. "Claude Code" at the
        /// caption size is the widest name the strip carries today.
        static var nameMinimumScale: CGFloat { 0.8 }
        /// The plate the scrubbed or chosen tile and row stand on.
        static var selectionWash: Double { 0.12 }
        /// How much of a tile's width its drawn plate leaves as the group's own margin. The
        /// touch target keeps the full cell; only the paint is inset.
        static var tilePlateInset: CGFloat { MobileDesign.Spacing.tight }
        /// Logins beyond what this many rows can show scroll instead of being scrubbed: a pan
        /// inside a scroll view belongs to the scroll view, and a surface that sometimes scrolls
        /// and sometimes scrubs would answer the same drag two ways.
        static var scrubbableRows: Int { 5 }
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
    @State private var scrubbedAgentID: String?
    @State private var scrubbedAccountID: String?
    @State private var commitFeedback = UIImpactFeedbackGenerator(style: .medium)

    /// The runtime a lift would take: the one under the finger, else the one already chosen.
    private var activeAgentID: String { scrubbedAgentID ?? selectedAgentID }

    private var agentRows: [[RemoteAgentChoiceDTO?]] {
        MobileIdentityPickerStrip.rows(agents, tilesPerRow: Metrics.tilesPerRow)
    }

    private var tilesPerRow: Int { agentRows.first?.count ?? Metrics.tilesPerRow }

    private var accountsScroll: Bool { accounts.count > Metrics.scrubbableRows }

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
        .animation(motion, value: scrubbedAgentID)
        .animation(motion, value: scrubbedAccountID)
        .onAppear { commitFeedback.prepare() }
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
            GeometryReader { geometry in
                stripContent
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .mobileScrubSurface(
                        item: { agent(at: $0, in: geometry.size)?.id },
                        scrubbed: $scrubbedAgentID,
                        onCommit: choose(agent:)
                    )
            }
            .frame(height: CGFloat(agentRows.count) * Metrics.tileHeight)
        }
    }

    private var stripContent: some View {
        VStack(spacing: 0) {
            ForEach(Array(agentRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, agent in
                        if let agent {
                            agentTile(agent)
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: Metrics.tileHeight)
            }
        }
    }

    private func agentTile(_ agent: RemoteAgentChoiceDTO) -> some View {
        let active = agent.id == activeAgentID
        return VStack(spacing: MobileDesign.Spacing.tight) {
            ZStack {
                Circle().fill(theme.controlResting)
                MobileAgentMarkGlyph(
                    identity: .resolve(agent.id),
                    tint: active ? theme.label : nil
                )
            }
            .frame(width: Metrics.disc, height: Metrics.disc)
            .overlay {
                // The chosen disc takes the accent as a ring rather than a fill: a brand mark
                // keeps its own colour by design, and Claude's coral on an accent-filled disc is
                // two brands arguing.
                Circle()
                    .strokeBorder(theme.accent, lineWidth: MobileDesign.Size.badgeStroke)
                    .opacity(active ? 1 : 0)
            }
            Text(agent.name)
                .font(.caption2.weight(.medium))
                .foregroundStyle(active ? theme.label : theme.secondaryLabel)
                .lineLimit(1)
                .minimumScaleFactor(Metrics.nameMinimumScale)
        }
        // The cell is the target; the plate is inset inside it, so the margin around what is
        // drawn still answers the finger.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            active ? theme.accent.opacity(Metrics.selectionWash) : Color.clear,
            in: RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                .inset(by: Metrics.tilePlateInset)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(agent.name)
        .accessibilityAddTraits(agent.id == selectedAgentID ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { choose(agent: agent.id) }
    }

    private func agent(at point: CGPoint, in size: CGSize) -> RemoteAgentChoiceDTO? {
        MobileIdentityPickerHitTest.tile(
            at: point,
            in: size,
            tilesPerRow: tilesPerRow,
            count: agents.count
        ).map { agents[$0] }
    }

    private func choose(agent id: String) {
        commitFeedback.impactOccurred()
        commitFeedback.prepare()
        onChooseAgent(id)
    }

    // MARK: - Logins

    @ViewBuilder
    private var accountList: some View {
        if accountsScroll {
            // Too many logins to divide the surface by: the pan belongs to the scroll view, so
            // the rows answer taps only.
            ScrollView(.vertical) {
                ThemedRowGroup { accountRows(scrubbable: false) }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: CGFloat(Metrics.scrubbableRows) * Metrics.rowHeight)
        } else {
            ThemedRowGroup {
                GeometryReader { geometry in
                    accountRows(scrubbable: true)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .mobileScrubSurface(
                            item: { account(at: $0, in: geometry.size)?.id },
                            scrubbed: $scrubbedAccountID,
                            onCommit: choose(account:)
                        )
                }
                .frame(height: CGFloat(accounts.count) * Metrics.rowHeight)
            }
        }
    }

    private func accountRows(scrubbable: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 {
                    ThemedRowDivider(
                        leadingInset: MobileDesign.Spacing.inset
                            + Metrics.disc
                            + MobileDesign.Spacing.medium
                    )
                }
                let row = accountRow(account).frame(maxWidth: .infinity)
                if scrubbable {
                    // The group is the surface. A recognizer on the row — even one that did
                    // nothing — would be the child gesture, and a child gesture takes every
                    // stationary touch away from its parent; that is how the rows shipped
                    // answering a drag and not a tap.
                    row
                } else {
                    row
                        .contentShape(.interaction, Rectangle())
                        .onTapGesture { choose(account: account.id) }
                }
            }
        }
    }

    private func accountRow(_ account: RemoteAccountChoiceDTO) -> some View {
        let chosen = account.id == selectedAccountID
        // The wash follows the finger while one is down, and rests on the chosen login
        // otherwise; the checkmark stays on the chosen one throughout, so the row says both what
        // is current and what lifting now would take.
        let active = scrubbedAccountID.map { $0 == account.id } ?? chosen
        let reading = MobileIdentityPickerReading.resolve(
            account: account,
            selectedAccountID: selectedAccountID,
            draftModelID: draftModelID
        )
        let words = MobileAccountUsageWords.resolve(account: account, reading: reading)
        return HStack(spacing: MobileDesign.Spacing.medium) {
            MobileAccountGlyphDisc(
                glyph: .resolve(
                    emoji: account.emoji,
                    email: account.email,
                    name: account.name
                ),
                reading: reading,
                presentation: account.presentation
            )

            // The text column owns the width the disc and the checkmark leave it, the way
            // `MobileDraftChooser`'s does; a spacer here measured a wrapping line one line tall.
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.hairline) {
                Text(account.visibleName)
                    .font(.subheadline.weight(chosen ? .semibold : .medium))
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
                .opacity(chosen ? 1 : 0)
        }
        .padding(.horizontal, MobileDesign.Spacing.inset)
        .frame(height: Metrics.rowHeight)
        .background(active ? theme.accent.opacity(Metrics.selectionWash) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(account.name)
        .accessibilityValue(words.text)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { choose(account: account.id) }
    }

    private func account(at point: CGPoint, in size: CGSize) -> RemoteAccountChoiceDTO? {
        MobileIdentityPickerHitTest.row(
            at: point,
            in: size,
            rowHeight: Metrics.rowHeight,
            count: accounts.count
        ).map { accounts[$0] }
    }

    private func choose(account id: String) {
        commitFeedback.impactOccurred()
        commitFeedback.prepare()
        onChooseAccount(id)
    }
}

// MARK: - Mobile Account Glyph Disc

/// A login as a disc: its glyph on the toolbar's own circle, ringed by its usage the way the
/// bar's disc rings the runtime's mark, so a row in the picker is the disc the bar would wear.
struct MobileAccountGlyphDisc: View {
    let glyph: MobileAccountGlyph
    let reading: MobileAccountUsageReading?
    var presentation: RemoteSessionAccountDTO? = nil
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        ZStack {
            Circle().fill(theme.controlResting)
            if let presentation {
                MobileResolvedAccountGlyph(presentation: presentation,
                    glyphSize: MobileDesign.Size.rowMarkGlyph, emojiSize: MobileDesign.Size.accountDiscEmoji)
            } else { mark }
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
