import Foundation

/// Test-only exporter compiled beside the exact shared leaves. Python measures the resulting
/// inks and renderer pixels independently; it does not reimplement the role-resolution policy.
@main
struct NeutralInkFixture {
    static func main() throws {
        let grounds: [(String, [Double])] = [
            ("body", [0.87, 0.87, 0.87, 1]),
            ("header", [0.78, 0.78, 0.78, 1]),
            ("selected-dark", [0.16, 0.42, 0.78, 1]),
            ("selected-pale", [0.8, 0.9, 1, 1]),
            ("actions-disabled", [0.52, 0.52, 0.52, 1]),
            ("actions-pressed", [0.25, 0.25, 0.25, 1]),
            ("actions-hover", [0.34, 0.34, 0.34, 1]),
            ("actions-normal", [0.42, 0.42, 0.42, 1])
        ]
        var cases: [[String: Any]] = []
        for (name, ground) in grounds {
            guard let ink = NeutralInk.resolve(
                on: .init(red: CGFloat(ground[0]), green: CGFloat(ground[1]),
                          blue: CGFloat(ground[2]), alpha: CGFloat(ground[3])),
                increasedContrast: false,
                readingRatio: TextLegibilityPolicy.readingRatio,
                glanceRatio: TextLegibilityPolicy.glanceRatio,
                strengthSteps: TextLegibilityPolicy.strengthSteps
            ) else { fatalError("Unresolved fixture ground: \(name)") }
            let base: Double = ink.base == .white ? 1 : 0
            func rgba(_ rung: NeutralInk.Rung) -> [Double] { [base, base, base, Double(rung.alpha)] }
            cases.append(["name": name, "ground": ground, "label": rgba(ink.label),
                          "secondary": rgba(ink.secondary), "tertiary": rgba(ink.tertiary),
                          "quaternary": rgba(ink.quaternary)])
        }
        let payload: [String: Any] = ["cases": cases,
            "readingRatio": Double(TextLegibilityPolicy.readingRatio),
            "glanceRatio": Double(TextLegibilityPolicy.glanceRatio)]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
