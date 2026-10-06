import AppKit
import Foundation

@MainActor
private final class Leaf: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 100, height: 10) }
}

@main
@MainActor
enum PriorityFixture {
    static func main() {
        for count in [1, 8, 32] {
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
            let host = NSView()
            host.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(host)
            let width = host.widthAnchor.constraint(equalToConstant: 300)
            width.priority = NSLayoutConstraint.Priority(251)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                host.topAnchor.constraint(equalTo: root.topAnchor),
                host.heightAnchor.constraint(equalToConstant: 20),
                host.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor), width
            ])
            for _ in 0..<count {
                let leaf = Leaf()
                leaf.translatesAutoresizingMaskIntoConstraints = false
                leaf.setContentHuggingPriority(NSLayoutConstraint.Priority(250), for: .horizontal)
                leaf.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
                host.addSubview(leaf)
                NSLayoutConstraint.activate([
                    leaf.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    leaf.topAnchor.constraint(equalTo: host.topAnchor),
                    leaf.widthAnchor.constraint(equalTo: host.widthAnchor)
                ])
            }
            root.layoutSubtreeIfNeeded()
            require(host.frame.width, 300, "many weak constraints outweighed priority 251")
            width.constant = 55
            root.layoutSubtreeIfNeeded()
            require(host.frame.width, 55, "warm shrink traded away the higher priority")
            width.constant = 300
            root.frame.size.width = 224
            root.layoutSubtreeIfNeeded()
            require(host.frame.width, 224, "required bound lost to soft constraints")
            root.frame.size.width = 400
            root.layoutSubtreeIfNeeded()
            require(host.frame.width, 300, "warm restore lost priority precedence")
            print("PASS \(count) repeated weak constraints: higher priority, warm shrink, required bound and restore")
        }
    }

    private static func require(_ value: CGFloat, _ expected: CGFloat, _ reason: String) {
        precondition(abs(value - expected) < 0.01, "\(reason): \(value), expected \(expected)")
    }
}
