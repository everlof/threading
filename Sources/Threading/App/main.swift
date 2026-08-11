import AppKit

let processMainEntryNanoseconds = DispatchTime.now().uptimeNanoseconds
let app = NSApplication.shared
let delegate = AppDelegate(processMainEntryNanoseconds: processMainEntryNanoseconds)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
