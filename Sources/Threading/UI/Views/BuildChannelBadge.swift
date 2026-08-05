import AppKit

/// The flavour mark in the sidebar's footer: a build that is not a release names itself —
/// NIGHTLY, BETA or DEV — beside the Settings button, so a screenshot or a bug report says
/// which kind of build produced it without the exact version being on screen. A release build
/// shows nothing: the mark exists to flag the exception, and a mark every install wore would
/// be wallpaper.
///
/// A bare label rather than a design-system component on purpose: it draws no surface and
/// takes no pointer, which is exactly the shape `docs/THEME_BOUNDARY.md` already exempts.
@MainActor
enum BuildChannelBadge {

    /// The label a channel wears, or nil for the release build that wears none.
    static func make(for channel: BuildChannel = AppInfo.buildChannel) -> NSTextField? {
        guard let title = title(for: channel), let spoken = spokenName(for: channel) else {
            return nil
        }
        let label = NSTextField(labelWithString: title)
        // `.detail`, not `.caption`: the uppercase already carries the emphasis, and caption's
        // semibold made the mark read louder than the Settings control it sits beside.
        label.applyFont(.detail())
        label.textColor = Design.Text.secondary
        // The title is shouted for the eye; the spoken name is the honest sentence — a
        // tooltip for whoever wonders what the mark means, and what VoiceOver reads instead
        // of spelling an abbreviation.
        label.toolTip = spoken
        label.setAccessibilityLabel(spoken)
        label.setAccessibilityIdentifier("sidebar.buildChannel")
        return label
    }

    /// What the badge shows. Uppercase in the source string rather than transformed, so the
    /// catalogue holds exactly what is drawn.
    static func title(for channel: BuildChannel) -> String? {
        switch channel {
        case .release: nil
        case .nightly: L10n.string("NIGHTLY")
        case .beta: L10n.string("BETA")
        case .dev: L10n.string("DEV")
        }
    }

    /// What the badge means, spelled out.
    static func spokenName(for channel: BuildChannel) -> String? {
        switch channel {
        case .release: nil
        case .nightly: L10n.string("Nightly build")
        case .beta: L10n.string("Beta build")
        case .dev: L10n.string("Development build")
        }
    }
}
