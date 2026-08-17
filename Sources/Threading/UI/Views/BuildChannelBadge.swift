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

    /// The mark for a channel, or nil for the release build that wears none.
    static func make(for channel: BuildChannel = AppInfo.buildChannel) -> NSTextField? {
        make(BuildDetails(channel: channel))
    }

    /// The same mark built from a whole set of readings, which is the form that carries the Help
    /// Tag. The channel comes **out of** the details rather than beside them: passing both let the
    /// About window ask for a release build's row and get a `DEV` mark, because the channel
    /// defaulted to the bundle's while the readings were the fixture's.
    static func make(_ details: BuildDetails) -> NSTextField? {
        guard let title = title(for: details.channel),
              let spoken = spokenName(for: details.channel) else {
            return nil
        }
        let label = NSTextField(labelWithString: title)
        // `.detail`, not `.caption`: the uppercase already carries the emphasis, and caption's
        // semibold made the mark read louder than the Settings control it sits beside.
        label.applyFont(.detail())
        label.textColor = Design.Text.secondary
        // The title is shouted for the eye; the spoken name is the honest sentence — what
        // VoiceOver reads instead of spelling an abbreviation.
        label.setAccessibilityLabel(spoken)
        // The Help Tag is the whole build, not just the sentence. Hovering three letters in a
        // footer is the one gesture anybody makes to ask what this copy of the app *is*, and it
        // was answering with a synonym for the abbreviation: "DEV" → "Development build". The
        // version, the configuration and when it was linked are what the question was after,
        // and this mark is the only thing on screen positioned to be asked.
        let helpTag = details.helpTag
        label.toolTip = helpTag
        // The same detail for whoever never sees a Help Tag. `accessibilityHelp` rather than the
        // label, so the row still announces as the mark it is rather than reciting a build.
        label.setAccessibilityHelp(helpTag)
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

    /// What the badge means, spelled out. The channel's own answer — `BuildDetails` opens its Help
    /// Tag with the same sentence, and two switches over four cases is how they come to disagree.
    static func spokenName(for channel: BuildChannel) -> String? {
        channel.spokenName
    }
}
