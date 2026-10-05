import Foundation

struct BrowserTabsPayload: Encodable {
  struct Viewport: Encodable {
    let width: Int
    let height: Int
  }

  struct Tab: Encodable {
    let index: Int
    let id: String
    let title: String
    let url: String?
    let active: Bool
    let restricted: Bool
    let popupDepth: Int
    let viewport: Viewport?
    let colorScheme: String
    let userAgent: String?
    let mediaType: String
    let context: String

    private enum CodingKeys: String, CodingKey {
      case index, id, title, url, active, restricted, viewport, context
      case popupDepth = "popup_depth"
      case colorScheme = "color_scheme"
      case userAgent = "user_agent"
      case mediaType = "media_type"
    }
  }

  let count: Int
  let tabs: [Tab]
}

struct BrowserCapabilitiesPayload: Encodable {
  struct ActiveTab: Encodable {
    let backend: String
    let context: String
    let viewport: BrowserTabsPayload.Viewport?
    let colorScheme: String
    let userAgent: String?
    let mediaType: String

    private enum CodingKeys: String, CodingKey {
      case backend, context, viewport
      case colorScheme = "color_scheme"
      case userAgent = "user_agent"
      case mediaType = "media_type"
    }
  }

  struct Backend: Encodable {
    let id: String
    let status: String
    let engine: String
    let intendedUse: String
    let contexts: [String]
    let emulation: [String: Bool]
    let automation: [String: Bool]
    let limits: [String]

    private enum CodingKeys: String, CodingKey {
      case id, status, engine, contexts, emulation, automation, limits
      case intendedUse = "intended_use"
    }
  }

  /// Whether `browser_fill_credentials` can do anything on this machine, so an agent can find
  /// out before it asks rather than discovering it through a refusal.
  ///
  /// It reports the *provider* and whether the vault holds anything at all — never which origins
  /// have entries, which would let a page enumerate where the user keeps test accounts.
  struct SignIn: Encodable {
    let provider: String
    let fillsWithoutUser: Bool
    let hasStoredCredentials: Bool
    let vaultReachableFromShell: Bool

    private enum CodingKeys: String, CodingKey {
      case provider
      case fillsWithoutUser = "fills_without_user"
      case hasStoredCredentials = "has_stored_credentials"
      case vaultReachableFromShell = "vault_reachable_from_shell"
    }
  }

  let schemaVersion: Int
  let defaultBackend: String
  let activeTab: ActiveTab?
  let signIn: SignIn
  let backends: [Backend]
  var networkCapture: BrowserNetworkCaptureOptions = .metadataOnly

  private enum CodingKeys: String, CodingKey {
    case backends
    case schemaVersion = "schema_version"
    case defaultBackend = "default_backend"
    case activeTab = "active_tab"
    case signIn = "sign_in"
    case networkCapture = "network_capture"
  }
}
