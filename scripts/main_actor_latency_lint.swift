import Foundation
import SwiftParser
import SwiftSyntax

struct Policy: Decodable {
    struct GlobalLimit: Decodable {
        let symbol: String
        let maximum: Int
        let reason: String
    }

    let globalLimits: [GlobalLimit]
}

struct Finding: Hashable, Comparable {
    let path: String
    let context: String
    let symbol: String
    let line: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.path, lhs.context, lhs.symbol, lhs.line)
            < (rhs.path, rhs.context, rhs.symbol, rhs.line)
    }
}

private let blockingMembers: Set<String> = [
    "attributesOfItem", "contentsOfDirectory", "copyItem", "createDirectory",
    "fileExists", "moveItem", "removeItem", "replaceItemAt", "resourceValues",
    "resolvingSymlinksInPath", "synchronize", "waitUntilExit"
]

private let readMembers: Set<String> = [
    "availableData", "readDataToEndOfFile", "readToEnd"
]

private let mainActorBaseTypes: Set<String> = [
    "NSApplication", "NSApplicationDelegate", "NSCollectionView", "NSControl",
    "NSDocument", "NSMenu", "NSResponder", "NSTableView", "NSTextView", "NSView",
    "NSViewController", "NSWindow", "NSWindowController", "UIApplicationDelegate",
    "UICollectionView", "UIControl", "UIResponder", "UITableView", "UITextView", "UIView",
    "UIViewController", "UIWindow"
]

final class LatencyVisitor: SyntaxVisitor {
    private let path: String
    private let converter: SourceLocationConverter
    private let mainActorTypes: Set<String>
    private(set) var findings: [Finding] = []

    init(path: String, tree: SourceFileSyntax, mainActorTypes: Set<String>) {
        self.path = path
        converter = SourceLocationConverter(fileName: path, tree: tree)
        self.mainActorTypes = mainActorTypes
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard isMainActorContext(Syntax(node)) else { return .visitChildren }

        let labels = node.arguments.map { ($0.label?.text ?? "_") + ":" }.joined()
        if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.text
            if isExpensiveInitializer(name: name, labels: labels) {
                report(node, symbol: "\(name)(\(labels))")
            }
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            let base = member.base?.trimmedDescription ?? ""
            if isExpensiveMember(name: name, base: base, labels: labels) {
                report(node, symbol: normalizedSymbol(name: name, labels: labels))
            }
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard isMainActorContext(Syntax(node)), readMembers.contains(node.declName.baseName.text)
        else { return .visitChildren }
        report(node, symbol: node.declName.baseName.text)
        return .visitChildren
    }

    private func isExpensiveInitializer(name: String, labels: String) -> Bool {
        guard labels.contains("contentsOf:") || labels.contains("data:") else { return false }
        return ["Data", "NSData", "NSImage", "NSBitmapImageRep", "String"].contains(name)
    }

    private func isExpensiveMember(name: String, base: String, labels: String) -> Bool {
        // `moveItem(at:inParent:to:inParent:)` is also an in-memory sidebar-tree operation.
        // FileManager's potentially blocking overload has exactly the two URL labels below.
        if name == "moveItem" { return labels == "at:to:" }
        if blockingMembers.contains(name) { return true }
        if name == "encode" || name == "decode" || name == "representation" { return true }
        if (name == "data" || name == "jsonObject"),
           base.split(separator: ".").last.map(String.init) == "JSONSerialization" {
            return true
        }
        if name == "sync" { return true }
        if name == "write",
           labels == "to:" || labels == "to:options:" || labels == "contentsOf:"
                || labels == "to:atomically:encoding:" {
            return true
        }
        if name == "init", labels.contains("contentsOf:") || labels.contains("data:") {
            return ["Data", "NSData", "NSImage", "NSBitmapImageRep", "String"]
                .contains(base.split(separator: ".").last.map(String.init) ?? base)
        }
        return false
    }

    private func normalizedSymbol(name: String, labels: String) -> String {
        switch name {
        case "attributesOfItem", "contentsOfDirectory", "copyItem", "createDirectory",
             "fileExists", "moveItem", "removeItem", "replaceItemAt":
            return "FileManager.\(name)(\(labels))"
        case "resourceValues", "resolvingSymlinksInPath":
            return "URL.\(name)(\(labels))"
        case "data", "jsonObject":
            return "JSONSerialization.\(name)(\(labels))"
        case "encode": return "Encoder.encode(\(labels))"
        case "decode": return "Decoder.decode(\(labels))"
        case "sync": return "DispatchQueue.sync(\(labels))"
        case "write": return "write(\(labels))"
        default: return "\(name)(\(labels))"
        }
    }

    private func isMainActorContext(_ syntax: Syntax) -> Bool {
        var current: Syntax? = syntax
        while let node = current {
            if let closure = node.as(ClosureExprSyntax.self), isWorkerClosure(closure) {
                return false
            }
            if let function = node.as(FunctionDeclSyntax.self) {
                if isNonisolated(function.modifiers) { return false }
                if hasMainActor(function.attributes) { return true }
            }
            if let initializer = node.as(InitializerDeclSyntax.self) {
                if isNonisolated(initializer.modifiers) { return false }
                if hasMainActor(initializer.attributes) { return true }
            }
            if let classDecl = node.as(ClassDeclSyntax.self) {
                if hasMainActor(classDecl.attributes) || mainActorTypes.contains(classDecl.name.text) {
                    return true
                }
            }
            if let structDecl = node.as(StructDeclSyntax.self),
               hasMainActor(structDecl.attributes) || mainActorTypes.contains(structDecl.name.text) {
                return true
            }
            if let enumDecl = node.as(EnumDeclSyntax.self),
               hasMainActor(enumDecl.attributes) || mainActorTypes.contains(enumDecl.name.text) {
                return true
            }
            if let extensionDecl = node.as(ExtensionDeclSyntax.self) {
                let terminal = extensionDecl.extendedType.trimmedDescription
                    .split(separator: ".").last.map(String.init)
                if hasMainActor(extensionDecl.attributes)
                    || terminal.map(mainActorTypes.contains) == true {
                    return true
                }
            }
            current = node.parent
        }
        return false
    }

    private func isWorkerClosure(_ closure: ClosureExprSyntax) -> Bool {
        var current = Syntax(closure).parent
        while let node = current {
            if let call = node.as(FunctionCallExprSyntax.self) {
                let callee = call.calledExpression.trimmedDescription
                if callee.contains("DispatchQueue.main") { return false }
                return callee.hasSuffix(".async")
                    || callee == "Task.detached"
                    || callee.hasSuffix(".detached")
            }
            if node.is(CodeBlockItemSyntax.self) { return false }
            current = node.parent
        }
        return false
    }

    private func hasMainActor(_ attributes: AttributeListSyntax) -> Bool {
        attributes.contains { element in
            guard case .attribute(let attribute) = element else { return false }
            return attribute.attributeName.trimmedDescription == "MainActor"
        }
    }

    private func isNonisolated(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.text == "nonisolated" }
    }

    private func report(_ node: some SyntaxProtocol, symbol: String) {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        findings.append(Finding(
            path: path,
            context: context(of: Syntax(node)),
            symbol: symbol,
            line: location.line
        ))
    }

    private func context(of syntax: Syntax) -> String {
        var names: [String] = []
        var current = syntax.parent
        while let node = current {
            if let function = node.as(FunctionDeclSyntax.self) { names.append(function.name.text) }
            else if node.is(InitializerDeclSyntax.self) { names.append("init") }
            else if let classDecl = node.as(ClassDeclSyntax.self) { names.append(classDecl.name.text) }
            else if let structDecl = node.as(StructDeclSyntax.self) { names.append(structDecl.name.text) }
            else if let enumDecl = node.as(EnumDeclSyntax.self) { names.append(enumDecl.name.text) }
            else if let extensionDecl = node.as(ExtensionDeclSyntax.self) {
                names.append(extensionDecl.extendedType.trimmedDescription)
            }
            current = node.parent
        }
        return names.reversed().joined(separator: ".")
    }
}

/// Swift's isolation is transitive through base classes and global-actor protocols, while feature
/// implementations often live in separate `Type+Feature.swift` extensions. Collecting the type
/// graph before scanning calls keeps those extensions from becoming an accidental escape hatch.
final class MainActorTypeCollector: SyntaxVisitor {
    private(set) var explicitTypes: Set<String> = []
    private(set) var inheritances: [String: Set<String>] = [:]

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        collect(
            name: node.name.text,
            attributes: node.attributes,
            inheritance: node.inheritanceClause
        )
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        collect(
            name: node.name.text,
            attributes: node.attributes,
            inheritance: node.inheritanceClause
        )
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        collect(
            name: node.name.text,
            attributes: node.attributes,
            inheritance: node.inheritanceClause
        )
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        collect(
            name: node.name.text,
            attributes: node.attributes,
            inheritance: node.inheritanceClause
        )
        return .visitChildren
    }

    private func collect(
        name: String,
        attributes: AttributeListSyntax,
        inheritance: InheritanceClauseSyntax?
    ) {
        if attributes.contains(where: { element in
            guard case .attribute(let attribute) = element else { return false }
            return attribute.attributeName.trimmedDescription == "MainActor"
        }) {
            explicitTypes.insert(name)
        }
        guard let inheritance else { return }
        let inherited = inheritance.inheritedTypes.compactMap { inherited -> String? in
            inherited.type.trimmedDescription.split(separator: ".").last.map(String.init)
        }
        inheritances[name, default: []].formUnion(inherited)
    }
}

func swiftFiles(in repository: URL) -> [URL] {
    let manager = FileManager.default
    var relativeRoots = ["Sources/Threading", "Sources/ThreadingMobile"]
    let packages = repository.appendingPathComponent("Packages", isDirectory: true)
    if let packageDirectories = try? manager.contentsOfDirectory(
        at: packages,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) {
        relativeRoots.append(contentsOf: packageDirectories.compactMap { package -> String? in
            guard package.lastPathComponent != "Vendor" else { return nil }
            let sources = package.appendingPathComponent("Sources", isDirectory: true)
            guard manager.fileExists(atPath: sources.path) else { return nil }
            return sources.path.replacingOccurrences(of: repository.path + "/", with: "")
        })
    }
    let roots = relativeRoots.map {
        repository.appendingPathComponent($0, isDirectory: true)
    }
    return roots.flatMap { root -> [URL] in
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }.sorted { $0.path < $1.path }
}

func mainActorTypes(in sources: [String]) -> Set<String> {
    let lock = NSLock()
    var explicitTypes: Set<String> = []
    var inheritances: [String: Set<String>] = [:]
    DispatchQueue.concurrentPerform(iterations: sources.count) { index in
        let collector = MainActorTypeCollector(viewMode: .sourceAccurate)
        collector.walk(Parser.parse(source: sources[index]))
        lock.lock()
        explicitTypes.formUnion(collector.explicitTypes)
        for (name, inherited) in collector.inheritances {
            inheritances[name, default: []].formUnion(inherited)
        }
        lock.unlock()
    }

    var types = mainActorBaseTypes
    types.formUnion(explicitTypes)
    var changed = true
    while changed {
        changed = false
        for (name, inherited) in inheritances where !types.contains(name) {
            if !types.isDisjoint(with: inherited) {
                types.insert(name)
                changed = true
            }
        }
    }
    return types
}

func inspect(source: String, path: String, mainActorTypes: Set<String>) -> [Finding] {
    let tree = Parser.parse(source: source)
    let visitor = LatencyVisitor(path: path, tree: tree, mainActorTypes: mainActorTypes)
    visitor.walk(tree)
    return visitor.findings
}

func runSelfTest() -> Bool {
    let fixtures: [(String, Int)] = [
        ("@MainActor final class C { func load() { _ = Data(contentsOf: URL(fileURLWithPath: \"/x\")) } }", 1),
        ("@MainActor final class C { func load() { queue.async { _ = Data(contentsOf: url) } } }", 0),
        ("@MainActor final class C { nonisolated func load() { _ = Data(contentsOf: url) } }", 0),
        ("final class C: NSViewController { func load() { _ = FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) } }", 1),
        ("@MainActor class Base {} final class C: Base {} extension C { func load() { _ = Data(contentsOf: url) } }", 1),
        ("final class C { func load() { _ = Data(contentsOf: url) } }", 0)
    ]
    for (index, fixture) in fixtures.enumerated() {
        let actorTypes = mainActorTypes(in: [fixture.0])
        let actual = inspect(
            source: fixture.0,
            path: "self-test-\(index).swift",
            mainActorTypes: actorTypes
        ).count
        if actual != fixture.1 {
            fputs("main-actor-latency self-test \(index) expected \(fixture.1), found \(actual)\n", stderr)
            return false
        }
    }
    print("main-actor-latency: self-test passed")
    return true
}

guard CommandLine.arguments.count == 3 || CommandLine.arguments.count == 4 else {
    fputs("usage: main-actor-latency-lint REPOSITORY POLICY.json [--inventory]\n", stderr)
    exit(2)
}

let repository = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let policyURL = URL(fileURLWithPath: CommandLine.arguments[2])
let policy = try JSONDecoder().decode(Policy.self, from: Data(contentsOf: policyURL))
if CommandLine.arguments.last == "--self-test" {
    exit(runSelfTest() ? 0 : 1)
}
let sourceFiles = try swiftFiles(in: repository).map { file in
    (file, try String(contentsOf: file, encoding: .utf8))
}
let actorTypes = mainActorTypes(in: sourceFiles.map(\.1))
let findingsLock = NSLock()
var findings: [Finding] = []
DispatchQueue.concurrentPerform(iterations: sourceFiles.count) { index in
    let (file, source) = sourceFiles[index]
    let path = file.path.replacingOccurrences(of: repository.path + "/", with: "")
    let inspected = inspect(
        source: source,
        path: path,
        mainActorTypes: actorTypes
    )
    findingsLock.lock()
    findings.append(contentsOf: inspected)
    findingsLock.unlock()
}

let findingsBySymbol = Dictionary(grouping: findings, by: \.symbol)
if CommandLine.arguments.last == "--inventory" {
    for (symbol, matches) in findingsBySymbol.sorted(by: { $0.key < $1.key }) {
        print("\(symbol)\t\(matches.count)")
    }
    exit(0)
}

let globalLimits = Dictionary(uniqueKeysWithValues: policy.globalLimits.map { ($0.symbol, $0) })
var failed = false
for (symbol, matches) in findingsBySymbol.sorted(by: { $0.key < $1.key }) {
    let maximum = globalLimits[symbol]?.maximum ?? 0
    guard matches.count > maximum else { continue }
    failed = true
    for finding in matches.sorted().dropFirst(maximum) {
        print("\(finding.path):\(finding.line): error: synchronous \(finding.symbol) in main-actor context \(finding.context)")
    }
}

if failed {
    fputs("main-actor-latency: move file access, JSON/image encoding, blocking waits and queue.sync to a bounded worker; return only Sendable results to the main actor\n", stderr)
    exit(1)
}
print("main-actor-latency: clean (\(findings.count) audited call(s), \(policy.globalLimits.count) API ratchet(s))")
