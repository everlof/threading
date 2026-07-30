import Foundation

public struct ExtensionSourcePolicyViolation: Equatable, Sendable {
    public let path: String
    public let line: Int
    public let module: String

    public init(path: String, line: Int, module: String) {
        self.path = path
        self.line = line
        self.module = module
    }

    public var diagnostic: String {
        "\(path):\(line): error: safe Threading extensions cannot import \(module); " +
            "emit ExtensionNode values through ThreadingExtensionKit"
    }
}

public enum ExtensionSourcePolicy {
    private static let forbiddenModules = ["AppKit", "SwiftUI"]

    /// Finds direct UI-framework imports in a safe extension source file.
    ///
    /// This is cooperative build-time policy for generated extensions. It is deliberately not
    /// presented as a security parser: the out-of-process protocol is the security boundary.
    public static func violations(
        in source: String,
        path: String
    ) -> [ExtensionSourcePolicyViolation] {
        let pattern = #"(?m)^[ \t]*"# +
            #"(?:@[_A-Za-z][_A-Za-z0-9]*(?:\([^)]*\))?[ \t]+)*"# +
            #"import[ \t]+"# +
            #"(?:(?:typealias|struct|class|enum|protocol|let|var|func)[ \t]+)?"# +
            #"(AppKit|SwiftUI)\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.matches(in: source, range: fullRange).compactMap { match in
            guard let moduleRange = Range(match.range(at: 1), in: source) else { return nil }
            let module = String(source[moduleRange])
            guard forbiddenModules.contains(module) else { return nil }

            let line = source[..<moduleRange.lowerBound].reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }
            return .init(path: path, line: line, module: module)
        }
    }
}
