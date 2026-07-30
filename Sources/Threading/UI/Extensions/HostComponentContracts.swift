import ThreadingExtensionKit

/// App-local spelling retained so existing UI code reads naturally. The declarations themselves
/// live in the Foundation-only SDK, which is now the source for runtime registration, generated
/// docs, schemas and MCP authoring tools.
typealias HostComponentContracts = ThreadingComponentCatalog
