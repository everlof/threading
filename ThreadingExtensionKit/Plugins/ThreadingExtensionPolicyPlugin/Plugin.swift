import PackagePlugin

@main
struct ThreadingExtensionPolicyPlugin: BuildToolPlugin {
    func createBuildCommands(
        context: PluginContext,
        target: Target
    ) async throws -> [Command] {
        guard let sourceTarget = target as? SourceModuleTarget else { return [] }

        let sources = sourceTarget.sourceFiles(withSuffix: "swift").map(\.path)
        guard !sources.isEmpty else { return [] }

        let checker = try context.tool(named: "ThreadingExtensionPolicyChecker")
        let stamp = context.pluginWorkDirectory.appending("extension-policy.stamp")

        return [
            .buildCommand(
                displayName: "Enforce safe Threading extension boundary",
                executable: checker.path,
                arguments: [stamp.string] + sources.map(\.string),
                inputFiles: sources,
                outputFiles: [stamp]
            )
        ]
    }
}
