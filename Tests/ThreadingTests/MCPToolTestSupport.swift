import XCTest
@testable import Threading

func requireToolCommand(
  _ command: AgentCommand?,
  tool: MCPBuiltInTool,
  file: StaticString = #filePath,
  line: UInt = #line
) throws -> AgentCommand {
  let command = try XCTUnwrap(command, "Expected a tool call", file: file, line: line)
  XCTAssertEqual(command.builtInTool, tool, file: file, line: line)
  return command
}

func requireToolArguments<Arguments: Decodable>(
  _ command: AgentCommand?,
  tool: MCPBuiltInTool,
  as type: Arguments.Type = Arguments.self,
  file: StaticString = #filePath,
  line: UInt = #line
) throws -> Arguments {
  let command = try requireToolCommand(command, tool: tool, file: file, line: line)
  return try command.decodedArguments(as: type)
}
