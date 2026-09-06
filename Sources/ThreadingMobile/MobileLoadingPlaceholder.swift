import SwiftUI

/// A surface with nothing to show yet: connecting to a session, waking a Mac, fetching a
/// document, opening an extension panel.
///
/// It fills the space it is offered and paints the theme's ground itself, because `background`
/// paints the bounds of the content it is attached to and nothing more. A spinner and a sentence
/// sized to themselves take the screen's `theme.ground` with them: the theme then arrives as a
/// plate exactly as wide as the words, standing on the navigation container's own system
/// background. That is what shipped on the session screen — a grey box around "Resuming on your
/// Mac…" in the middle of an otherwise black, unthemed screen — and the same three-line shape had
/// been copied to the attachments, attachment preview and extension-panel screens.
///
/// `ContentUnavailableView` needs none of this: it already expands to the space it is given,
/// which is why the failure state beside each of these was themed the whole time.
struct MobileLoadingPlaceholder: View {
    @Environment(\.remoteTheme) private var theme
    private let message: String
    /// A loader standing over content that is still worth seeing — a terminal reconnecting
    /// behind it — paints a small plate under its words instead of the whole ground.
    private let standsOnContent: Bool

    /// The message arrives localized. The key belongs at the call site, where the sentence is
    /// chosen, so the localization lint audits it there rather than losing it behind a view.
    init(_ message: String, standsOnContent: Bool = false) {
        self.message = message
        self.standsOnContent = standsOnContent
    }

    var body: some View {
        VStack(spacing: MobileDesign.Spacing.medium) {
            ProgressView()
                .tint(theme.accent)
            MobileMorphingTitle(
                title: message,
                textStyle: .subheadline,
                weight: .regular,
                textColor: theme.uiSecondaryLabel,
                groundColor: standsOnContent ? theme.uiFloatingSurface : theme.uiGround,
                alignment: .center,
                role: .connectionProgress
            )
            .padding(.horizontal, MobileDesign.Spacing.large)
        }
        .padding(standsOnContent ? MobileDesign.Spacing.large : 0)
        .background {
            if standsOnContent {
                RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous)
                    .fill(theme.floatingSurface.opacity(0.9))
                    .overlay {
                        RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous)
                            .stroke(theme.border, lineWidth: theme.borderWidth)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Bottom only: every screen that shows this puts it last, so the ground reaches the
        // home indicator rather than stopping on a black strip. Letting it ignore the top too
        // would let the colour rise over a sibling header drawn before it. A loader standing
        // on content paints no ground at all: the content is the ground.
        .background {
            if !standsOnContent {
                theme.ground.ignoresSafeArea(edges: .bottom)
            }
        }
    }
}
