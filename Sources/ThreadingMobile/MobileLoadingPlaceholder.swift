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

    /// The message arrives localized. The key belongs at the call site, where the sentence is
    /// chosen, so the localization lint audits it there rather than losing it behind a view.
    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        VStack(spacing: MobileDesign.Spacing.medium) {
            ProgressView()
                .tint(theme.accent)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(theme.secondaryLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, MobileDesign.Spacing.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Bottom only: every screen that shows this puts it last, so the ground reaches the
        // home indicator rather than stopping on a black strip. Letting it ignore the top too
        // would let the colour rise over a sibling header drawn before it.
        .background(theme.ground.ignoresSafeArea(edges: .bottom))
    }
}
