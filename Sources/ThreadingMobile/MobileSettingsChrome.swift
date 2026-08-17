import SwiftUI

/// The chrome a phone settings surface wears so that it belongs to the Mac's theme.
///
/// Hiding a `List`'s *scroll* background is only half of the job. iOS still paints every grouped
/// row from `secondarySystemGroupedBackground` and every hairline from `separator`, and those are
/// system greys with no relationship to an authored theme. So each destination that had reached
/// only for `.scrollContentBackground(.hidden)` — Terminal Keys and its four editors,
/// Notifications, Diagnostics, Mac appearance, Ask for input, the issue report — drew a slab of
/// unrelated grey directly on the theme's own ground. That is what "unthemed" looked like on a
/// phone: the page was right and everything standing on it was not.
///
/// `ThemedSettingsSection` is what those screens use in place of `Section`. It *is* a `Section`,
/// so inset-grouped geometry, swipe to delete and `EditButton` reordering keep working; only the
/// colours stop coming from UIKit. `themedSettingsPage` is the page around it, including the
/// navigation bar, which drifted the same way — four of the five key-bar screens had a bare bar
/// over a themed body.
///
/// `ThemedSettingsGroup` in `MobileSettingsView` remains the vocabulary for a screen assembled
/// out of a plain `ScrollView`. A screen picks one or the other: a `List` when its rows are
/// editable or externally sized, the group when the form is a small fixed shape.
///
/// `scripts/check_mobile_theme_boundaries.py` fails the build on a `Section` that is a direct
/// child of a `List` or `Form` anywhere in this target, which is the drift this file exists to
/// end.
struct ThemedSettingsSection<Content: View, Header: View, Footer: View>: View {
    @Environment(\.remoteTheme) private var theme

    private let content: Content
    private let header: Header
    private let footer: Footer

    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer
    ) {
        self.content = content()
        self.header = header()
        self.footer = footer()
    }

    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header
    ) where Footer == EmptyView {
        self.init(content: content, header: header, footer: { EmptyView() })
    }

    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) where Header == EmptyView {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }

    init(@ViewBuilder content: () -> Content) where Header == EmptyView, Footer == EmptyView {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }

    var body: some View {
        Section {
            content
        } header: {
            // A settings group is titled the way `MobileSettingsView`'s cards are titled, rather
            // than in UIKit's small uppercase, so the two idioms read as one screen.
            header
                .font(.headline)
                .foregroundStyle(theme.label)
                .textCase(nil)
        } footer: {
            footer
                .font(.footnote)
                .foregroundStyle(theme.secondaryLabel)
        }
        .listRowBackground(theme.panel)
        .listRowSeparatorTint(theme.divider)
    }
}

extension View {
    /// The themed page under a `List` or `Form`: the theme's ground instead of the system's
    /// grouped background, and a navigation bar in the surface role rather than whatever UIKit
    /// would blur through from the content.
    func themedSettingsPage(_ theme: RemoteThemePalette) -> some View {
        scrollContentBackground(.hidden)
            .background(theme.ground)
            .toolbarBackground(theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }

    /// A themed row plate for a `List` that is not built from `ThemedSettingsSection` — a plain
    /// list of externally sized content, where rows sit directly on the page rather than in a
    /// grouped card.
    func themedSettingsRow(_ theme: RemoteThemePalette) -> some View {
        listRowBackground(theme.surface)
            .listRowSeparatorTint(theme.divider)
    }
}
