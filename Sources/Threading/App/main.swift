import AppKit

if let promptFile = ExternalPromptEditor.requestedFile(arguments: CommandLine.arguments) {
    // Editor invocations are short-lived child processes. They must never enter the ordinary
    // application's single-instance lock, persistence startup, agent runtime or diagnostics.
    ExternalPromptEditor.run(file: promptFile)
} else {
    let processMainEntryNanoseconds = DispatchTime.now().uptimeNanoseconds
    SentryDiagnostics.startIfEnabled()
    // The subclass has to be the first thing to ask for the shared application: `NSApplication.shared`
    // instantiates whichever class it is sent to, and every later caller gets the same object.
    let app = ThreadingApplication.shared
    let delegate = AppDelegate(processMainEntryNanoseconds: processMainEntryNanoseconds)
    app.delegate = delegate
    let runsSimulatorCompatibilityProbe = SimulatorCompatibilityProbeArguments.isRequested(
        CommandLine.arguments
    )
    app.setActivationPolicy(runsSimulatorCompatibilityProbe ? .prohibited : .regular)
    if !runsSimulatorCompatibilityProbe {
        app.activate(ignoringOtherApps: true)
    }
    app.run()
}
