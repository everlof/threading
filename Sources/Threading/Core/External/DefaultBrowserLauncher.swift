import AppKit

/// Opens local documents in the user's default web browser, independently of each file type's
/// LaunchServices association.
///
/// A `.html` file may be associated with an editor, so `NSWorkspace.open(_:)` cannot implement an
/// action that specifically promises a browser. The default handler for an HTTPS URL is the
/// browser choice macOS owns; this resolves that application, then hands the local files to it.
@MainActor
enum DefaultBrowserLauncher {
    @discardableResult
    static func open(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty,
              let probeURL = URL(string: DefaultBrowserLauncherDefaults.handlerProbeAddress),
              let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: probeURL) else {
            SystemAlert.refuse()
            ThreadingLogger.browser.error("No default browser is registered")
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { _, error in
            guard let error else { return }
            Task { @MainActor in
                SystemAlert.refuse()
                ThreadingLogger.browser.error(
                    "Could not open local document in the default browser: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        return true
    }
}

private enum DefaultBrowserLauncherDefaults {
    static let handlerProbeAddress = "https://threading.codes"
}
