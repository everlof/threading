import Foundation

/// The argument decoder attached to one admitted built-in descriptor.
///
/// The concrete payload types remain ordinary `Decodable` values. This binding is what turns
/// that wire payload into the exact application command the execution side accepts.
struct MCPToolArgumentDecoding: Sendable {
  let tool: MCPBuiltInTool
  private let decodeBody:
    @Sendable (KeyedDecodingContainer<MCPToolCallParameters.CodingKeys>) throws -> AgentCommand

  init(
    tool: MCPBuiltInTool,
    decode: @escaping @Sendable (
      KeyedDecodingContainer<MCPToolCallParameters.CodingKeys>
    ) throws -> AgentCommand
  ) {
    self.tool = tool
    self.decodeBody = decode
  }

  func decode(
    from container: KeyedDecodingContainer<MCPToolCallParameters.CodingKeys>
  ) throws -> AgentCommand {
    try decodeBody(container)
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
    handler.executeBuiltIn(command, for: sessionID, completion: completion)
  }
}

/// One complete admitted built-in tool contract.
///
/// Identity, typed argument decoding, wire schema, behavior annotations, Settings/catalog
/// presentation, group membership, and application execution all meet here.
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

/// An independently auditable projection of authored declarations. Production uses one live
/// snapshot; tests can remove or duplicate a declaration and prove every consumer fails closed.
struct MCPBuiltInToolRegistrySnapshot: Sendable {
  let descriptors: [MCPBuiltInToolDescriptor]
  let issues: [String]

  init(
    declarations: [MCPToolDefinition],
    expectedTools: [MCPBuiltInTool] = MCPBuiltInTool.allCases
  ) {
    var issues: [String] = []
    var declarationsByTool: [MCPBuiltInTool: [MCPToolDefinition]] = [:]
    var declarationsByName: [String: [MCPToolDefinition]] = [:]
    for definition in declarations {
      guard let tool = definition.tool else {
        issues.append("the built-in registry contains an external definition")
        continue
      }
      declarationsByTool[tool, default: []].append(definition)
      declarationsByName[definition.name, default: []].append(definition)
    }

    var descriptors: [MCPBuiltInToolDescriptor] = []
    for (order, tool) in expectedTools.enumerated() {
      let definitions = declarationsByTool[tool] ?? []
      if definitions.count != 1 {
        issues.append(
          "\(String(describing: tool)) has \(definitions.count) declarations; expected exactly one"
        )
      }
      guard let definition = definitions.only,
        let groupID = definition.builtInGroupID,
        let family = definition.builtInFamily,
        let presentation = definition.builtInPresentation,
        let argumentDecoding = definition.argumentDecoding,
        let annotations = definition.annotations
      else {
        if definitions.count == 1 {
          issues.append(
            "\(String(describing: tool)) is missing built-in declaration metadata"
          )
        }
        continue
      }
      guard declarationsByName[definition.name]?.count == 1 else {
        issues.append("\(definition.name) is declared by more than one built-in identity")
        continue
      }

      descriptors.append(
        MCPBuiltInToolDescriptor(
          tool: tool,
          argumentDecoding: argumentDecoding,
          definition: definition,
          annotations: annotations,
          groupID: groupID,
          family: family,
          presentation: presentation,
          catalogOrder: order,
          execution: MCPToolExecutionBinding(tool: tool)
        ))
    }

    self.descriptors = descriptors
    self.issues = issues
  }

  func descriptor(for tool: MCPBuiltInTool) -> MCPBuiltInToolDescriptor? {
    descriptors.first { $0.tool == tool }
  }

  func descriptor(named name: String) -> MCPBuiltInToolDescriptor? {
    descriptors.first { $0.definition.name == name }
  }
}

/// The authoritative built-in registry. An incomplete or contradictory declaration is omitted,
/// so decoding, advertisement, enablement, catalog display, scoped access, and execution all fail
/// closed in the same way.
enum MCPBuiltInToolRegistry {
  private static let result = MCPBuiltInToolRegistrySnapshot(
    declarations: MCPTools.authoredDeclarations
  )

  static let descriptors = result.descriptors
  static let issues = result.issues

  static func descriptor(for tool: MCPBuiltInTool) -> MCPBuiltInToolDescriptor? {
    descriptors.first { $0.tool == tool }
  }

  static func descriptor(named name: String) -> MCPBuiltInToolDescriptor? {
    descriptors.first { $0.definition.name == name }
  }

  static func descriptors(inGroupID groupID: String) -> [MCPBuiltInToolDescriptor] {
    descriptors
      .filter { $0.groupID == groupID }
      .sorted { $0.catalogOrder < $1.catalogOrder }
  }

  /// Constructs a command through the same typed decoder used on the wire. This is useful to
  /// application adapters and tests that already hold an argument value; it deliberately does
  /// not provide another execution route.
  static func command<Arguments: Encodable & Sendable>(
    for tool: MCPBuiltInTool,
    arguments: Arguments
  ) throws -> AgentCommand {
    let encodedArguments = try JSONEncoder().encode(arguments)
    let argumentsValue = try JSONDecoder().decode(MCPJSONValue.self, from: encodedArguments)
    let envelope = MCPJSONValue.object([
      "name": .string(tool.rawValue),
      "arguments": argumentsValue,
    ])
    let data = try JSONEncoder().encode(envelope)
    return try JSONDecoder().decode(MCPToolCallParameters.self, from: data).call
  }

}

private extension Array {
  var only: Element? { count == 1 ? self[0] : nil }
}
