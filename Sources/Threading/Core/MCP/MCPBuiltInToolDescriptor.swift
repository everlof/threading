import Foundation

/// The argument decoder attached to one admitted built-in descriptor.
///
/// The concrete payload types remain ordinary `Decodable` values. This binding is what turns
/// that wire payload into the exact application command the execution side accepts.
struct MCPToolArgumentDecoding: Sendable {
  let tool: MCPBuiltInTool

  func decode(
    from container: KeyedDecodingContainer<MCPToolCallParameters.CodingKeys>
  ) throws -> AgentCommand {
    try tool.decodeArguments(from: container)
  }
}

/// The only built-in route from a descriptor into the application command handler.
struct MCPToolExecutionBinding: Sendable {
  let tool: MCPBuiltInTool

  @MainActor
  func execute(
    _ command: AgentCommand,
    with handler: AgentCommandHandling,
    for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  ) {
    guard command.builtInTool == tool else {
      completion(.failure("Threading refused a mismatched built-in tool binding."))
      return
    }
    handler.handle(command, for: sessionID, completion: completion)
  }
}

/// One complete admitted built-in tool contract.
///
/// Identity, typed argument decoding, wire schema, behavior annotations, Settings/catalog
/// presentation, group membership, and application execution all meet here. The underlying
/// schema and presentation literals each remain beside the large declarative catalog that owns
/// their wording, but no runtime consumer joins those lists independently.
struct MCPBuiltInToolDescriptor: Sendable {
  let tool: MCPBuiltInTool
  let argumentDecoding: MCPToolArgumentDecoding
  let definition: MCPToolDefinition
  let annotations: MCPToolAnnotations
  let groupID: String
  let family: MCPBuiltInTool.Family
  let presentation: MCPToolInfo
  let catalogOrder: Int
  let execution: MCPToolExecutionBinding
}

/// The authoritative built-in registry. An incomplete or contradictory declaration is omitted,
/// so decoding, advertisement, enablement, catalog display, scoped access, and execution all fail
/// closed in the same way.
enum MCPBuiltInToolRegistry {
  private struct PresentationRow: Sendable {
    let groupID: String
    let family: MCPBuiltInTool.Family
    let presentation: MCPToolInfo
    let order: Int
  }

  private struct BuildResult: Sendable {
    let descriptors: [MCPBuiltInToolDescriptor]
    let issues: [String]
  }

  private static let result = build()

  static let descriptors = result.descriptors
  static let issues = result.issues

  static func descriptor(for tool: MCPBuiltInTool) -> MCPBuiltInToolDescriptor? {
    descriptors.first { $0.tool == tool }
  }

  static func descriptor(named name: String) -> MCPBuiltInToolDescriptor? {
    guard let tool = MCPBuiltInTool(rawValue: name) else { return nil }
    return descriptor(for: tool)
  }

  static func descriptors(inGroupID groupID: String) -> [MCPBuiltInToolDescriptor] {
    descriptors
      .filter { $0.groupID == groupID }
      .sorted { $0.catalogOrder < $1.catalogOrder }
  }

  private static func build() -> BuildResult {
    var issues: [String] = []

    var definitionsByTool: [MCPBuiltInTool: [MCPToolDefinition]] = [:]
    for definition in MCPTools.declaredDefinitions {
      guard let tool = definition.tool else {
        issues.append("the built-in schema registry contains an external definition")
        continue
      }
      definitionsByTool[tool, default: []].append(definition)
    }

    var rowsByTool: [MCPBuiltInTool: [PresentationRow]] = [:]
    var order = 0
    for group in MCPToolCatalog.declaredGroups {
      guard let family = group.builtInFamily else {
        issues.append("the built-in catalog contains external group \(group.id)")
        continue
      }
      for presentation in group.tools {
        guard let tool = presentation.builtInTool else {
          issues.append("\(group.id) mixes built-in and external tool metadata")
          continue
        }
        rowsByTool[tool, default: []].append(
          PresentationRow(
            groupID: group.id,
            family: family,
            presentation: presentation,
            order: order
          ))
        order += 1
      }
    }

    var descriptors: [MCPBuiltInToolDescriptor] = []
    for tool in MCPBuiltInTool.allCases {
      let definitions = definitionsByTool[tool] ?? []
      let rows = rowsByTool[tool] ?? []
      if definitions.count != 1 {
        issues.append(
          "\(tool.rawValue) has \(definitions.count) schema declarations; expected exactly one"
        )
      }
      if rows.count != 1 {
        issues.append(
          "\(tool.rawValue) has \(rows.count) catalog entries; expected exactly one"
        )
      }
      guard let definition = definitions.only, let row = rows.only else { continue }
      guard row.family == tool.family else {
        issues.append(
          "\(tool.rawValue) belongs to \(tool.family.rawValue), not \(row.family.rawValue)"
        )
        continue
      }
      guard definition.name == tool.rawValue,
        definition.annotations == tool.annotations
      else {
        issues.append("\(tool.rawValue) schema identity or annotations disagree with its type")
        continue
      }

      descriptors.append(
        MCPBuiltInToolDescriptor(
          tool: tool,
          argumentDecoding: MCPToolArgumentDecoding(tool: tool),
          definition: definition,
          annotations: tool.annotations,
          groupID: row.groupID,
          family: row.family,
          presentation: row.presentation,
          catalogOrder: row.order,
          execution: MCPToolExecutionBinding(tool: tool)
        ))
    }

    return BuildResult(descriptors: descriptors, issues: issues)
  }
}

private extension Array {
  var only: Element? { count == 1 ? self[0] : nil }
}
