import Foundation

/// The supported safe-extension contract shipped by SkalmanExtensionKit SDK snapshot 1.
///
/// These values are deliberately separate from an extension's own package version and
/// `dataVersion`. See `docs/extensions/API_V1.md` for the compatibility rules attached to each
/// version domain.
public enum SkalmanExtensionAPI {
    public static let majorVersion = 1
    public static let sdkVersion = 1
    public static let manifestFormatVersion = ExtensionManifest.currentFormatVersion
    public static let processProtocolVersion = ExtensionCommandRequest.currentProtocolVersion
    public static let hostProtocolVersion =
        ExtensionComponentPatchPublication.currentProtocolVersion
    public static let companionProtocolVersion = SkalmanCompanionAPI.protocolVersion
    public static let remoteSurfaceProtocolVersion =
        ExtensionRemoteSurfaceMessage.currentProtocolVersion
    public static let componentCatalogFormatVersion =
        ExtensionComponentCatalogDocument.currentFormatVersion
    public static let safeRuntime = ExtensionRuntime.webAssembly

    /// Authorities implemented for WebAssembly extensions in safe API v1.
    ///
    /// `network.client` intentionally does not appear here. It remains decodable for legacy
    /// native format-1 packages, but the WebAssembly guest has no socket import; a future safe
    /// network broker must be versioned and added explicitly.
    public static let safeCapabilities: Set<ExtensionCapability> = [
        .commands,
        .panels,
        .mcpTools,
        .settings,
        .servicesProvide,
        .servicesConsume,
        .companionOperations,
        .componentCustomization,
        .customMetalSurfaces,
        .hostProjectsRead,
        .hostSessionsRead,
        .hostSessionRuntimeRead,
        .hostRepositoriesRead,
        .hostProvidersRead,
        .hostAccountsPresentationRead,
        .hostEvents,
        .providerIconResolver,
        .accountIconResolver,
        .sessionIdentityRenderer,
        // Data-plane contributions: the package carries documents and font files the host
        // reads itself. No new authority reaches the running guest, which is why they are
        // safe — the code never sees a broker call for either.
        .themeProvider,
        .fontProvider,
        .keyValueStorage,
        .cacheStorage,
        .secrets
    ]

    /// The component contracts frozen with SDK v1. A component evolves by adding a new contract
    /// version; an existing version is never silently reinterpreted.
    public static let componentContractVersions: [ExtensionComponentID: Int] =
        Dictionary(uniqueKeysWithValues: SkalmanComponentCatalog.all.map {
            ($0.id, $0.version)
        })
}
