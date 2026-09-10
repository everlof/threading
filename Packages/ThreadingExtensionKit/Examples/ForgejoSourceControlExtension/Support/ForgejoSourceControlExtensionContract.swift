import ThreadingExtensionKit

public enum ForgejoSourceControlExtensionContract {
    public static let provider = ExtensionSourceControlProviderDefinition(
        id: "forgejo",
        displayName: "Forgejo",
        changeRequestName: "pull request",
        changeRequestPluralName: "pull requests",
        apiPathPrefix: "/api/v1",
        authenticationKinds: [.authorizationToken, .none],
        reportsChecks: true,
        reportsApprovals: true,
        reportsChangesRequested: true
    )

    public static let manifest = ExtensionManifest(
        identifier: "codes.threading.forgejo-source-control",
        name: "Forgejo Source Control",
        version: "0.1.0",
        runtime: .webAssembly,
        executable: "bin/forgejo-source-control.wasm",
        capabilities: [.sourceControlRead],
        sourceControlProviders: [provider]
    )

    public static let registration = ExtensionRegistration(
        sourceControlProviders: [provider]
    )
}

public enum ForgejoSourceControlLimits {
    public static let maximumPageItems = 50
    public static let maximumProtocolLineBytes = 1_048_576
}
