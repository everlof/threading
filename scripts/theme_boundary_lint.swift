import Foundation
import SwiftParser
import SwiftSyntax

struct Policy: Decodable {
    struct Exception: Decodable {
        let path: String
        let kind: String
        let symbol: String
        let reason: String
    }

    let bannedTypes: [String: String]
    let allowedTextFieldLabels: Set<String>
    let bannedFactories: [String: String]
    let interactiveComponentDirectories: [String]
    let interactiveBaseTypes: Set<String>
    let fontFactories: Set<String>
    let systemChromeContractDirectories: [String]
    let systemChromeContractTypes: Set<String>
    let implementationBanDirectories: [String]
    let implementationBannedTypes: [String: String]
    let windowControllerDirectories: [String]
    let windowControllerBaseType: String
    let motionDirectories: [String]
    let motionDurationNamespace: String
    let systemColors: Set<String>
    let confirmationResponses: Set<String>
    let confirmationGateDirectories: [String]
    let exceptions: [Exception]

    func permits(path: String, kind: String, symbol: String) -> Bool {
        exceptions.contains {
            $0.path == path && $0.kind == kind && ($0.symbol == symbol || $0.symbol == "*")
        }
    }
}

struct Offence: Comparable {
    let path: String
    let line: Int
    let column: Int
    let kind: String
    let message: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.path, lhs.line, lhs.column, lhs.kind, lhs.message)
            < (rhs.path, rhs.line, rhs.column, rhs.kind, rhs.message)
    }
}

final class BoundaryVisitor: SyntaxVisitor {
    private let policy: Policy
    private let relativePath: String
    private let converter: SourceLocationConverter
    private var aliases: [String: String] = [:]
    private(set) var offences: [Offence] = []

    init(policy: Policy, relativePath: String, tree: SourceFileSyntax) {
        self.policy = policy
        self.relativePath = relativePath
        converter = SourceLocationConverter(fileName: relativePath, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        let target = terminalTypeName(node.initializer.value.trimmedDescription)
        if replacement(for: target) != nil {
            aliases[node.name.text] = target
            report(
                node: node,
                kind: "alias",
                symbol: target,
                message: "typealias \(node.name.text) hides banned AppKit type \(target); "
                    + "use \(replacement(for: target) ?? "its UI/Design replacement") directly"
            )
        }
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if let inherited = node.inheritanceClause?.inheritedTypes {
            for item in inherited {
                let written = terminalTypeName(item.type.trimmedDescription)
                let resolved = aliases[written] ?? written
                guard let replacement = replacement(for: resolved) else { continue }
                report(
                    node: item.type,
                    kind: "inherit",
                    symbol: resolved,
                    message: "subclassing \(resolved) bypasses the themed boundary; "
                        + "subclass \(replacement) instead"
                )
            }
        }

        checkInteractiveContract(node)
        checkThemedControlAccessibilityContract(node)
        checkWindowControllerContract(node)
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard let type = binding.typeAnnotation?.type.trimmedDescription else { continue }
            if checksSystemChromeContracts, !isPrivate(node.modifiers) {
                checkSystemChromeContract(type: type, node: binding)
            }
            checkImplementationType(type: type, node: binding)
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        for parameter in node.signature.parameterClause.parameters {
            let type = parameter.type.trimmedDescription
            if checksSystemChromeContracts, !isPrivate(node.modifiers) {
                checkSystemChromeContract(type: type, node: parameter.type)
            }
            checkImplementationType(type: type, node: parameter.type)
        }
        if let returnType = node.signature.returnClause?.type {
            let type = returnType.trimmedDescription
            if checksSystemChromeContracts, !isPrivate(node.modifiers) {
                checkSystemChromeContract(type: type, node: returnType)
            }
            checkImplementationType(type: type, node: returnType)
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let arguments = node.arguments

        if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            checkConstruction(
                writtenName: reference.baseName.text,
                firstArgumentLabel: arguments.first?.label?.text,
                node: node
            )
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let memberName = member.declName.baseName.text
            let base = member.base?.trimmedDescription ?? ""
            let baseName = terminalTypeName(base)

            if policy.fontFactories.contains(memberName),
               base.isEmpty || baseName == "NSFont" {
                report(
                    node: node,
                    kind: "fontFactory",
                    symbol: memberName,
                    message: "\(memberName) chooses typography in feature code; "
                        + "read a semantic Design.Typography role"
                )
            }

            if memberName == "init" {
                checkConstruction(writtenName: baseName, firstArgumentLabel: arguments.first?.label?.text, node: node)
            } else if replacement(for: memberName) != nil {
                // `AppKit.NSButton(...)`.
                checkConstruction(writtenName: memberName, firstArgumentLabel: arguments.first?.label?.text, node: node)
            }

            let factoryOwner = aliases[baseName] ?? baseName
            let factory = "\(factoryOwner).\(memberName)"
            if let replacement = policy.bannedFactories[factory] {
                report(
                    node: node,
                    kind: "factory",
                    symbol: factory,
                    message: "\(factory) returns stock AppKit chrome; use \(replacement)"
                )
            }
        }

        return .visitChildren
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        guard let type = node.typeAnnotation?.type,
              let call = node.initializer?.value.as(FunctionCallExprSyntax.self),
              let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              member.base == nil,
              member.declName.baseName.text == "init"
        else { return .visitChildren }

        let written = terminalTypeName(type.trimmedDescription)
        let resolved = aliases[written] ?? written
        guard let replacement = replacement(for: resolved) else { return .visitChildren }
        report(
            node: call,
            kind: "construct",
            symbol: resolved,
            message: "inferred .init() constructs \(resolved); use "
                + replacement
        )
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let member = node.declName.baseName.text

        // An informational alert never inspects its response — only a decision reads one. That
        // makes this the precise signal for "a confirmation was built here", whether the source
        // uses the old AppKit response names or ThemedAlert's app-owned response base. Must run
        // before the system-colour guard below, which returns early.
        if policy.confirmationResponses.contains(member), !isConfirmationGate {
            let responseBase = node.base?.trimmedDescription
            if responseBase == nil
                || responseBase == "NSApplication.ModalResponse"
                || responseBase == "AppKit.NSApplication.ModalResponse"
                || responseBase == "ThemedAlert" {
                report(
                    node: node,
                    kind: "confirmationResponse",
                    symbol: member,
                    message: "reading \(member) means an alert is asking a question; build it "
                        + "through ConfirmationAlert so the prompt is registered in "
                        + "ConfirmationPrompt and states whether it may be switched off"
                )
            }
        }

        guard policy.systemColors.contains(member) else { return .visitChildren }

        let base = node.base?.trimmedDescription
        guard base == nil || base == "NSColor" || base == "AppKit.NSColor" else {
            return .visitChildren
        }
        report(
            node: node,
            kind: "systemColor",
            symbol: member,
            message: "system colour \(member) bypasses the app theme; read a semantic Design role"
        )
        return .visitChildren
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        guard let assignment = elements.firstIndex(where: { $0.is(AssignmentExprSyntax.self) }),
              assignment > 0,
              assignment + 1 < elements.count
        else { return .visitChildren }

        let left = elements[..<assignment].map(\.trimmedDescription).joined()
        let right = elements[(assignment + 1)...].map(\.trimmedDescription).joined()
        if right.contains(".cgColor") {
            let properties = ["backgroundColor", "borderColor", "shadowColor", "strokeColor", "fillColor"]
            if let property = properties.first(where: { left.hasSuffix(".\($0)") }) {
                report(
                    node: node,
                    kind: "frozenLayerColor",
                    symbol: property,
                    message: "\(property) stores a frozen CGColor; "
                        + "use the refresh-aware NSView layer-colour helper"
                )
            }
        }

        if checksMotionContracts,
           left.hasSuffix(".duration"),
           !right.contains(policy.motionDurationNamespace) {
            report(
                node: node,
                kind: "motionDuration",
                symbol: "duration",
                message: "animation duration bypasses \(policy.motionDurationNamespace); "
                    + "Reduce Motion would leave it running"
            )
        }
        return .visitChildren
    }

    private func checkConstruction(
        writtenName: String,
        firstArgumentLabel: String?,
        node: some SyntaxProtocol
    ) {
        let name = aliases[writtenName] ?? terminalTypeName(writtenName)
        guard let replacement = replacement(for: name) else { return }
        if name == "NSTextField", let firstArgumentLabel,
           policy.allowedTextFieldLabels.contains(firstArgumentLabel) {
            return
        }
        report(
            node: node,
            kind: "construct",
            symbol: name,
            message: "constructing \(name) bypasses the themed boundary; use \(replacement)"
        )
    }

    /// An app-owned component that handles pointer activation is a control even if its author
    /// happened to subclass `NSView`. Requiring the control base keeps keyboard, enabled-state,
    /// focus, and accessibility behavior from becoming optional details.
    private func checkInteractiveContract(_ node: ClassDeclSyntax) {
        guard policy.interactiveComponentDirectories.contains(where: {
            relativePath == $0 || relativePath.hasPrefix("\($0)/")
        }) else { return }

        let handlesPointerActivation = node.memberBlock.members.contains { member in
            guard let function = member.decl.as(FunctionDeclSyntax.self) else { return false }
            return function.name.text == "mouseDown" || function.name.text == "mouseUp"
        }
        guard handlesPointerActivation else { return }

        let inherited = Set(node.inheritanceClause?.inheritedTypes.map {
            terminalTypeName($0.type.trimmedDescription)
        } ?? [])
        guard inherited.isDisjoint(with: policy.interactiveBaseTypes) else { return }

        let requiredBases = policy.interactiveBaseTypes.sorted().joined(separator: " or ")
        report(
            node: node,
            kind: "interactiveComponent",
            symbol: node.name.text,
            message: "\(node.name.text) handles pointer activation from a plain view; "
                + "subclass \(requiredBases) "
                + "so keyboard, focus, enabled state, and accessibility remain part of the contract"
        )
    }

    /// The base supplies keyboard focus, activation routing and enabled state, but it cannot
    /// guess whether a concrete control is a button, checkbox, or pop-up. Require every direct
    /// subclass to state its semantic role and accessibility action.
    private func checkThemedControlAccessibilityContract(_ node: ClassDeclSyntax) {
        guard policy.interactiveComponentDirectories.contains(where: {
            relativePath == $0 || relativePath.hasPrefix("\($0)/")
        }) else { return }

        let inherited = Set(node.inheritanceClause?.inheritedTypes.map {
            terminalTypeName($0.type.trimmedDescription)
        } ?? [])
        guard !inherited.isDisjoint(with: policy.interactiveBaseTypes) else { return }

        let functions = Set(node.memberBlock.members.compactMap {
            $0.decl.as(FunctionDeclSyntax.self)?.name.text
        })
        let required = ["accessibilityRole", "accessibilityPerformPress"]
        for function in required where !functions.contains(function) {
            report(
                node: node,
                kind: "accessibilityContract",
                symbol: function,
                message: "\(node.name.text) does not implement \(function); "
                    + "a themed control must expose its semantic role and primary action"
            )
        }
    }

    /// Every top-level app window inherits the same delayed runtime audit. Making that a source
    /// contract means a newly added window cannot silently omit the audit by forgetting a call.
    private func checkWindowControllerContract(_ node: ClassDeclSyntax) {
        guard policy.windowControllerDirectories.contains(where: {
            relativePath == $0 || relativePath.hasPrefix("\($0)/")
        }) else { return }

        let inherited = Set(node.inheritanceClause?.inheritedTypes.map {
            terminalTypeName($0.type.trimmedDescription)
        } ?? [])
        guard inherited.contains("NSWindowController") else { return }
        guard node.name.text != policy.windowControllerBaseType else { return }

        report(
            node: node,
            kind: "windowController",
            symbol: node.name.text,
            message: "\(node.name.text) bypasses whole-window runtime auditing; "
                + "subclass \(policy.windowControllerBaseType)"
        )
    }

    private var checksSystemChromeContracts: Bool {
        policy.systemChromeContractDirectories.contains {
            relativePath == $0 || relativePath.hasPrefix("\($0)/")
        }
    }

    private var checksImplementationBans: Bool {
        policy.implementationBanDirectories.contains {
            relativePath == $0 || relativePath.hasPrefix("\($0)/")
        }
    }

    private var checksMotionContracts: Bool {
        policy.motionDirectories.contains {
            relativePath == $0 || relativePath.hasPrefix("\($0)/")
        }
    }

    private var isConfirmationGate: Bool {
        policy.confirmationGateDirectories.contains {
            relativePath == $0 || relativePath.hasPrefix("\($0)/")
        }
    }

    private func isPrivate(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains {
            $0.name.text == "private" || $0.name.text == "fileprivate"
        }
    }

    /// A design component may contain system chrome, but its callers must not build against
    /// that system type. Private implementation details are the containment boundary.
    private func checkSystemChromeContract(type: String, node: some SyntaxProtocol) {
        for forbidden in policy.systemChromeContractTypes where containsType(forbidden, in: type) {
            report(
                node: node,
                kind: "systemChromeContract",
                symbol: forbidden,
                message: "\(forbidden) escapes a UI/Design component contract; "
                    + "expose a semantic app-owned model and keep system chrome private"
            )
        }
    }

    /// App-owned design components may not quietly fall back to the system dropdown stack.
    /// Unlike contract checking, this includes private declarations: the visible implementation
    /// itself is the thing being protected.
    private func checkImplementationType(type: String, node: some SyntaxProtocol) {
        guard checksImplementationBans else { return }
        for (forbidden, replacement) in policy.implementationBannedTypes
        where containsType(forbidden, in: type) {
            report(
                node: node,
                kind: "implementationType",
                symbol: forbidden,
                message: "\(forbidden) is forbidden inside an app-owned design component; "
                    + "use \(replacement)"
            )
        }
    }

    private func replacement(for type: String) -> String? {
        if let replacement = policy.bannedTypes[type] {
            return replacement
        }
        if checksImplementationBans {
            return policy.implementationBannedTypes[type]
        }
        return nil
    }

    private func containsType(_ name: String, in written: String) -> Bool {
        let parts = written.split { !$0.isLetter && !$0.isNumber && $0 != "_" }
        return parts.contains(Substring(name))
    }

    private func report(
        node: some SyntaxProtocol,
        kind: String,
        symbol: String,
        message: String
    ) {
        guard !policy.permits(path: relativePath, kind: kind, symbol: symbol) else { return }
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        offences.append(
            Offence(
                path: relativePath,
                line: location.line,
                column: location.column,
                kind: kind,
                message: message
            )
        )
    }

    private func terminalTypeName(_ written: String) -> String {
        written
            .split(separator: ".")
            .last
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "?! ")) ?? written
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("theme-boundary: \(message)\n".utf8))
    exit(2)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: theme_boundary_lint <repo-root> <policy.json>")
}

// FileManager may enumerate through a resolved path even when the caller reached the checkout
// through a symlink (`/var` -> `/private/var` on macOS). Resolve both ends before deriving
// repository-relative paths, or exact policy exceptions silently stop matching.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
    .standardizedFileURL
    .resolvingSymlinksInPath()
let policyURL = URL(fileURLWithPath: CommandLine.arguments[2])
    .standardizedFileURL
    .resolvingSymlinksInPath()
let decoder = JSONDecoder()

let policy: Policy
do {
    policy = try decoder.decode(Policy.self, from: Data(contentsOf: policyURL))
} catch {
    fail("cannot read \(policyURL.path): \(error)")
}

func lint(source: String, path: String, policy: Policy) -> [Offence] {
    let tree = Parser.parse(source: source)
    let visitor = BoundaryVisitor(policy: policy, relativePath: path, tree: tree)
    visitor.walk(tree)
    return visitor.offences
}

/// Pins the syntax forms that motivated moving beyond regexes. A toolchain update that changes
/// SwiftSyntax's tree shape must fail the build here rather than silently weakening the policy.
func verifyChecker(_ policy: Policy) {
    let path = "Tests/ThemeBoundaryCheckerFixture.swift"
    let violations: [(String, String)] = [
        ("let value = NSButton()", "construct"),
        ("let value = AppKit.NSButton()", "construct"),
        ("let value = NSButton.init(frame: .zero)", "construct"),
        ("let value: NSButton = .init()", "construct"),
        ("final class RawButton: NSButton {}", "inherit"),
        ("typealias RawButton = NSButton", "alias"),
        ("let value = NSTextView.scrollableTextView()", "factory"),
        ("let value = NSColor.labelColor", "systemColor"),
        ("let value = NSColor.placeholderTextColor", "systemColor"),
        ("let value = NSFont.systemFont(ofSize: 13)", "fontFactory"),
        ("label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)", "fontFactory"),
        ("view.layer?.backgroundColor = Design.Surface.panel.cgColor", "frozenLayerColor"),
        ("guard alert.runModal() == .alertFirstButtonReturn else { return }", "confirmationResponse"),
        ("let ok = response == NSApplication.ModalResponse.alertSecondButtonReturn",
         "confirmationResponse"),
        // `Parser.parse` wraps a case pattern in `ExpressionPatternSyntax`, so this pins that
        // the visitor still reaches the member access inside one.
        ("switch response { case .alertThirdButtonReturn: break; default: break }",
         "confirmationResponse"),
        ("let accepted = response == ThemedAlert.firstButtonResponse", "confirmationResponse")
    ]

    for (source, expectedKind) in violations {
        let found = lint(source: source, path: path, policy: policy)
        if !found.contains(where: { $0.kind == expectedKind }) {
            fail("checker self-test missed \(expectedKind): \(source)")
        }
    }

    let allowed = [
        #"let label = NSTextField(labelWithString: "Title")"#,
        "let button = ThemedButton()",
        "let container = NSView()",
        // An OK-only alert states something; it asks nothing, so it is not a confirmation.
        "let finished = response == .OK"
    ]
    for source in allowed {
        let found = lint(source: source, path: path, policy: policy)
        if !found.isEmpty {
            fail("checker self-test rejected allowed source: \(source)")
        }
    }

    let interactivePath = "Sources/Threading/UI/Design/CheckerFixture.swift"
    let rawInteractive = """
        final class MouseOnlyControl: NSView {
            override func mouseDown(with event: NSEvent) {}
        }
        """
    if !lint(source: rawInteractive, path: interactivePath, policy: policy)
        .contains(where: { $0.kind == "interactiveComponent" }) {
        fail("checker self-test missed an interactive NSView component")
    }

    let themedInteractive = """
        final class AccessibleControl: ThemedControl {
            override func mouseDown(with event: NSEvent) {}
            override func accessibilityRole() -> NSAccessibility.Role? { .button }
            override func accessibilityPerformPress() -> Bool { true }
        }
        """
    if !lint(source: themedInteractive, path: interactivePath, policy: policy).isEmpty {
        fail("checker self-test rejected a ThemedControl interaction")
    }

    let inaccessibleControl = """
        final class MouseOnlyThemedControl: ThemedControl {
            override func mouseDown(with event: NSEvent) {}
        }
        """
    if lint(source: inaccessibleControl, path: interactivePath, policy: policy)
        .filter({ $0.kind == "accessibilityContract" }).count != 2 {
        fail("checker self-test missed a themed control without accessibility semantics")
    }

    let rawMotion = "context.duration = 0.2"
    if !lint(source: rawMotion, path: interactivePath, policy: policy)
        .contains(where: { $0.kind == "motionDuration" }) {
        fail("checker self-test missed an animation duration outside Design.Motion")
    }

    let reducedMotion = "context.duration = Design.Motion.quick"
    if !lint(source: reducedMotion, path: interactivePath, policy: policy).isEmpty {
        fail("checker self-test rejected a Design.Motion duration")
    }

    let escapingMenu = """
        final class LeakyChoice: ThemedControl {
            var menuProvider: (() -> NSMenu)?
            func selectedItem() -> NSMenuItem? { nil }
        }
        """
    let contractOffences = lint(source: escapingMenu, path: interactivePath, policy: policy)
    if contractOffences.filter({ $0.kind == "systemChromeContract" }).count != 2 {
        fail("checker self-test missed system chrome escaping a design-component contract")
    }

    let containedMenu = """
        final class SystemDropdownChoice: ThemedControl {
            private func makeMenu() -> NSMenu { NSMenu() }
            override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
            override func accessibilityPerformPress() -> Bool { true }
        }
        """
    let implementationOffences = lint(source: containedMenu, path: interactivePath, policy: policy)
    if !implementationOffences.contains(where: {
        $0.kind == "implementationType" && $0.message.contains("ThemedMenuPresenter")
    }) {
        fail("checker self-test missed private system dropdown chrome inside a design component")
    }

    let windowPath = "Sources/Threading/UI/Windows/CheckerFixture.swift"
    let rawWindow = "final class UncheckedWindow: NSWindowController {}"
    if !lint(source: rawWindow, path: windowPath, policy: policy)
        .contains(where: { $0.kind == "windowController" }) {
        fail("checker self-test missed a window outside the runtime-audited base class")
    }

    let auditedWindow = "final class CheckedWindow: ThemedWindowController {}"
    if !lint(source: auditedWindow, path: windowPath, policy: policy).isEmpty {
        fail("checker self-test rejected the runtime-audited window base class")
    }
}

verifyChecker(policy)

let sources = root.appendingPathComponent("Sources")
guard let enumerator = FileManager.default.enumerator(atPath: sources.path) else {
    fail("cannot enumerate \(sources.path)")
}

var allOffences: [Offence] = []
for case let sourceRelativePath as String in enumerator {
    let pathComponents = sourceRelativePath.split(separator: "/")
    guard !pathComponents.contains(where: { $0.hasPrefix(".") }) else { continue }

    let file = sources.appendingPathComponent(sourceRelativePath)
    guard file.pathExtension == "swift" else { continue }
    let relativePath = "Sources/\(sourceRelativePath)"
    let source: String
    do {
        source = try String(contentsOf: file, encoding: .utf8)
    } catch {
        fail("cannot read \(relativePath): \(error)")
    }

    allOffences.append(contentsOf: lint(source: source, path: relativePath, policy: policy))
}

for offence in allOffences.sorted() {
    print("\(offence.path):\(offence.line):\(offence.column): error: \(offence.message)")
}

if !allOffences.isEmpty {
    print("theme-boundary: \(allOffences.count) violation(s)")
    exit(1)
}

print("theme-boundary: clean")
