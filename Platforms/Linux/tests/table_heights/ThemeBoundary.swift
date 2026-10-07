import AppKit

// Environment values for the exact production row host. Geometry and reuse remain in it.
enum Design {
    enum Motion {
        static let reducesMotion = true
        static let transcriptArrive: TimeInterval = 0.26
        static let lift = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    }
    enum Chat { static let arrivalRise: CGFloat = 10 }
    enum Spacing { static let inset: CGFloat = 12 }
    enum Size { static let readableWidth: CGFloat = 620 }
}
