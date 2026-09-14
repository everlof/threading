import CoreGraphics
import Foundation
import ThreadingSimulatorKit

/// The one traversal that assigns `eN` refs, shared by the snapshot renderer (which numbers the
/// listed elements) and the resolver (which maps a ref back to an element). Keeping it in one place
/// is what makes a ref the agent saw resolve to the same element on the next read.
enum SimulatorElementListing {
    /// Roles an agent can usefully act on — used to decide which elements the default
    /// `interactive_only` listing keeps.
    static let interactiveRoles: Set<String> = [
        "AXButton", "AXTextField", "AXSecureTextField", "AXSearchField", "AXTextArea",
        "AXSwitch", "AXSlider", "AXLink", "AXCell", "AXPopUpButton", "AXCheckBox",
        "AXStepper", "AXMenuButton", "AXSegmentedControl"
    ]

    static func isListed(_ element: SimulatorAccessibilityElement, interactiveOnly: Bool) -> Bool {
        if !interactiveOnly { return true }
        if interactiveRoles.contains(element.role) { return true }
        if let label = element.label, !label.isEmpty { return true }
        if let identifier = element.identifier, !identifier.isEmpty { return true }
        return false
    }

    /// Pre-order, root excluded — the order `eN` refs are numbered in.
    static func listed(
        _ root: SimulatorAccessibilityElement,
        interactiveOnly: Bool
    ) -> [SimulatorAccessibilityElement] {
        var out: [SimulatorAccessibilityElement] = []
        func visit(_ element: SimulatorAccessibilityElement, isRoot: Bool) {
            if !isRoot, isListed(element, interactiveOnly: interactiveOnly) { out.append(element) }
            for child in element.children { visit(child, isRoot: false) }
        }
        visit(root, isRoot: true)
        return out
    }
}

/// Resolves a tap/type locator (`eN` ref, or role + label/identifier) against a fresh snapshot to a
/// normalized point, or explains why it could not — a miss or an ambiguity, never a silent guess.
enum SimulatorElementResolver {
    enum Outcome {
        /// A normalized center, top-left origin — the 0…1 point `simulator_tap` takes.
        case point(CGPoint)
        case notFound(String)
        case ambiguous(String)
    }

    static func resolve(
        _ locator: SimulatorAgentCommandService.ElementLocator,
        in root: SimulatorAccessibilityElement
    ) -> Outcome {
        let width = root.frame.width
        let height = root.frame.height
        guard width > 0, height > 0 else {
            return .notFound("The Simulator returned an empty accessibility frame.")
        }

        // Ref mode: index into the default (interactive_only) listing the snapshot numbered.
        if let ref = locator.ref, !ref.isEmpty {
            let listed = SimulatorElementListing.listed(root, interactiveOnly: true)
            guard let index = Int(ref.dropFirst()), index >= 1, index <= listed.count else {
                return .notFound(
                    "Ref \(ref) is not in the current snapshot (\(listed.count) elements). "
                        + "Re-run simulator_snapshot for fresh refs."
                )
            }
            return .point(center(of: listed[index - 1], width: width, height: height))
        }

        // Semantic mode: search the whole tree; ambiguity is a failure, not a first-match guess.
        var matches: [SimulatorAccessibilityElement] = []
        func visit(_ element: SimulatorAccessibilityElement) {
            if semanticMatch(locator, element) { matches.append(element) }
            for child in element.children { visit(child) }
        }
        visit(root)

        if matches.isEmpty {
            return .notFound(
                "\(describe(locator)) matched no element. Run simulator_snapshot to see the targets."
            )
        }
        if matches.count > 1 {
            let candidates = matches.prefix(6).map { element -> String in
                let point = center(of: element, width: width, height: height)
                return String(
                    format: "%@ \"%@\" tap=(%.3f,%.3f)",
                    element.role, element.label ?? "", point.x, point.y
                )
            }.joined(separator: "; ")
            return .ambiguous(
                "\(describe(locator)) matched \(matches.count) elements — narrow it with role or "
                    + "identifier, or tap one by coordinate: \(candidates)"
            )
        }
        return .point(center(of: matches[0], width: width, height: height))
    }

    /// How many elements a semantic locator matches — the basis for `simulator_wait` (appears when
    /// > 0, disappears when 0). Ref-based locators are not counted; waiting is semantic.
    static func matchCount(
        _ locator: SimulatorAgentCommandService.ElementLocator,
        in root: SimulatorAccessibilityElement
    ) -> Int {
        var count = 0
        func visit(_ element: SimulatorAccessibilityElement) {
            if semanticMatch(locator, element) { count += 1 }
            for child in element.children { visit(child) }
        }
        visit(root)
        return count
    }

    private static func semanticMatch(
        _ locator: SimulatorAgentCommandService.ElementLocator,
        _ element: SimulatorAccessibilityElement
    ) -> Bool {
        if let role = locator.role, !role.isEmpty,
           element.role.compare(role, options: .caseInsensitive) != .orderedSame {
            return false
        }
        if let label = locator.label, !label.isEmpty {
            let elementLabel = element.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if elementLabel.compare(
                label.trimmingCharacters(in: .whitespacesAndNewlines),
                options: .caseInsensitive
            ) != .orderedSame {
                return false
            }
        }
        // Identifiers are code identifiers: matched exactly.
        if let identifier = locator.identifier, !identifier.isEmpty, element.identifier != identifier {
            return false
        }
        return true
    }

    private static func center(
        of element: SimulatorAccessibilityElement,
        width: Double,
        height: Double
    ) -> CGPoint {
        CGPoint(x: element.frame.midX / width, y: element.frame.midY / height)
    }

    private static func describe(_ locator: SimulatorAgentCommandService.ElementLocator) -> String {
        var parts: [String] = []
        if let role = locator.role, !role.isEmpty { parts.append("role=\(role)") }
        if let label = locator.label, !label.isEmpty { parts.append("label=\"\(label)\"") }
        if let identifier = locator.identifier, !identifier.isEmpty {
            parts.append("identifier=\(identifier)")
        }
        return parts.isEmpty ? "the locator" : parts.joined(separator: " ")
    }
}
