import AppKit

// Environment values for the exact production row host. Geometry and reuse remain in it.
enum Design {
    enum Motion {
        static let reducesMotion = true
        static let transcriptArrive: TimeInterval = 0.26
        static let lift = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    }
    enum Chat {
        static let arrivalRise: CGFloat = 10
        // The fixture has no user font scale; production's default is 14pt × 52em.
        static let columnWidth: CGFloat = 14 * 52
    }
    enum Spacing { static let inset: CGFloat = 12 }
    enum Size { static let readableWidth: CGFloat = 620 }
}

// This harness measures row geometry only. Text selection belongs to the full conversation
// shell, so these compile-only ports keep its unrelated interaction path out of the fixture.
final class TranscriptTextSelection {
    func track(mouseDown: NSEvent) {}
    func track(mouseDragged: NSEvent) {}
    func track(mouseUp: NSEvent) {}
}

enum TranscriptTextSegments {
    static func isText(_ view: NSView, within host: NSView) -> Bool { false }
}
