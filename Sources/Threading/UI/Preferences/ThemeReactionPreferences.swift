import AppKit

/// The Threading-wide **Reaction strength** inside Motion settings: one scale on how strongly
/// themes and extensions answer agent activity and music (`ThemeReactions`). Each theme authors
/// its own response; this is the person's say over all of them, so it is host-only and no theme
/// or pack carries a value for it.
@MainActor
final class ThemeReactionPreferences: NSObject {

    private enum Layout {
        /// Long enough that a 10% step is a visible move of the knob.
        static let scrubberWidth: CGFloat = 180
    }

    private let settings: AppSettings
    private let appEvents = AppEventObservations()
    private let scrubber = ThemedScrubber(frame: .zero)
    private let reading = SettingsUI.note("", localizes: false)
    private var isBuilt = false

    init(settings: AppSettings = .shared) {
        self.settings = settings
        super.init()
        appEvents.observe(AppSettingsDidChange.self) { [weak self] event in
            if event.affects(AppSettingIdentity.themeReactionStrength.rawValue) { self?.refresh() }
        }
    }

    func section() -> NSView {
        isBuilt = true
        scrubber.setAccessibilityIdentifier("motion.theme-reaction-strength")
        scrubber.setAccessibilityLabel(L10n.string("Reaction strength"))
        scrubber.onChange = { [weak self] fraction in self?.commit(fraction) }
        reading.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            scrubber.widthAnchor.constraint(equalToConstant: Layout.scrubberWidth)
        ])
        let card = SettingsCard(rows: [
            SettingsUI.row(
                title: "Reaction strength",
                subtitle: "How strongly themes and extensions answer agent activity and music. "
                    + "Each theme chooses its own response; 0% holds it still and 200% doubles it.",
                control: SettingsUI.controlGroup([scrubber, reading])
            )
        ])
        refresh()
        return SettingsUI.section("Reactions", card, help: SettingsUI.help(
            "Reaction strength",
            "Some themes and extensions move with what the app is doing: particles that stream "
                + "faster while agents work, rain that thickens, spectra that follow the music.",
            "This scales all of them at once. It changes only decoration — working counts, "
                + "statuses and notifications stay exactly as they are — and it never starts "
                + "audio capture. Reduce Motion and Theme animations still stop the motion."
        ))
    }

    private func refresh() {
        guard isBuilt else { return }
        let percent = settings.themeReactionStrength
        scrubber.value = Double(percent) / Double(ThemeReactionDefaults.strengthPercentRange.upperBound)
        let spoken = L10n.format("%lld percent", Int64(percent))
        scrubber.spokenValue = spoken
        reading.stringValue = "\(percent)%"
    }

    /// Lands on whole tens: the scale is a feel, and a reading of 137% says nothing 140% does not.
    private func commit(_ fraction: Double) {
        let upper = Double(ThemeReactionDefaults.strengthPercentRange.upperBound)
        let percent = Int((fraction * upper / 10).rounded()) * 10
        guard percent != settings.themeReactionStrength else { return }
        settings.themeReactionStrength = percent
    }
}
