import AppKit

let processMainEntryNanoseconds = DispatchTime.now().uptimeNanoseconds
// The subclass has to be the first thing to ask for the shared application: `NSApplication.shared`
// instantiates whichever class it is sent to, and every later caller gets the same object.
let app = ThreadingApplication.shared
let delegate = AppDelegate(processMainEntryNanoseconds: processMainEntryNanoseconds)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
