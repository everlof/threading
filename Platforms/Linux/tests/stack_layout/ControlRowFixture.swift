import AppKit
import Foundation

// Only application environment facts are supplied here. ControlRow.swift itself is compiled
// unchanged from Sources/Threading/UI/Design against the Linux AppKit module.
@MainActor public enum Design {
    public enum Size {
        static let choiceHeight: CGFloat = 26
        static let fieldHeight: CGFloat = 34
    }
    public enum Spacing {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
    }
    public enum Symbol {
        public enum Role { case compact
            public var pointSize: CGFloat { 12 }
        }
        static func slot(inControlOfHeight height: CGFloat) -> CGFloat { height - 4 }
        static func role(forSlot slot: CGFloat) -> Role { .compact }
    }
}

struct AppThemeDidChange {}
@MainActor final class AppEventObservations {
    func observe<Event>(_ event: Event.Type, _ handler: @escaping (Event) -> Void) {}
}

@MainActor
private final class InkView: NSView, ControlRowMember {
    let ink: NSColor
    var adoptedHeight: CGFloat?

    init(width: CGFloat, ink: NSColor) {
        self.ink = ink
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func adopt(_ metrics: ControlRowMetrics) { adoptedHeight = metrics.height }

    override func draw(_ dirtyRect: NSRect) {
        ink.setFill()
        bounds.fill()
    }
}

@MainActor
private func approximately(_ actual: CGFloat, _ expected: CGFloat, _ name: String) {
    precondition(abs(actual - expected) < 0.05, "\(name): \(actual), expected \(expected)")
}

@main
struct ControlRowFixture {
    @MainActor static func main() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        let leading = InkView(width: 40, ink: NSColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1))
        let trailing = InkView(width: 60, ink: NSColor(srgbRed: 0.1, green: 0.2, blue: 0.8, alpha: 1))
        let row = ControlRowView(leading: [leading], trailing: [trailing])
        root.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            row.topAnchor.constraint(equalTo: root.topAnchor)
        ])

        root.layoutSubtreeIfNeeded()
        approximately(row.frame.height, 26, "row height")
        approximately(leading.frame.minX, 0, "leading control")
        approximately(trailing.frame.maxX, 300, "trailing control")
        precondition(leading.adoptedHeight == 26 && trailing.adoptedHeight == 26)

        #if os(Linux)
        let bitmap = Bitmap(width: 300, height: 80, background: (1, 1, 1, 1))
        let context = NSGraphicsContext(bitmap: bitmap, scale: 1)
        NSGraphicsContext.current = context
        root.render(in: context)
        try PNGWriter.write(bitmap, to: URL(fileURLWithPath: "out/control-row-stack.png"))
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let index = (y * bitmap.width + x) * 4
            return Array(bitmap.pixels[index..<(index + 4)])
        }
        precondition(pixel(20, 13)[0] > 180, "leading control did not render")
        precondition(pixel(270, 13)[2] > 160, "trailing control did not render")
        #endif

        leading.isHidden = true
        root.layoutSubtreeIfNeeded()
        approximately(trailing.frame.maxX, 300, "trailing control after hide")
        precondition(row.leadingViews.count == 1)
        print("production ControlRow contract passed")
    }
}
