import SwiftUI
import ThreadingRemoteKit

#if os(iOS)
/// The row of quoted terminal lines waiting to go into the next message.
///
/// Each chip stands for one selection the person added from the terminal's edit menu and can
/// be taken back with its ×, which is the whole of "cancel selection" here: the selection in
/// the buffer was cleared when the quote was taken, because the buffer keeps moving under it
/// and the chip is what actually gets sent. The tray has two homes. Under a direct-input TUI
/// it stands alone above the key bar with an insert control, the way staged attachments do,
/// because the TUI owns the line and the person decides when the quotes land at its cursor.
/// Inside the independent composer the quotes ride with the draft and Send delivers both.
struct TerminalSelectionQuoteTray: View {
    struct Insert {
        let isEnabled: Bool
        let action: () -> Void
    }

    enum Placement {
        case standalone(insert: Insert)
        case inComposer
    }

    let quotes: [RemoteTerminalSelectionQuote]
    let placement: Placement
    let remove: (UUID) -> Void
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MobileDesign.Spacing.small) {
                    ForEach(quotes) { quote in
                        chip(for: quote)
                    }
                }
            }
            if case .standalone(let insert) = placement {
                Button(action: insert.action) {
                    Image(systemName: "text.insert")
                        .font(.headline)
                        .frame(
                            width: MobileDesign.Size.minimumTapTarget,
                            height: MobileDesign.Size.minimumTapTarget
                        )
                        .background(
                            insert.isEnabled ? theme.accent : theme.controlResting,
                            in: RoundedRectangle(cornerRadius: theme.controlRadius)
                        )
                        .foregroundStyle(insert.isEnabled ? theme.ground : theme.secondaryLabel)
                }
                .disabled(!insert.isEnabled)
                .accessibilityLabel(MobileL10n.string("Insert into prompt"))
            }
        }
        .padding(.horizontal, MobileDesign.Spacing.inset)
        .padding(.vertical, MobileDesign.Spacing.small)
        .background(standsAlone ? theme.panel : Color.clear)
        .overlay(alignment: .top) {
            if standsAlone {
                Rectangle().fill(theme.divider).frame(height: theme.borderWidth)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(MobileL10n.string("Quoted terminal lines"))
    }

    private var standsAlone: Bool {
        if case .standalone = placement { return true }
        return false
    }

    private func chip(for quote: RemoteTerminalSelectionQuote) -> some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            Image(systemName: "text.quote")
                .font(.caption)
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(lineCountLabel(for: quote))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.label)
                Text(quote.preview)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.secondaryLabel)
                    .lineLimit(1)
            }
            .frame(maxWidth: TerminalSelectionQuoteMetrics.maximumChipTextWidth, alignment: .leading)
            Button {
                remove(quote.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(theme.label)
                    .frame(
                        width: TerminalSelectionQuoteMetrics.removeTarget,
                        height: TerminalSelectionQuoteMetrics.removeTarget
                    )
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(MobileL10n.string("Remove quoted lines"))
        }
        .padding(.leading, MobileDesign.Spacing.medium)
        .padding(.trailing, MobileDesign.Spacing.tight)
        .frame(height: MobileDesign.Size.minimumTapTarget)
        .background(theme.controlResting, in: RoundedRectangle(cornerRadius: theme.controlRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(lineCountLabel(for: quote))
        .accessibilityValue(quote.preview)
    }

    private func lineCountLabel(for quote: RemoteTerminalSelectionQuote) -> String {
        quote.lineCount == 1
            ? MobileL10n.string("1 line")
            : MobileL10n.string("%lld lines", Int64(quote.lineCount))
    }
}

enum TerminalSelectionQuoteMetrics {
    static let maximumChipTextWidth: CGFloat = 220
    static let removeTarget: CGFloat = 32
}
#endif
