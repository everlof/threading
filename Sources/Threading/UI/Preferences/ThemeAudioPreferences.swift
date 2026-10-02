import AppKit

/// Host-only consent/source controls inside Motion settings. Themes own the presentation that
/// consumes the feed; they cannot replace these controls or enable capture themselves.
@MainActor
final class ThemeAudioPreferences: NSObject {
    private let settings: AppSettings
    private let service: AudioSpectrumService
    private let appEvents = AppEventObservations()
    private let toggle = ThemedToggle()
    private let source = ThemedPopUp()
    private let spectrum: AudioSpectrumView
    private var sourceSubtitle: NSTextField?
    private var statusSubtitle: NSTextField?
    private var sourceTask: Task<Void, Never>?
    private var discovered: [AudioSpectrumSource] = []
    private var isBuilt = false

    init(settings: AppSettings = .shared, service: AudioSpectrumService = .shared) {
        self.settings = settings
        self.service = service
        spectrum = AudioSpectrumView(service: service)
        super.init()
        appEvents.observe(AudioSpectrumStateDidChange.self) { [weak self] _ in self?.refresh() }
        appEvents.observe(AppSettingsDidChange.self) { [weak self] event in
            if event.affects(AppSettingIdentity.sharesThemeAudio.rawValue,
                             AppSettingIdentity.themeAudioSource.rawValue) { self?.refresh() }
        }
    }

    func section() -> NSView {
        isBuilt = true
        toggle.target = self
        toggle.action = #selector(enabledChanged)
        toggle.setAccessibilityIdentifier("motion.theme-audio-enabled")
        source.target = self
        source.action = #selector(sourceChanged)
        source.setAccessibilityIdentifier("motion.theme-audio-source")
        SettingsUI.preferControlWidth(source)
        let rescan = SettingsUI.button("Refresh", target: self, action: #selector(refreshSources))
        rescan.setAccessibilityLabel(L10n.string("Refresh audio sources"))
        let sourceControls = NSStackView(views: [source, rescan])
        sourceControls.orientation = .horizontal
        sourceControls.spacing = Design.Spacing.small
        let retry = SettingsUI.button("Retry", target: self, action: #selector(retryCapture))
        retry.setAccessibilityLabel(L10n.string("Retry audio capture"))
        let live = NSStackView(views: [spectrum, retry])
        live.orientation = .horizontal
        live.alignment = .centerY
        live.spacing = Design.Spacing.medium
        NSLayoutConstraint.activate([
            spectrum.widthAnchor.constraint(equalToConstant: Design.AudioSpectrum.size.width),
            spectrum.heightAnchor.constraint(equalToConstant: Design.AudioSpectrum.size.height)
        ])
        let card = SettingsCard(rows: [
            SettingsUI.row(title: "Music-reactive themes",
                           subtitle: "Share audio levels with themes; requires system audio permission.",
                           control: toggle),
            SettingsUI.row(title: "Audio source", subtitle: "All system audio includes calls and alerts.",
                           control: sourceControls, subtitleField: &sourceSubtitle),
            SettingsUI.row(title: "Live spectrum", subtitle: "Audio sharing is off.",
                           control: live, subtitleField: &statusSubtitle)
        ])
        refresh()
        rebuildSources()
        return SettingsUI.section("Music", card, help: SettingsUI.help(
            "Music-reactive themes",
            "Threading analyzes the selected app’s output locally. Themes receive only loudness and eight frequency bands; audio is never saved or sent to extensions.",
            "Capture runs only while a visible theme or preview needs it. Reduce Motion, Theme animations, and Low Power Mode stop music-driven decoration.",
            "Requires macOS 14.2 or later. If permission is refused, allow Threading in System Settings → Privacy & Security → Screen & System Audio Recording, then press Retry.",
            "App sources include processes with the same bundle identifier. Browser helper processes may appear separately. Some protected playback may not provide audio."
        ))
    }

    func appeared() { refreshSources() }
    func disappeared() { sourceTask?.cancel(); sourceTask = nil }

    private func refresh() {
        guard isBuilt else { return }
        toggle.state = settings.sharesThemeAudio ? .on : .off
        if #available(macOS 14.2, *) { toggle.isEnabled = true } else { toggle.isEnabled = false }
        rebuildSources()
        sourceSubtitle?.stringValue = settings.themeAudioSource == AudioSpectrumSource.systemID
            ? L10n.string("All system audio includes calls and alerts.")
            : L10n.string("Capture this app’s audio output.")
        let message: String
        switch service.state {
        case .disabled: message = L10n.string("Audio sharing is off.")
        case .unsupported: message = L10n.string("Requires macOS 14.2 or later.")
        case .waiting: message = L10n.string("Waiting for a visible music-reactive surface.")
        case .starting: message = L10n.string("Connecting to the audio source…")
        case .awaitingSamples: message = L10n.string("Waiting for audio. Check the source and system permission.")
        case .capturing: message = L10n.string("Analyzing audio locally.")
        case .sourceUnavailable: message = L10n.string("Waiting for the selected app to play audio.")
        case .failed: message = L10n.string("Capture unavailable. Check system audio permission, then Retry.")
        }
        statusSubtitle?.stringValue = toggle.isEnabled ? message : L10n.string("Requires macOS 14.2 or later.")
    }

    private func rebuildSources() {
        source.removeAllItems()
        var options = [AudioSpectrumSource(id: AudioSpectrumSource.systemID,
                                          title: L10n.string("All system audio"))] + discovered
        if !options.contains(where: { $0.id == settings.themeAudioSource }) {
            options.append(AudioSpectrumSource(id: settings.themeAudioSource,
                title: L10n.format("%@ (not running)", settings.themeAudioSource)))
        }
        for option in options { source.addItem(ThemedMenuItem(title: option.title, representedValue: option.id)) }
        source.selectItem(at: options.firstIndex { $0.id == settings.themeAudioSource } ?? 0)
    }

    @objc private func enabledChanged() { settings.sharesThemeAudio = toggle.state == .on }
    @objc private func sourceChanged() {
        guard let id = source.selectedItem?.representedValue as? String else { return }
        settings.themeAudioSource = id
    }
    @objc private func retryCapture() { service.retry() }
    @objc private func refreshSources() {
        sourceTask?.cancel()
        sourceTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sources = try await service.sources()
                guard !Task.isCancelled else { return }
                discovered = sources
                rebuildSources()
            } catch {
                // Preserve the chosen source and the last successful bounded list on failure.
                guard !Task.isCancelled else { return }
                sourceSubtitle?.stringValue = L10n.string("Audio sources could not be refreshed. Try again.")
            }
        }
    }

    var preview: AudioSpectrumView { spectrum }
}
