import AppKit
import Foundation

// A one-frame renderer: build a view tree, walk it, write a PNG. Stands in for the window server,
// the run loop and the compositor, none of which the spike is asking about yet.
@MainActor
func render(_ root: NSView, scale: CGFloat = 2, background: NSColor, to path: String) throws {
    let bitmap = Bitmap(
        width: Int(root.frame.width * scale),
        height: Int(root.frame.height * scale),
        background: background.components
    )
    let context = NSGraphicsContext(bitmap: bitmap, scale: scale)
    NSGraphicsContext.current = context
    root.render(in: context)
    try PNGWriter.write(bitmap, to: URL(fileURLWithPath: path))
    print("wrote \(path) — \(bitmap.width)×\(bitmap.height)")
}

let output = ProcessInfo.processInfo.environment["SPIKE_OUT"] ?? "."
let layoutPassed = LayoutTests.run()
LayoutBenchmark.run()
try Smoke.run(into: output)
try Specimen.run(into: output)
try ConstraintSpecimen.run(into: output)
