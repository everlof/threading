import Foundation

/// Wire names shared by the app registry and portable transcript projection.
enum MCPToolNaming {
    static let serverName = "threading"
    static let displayChart = "display_chart"
    static func allowedToolName(_ tool: String) -> String { "mcp__\(serverName)__\(tool)" }
}
