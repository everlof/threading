import Foundation

/// An exact HTTP response fixture offered by an extension. Threading applies it only when a
/// capture explicitly names that enabled extension. No extension process runs per request.
public struct ExtensionTrafficMock: Codable, Equatable, Sendable {
    public static let maximumCount = 8
    public static let maximumBodyBytes = 4_096

    public let host: String
    public let port: Int
    public let method: String
    public let path: String
    public let status: Int
    public let headers: [String: String]
    public let body: String

    public init(host: String, port: Int, method: String, path: String, status: Int,
                headers: [String: String] = [:], body: String = "") {
        self.host = host
        self.port = port
        self.method = method
        self.path = path
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func validationIssues(path prefix: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        let hostBytes = Array(host.utf8)
        if hostBytes.isEmpty || hostBytes.count > 254 || host != host.lowercased() ||
            hostBytes.contains(where: { !((97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46) }) ||
            host.hasPrefix(".") || host.hasSuffix(".") || host.contains("..") {
            issues.append(.init(path: "\(prefix).host", message: "must be an exact lowercase DNS name without a wildcard"))
        }
        if !(1...65_535).contains(port) {
            issues.append(.init(path: "\(prefix).port", message: "must be between 1 and 65535"))
        }
        if method.isEmpty || method.utf8.count > 16 ||
            method.utf8.contains(where: { !(65...90).contains($0) }) || method == "CONNECT" {
            issues.append(.init(path: "\(prefix).method", message: "must be an uppercase HTTP method other than CONNECT"))
        }
        if !path.hasPrefix("/") || path.utf8.count > 4_096 ||
            path.utf8.contains(where: { $0 <= 32 || $0 >= 127 || $0 == 35 || $0 == 92 }) {
            issues.append(.init(path: "\(prefix).path", message: "must be an exact ASCII origin path, optionally with a query"))
        }
        if !(200...599).contains(status) || status == 204 || status == 205 || status == 304 {
            issues.append(.init(path: "\(prefix).status", message: "must be a body-capable final HTTP status"))
        }
        if body.utf8.count > Self.maximumBodyBytes || body.utf8.contains(0) ||
            (method == "HEAD" && !body.isEmpty) {
            issues.append(.init(path: "\(prefix).body", message: "must be at most 4096 UTF-8 bytes, with no NUL; HEAD has no body"))
        }
        if headers.count > 16 || headers.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) > 2_048 {
            issues.append(.init(path: "\(prefix).headers", message: "must contain at most 16 fields and 2048 bytes"))
        }
        let forbidden = Set(["connection", "content-length", "transfer-encoding", "trailer", "upgrade", "proxy-connection"])
        for (name, value) in headers {
            let validName = !name.isEmpty && name.utf8.count <= 64 && name.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
            }
            if !validName || forbidden.contains(name.lowercased()) ||
                value.utf8.contains(where: { ($0 < 32 && $0 != 9) || $0 == 127 }) {
                issues.append(.init(path: "\(prefix).headers", message: "contains an invalid or proxy-owned response header"))
                break
            }
        }
        return issues
    }
}
