import AppKit
import Foundation
import LinuxWindowBridge

/// This deliberately occupies MainActor in SDL's native wait, as the ordinary workspace does.
/// A Task-only completion would remain queued until the test's deadline expired.
@MainActor
enum NativeUIWorkerContract {
    static func run() throws {
        let retired = try checkTextDelivery()
        try checkRetiredWake(retired)
        print("PASS native UI worker: occupied SDL wait receives full metrics/pixels, display invalidation, stale wake refusal and idle wait")
    }

    private static func checkTextDelivery() throws -> UInt64 {
        guard let native = tw_open("Threading UI worker contract", 360, 180) else {
            throw WindowFailure(String(cString: tw_error()))
        }
        defer { tw_close(native) }
        let work = NativeUIWorkLoop(window: native)
        defer { work.close() }
        let window = NSWindow(backingScaleFactor: 1)
        let label = NSTextField(wrappingLabelWithString:
            "FIRST 👩🏽‍🚀\n" + (0..<700).map { "Line \($0) 日本語 العربية\n" }.joined() + "TAIL")
        label.isSelectable = true
        label.preferredMaxLayoutWidth = 360
        label.frame = NSRect(x: 0, y: 0, width: 360, height: 180)
        window.contentView = label
        let before = window.displayRevision
        _ = label.intrinsicContentSize
        var wakes = 0
        let deadline = Date().addingTimeInterval(15)
        // A startup expose can let us drain the receipt just before the worker's wake arrives.
        // Wait for both facts rather than treating that legitimate ordering as a missing wake.
        while (!label.isCompleteTextLayoutReady || wakes == 0), Date() < deadline {
            var event = TWEvent()
            let received = tw_next_timeout(native, &event, 1_000)
            guard received >= 0 else { throw WindowFailure(String(cString: tw_error())) }
            if event.kind == 52 { wakes += 1 }
            work.drain()
        }
        guard label.isCompleteTextLayoutReady, label.intrinsicContentSize.height > 10_000,
              wakes > 0, window.displayRevision > before else {
            throw WindowFailure("complete text worker receipt: ready=\(label.isCompleteTextLayoutReady) height=\(label.intrinsicContentSize.height) wakes=\(wakes) display=\(before)->\(window.displayRevision)")
        }
        let bitmap = Bitmap(width: 360, height: 180, background: (1, 1, 1, 1))
        label.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
        while !label.isCompleteTextViewportReady, Date() < deadline {
            var event = TWEvent()
            guard tw_next_timeout(native, &event, 1_000) >= 0 else {
                throw WindowFailure(String(cString: tw_error()))
            }
            work.drain()
            label.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
        }
        guard label.isCompleteTextViewportReady else { throw WindowFailure("native loop did not deliver viewport pixels") }

        return tw_worker_wake_identity(native)
    }

    private static func checkRetiredWake(_ retired: UInt64) throws {
        guard let native = tw_open("Threading replacement window", 360, 180) else {
            throw WindowFailure(String(cString: tw_error()))
        }
        defer { tw_close(native) }
        // This window has no text job. Only the closed window's token is pushed; legitimate
        // expose/focus events remain allowed, but no retired worker wake may be admitted.
        var event = TWEvent()
        _ = tw_worker_wake(retired)
        let deadline = Date().addingTimeInterval(0.05)
        while Date() < deadline {
            let remaining = Int32(max(1, ceil(deadline.timeIntervalSinceNow * 1_000)))
            let received = tw_next_timeout(native, &event, remaining)
            guard received >= 0 else { throw WindowFailure(String(cString: tw_error())) }
            if received == 0 { return }
            if event.kind == 52 { throw WindowFailure("closed window generation admitted a worker wake") }
        }
    }
}
