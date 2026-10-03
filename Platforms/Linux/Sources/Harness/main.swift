import AppKit
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

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
if !LayoutTests.run() || !LayoutRegionTests.run() || !BackingAlignmentTests.run() {
    fflush(nil)
    exit(1)
}
// Correctness and rendering smoke runs have their own bound; keep the scaling curve opt-out.
if ProcessInfo.processInfo.environment["SPIKE_SKIP_LAYOUT_BENCHMARK"] != "1" {
    LayoutBenchmark.run()
}
try Smoke.run(into: output)
try Specimen.run(into: output)
try ConstraintSpecimen.run(into: output)
