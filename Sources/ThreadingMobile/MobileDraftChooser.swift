import SwiftUI

#if os(iOS)
import UIKit

/// One option of a draft chooser: a name, a glyph and the line that says what it does.
struct MobileDraftChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String?
    let symbol: String
    /// Where the option sits on its scale, 0…1. The glyph's disc deepens with it, so a list of
    /// permission modes reads as a ramp of autonomy before any name is read. Nil for an option
    /// with no place on the scale, such as inheriting.
    let rank: Double?
}

/// The phone's chooser for a draft setting whose options each need a name, a glyph and a line —
/// the permission mode, the speed.
///
/// A system menu gave those options one glyph each and replaced the chosen one's glyph with a
/// checkmark, so seven permission modes were seven raised hands and the reader could not tell
/// what any of them granted. Here the rows are themed content on one plate, the way the iOS
/// dialog contract asks for a chooser, presented in the same popover surface as the model ×
/// effort picker beside it. The chosen row keeps its glyph and takes the accent; the checkmark
/// sits at the trailing edge where it eats nothing.
struct MobileDraftChooser: View {
    private enum Metrics {
        // Computed accessors, so an InjectionNext session can retune them after launch.
        static var discDiameter: CGFloat { 32 }
        /// One fixed width, and one the popover can grant. A popover measures its content at
        /// the width the content asks for and then lays it out at whatever fits the screen, so
        /// a width the phone cannot give let a three-line detail be measured two lines tall and
        /// drawn over the row beneath it. `pane` is the margin the popover keeps on each side.
        static var preferredWidth: CGFloat { 356 }
        static var width: CGFloat {
            min(
                preferredWidth,
                UIScreen.main.bounds.width - 2 * MobileDesign.Spacing.pane - MobileDesign.Spacing.tight
            )
        }
        /// How deep the glyph disc's accent wash gets at the top of the scale.
        static var washMaximum: Double { 0.45 }
        /// The plate the chosen row stands on, over the group's own panel.
        static var selectionWash: Double { 0.12 }
        /// A list that outgrows the room above the chip scrolls rather than being clipped.
        static var maximumListHeight: CGFloat { 520 }
    }

    @Environment(\.remoteTheme) private var theme
    let title: String
    let choices: [MobileDraftChoice]
    let selectedID: String
    let onChoose: (String) -> Void
    @State private var feedback = UISelectionFeedbackGenerator()

    var body: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryLabel)
                .lineLimit(1)

            ScrollView(.vertical) {
                ThemedRowGroup {
                    ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                        if index > 0 {
                            ThemedRowDivider(
                                leadingInset: MobileDesign.Spacing.inset
                                    + Metrics.discDiameter
                                    + MobileDesign.Spacing.medium
                            )
                        }
                        row(choice)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: Metrics.maximumListHeight)
        }
        .padding(MobileDesign.Spacing.inset)
        .background(theme.floatingSurface)
        .overlay {
            RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous)
                .strokeBorder(theme.border, lineWidth: max(theme.borderWidth, 1))
        }
        .frame(width: Metrics.width)
        // The popover sizes its hosting controller from the content's ideal size. Without this,
        // that measurement proposes every row an unbounded width, each detail measures one line
        // tall, and a wrapped one is drawn over the row beneath it.
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { feedback.prepare() }
        .accessibilityElement(children: .contain)
    }

    private func row(_ choice: MobileDraftChoice) -> some View {
        let selected = choice.id == selectedID
        let rank = choice.rank ?? 0
        return Button {
            feedback.selectionChanged()
            onChoose(choice.id)
        } label: {
            HStack(spacing: MobileDesign.Spacing.medium) {
                ZStack {
                    Circle().fill(selected ? theme.accent : theme.controlResting)
                    if !selected {
                        Circle().fill(theme.accent.opacity(rank * Metrics.washMaximum))
                    }
                    Image(systemName: choice.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(
                            selected
                                ? theme.accentForeground
                                : (rank > 0.5 ? theme.accent : theme.secondaryLabel)
                        )
                }
                .frame(width: Metrics.discDiameter, height: Metrics.discDiameter)

                // The text column owns the width the disc and the checkmark leave it. Beside a
                // spacer, a wrapping detail was measured one line tall and drawn four, over
                // the rows beneath it.
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.hairline) {
                    Text(choice.name)
                        .font(.subheadline.weight(selected ? .semibold : .medium))
                        .foregroundStyle(theme.label)
                    if let detail = choice.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(theme.secondaryLabel)
                    }
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
        .accessibilityLabel(choice.name)
        .accessibilityValue(choice.detail ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }
}

/// The glyph and the place on the autonomy scale of each shared permission mode.
///
/// The ids are Claude's own flag values, which every provider's mode list is expressed in; an
/// id this table does not know draws a neutral ring and stands off the scale rather than
/// borrowing a neighbour's meaning.
enum MobilePermissionModeGlyph {
    private static let scale: [(id: String, symbol: String)] = [
        ("manual", "hand.raised"),
        ("plan", "map"),
        ("acceptEdits", "square.and.pencil"),
        ("auto", "wand.and.stars"),
        ("dontAsk", "hand.raised.slash"),
        ("bypassPermissions", "lock.open"),
    ]

    static let inheritSymbol = "arrow.triangle.branch"
    static let unsetSymbol = "hand.raised"

    static func symbol(for modeID: String) -> String {
        scale.first { $0.id == modeID }?.symbol ?? "circle.dashed"
    }

    static func rank(for modeID: String) -> Double? {
        guard let index = scale.firstIndex(where: { $0.id == modeID }) else { return nil }
        return Double(index) / Double(max(scale.count - 1, 1))
    }
}
#endif
