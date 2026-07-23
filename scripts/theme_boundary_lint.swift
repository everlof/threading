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
    let systemColors: Set<String>
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
        if policy.bannedTypes[target] != nil {
            aliases[node.name.text] = target
            report(
                node: node,
                kind: "alias",
                symbol: target,
                message: "typealias \(node.name.text) hides banned AppKit type \(target); "
                    + "use \(policy.bannedTypes[target] ?? "its UI/Design replacement") directly"
            )
        }
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if let inherited = node.inheritanceClause?.inheritedTypes {
            for item in inherited {
                let written = terminalTypeName(item.type.trimmedDescription)
                let resolved = aliases[written] ?? written
                guard policy.bannedTypes[resolved] != nil else { continue }
                report(
                    node: item.type,
                    kind: "inherit",
                    symbol: resolved,
                    message: "subclassing \(resolved) bypasses the themed boundary; "
                        + "subclass \(policy.bannedTypes[resolved] ?? "its UI/Design replacement") instead"
                )
            }
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

            if memberName == "init" {
                checkConstruction(writtenName: baseName, firstArgumentLabel: arguments.first?.label?.text, node: node)
            } else if policy.bannedTypes[memberName] != nil {
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
        guard policy.bannedTypes[resolved] != nil else { return .visitChildren }
        report(
            node: call,
            kind: "construct",
            symbol: resolved,
            message: "inferred .init() constructs \(resolved); use "
                + (policy.bannedTypes[resolved] ?? "its UI/Design replacement")
        )
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let member = node.declName.baseName.text
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
        guard right.contains(".cgColor") else { return .visitChildren }

        let properties = ["backgroundColor", "borderColor", "shadowColor", "strokeColor", "fillColor"]
        guard let property = properties.first(where: { left.hasSuffix(".\($0)") }) else {
            return .visitChildren
        }

        report(
            node: node,
            kind: "frozenLayerColor",
            symbol: property,
            message: "\(property) stores a frozen CGColor; use the refresh-aware NSView layer-colour helper"
        )
        return .visitChildren
    }

    private func checkConstruction(
        writtenName: String,
        firstArgumentLabel: String?,
        node: some SyntaxProtocol
    ) {
        let name = aliases[writtenName] ?? terminalTypeName(writtenName)
        guard let replacement = policy.bannedTypes[name] else { return }
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
        ("view.layer?.backgroundColor = Design.Surface.panel.cgColor", "frozenLayerColor")
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
        "let container = NSView()"
    ]
    for source in allowed {
        let found = lint(source: source, path: path, policy: policy)
        if !found.isEmpty {
            fail("checker self-test rejected allowed source: \(source)")
        }
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
